defmodule Newbee.Events do
  @moduledoc """
  统一事件入口（DESIGN §4.6）：全系统**一条事件总线**，两域。

  - **durable 事实**：`turn/*`、`step/*`、`change_*`、`release_*`、
    `need/feedback/rolled_back`、`tool/*`——进 Event Store，重启存活；
    worker 侧补充：`usage`、`progress/*`、`rule_hit`、`goal/*`，以及
    Protocol 全部消息类（`candidate_ready`、`rollback_request` 等，§7.2
    「消息是事件流中的一类事件」）；无项目 store（standalone）时优雅降级只发 Bus；
  - **live 拦截点**：`agent/pre-step`、`llm/stream`（沉睡规则监控面）、
    `tools/pre-execute`——不落盘，供策略与观察。

  一切订阅同一条总线：TUI 渲染、指标采集、沉睡规则、审计日志、
  adapter 触发——零各自为政的监听点。
  """

  @durable_prefixes ~w(turn step change release revision tool user assistant goal audit feedback need rolled_back module evaluation antibody usage progress rule candidate rollback)

  @live_topics [:"agent/pre-step", :"llm/stream", :"tools/pre-execute"]

  @doc "广播事件。durable topic 同步落盘 Event Store（落盘成功才算发生）。"
  def emit(topic, event) when is_atom(topic) do
    if durable?(topic), do: append_durable(topic, event)
    Newbee.Bus.emit(topic, event)
    :ok
  end

  def emit_sync(topic, event) do
    if durable?(topic), do: append_durable(topic, event)
    Newbee.Bus.emit_sync(topic, event)
    :ok
  end

  def subscribe, do: Newbee.Bus.subscribe()
  def unsubscribe, do: Newbee.Bus.unsubscribe()
  def subscribers, do: Newbee.Bus.subscribers()

  @doc "durable 事实域判定。"
  def durable?(topic) when is_atom(topic) do
    if topic in @live_topics do
      false
    else
      prefix = topic |> Atom.to_string() |> String.split("/") |> hd() |> String.split("_") |> hd()
      prefix in @durable_prefixes or to_string(topic) in @durable_prefixes
    end
  end

  @doc "live 拦截点域判定。"
  def live?(topic), do: topic in @live_topics

  # 项目 EventStore 由 Coordinator 持有并注册到 persistent_term
  defp append_durable(topic, event) do
    case :persistent_term.get({__MODULE__, :project_store}, nil) do
      nil ->
        :ok

      store when is_pid(store) ->
        if Process.alive?(store) do
          Newbee.EventStore.append(store, topic, %{"payload" => json_safe(event)})
        end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def register_store(store) when is_pid(store) do
    :persistent_term.put({__MODULE__, :project_store}, store)
  end

  @doc false
  def unregister_store do
    :persistent_term.erase({__MODULE__, :project_store})
  end

  defp json_safe(v) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)

  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&json_safe/1)
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v), do: v
  defp json_safe(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v, limit: 10)
end
