defmodule Newbee.Web.Session do
  @moduledoc """
  WebUI 会话内核（移植 dsh web 的 session 域语义）：一个 Session 封装一个
  `Newbee.Agent.Loop` kernel —— 管理生命周期、串行化 submit、广播该会话
  的事件给所有已连接的 WebSocket 订阅者。

  事件流：Loop render 回调 → `{:web_event, sid, kind, payload}` 广播到 Bus，
  `Newbee.Web.Socket` 订阅后下行给浏览器（对应 dsh 的 websocket-downlink）。
  """
  use GenServer


  defstruct kernel: nil,
            sid: nil,
            busy: false,
            queue: :queue.new(),
            turns: 0,
            usage_snap: %{},
            steps_snap: 0,
            client: nil

  # ── registry ──

  def reg_name(sid), do: {:via, Registry, {Newbee.Web.SessionRegistry, sid}}

  @doc "取已存在的会话进程；没有则 {:error, :not_found}。"
  def lookup(sid) do
    case Registry.lookup(Newbee.Web.SessionRegistry, sid) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "确保会话存在：resume 已有 session id 或新建。返回 {:ok, pid, sid}。"
  def ensure(sid \\ nil) do
    sid = sid || gen_session_id()

    case lookup(sid) do
      {:ok, pid} ->
        {:ok, pid, sid}

      {:error, :not_found} ->
        case DynamicSupervisor.start_child(Newbee.Web.SessionSup, {__MODULE__, sid}) do
          {:ok, pid} -> {:ok, pid, sid}
          {:error, {:already_started, pid}} -> {:ok, pid, sid}
          other -> other
        end
    end
  end
  @doc "销毁会话：停 web 会话进程（如活着）+ 删除底层存储（transcript/artifacts/索引）。"
  def destroy(sid) when is_binary(sid) do
    case lookup(sid) do
      {:ok, pid} ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 3_000)
        :ok

      _ ->
        :ok
    end

    Newbee.Session.delete(sid)
  end


  @doc false
  def gen_session_id do
    # 与 Newbee.Session 的 id 体系一致：时间戳 + 随机后缀
    {{y, m, d}, {h, mi, s}} = :calendar.local_time()
    ts = "#{y}#{pad(m)}#{pad(d)}-#{pad(h)}#{pad(mi)}#{pad(s)}"
    "#{ts}-#{:rand.uniform(0xFFFF) |> Integer.to_string(16) |> String.pad_leading(4, "0")}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "child_spec：以 session id 为重启键。"
  def child_spec(sid) do
    %{id: {__MODULE__, sid}, start: {__MODULE__, :start_link, [sid]}, restart: :temporary}
  end

  def start_link(sid) do
    GenServer.start_link(__MODULE__, sid, name: reg_name(sid))
  end

  # ── client API ──

  @doc "异步提交用户输入；事件经 Bus 下行，终态也以事件通知（不阻塞调用者）。"
  def prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

  @doc "非阻塞中断当前 turn。"
  def interrupt(pid), do: GenServer.cast(pid, :interrupt)

  @doc "权限回复（ask 档位）。"
  def permission_reply(pid, ok), do: GenServer.cast(pid, {:permission_reply, ok})

  @doc "热切模型：model_id 如 openrouter/anthropic/claude-sonnet-4。"
  def switch_model(pid, model_id), do: GenServer.call(pid, {:switch_model, model_id}, 10_000)

  @doc "当前状态快照（供 HTTP 轮询 / socket 重连对齐）。"
  def state(pid), do: GenServer.call(pid, :state, 5_000)

  # ── GenServer ──

  @doc false
  def client_for_session(sid) do
    base = Newbee.LLM.Config.client_for()

    case Newbee.Session.model(sid) do
      nil -> base
      model -> %{base | model: model}
    end
  end

  @doc false
  def switch_session_model(st, model_id) do
    cond do
      not is_binary(model_id) ->
        {:error, :bad_model_id}

      String.trim(model_id) == "" or not String.contains?(model_id, "/") ->
        {:error, :bad_model_id}

      true ->
        :ok = Newbee.Session.set_model(st.sid, model_id)
        client = %{st.client | model: model_id}

        case Newbee.Agent.Loop.switch_model(st.kernel, client) do
          :ok ->
            broadcast(st.sid, :model_switched, %{model: model_id})
            {:ok, %{st | client: client}}

          {:error, _} = err ->
            err
        end
    end
  end

  @impl true
  def init(sid) do
    client = client_for_session(sid)

    if client.api_key do
      kernel = start_kernel(sid, client)
      {:ok, %__MODULE__{kernel: kernel, sid: sid, client: client}}
    else
      broadcast(sid, :error, %{message: "缺少 API key：检查 ~/.newbee/model.json"})
      {:stop, :no_api_key}
    end
  end

  defp start_kernel(sid, client) do
    sid_opt = sid
    evaluator = Newbee.Environment.Boot.evaluator_or_fallback(session_id: sid_opt)

    render = fn event ->
      kind = elem(event, 0)
      broadcast(sid, kind, encode_event(event))
      if kind == :usage, do: GenServer.cast(reg_name(sid), {:usage_snap, elem(event, 1)})
    end

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: evaluator,
        session_id: sid_opt,
        auto_antibodies: true,
        render: render
      )

    kernel
  end


  @impl true
  def handle_cast({:prompt, text}, %{busy: true} = st) do
    {:noreply, %{st | queue: :queue.in(text, st.queue)}}
  end

  def handle_cast({:prompt, text}, st) do
    {:noreply, dispatch_input(st, text)}
  end

  def handle_cast(:interrupt, st) do
    if st.kernel && Process.alive?(st.kernel), do: Newbee.Agent.Loop.interrupt(st.kernel)
    {:noreply, st}
  end

  def handle_cast({:permission_reply, ok}, st) do
    if st.kernel && Process.alive?(st.kernel) do
      send(st.kernel, {:permission_reply, ok})
    end

    {:noreply, st}
  end
  # usage 快照（render 回调经 cast 推来，绝不 call 忙碌 kernel）
  def handle_cast({:usage_snap, usage}, st) when is_map(usage) do
    merged = Map.merge(st.usage_snap, usage, fn _k, a, b -> (num(a) || 0) + (num(b) || 0) end)
    {:noreply, %{st | usage_snap: merged, steps_snap: st.steps_snap + 1}}
  end


  @impl true
  def handle_call({:switch_model, model_id}, _from, st) do
    case switch_session_model(st, model_id) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, st}
    end
  end

  def handle_call(:state, _from, st) do
    # 只读本地快照：turn 进行中 Loop 的 GenServer.call 会排队超时（state 不该被阻塞）
    usage = st.usage_snap
    steps = st.steps_snap
    goal = nil
    bindings = bindings_count()

    {:reply,
     %{
       sid: st.sid,
       busy: st.busy,
       queued: :queue.len(st.queue),
       model: st.client.model,
       usage: usage,
       goal: goal,
        awaiting_permission: Newbee.Agent.Loop.awaiting_permission?(),
        steps: steps,
        bindings: bindings,
        policy: Newbee.Environment.Autonomy.get(),
        turns: st.turns
     }, st}
  end

  @impl true
  def handle_info({:turn_finished, result}, st) do
    st = %{st | turns: st.turns + 1}
    broadcast_turn_end(st.sid, result)

    case :queue.out(st.queue) do
      {{:value, next}, q} -> {:noreply, do_submit(%{st | queue: q}, next)}
      {:empty, _} -> {:noreply, %{st | busy: false}}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  # submit 在独立 task 里同步跑整个 turn；终态回投本进程以驱动队列。
  # 期间 interrupt/permission_reply 仍可送达 kernel（Loop 用 send 接收）。
  # 输入分派：/ 命令走 Newbee.Commands（say 输出作为 notice 事件下行），
  # 其余走 do_submit 提交给 LLM。/new /resume 等需要换 kernel 的命令在
  # 此直接处理。
  defp dispatch_input(st, text) do
    say = fn line -> broadcast(st.sid, :notice, %{text: line}) end
    ctx = %{kernel: st.kernel, say: say}

    case Newbee.Commands.handle(text, ctx) do
      {:submit, t} -> do_submit(st, t)
      :new -> restart_kernel(st)
      :handled -> st
      :ok -> st
      {:shell, cmd} -> run_shell_notice(st, cmd)
      other ->
        say.("该命令在 WebUI 暂不支持: " <> inspect(other))
        st
    end
  end

  defp run_shell_notice(st, cmd) do
    result = Newbee.Tools.Run.sh(cmd, timeout: 300_000)
    broadcast(st.sid, :shell_result, %{cmd: cmd, output: String.slice(result.output, 0, 8000), exit: result.exit})
    st
  end

  defp restart_kernel(st) do
    if st.kernel && Process.alive?(st.kernel), do: GenServer.stop(st.kernel)
    kernel = start_kernel(st.sid <> "-w" <> Integer.to_string(:erlang.unique_integer([:positive])), st.client)
    broadcast(st.sid, :notice, %{text: "已开启新会话"})
    %{st | kernel: kernel}
  end

  defp do_submit(st, text) do
    parent = self()
    kernel = st.kernel

    Task.start(fn ->
      result =
        try do
          Newbee.Agent.Loop.submit(kernel, text)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, r -> {:error, "exit: #{inspect(r)}"}
        end

      send(parent, {:turn_finished, result})
    end)

    %{st | busy: true}
  end

  # DEE 绑定数：优先 EvaluatorPool（generation 路由），否则具名 Evaluator
  defp bindings_count do
    task =
      Task.async(fn ->
        case Newbee.Environment.EvaluatorPool.current() do
          nil ->
            if Process.whereis(Newbee.DEE.Evaluator) do
              length(Newbee.DEE.Evaluator.bindings_summary(Newbee.DEE.Evaluator, 300))
            else
              0
            end

          pool ->
            length(Newbee.Environment.EvaluatorPool.bindings_summary(pool))
        end
      end)

    case Task.yield(task, 400) do
      {:ok, n} -> n
      nil -> Task.shutdown(task, :brutal_kill); 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: nil


  defp broadcast_turn_end(sid, result) do
    {kind, payload} =
      case result do
        {:done, summary} -> {:done, %{summary: summary}}
        {:ask, q} -> {:ask, %{question: q}}
        {:text, body} -> {:text_end, %{body: body}}
        {:error, e} -> {:error, %{message: inspect(e)}}
        other -> {:error, %{message: inspect(other)}}
      end

    broadcast(sid, kind, payload)
  end

  # Loop 事件统一编码为 JSON 安全的 {kind, payload}，经 Bus 广播给 socket。
  defp broadcast(sid, kind, payload) do
    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.emit(:web_event, {:web_event, sid, kind, payload})
    end

    :ok
  end

  defp encode_event({:text, delta}), do: %{delta: delta}
  defp encode_event({:reasoning, delta}), do: %{delta: delta}
  defp encode_event({:tool_start, name, title, code}), do: %{name: name, title: title, code: code}
  defp encode_event({:tool_result, _, text}), do: %{text: text}
  defp encode_event({:tool_result, _, text, duration_ms}), do: %{text: text, duration_ms: duration_ms}
  defp encode_event({:tool_error, text}), do: %{text: text}
  defp encode_event({:tool_warnings, text}), do: %{text: text}
  defp encode_event({:file_diff, path, diff, stats}), do: %{path: path, diff: diff, stats: stats}
  defp encode_event({:permission_ask, {:permission_ask, preview}}), do: %{preview: preview}
  defp encode_event({:usage, usage}), do: %{usage: usage}
  defp encode_event({:compacted, n}), do: %{count: n}
  defp encode_event({:rule_hit, hits}) when is_list(hits), do: %{hits: Enum.map(hits, &Map.take(&1, [:id, :injection]))}
  defp encode_event({:prompt_injection, details}) when is_map(details), do: details
  defp encode_event({:progress, score, scores}), do: %{score: score, scores: scores}
  defp encode_event({:progress_stall, scores}), do: %{scores: scores}
  defp encode_event({:final_check, score}), do: %{score: score}
  defp encode_event({:final_check_low, score}), do: %{score: score}
  defp encode_event({:turn_long, step}), do: %{step: step}
  defp encode_event({:interrupted, _}), do: %{}
  defp encode_event({:error, e}), do: %{message: inspect(e)}
  defp encode_event({:turn_end, kind, ms}), do: %{result: kind, ms: ms}
  defp encode_event({:goal_start, text}), do: %{text: text}
  defp encode_event({:goal_done, summary}), do: %{summary: summary}
  defp encode_event({:goal_ask, q}), do: %{question: q}
  defp encode_event({:goal_round, n}), do: %{round: n}
  defp encode_event({:goal_retry, n}), do: %{retry: n}
  defp encode_event({:goal_cancelled, why}), do: %{reason: inspect(why)}
  defp encode_event({:goal_limit, n}), do: %{max: n}
  defp encode_event({:advisor_note, {:advisor_note, text}}), do: %{text: text}
  defp encode_event(other) when is_tuple(other), do: %{raw: inspect(other)}
end
