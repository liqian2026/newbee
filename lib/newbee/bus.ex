defmodule Newbee.Bus do
  @moduledoc """
  事件总线 (DESIGN §4.6) ⭐：全系统一条总线，两域。

  - **durable 事实**（turn/*、step/*、user/*、assistant/*、tool/*）由 EventLog 订阅落盘；
  - **live 拦截点**（agent/pre-step、llm/stream、tools/pre-execute）只广播不落盘。

  订阅者收到 `{:newbee_event, topic, event}`。订阅在进程退出时自动清理。
  """

  use GenServer

  @doc "启动总线（监督树 child）。"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "订阅事件流：此后收到 {:newbee_event, topic, event} 消息。"
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc "取消订阅。"
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  rescue
    _ -> :ok
  end

  @doc "广播事件。topic 为原子（:turn_end、:tool_start、:audit …）。"
  def emit(topic, event) when is_atom(topic) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:emit, topic, event})
    end

    :ok
  end

  @doc "同步广播（订阅者计数返回；测试用）。"
  def emit_sync(topic, event) do
    GenServer.call(__MODULE__, {:emit, topic, event})
  end

  @doc "当前订阅者列表（诊断用）。"
  def subscribers do
    GenServer.call(__MODULE__, :subscribers)
  end

  @impl true
  def init(_), do: {:ok, %{subs: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subs: Map.put(state.subs, pid, true)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subs: Map.delete(state.subs, pid)}}
  end

  def handle_call(:subscribers, _from, state) do
    {:reply, Map.keys(state.subs), state}
  end

  def handle_call({:emit, topic, event}, _from, state) do
    broadcast(state, topic, event)
    {:reply, map_size(state.subs), state}
  end

  @impl true
  def handle_cast({:emit, topic, event}, state) do
    broadcast(state, topic, event)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(state, topic, event) do
    for pid <- Map.keys(state.subs) do
      send(pid, {:newbee_event, topic, event})
    end
  end
end
