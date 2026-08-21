defmodule Newbee.Web.Socket do
  @moduledoc """
  WebUI 事件下行通道（移植 dsh websocket-downlink 语义）：浏览器连
  `GET /ws?session=<sid>`，本进程订阅 Bus，把该会话的 Loop 事件以 JSON
  帧推下去；同时接收上行控制帧（interrupt / permission_reply）。

  下行帧： {"type": "event", "sessionId": sid, "kind": "text", "payload": {...}}
  上行帧： {"type": "interrupt"} | {"type": "permission", "ok": true} |
           {"type": "prompt", "text": "..."}（等价 POST session.prompt，省一跳）
  """
  @behaviour WebSock

  alias Newbee.Web.Session, as: WSession

  @impl true
  def init(%{assigns: %{session: sid}}) do
    Newbee.Bus.subscribe()
    {:ok, _pid, _sid} = WSession.ensure(sid)
    {:ok, %{sid: sid}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, st) do
    case Jason.decode(text) do
      {:ok, %{"type" => "interrupt"}} ->
        cast_session(st.sid, &WSession.interrupt/1)

      {:ok, %{"type" => "permission", "ok" => ok}} ->
        cast_session(st.sid, &WSession.permission_reply(&1, ok))

      {:ok, %{"type" => "prompt", "text" => t}} ->
        cast_session(st.sid, &WSession.prompt(&1, t))

      _ ->
        :ok
    end

    {:ok, st}
  end

  def handle_in(_, st), do: {:ok, st}

  @impl true
  def handle_info({:newbee_event, :web_event, {:web_event, sid, kind, payload}}, %{sid: sid} = st) do
    frame = Jason.encode_to_iodata!(%{type: "event", sessionId: sid, kind: to_string(kind), payload: payload})
    {:push, [{:text, frame}], st}
  end

  # 其它会话的事件、以及总线上所有非 web_event，直接忽略
  def handle_info({:newbee_event, _, _}, st), do: {:ok, st}
  def handle_info(_, st), do: {:ok, st}

  @impl true
  def terminate(_reason, st) do
    Newbee.Bus.unsubscribe()
    {:ok, st}
  end

  defp cast_session(sid, fun) do
    case WSession.ensure(sid) do
      {:ok, pid, _} -> fun.(pid)
      _ -> :ok
    end
  end
end
