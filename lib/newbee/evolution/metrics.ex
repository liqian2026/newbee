defmodule Newbee.Evolution.Metrics do
  @moduledoc """
  指标采集 (DESIGN §6.1)：订阅事件总线，采集每个 turn 的
  token/耗时/工具调用/错误/规则命中，作为进化目标函数的观测面。
  落盘 ~/.newbee/metrics.jsonl，内存保留聚合。
  """
  use GenServer

  @path Path.join(System.user_home!(), ".newbee/metrics.jsonl")

  defstruct turns: 0,
            tokens_in: 0,
            tokens_out: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            tool_calls: 0,
            errors: 0,
            rule_hits: 0,
            dones: 0,
            asks: 0,
            latencies: [],
            # 按模型分组（§6.3 按模型分别度量）
            per_model: %{},
            # 用户验收回流（§6.3）
            approvals: 0,
            rejections: 0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "聚合摘要（给 evolver 与 /tokens 用）。"
  def summary, do: GenServer.call(__MODULE__, :summary)

  @impl true
  def init(_opts) do
    File.mkdir_p!(Path.dirname(@path))
    if Process.whereis(Newbee.Bus), do: Newbee.Bus.subscribe()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info({:newbee_event, topic, payload}, state) do
    {:noreply, ingest(state, topic, payload)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:summary, _from, state) do
    avg_lat =
      case state.latencies do
        [] -> 0
        ls -> div(Enum.sum(ls), length(ls))
      end

    total_input = state.tokens_in + state.cache_read_tokens + state.cache_write_tokens

    {:reply,
     %{
       turns: state.turns,
       tokens_in: state.tokens_in,
       tokens_out: state.tokens_out,
       cache_read_tokens: state.cache_read_tokens,
       cache_write_tokens: state.cache_write_tokens,
       cache_hit_rate: if(total_input == 0, do: 0.0, else: state.cache_read_tokens / total_input),
       tool_calls: state.tool_calls,
       errors: state.errors,
       rule_hits: state.rule_hits,
       dones: state.dones,
       asks: state.asks,
       avg_latency_ms: avg_lat,
       per_model: state.per_model,
       approvals: state.approvals,
       rejections: state.rejections
     }, state}
  end

  defp ingest(state, :usage, {:usage, usage}) when is_map(usage) do
    model = usage["model"] || "unknown"
    acc = Map.get(state.per_model, model, %{tokens_in: 0, tokens_out: 0})

    per_model =
      Map.put(state.per_model, model, %{
        tokens_in: acc.tokens_in + input_tokens(usage),
        tokens_out: acc.tokens_out + token(usage, "completion_tokens")
      })

    %{
      state
      | tokens_in: state.tokens_in + input_tokens(usage),
        tokens_out: state.tokens_out + token(usage, "completion_tokens"),
        cache_read_tokens: state.cache_read_tokens + token(usage, "cache_read_tokens"),
        cache_write_tokens: state.cache_write_tokens + token(usage, "cache_write_tokens"),
        per_model: per_model
    }
  end

  # 用户验收回流（§6.3）：/approve 与否作为真实世界信号进入指标
  defp ingest(state, :audit, {:audit, verdict, "user", _target, :staging}) do
    case verdict do
      :approved -> %{state | approvals: state.approvals + 1}
      :rejected -> %{state | rejections: state.rejections + 1}
      _ -> state
    end
  end

  defp ingest(state, :tool_start, _), do: %{state | tool_calls: state.tool_calls + 1}
  defp ingest(state, :tool_error, _), do: %{state | errors: state.errors + 1}
  defp ingest(state, :rule_hit, {:rule_hit, hits}), do: %{state | rule_hits: state.rule_hits + length(hits)}

  defp ingest(state, :turn_end, {:turn_end, kind, ms}) do
    state = %{state | turns: state.turns + 1, latencies: Enum.take([ms | state.latencies], 100)}
    state = if kind == :done, do: %{state | dones: state.dones + 1}, else: state
    state = if kind == :ask, do: %{state | asks: state.asks + 1}, else: state
    append(%{topic: :turn_end, kind: kind, ms: ms})
    state
  end

  defp ingest(state, _, _), do: state

  defp input_tokens(usage), do: usage["uncached_prompt_tokens"] || token(usage, "prompt_tokens")
  defp token(usage, key) when is_map(usage), do: usage[key] || 0

  defp append(map) do
    line = Jason.encode_to_iodata!(Map.put(map, :at, DateTime.to_iso8601(DateTime.utc_now())))
    File.write!(@path, [line, "\n"], [:append])
  end
end
