defmodule Newbee.DEE.Kernel do
  @moduledoc """
  主循环 (DESIGN §4.1)：组装 prompt → LLM → run_elixir → 压缩回填 → 循环，
  直到 done / ask / 无工具调用。每轮事件通过 render 回调流出。
  """
  use GenServer

  defstruct messages: [], client: nil, evaluator: nil, render: nil,
            client_fun: nil, usage: %{}, steps: 0, session: nil, progress: nil,
            goal: nil

  # ── API ──

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "提交一段用户输入，同步执行整个 turn，返回 {:done, summary} | {:ask, q} | {:text, body} | {:error, e}"
  def submit(kernel, text), do: GenServer.call(kernel, {:submit, text}, :infinity)
  @doc "设定自主目标（/goal）：注入目标并异步启动自主循环，直到达成/取消/达上限。"
  def set_goal(kernel, text, opts \\ []), do: GenServer.call(kernel, {:set_goal, text, opts}, :infinity)

  @doc "清除自主目标（/goal clear）。"
  def clear_goal(kernel), do: GenServer.call(kernel, :clear_goal)

  @doc "查询自主目标状态：nil | %{text, rounds, max_rounds, idle}。"
  def goal(kernel), do: GenServer.call(kernel, :goal)


  def usage(kernel), do: GenServer.call(kernel, :usage)

  # ── init ──

  @impl true
  def init(opts) do
    client = Keyword.fetch!(opts, :client)
    render = Keyword.get(opts, :render, fn _ -> :ok end)
    evaluator = Keyword.get(opts, :evaluator, Newbee.DEE.Evaluator)

    client_fun =
      Keyword.get(opts, :client_fun, fn messages, on_text, on_reasoning ->
        Newbee.LLM.Client.stream_chat(client, messages, on_text, on_reasoning)
      end)

    # 进度监控（LLM-as-a-Verifier 落地）：每 every 步对轨迹前缀打连续分，
    # 停滞时注入干预提醒。client 默认走 model.json 的 verifier role（无则回退 default）。
    progress =
      case Keyword.get(opts, :progress, false) do
        false -> nil
        p when is_map(p) or is_list(p) ->
          %{
            client: Map.get(p, :client) || Newbee.LLM.Config.client_for("verifier"),
            every: Map.get(p, :every, 5),
            scale: Map.get(p, :scale, :letters),
            window: Map.get(p, :window, 5),
            min_steps: Map.get(p, :min_steps, 3),
            threshold: Map.get(p, :threshold, 0.0),
            complete_fn: Map.get(p, :complete_fn),
            final_check: Map.get(p, :final_check, false),
            done_threshold: Map.get(p, :done_threshold, 12),
            final_checked: false,
            final_score: nil,
            scores: [],
            injected: false
          }
      end

    session =
      if Keyword.get(opts, :session, true) do
        s = Newbee.Session.open(Keyword.get(opts, :session_id))
        prior = s |> Newbee.Session.messages() |> repair_history()
        {s, prior}
      else
        {nil, []}
      end

    {session, prior_messages} = session

    # 恢复会话：消息已载入，绑定灌回求值器（tombstone 项自然跳过）
    if session && prior_messages != [] do
      bindings = Newbee.Session.load_bindings(session)

      if bindings != [] do
        Newbee.DEE.Evaluator.restore_bindings(evaluator, bindings)
      end
    end

    prompt =
      case session do
        nil -> system_prompt()
        session -> Newbee.Session.system_prompt(session) || Newbee.Session.save_system_prompt(session, system_prompt())
      end

    # 同一 session 的 system prompt 是请求头：首次生成后持久化，恢复时逐字复用。
    # 历史消息只追加，因而后续请求可作为上一次请求的 provider cache prefix extension。
    {:ok,
     %__MODULE__{
       messages: [%{"role" => "system", "content" => prompt}] ++ prior_messages,
       client: client,
       evaluator: evaluator,
       render: render,
       client_fun: client_fun,
       session: session,
       progress: progress
     }}
  end

  @impl true
  def handle_call({:submit, text}, _from, state) do
    # 注意：不能在回合开始清中断标志——execute_calls 阶段的中断检查依赖它。
    t0 = :erlang.monotonic_time(:millisecond)
    Newbee.DebugLog.log(:submit, "start text=#{String.slice(text, 0, 120) |> inspect()}")
    state = push_msg(state, %{"role" => "user", "content" => text})
    {reply, state} = run_turn(state, 1)
    {reply, state} = after_turn(reply, state)
    # 回合出口统一清标志：消费过的/残留的都不带进下一轮
    Newbee.LLM.Client.clear_interrupt()
    persist_bindings(state)
    ms = :erlang.monotonic_time(:millisecond) - t0
    Newbee.DebugLog.log(:submit, "done in #{ms}ms reply=#{elem(reply, 0)}")
    emit(state, {:turn_end, elem(reply, 0), ms})
    # 同步屏障：本回合所有 Bus 广播都是 cast（异步）。测试用 assert_received
    # （0 超时）要求事件在 submit 返回前已送达订阅者信箱——借 subscribers 的
    # 同步调用按 FIFO 排空本进程先前的 cast。
    flush_bus()
    {:reply, reply, state}
  end

  def handle_call(:usage, _from, state), do: {:reply, state.usage, state}
  def handle_call({:set_goal, text, opts}, _from, state) do
    text = String.trim(text)
    max_rounds = Keyword.get(opts, :max_rounds, 50)

    if text == "" do
      {:reply, {:error, :empty_goal}, state}
    else
      state =
        state
        |> push_msg(%{"role" => "system", "content" => goal_system_prompt(text)})
        |> push_msg(%{"role" => "user", "content" => "（自主目标模式启动）目标：#{text}\n请开始自主工作，直到达成目标。"})

      goal = %{text: text, rounds: 0, max_rounds: max_rounds, idle: 0, msg_len: length(state.messages)}
      emit(state, {:goal_start, text})
      send(self(), :goal_next)
      {:reply, :ok, %{state | goal: goal}}
    end
  end

  def handle_call(:clear_goal, _from, state) do
    if state.goal, do: emit(state, {:goal_cancelled, :user})
    {:reply, :ok, %{state | goal: nil}}
  end

  def handle_call(:goal, _from, state), do: {:reply, state.goal, state}

  # 自主目标循环：异步驱动（每轮之间可处理 mailbox，/goal clear 可插入取消）。
  @impl true
  def handle_info(:goal_next, state) do
    if state.goal do
      {reply, state} = run_turn(state, 1)
      {_reply, state} = after_turn(reply, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  rescue
    e ->
      Newbee.DebugLog.log(:goal, "goal loop crashed: #{inspect(e)}")
      emit(state, {:goal_cancelled, :crash})
      {:noreply, %{state | goal: nil}}
  end

  # ── 自主目标（/goal）：turn 出口统一处理 ──

  # 非目标模式：原样返回
  defp after_turn(reply, %{goal: nil} = state), do: {reply, state}

  # 目标模式：模型以纯文本结束 → 自动开始下一轮（轮数上限 + 停滞提醒保护）
  defp after_turn({:text, content}, state) do
    g = state.goal
    added = Enum.slice(state.messages, g.msg_len..-1//1)
    idle = if Enum.any?(added, &(&1["role"] == "tool")), do: 0, else: g.idle + 1
    rounds = g.rounds + 1
    state = %{state | goal: %{g | rounds: rounds, idle: idle}}

    if rounds >= g.max_rounds do
      emit(state, {:goal_limit, g.max_rounds})
      {{:goal_limit, g.max_rounds}, %{state | goal: nil}}
    else
      emit(state, {:goal_round, rounds})

      state =
        if idle >= 3 do
          push_msg(state, %{"role" => "system", "content" => goal_idle_reminder(rounds)})
          |> then(fn s -> %{s | goal: %{s.goal | idle: 0}} end)
        else
          state
        end

      state =
        push_msg(state, %{"role" => "system", "content" => goal_continue_msg(rounds)})
        |> then(fn s -> %{s | goal: %{s.goal | msg_len: length(s.messages)}} end)

      send(self(), :goal_next)
      {{:text, content}, state}
    end
  end

  defp after_turn({:done, summary}, state) do
    emit(state, {:goal_done, summary})
    {{:done, summary}, %{state | goal: nil}}
  end

  defp after_turn({:ask, question}, state) do
    # 目标保留：用户回答后的 submit 出口会自动续跑
    emit(state, {:goal_ask, question})
    {{:ask, question}, state}
  end

  defp after_turn({:interrupted, content}, state) do
    emit(state, {:goal_cancelled, :interrupted})
    {{:interrupted, content}, %{state | goal: nil}}
  end

  defp after_turn({:error, e}, state) do
    emit(state, {:goal_cancelled, :error})
    {{:error, e}, %{state | goal: nil}}
  end

  defp goal_system_prompt(text) do
    """
    [自主目标模式] 你被赋予一个明确的完成目标，需要自主、持续地工作直到达成。

    目标：#{text}

    工作纪律：
    - 持续工作：一轮结束后若目标未达成，系统会自动开启下一轮，无需等待用户。
    - 每轮要有实质进展：运行代码、跑测试、修改文件、验证结果。
    - 达成目标后：调用 done 工具，附上完成总结（做了什么、如何验证）。
    - 未达成前不要调用 done，也不要仅用文字结束回合。
    - 确实需要用户决策时用 ask；能自主解决的就自主解决。
    """
  end

  defp goal_continue_msg(round) do
    "（自主模式第 #{round} 轮：目标未确认达成，请继续工作。达成后调用 done 并附总结。）"
  end

  defp goal_idle_reminder(round) do
    "（自主模式第 #{round} 轮：你已连续多轮没有调用工具、没有实质进展。" <>
      "请立即采取行动：检查/运行/修改/验证。若目标已达成请调用 done。）"
  end

  # ── turn 循环 ──

  # 步数不设硬上限（§8 放行+审计：硬杀会误伤长任务，如自改代码）。
  # 失控保护 = 每 25 步审计告警（事件流可见，用户可 Ctrl-C）。
  defp run_turn(state, step) do
    if rem(step, 25) == 0 do
      Newbee.DebugLog.log(:turn, "step #{step}: long turn (uncapped, audited)")
      emit(state, {:turn_long, step})
    end
    Newbee.DebugLog.log(:turn, "step #{step} messages=#{length(state.messages)}")
    on_text = fn delta -> emit(state, {:text, delta}) end
    on_reasoning = fn delta -> emit(state, {:reasoning, delta}) end

    case call_client(state.client_fun, state.messages, on_text, on_reasoning) do
      {:ok, msg, usage} ->
        Newbee.DebugLog.log(:turn, "step #{step} llm ok calls=#{length(msg["tool_calls"] || [])}")
        emit(state, {:usage, usage})
        state = %{push_msg(state, msg) | usage: merge_usage(state.usage, usage)}

        case Newbee.Codec.extract_tool_calls(msg) do
          [] ->
            Newbee.DebugLog.log(:turn, "step #{step} no tool calls, turn end")
            {{:text, msg["content"]}, state}

          calls ->
            case execute_calls(calls, state) do
              {:halt, reply, state} -> {reply, state}
              {:cont, state} -> run_turn(state, step + 1)
            end
        end

      {:interrupted, content} ->
        # Esc 中断：终止整个 turn（部分生成的 assistant 消息不入历史，
        # 避免悬空 tool_calls 触发 DeepSeek 400）
        Newbee.DebugLog.log(:turn, "step #{step} interrupted")
        emit(state, {:interrupted, content})
        {{:interrupted, content}, state}

      {:error, e} ->
        Newbee.DebugLog.log(:turn, "step #{step} llm error #{inspect(e)}")
        emit(state, {:error, e})
        {{:error, e}, state}
    end
  end

  defp call_client(fun, messages, on_text, on_reasoning) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 3} -> fun.(messages, on_text, on_reasoning)
      {:arity, 2} -> fun.(messages, on_text)
    end
  end

  defp execute_calls(calls, state) do
    Enum.reduce_while(calls, {:cont, state}, fn call, {:cont, state} ->
      if Newbee.LLM.Client.interrupted?() do
        # Esc 中断发生在工具执行阶段：不再发起下一个工具调用
        {:halt, {:halt, {:interrupted, nil}, state}}
      else
        t0 = System.monotonic_time(:millisecond)
      Newbee.DebugLog.log(:tool, "start #{call.name} id=#{call.id} args=#{String.slice(inspect(call.args), 0, 200)}")

      result =
        case call.name do
          "run_elixir" ->
            code = call.args["code"] || ""
            title = call.args["title"] || ""

            case check_rules(code) do
              [] ->
                audit_dangerous(code)
                emit(state, {:tool_start, "run_elixir", title, code})
                Newbee.DebugLog.log(:tool, "eval start #{title}")

                eval_result =
                  try do
                    Newbee.DEE.Evaluator.eval(state.evaluator, code)
                  rescue
                    e ->
                      Newbee.DebugLog.log(:tool, "eval raised #{inspect(e)}")
                      %{status: :error, error: inspect(e), output: ""}
                  end

                Newbee.DebugLog.log(:tool, "eval done status=#{eval_result.status} title=#{title}")
                rendered = Newbee.DEE.Result.render(eval_result)

                if eval_result.status == :error do
                  emit(state, {:tool_error, rendered})
                end

                emit(state, {:tool_result, "run_elixir", rendered})

                tool_msg = %{
                  "role" => "tool",
                  "tool_call_id" => call.id,
                  "content" => rendered
                }

                {:cont, {:cont, state |> push_msg(tool_msg) |> maybe_progress()}}

              hits ->
                emit(state, {:rule_hit, hits})
                injections = Enum.map_join(hits, "\n", &("- [" <> &1.id <> "] " <> &1.injection))

                tool_msg = %{
                  "role" => "tool",
                  "tool_call_id" => call.id,
                  "content" => "⛔ 未执行——命中环境规则，请先按以下提醒修正再重试:\n" <> injections
                }

                reminder = %{
                  "role" => "system",
                  "content" => "[沉睡规则注入] 你刚才的代码命中了以下环境规则:\n" <> injections
                }

                {:cont, {:cont, state |> push_msg(tool_msg) |> push_msg(reminder)}}
            end

          "done" ->
            summary = call.args["summary"] || ""
            tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => "✓ done"}

            case final_check(state) do
              {:done, state} ->
                emit(state, {:done, summary})
                # DeepSeek 严格校验：带 tool_calls 的 assistant 后必须跟齐 tool 响应，
                # 否则下一回合 400（此前 done/ask 从不回填，历史必然悬空）
                {:halt, {:halt, {:done, summary}, push_msg(state, tool_msg)}}

              {:retry, state, reminder} ->
                emit(state, {:final_check_low, state.progress.final_score})
                # 低分：注入提醒 + 让循环继续，模型重新评估后再 done
                {:cont, {:cont, state |> push_msg(tool_msg) |> push_msg(%{"role" => "user", "content" => reminder})}}
            end

          "ask" ->
            question = call.args["question"] || ""
            emit(state, {:ask, question})
            tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => "（等待用户回答）"}
            {:halt, {:halt, {:ask, question}, push_msg(state, tool_msg)}}

          other ->
            tool_msg = %{
              "role" => "tool",
              "tool_call_id" => call.id,
              "content" => "✗ unknown tool: #{other}"
            }

            {:cont, {:cont, push_msg(state, tool_msg)}}
        end

      Newbee.DebugLog.log(:tool, "done #{call.name} in #{System.monotonic_time(:millisecond) - t0}ms")
      result
      end
    end)
    |> case do
      {:cont, state} -> {:cont, state}
      {:halt, reply, state} -> {:halt, reply, state}
    end
  end

  # 宽松沙箱（§8 放行+审计）：危险模式不拦，但写事件日志留证
  @dangerous ~w(:init.stop System.halt :erlang.halt :code.delete :code.purge File.rm_rf!)

  # 崩溃/中断会在 transcript 留下悬空 tool_calls（DeepSeek 严格校验直接 400）。
  # 载入时修补：缺响应的补占位 tool 消息，孤立 tool 消息丢弃。
  defp repair_history(messages) do
    {chunks, pending} =
      Enum.map_reduce(messages, [], fn msg, pending ->
        case msg do
          %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) and calls != [] ->
            {tool_placeholders(pending) ++ [msg], Enum.map(calls, & &1["id"])}

          %{"role" => "tool", "tool_call_id" => id} ->
            if id in pending, do: {[msg], pending -- [id]}, else: {[], pending}

          _ ->
            {tool_placeholders(pending) ++ [msg], []}
        end
      end)

    Enum.concat(chunks) ++ tool_placeholders(pending)
  end

  defp tool_placeholders(ids) do
    Enum.map(ids, fn id ->
      %{"role" => "tool", "tool_call_id" => id, "content" => "（会话中断，该工具结果丢失）"}
    end)
  end

  defp audit_dangerous(code) do
    hits = Enum.filter(@dangerous, &String.contains?(code, &1))

    if hits != [] do
      if Process.whereis(Newbee.Bus) do
        Newbee.Bus.emit(:audit, {:audit, :dangerous_code, hits})
      end
    end
  end

  defp check_rules(code) do
    if Process.whereis(Newbee.DEE.Rules) do
      Newbee.DEE.Rules.check(code)
    else
      []
    end
  end

  defp merge_usage(a, b) when is_map(b) do
    Map.merge(a, b, fn _k, x, y -> (to_num(x) || 0) + (to_num(y) || 0) end)
  end

  defp merge_usage(a, _), do: a
  defp to_num(n) when is_number(n), do: n
  defp to_num(_), do: nil

  # ── 事件与持久化 ──

  defp emit(state, event) do
    state.render.(event)

    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.emit(elem(event, 0), event)
    end
  end

  # 同步屏障：对 Bus 发起一次同步调用，令其按 FIFO 处理完本进程先前投递的
  # 所有 cast（广播），从而保证事件在调用返回前已送达订阅者信箱。
  defp flush_bus do
    if Process.whereis(Newbee.Bus) do
      try do
        Newbee.Bus.subscribers()
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp push_msg(state, msg) do
    msg = sanitize_msg(msg)
    if state.session, do: Newbee.Session.append(state.session, msg)
    %{state | messages: state.messages ++ [msg]}
  end

  # 兜底：任何入会话消息都必须是合法 UTF-8，否则 Jason 编码崩溃
  defp sanitize_msg(msg) when is_map(msg) do
    Map.new(msg, fn
      {k, v} when is_binary(v) -> {k, Newbee.DEE.Result.sanitize(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &sanitize_msg/1)}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize_msg(other), do: other

  # ── 终局验证（LLM-as-a-Verifier）──

  # done 前的终局检查：分数 ≥ 阈值直接 done；低分注入提醒让模型重新评估（仅一次）。
  defp final_check(%{progress: nil} = state), do: {:done, state}

  defp final_check(state) do
    p = state.progress

    if p.final_check and not p.final_checked do
      task = build_task(state.messages)
      traj = build_traj(state.messages)

      score_opts =
        if p.complete_fn, do: [scale: p.scale, complete_fn: p.complete_fn], else: [scale: p.scale]

      result =
        try do
          Newbee.Evolution.Progress.score(p.client, task, traj, score_opts)
        rescue
          e -> %{score: nil, error: inspect(e)}
        end

      case result do
        %{score: s, criteria: criteria} when is_number(s) ->
          state = %{state | progress: %{p | final_checked: true, final_score: s}}
          emit(state, {:final_check, s})

          # 判分失败（criteria 全 error）视为无法判断：不阻塞完成
          if criteria != [] and Enum.all?(criteria, &(&1.method == :error)) do
            {:done, state}
          else
            if s >= p.done_threshold do
              {:done, state}
            else
              reminder =
                "[终局验证] 你的完成分数 #{Float.round(s, 1)}/20 低于阈值 #{p.done_threshold}。" <>
                  "请重新检查是否真正满足所有任务要求（输出格式、错误处理、测试通过）。" <>
                  "确认无误后再调用 done，或继续修正。"
              {:retry, state, reminder}
            end
          end

        _ ->
          # 判分失败不阻塞完成
          {:done, %{state | progress: %{p | final_checked: true}}}
      end
    else
      {:done, state}
    end
  end

  # ── 进度监控（LLM-as-a-Verifier）──

  defp maybe_progress(%{progress: nil} = state), do: state


  defp maybe_progress(state) do
    steps = state.steps + 1
    state = %{state | steps: steps}

    if rem(steps, state.progress.every) == 0 do
      do_progress_check(state)
    else
      state
    end
  end

  # 每 every 步对轨迹前缀打一次连续分；连续停滞则注入干预提醒（只注入一次）。
  defp do_progress_check(state) do
    p = state.progress
    task = build_task(state.messages)
    traj = build_traj(state.messages)

    score_opts =
      if p.complete_fn, do: [scale: p.scale, complete_fn: p.complete_fn], else: [scale: p.scale]

    result =
      try do
        Newbee.Evolution.Progress.score(p.client, task, traj, score_opts)
      rescue
        e -> %{score: nil, variance: nil, error: inspect(e)}
      end

    case result do
      %{score: s} when is_number(s) ->
        scores = p.scores ++ [s]
        emit(state, {:progress, s, scores})
        Newbee.DebugLog.log(:progress, "score=#{Float.round(s, 2)} trend=#{inspect(scores)}")

        if Newbee.Evolution.Progress.stalled?(scores,
             window: p.window,
             min_steps: p.min_steps,
             threshold: p.threshold
           ) and not p.injected do
          emit(state, {:progress_stall, scores})
          reminder = progress_reminder(scores)
          Newbee.DebugLog.log(:progress, "stalled, injecting reminder")
          %{state | progress: %{p | scores: scores, injected: true}}
          |> push_msg(%{"role" => "user", "content" => reminder})
        else
          %{state | progress: %{p | scores: scores}}
        end

      _ ->
        Newbee.DebugLog.log(:progress, "score failed: #{inspect(result)}")
        state
    end
  end

  # 从消息历史提取任务描述（第一条 user 消息）
  defp build_task(messages) do
    messages
    |> Enum.find_value(fn m -> if m["role"] == "user" and is_binary(m["content"]), do: m["content"] end)
    |> case do
      nil -> "(无任务描述)"
      t -> String.slice(t, 0, 800)
    end
  end

  # 从消息历史提取轨迹前缀：run_elixir 工具结果（压缩）
  defp build_traj(messages) do
    messages
    |> Enum.filter(fn m -> m["role"] == "tool" and is_binary(m["content"]) end)
    |> Enum.map(fn m ->
      m["content"]
      |> String.replace("

", "
")
      |> String.slice(0, 300)
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} -> "step #{i}: #{c}" end)
    |> Enum.join("
")
  end

  defp progress_reminder(scores) do
    trend = Newbee.Evolution.Progress.render_scores(scores)

    "[进度监控] 检测到进度停滞（最近分数趋势：#{trend}）。
" <>
      "你最近的步骤没有取得实质进展。请停下来重新评估：是否在绕路（安装无关依赖、反复尝试同一方案、在错误方向深挖）？
" <>
      "建议：回退到最近的高分状态（可用 git rollback 或重新梳理），换一个更直接的路径。"
  end

  defp persist_bindings(%{session: nil}), do: :ok

  defp persist_bindings(state) do
    binding = Newbee.DEE.Evaluator.dump_bindings(state.evaluator)
    Newbee.Session.save_bindings(state.session, binding)
  rescue
    _ -> :ok
  end

  # ── system prompt 组装（光头原则 §1.1：只注入小而准的三件）──

  defp system_prompt do
    base =
      case File.read(Path.join(:code.priv_dir(:newbee), "prompts/system.md")) do
        {:ok, body} -> body
        _ -> "你是 newbee，用 run_elixir 在持久 Elixir 环境中完成编程任务。"
      end

    base <>
      "\n\n当前工程根目录: #{File.cwd!()}\n" <>
      project_memory() <>
      prompt_fragments() <>
      repo_map_section()
  end

  # 进化产出的 prompt 片段（基因 bundle / evolver 合成；每片≤500字符，最多5片）
  defp prompt_fragments do
    dir = Path.join(System.user_home!(), ".newbee/prompts")

    if File.dir?(dir) do
      dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.take(5)
      |> Enum.map_join("\n", fn f -> File.read!(f) |> String.slice(0, 500) end)
      |> case do
        "" -> ""
        body -> "\n## 环境经验（进化产出）\n" <> body <> "\n"
      end
    else
      ""
    end
  end

  # NEWBEE.md / AGENTS.md / CLAUDE.md 项目记忆（§5.4，封顶 200 行）
  defp project_memory do
    Enum.find_value(["NEWBEE.md", "AGENTS.md", "CLAUDE.md"], "", fn f ->
      if File.exists?(f), do: File.read!(f) |> String.split("\n") |> Enum.take(200) |> Enum.join("\n"), else: nil
    end)
    |> case do
      "" -> ""
      body -> "\n## 项目记忆\n" <> body <> "\n"
    end
  end

  # RepoMap（§3.6）：仅 Elixir 工程注入结构图
  defp repo_map_section do
    if File.exists?("mix.exs") do
      map = Newbee.DEE.RepoMap.build(".")
      if map == "", do: "", else: "\n## 工程结构图（RepoMap，按图定位再精确读取）\n" <> map <> "\n"
    else
      ""
    end
  end
end