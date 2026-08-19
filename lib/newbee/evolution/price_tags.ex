defmodule Newbee.Evolution.PriceTags do
  @moduledoc """
  价签系统 (DESIGN §9.11) ⭐：每个工具携带实测价签（调用次数、成功率、
  平均耗时、平均结果大小），随工具清单一并暴露给模型——模型自己按
  "够用且最便宜"选路，省 token 从隐藏策略变成模型的显式决策。

  数据来自事件总线的持续测量（§6.1），越用越准。进程内存态 + 落盘
  `~/.newbee/price_tags.json`（重启恢复）。
  """

  use GenServer

  @path Path.join(System.user_home!(), ".newbee/price_tags.json")

  defstruct stats: %{}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "全部价签：%{tool_name => %{calls, errors, ms, bytes}}。"
  def summary, do: GenServer.call(__MODULE__, :summary)

  @impl true
  def init(_) do
    if Process.whereis(Newbee.Bus), do: Newbee.Bus.subscribe()
    {:ok, %__MODULE__{stats: load()}}
  end

  @impl true
  def handle_info({:newbee_event, :tool_start, {:tool_start, name, _, _}}, state) do
    stat = Map.get(state.stats, name, %{calls: 0, errors: 0, ms: 0, bytes: 0, started: nil})

    {:noreply,
     %{
       state
       | stats:
           Map.put(state.stats, name, %{stat | calls: stat.calls + 1, started: System.monotonic_time(:millisecond)})
     }}
  end

  def handle_info({:newbee_event, :tool_result, {:tool_result, name, text}}, state) do
    stat = Map.get(state.stats, name, %{calls: 0, errors: 0, ms: 0, bytes: 0, started: nil})

    elapsed =
      case stat.started do
        nil -> 0
        t0 -> System.monotonic_time(:millisecond) - t0
      end

    stat = %{stat | ms: stat.ms + elapsed, bytes: stat.bytes + byte_size(text), started: nil}
    {:noreply, persist(%{state | stats: Map.put(state.stats, name, stat)})}
  end

  def handle_info({:newbee_event, :tool_error, _}, state) do
    # tool_error 事件不带工具名——按最近一个已启动未结束的工具计（近似）
    name =
      state.stats
      |> Enum.find_value(fn {n, s} -> if s.started, do: n end)
      |> Kernel.||(nil)

    state =
      if name do
        stat = Map.get(state.stats, name)
        %{state | stats: Map.put(state.stats, name, %{stat | errors: stat.errors + 1})}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:summary, _from, state) do
    {:reply, summarize(state.stats), state}
  end

  defp summarize(stats) do
    Map.new(stats, fn {name, s} ->
      {name,
       %{
         calls: s.calls,
         errors: s.errors,
         success_rate: if(s.calls == 0, do: 0.0, else: 1 - s.errors / s.calls),
         avg_ms: if(s.calls == 0, do: 0, else: div(s.ms, s.calls)),
         avg_bytes: if(s.calls == 0, do: 0, else: div(s.bytes, s.calls))
       }}
    end)
  end

  @doc "prompt 注入的一行价签清单（§9.11）。"
  def prompt_section do
    if Process.whereis(__MODULE__) do
      summary()
      |> Enum.map_join("\n", fn {name, s} ->
        "  - #{name}: #{s.calls} 次 · 成功率 #{Float.round(s.success_rate * 100, 0)}% · 平均 #{div(s.avg_ms, 1000)}s · 结果 #{div(s.avg_bytes, 1024)}KB"
      end)
      |> case do
        "" -> ""
        body -> "\n## 工具价签（实测：按\"够用且最便宜\"选路）\n" <> body <> "\n"
      end
    else
      ""
    end
  end

  defp load do
    case File.read(@path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, stats} when is_map(stats) ->
            Map.new(stats, fn {k, v} ->
              {k,
               %{
                 calls: v["calls"] || 0,
                 errors: v["errors"] || 0,
                 ms: v["ms"] || 0,
                 bytes: v["bytes"] || 0,
                 started: nil
               }}
            end)

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp persist(state) do
    File.mkdir_p!(Path.dirname(@path))
    File.write!(@path, Jason.encode_to_iodata!(state.stats))
    state
  end
end
