defmodule Newbee.Evolution.JIT do
  @moduledoc """
  认知的 JIT 编译 (DESIGN §6.2) ⭐：教训分三级，热的路径升级、失效降级：

    L1 观察笔记（memory 里的一条备注，零成本）
    L2 沉睡规则（沉睡在 Rules，命中才出现）
    L3 编译代码（HotLoader 工具，零 token 常驻）

  剖析（profiling）：L1 被引用 ≥ @promote_l2 次 → 升 L2；
  L2 命中 ≥ @promote_l3 次 → 候选升 L3（由 evolver 完成代码化）；
  L3 工具出错 ≥ @deopt 次 → 降回 L2（deopt，永不删除）。
  持久化 ~/.newbee/evolution/jit.json。
  """
  use GenServer

  @promote_l2 3
  @promote_l3 3
  @deopt 2
  @path Path.join(System.user_home!(), ".newbee/evolution/jit.json")

  defstruct items: %{}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "登记一条 L1 教训。返回 :ok。"
  def learn(id, note), do: GenServer.call(__MODULE__, {:learn, to_string(id), note})

  @doc "记录某条教训被引用/命中一次；可能触发升级。返回 {:promoted, level} | :ok。"
  def hit(id), do: GenServer.call(__MODULE__, {:hit, to_string(id)})

  @doc "记录 L3 工具失败；可能 deopt。返回 {:deopted, :l2} | :ok。"
  def fail(id), do: GenServer.call(__MODULE__, {:fail, to_string(id)})

  @doc "L3 升级完成（evolver 调用）：登记工具模块名。"
  def promote_to_tool(id, module), do: GenServer.call(__MODULE__, {:l3, to_string(id), module})

  @doc "全部条目（新→旧）。"
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_), do: {:ok, %__MODULE__{items: load()}}

  @impl true
  def handle_call({:learn, id, note}, _from, state) do
    item = %{id: id, level: :l1, note: note, hits: 0, fails: 0, module: nil}
    state = put_item(state, item)
    {:reply, :ok, state}
  end

  def handle_call({:hit, id}, _from, state) do
    case Map.fetch(state.items, id) do
      :error ->
        {:reply, :ok, state}

      {:ok, item} ->
        item = %{item | hits: item.hits + 1}

        {item, reply} =
          cond do
            item.level == :l1 and item.hits >= @promote_l2 ->
              # 升 L2：落成沉睡规则
              if Process.whereis(Newbee.DEE.Rules) do
                Newbee.DEE.Rules.add(id, rule_pattern(item), item.note, source: :evolver)
              end

              {%{item | level: :l2}, {:promoted, :l2}}

            item.level == :l2 and item.hits >= @promote_l2 + @promote_l3 ->
              # L2 继续命中 → 标记待 L3（evolver 来认领代码化）
              {%{item | level: :l2_hot}, {:promoted, :l2_hot}}

            true ->
              {item, :ok}
          end

        {:reply, reply, put_item(state, item)}
    end
  end

  def handle_call({:fail, id}, _from, state) do
    case Map.fetch(state.items, id) do
      :error ->
        {:reply, :ok, state}

      {:ok, item} ->
        item = %{item | fails: item.fails + 1}

        {item, reply} =
          if item.level == :l3 and item.fails >= @deopt do
            # deopt：工具降回沉睡规则（不删除，规则兜底）
            if Process.whereis(Newbee.DEE.Rules) do
              Newbee.DEE.Rules.add(id, rule_pattern(item), item.note, source: :evolver)
            end

            {%{item | level: :l2, fails: 0}, {:deopted, :l2}}
          else
            {item, :ok}
          end

        {:reply, reply, put_item(state, item)}
    end
  end

  def handle_call({:l3, id, module}, _from, state) do
    case Map.fetch(state.items, id) do
      :error -> {:reply, {:error, :not_found}, state}
      {:ok, item} -> {:reply, :ok, put_item(state, %{item | level: :l3, module: to_string(module)})}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state.items |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  defp put_item(state, item) do
    %{state | items: Map.put(state.items, item.id, item)}
    |> tap(fn s -> persist(s.items) end)
  end

  defp rule_pattern(item) do
    # L1 笔记的第一行关键词作为沉睡规则 pattern（粗略但可用）
    item.note
    |> String.split("\n")
    |> hd()
    |> String.replace(~r/[^\w\.]+/, " ")
    |> String.trim()
    |> String.split()
    |> Enum.take(3)
    |> Enum.join("|")
    |> case do
      "" -> item.id
      p -> p
    end
  end

  defp load do
    case File.read(@path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, items} when is_list(items) ->
            Map.new(items, fn i ->
              {i["id"],
               %{id: i["id"], level:
… [compressed: 10017 bytes, 2 lines; 用 binding 变量或写文件后再局部读取] …
"回放全部抗体（用独立求值器，互不污染）。返回 {passed, failed, details}。"
  def replay(opts \\ []) do
    evaluator = Keyword.get(opts, :evaluator, Newbee.DEE.Evaluator)

    results =
      antibodies()
      |> Enum.map(fn a ->
        {passed?, detail} = run_antibody(a, evaluator)
        {a["id"], passed?, detail}
      end)

    failed = Enum.filter(results, fn {_, ok, _} -> !ok end)
    {length(results) - length(failed), length(failed), results}
  end

  defp run_antibody(%{"code" => code, "check" => %{"kind" => kind, "pattern" => pat}}, evaluator) do
    result = Newbee.DEE.Evaluator.eval(evaluator, code)
    rendered = Newbee.DEE.Result.render(result)

    passed =
      case kind do
        "expect_ok" -> result.status == :ok and (pat == "" or rendered =~ pat)
        "expect_error" -> result.status == :error and rendered =~ pat
        _ -> false
      end

    {passed, String.slice(rendered, 0, 300)}
  rescue
    e -> {false, "replay crash: #{inspect(e)}"}
  end

  @doc "真实任务集（bench/tasks/*.json）：端到端验收。每项 {id, prompt, must_match}。"
  def tasks do
    Path.join(File.cwd!(), "bench/tasks")
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) |> then(fn {:ok, b} -> Jason.decode(b) end) do
        {:ok, t} -> [t]
        _ -> []
      end
    end)
  end

  @doc "跑任务集（真实 LLM）。返回 %{passed, total, tokens, details}。"
  def run_tasks(client) do
    details =
      tasks()
      |> Enum.map(fn t ->
        {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :node)

        {:ok, k} =
          Newbee.DEE.Kernel.start_link(client: client, evaluator: ev, session: false, render: fn _ -> :ok end)

        reply = Newbee.DEE.Kernel.submit(k, t["prompt"])
        usage = Newbee.DEE.Kernel.usage(k)

        passed =
          case reply do
            {:done, summary} -> summary =~ (t["must_match"] || "")
            _ -> false
          end

        GenServer.stop(k)
        GenServer.stop(ev)

        %{id: t["id"], passed: passed, tokens: usage["total_tokens"] || 0, reply: inspect(reply) |> String.slice(0, 200)}
      end)

    %{
      passed: Enum.count(details, & &1.passed),
      total: length(details),
      tokens: Enum.sum(Enum.map(details, & &1.tokens)),
      details: details
    }
  end
end
", "