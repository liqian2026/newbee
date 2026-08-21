defmodule Newbee.Web.Api do
  @moduledoc """
  WebUI HTTP API（移植 dsh apiproxy 语义）：`POST /api/<method>` 的
  RPC-over-HTTP 网关。wire 信封对齐 dsh 四象限消息模型的 client-request：

      请求  {"rpcId": "...", "method": "session.prompt", "payload": {...}}
      应答  {"rpcId": "...", "result": {"ok": <value>}} |
            {"rpcId": "...", "result": {"error": {"code": ..., "message": ...}}}

  会话事件下行不走 HTTP，走 WebSocket（见 Newbee.Web.Socket）。
  """
  use Plug.Router

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  # ── RPC envelope ──

post "/:method" do
    rpc_id = get_in(conn.body_params, ["rpcId"]) || "-"
    payload = get_in(conn.body_params, ["payload"]) || %{}

    case dispatch_rpc(method, payload) do
      {:ok, value} ->
        reply(conn, 200, %{rpcId: rpc_id, result: %{ok: json_safe(value)}})

      {:error, code, message} ->
        reply(conn, 200, %{rpcId: rpc_id, result: %{error: %{code: code, message: message}}})
    end
  end

  # 便捷 GET：会话列表 / 健康检查（不进 RPC 信封，等价 dsh downloads 的 GET 面）
get "/sessions" do
    metas = Newbee.Session.list_with_meta(50)
    reply(conn, 200, Enum.map(metas, &json_safe/1))
  end

get "/health" do
    reply(conn, 200, %{ok: true, model: current_model()})
  end

  match _ do
    reply(conn, 404, %{error: "not found"})
  end

  # ── method 分派 ──

  # 会话域
  defp dispatch_rpc("session.list", _p) do
    sessions =
      Newbee.Session.list_with_meta(50)
      |> Enum.map(fn s ->
        id = s[:id] || s["id"]
        busy = Newbee.Web.Session.peek_busy(id)
        running = match?({:ok, _}, Newbee.Web.Session.lookup(id))

        Map.merge(s, %{
          running: running,
          busy: busy
        })
      end)

    {:ok, %{sessions: Enum.map(sessions, &json_safe/1)}}
  end

  defp dispatch_rpc("session.history", %{"sessionId" => sid}) do
    msgs = Newbee.Session.open(sid) |> Newbee.Session.messages()
    {:ok, %{messages: Enum.map(msgs, &history_msg/1)}}
  end

  defp dispatch_rpc("session.create", p) do
    sid = p["sessionId"]
    {:ok, _pid, sid} = Newbee.Web.Session.ensure(blank_to_nil(sid))
    {:ok, %{sessionId: sid}}
  end

  defp dispatch_rpc("session.resume", %{"sessionId" => sid}) do
    case Newbee.Web.Session.ensure(sid) do
      {:ok, _pid, sid} -> {:ok, %{sessionId: sid}}
      {:error, r} -> {:error, "session_error", inspect(r)}
    end
  end

  defp dispatch_rpc("session.delete", %{"sessionId" => sid}) do
    case Newbee.Web.Session.destroy(sid) do
      :ok -> {:ok, %{deleted: sid}}
      {:error, r} -> {:error, "delete_error", inspect(r)}
    end
  end

  defp dispatch_rpc("session.rename", %{"sessionId" => sid, "title" => t}) do
    Newbee.Session.rename(sid, String.trim(t || ""))
    {:ok, %{sessionId: sid, title: t}}
  rescue
    e -> {:error, "rename_error", Exception.message(e)}
  end

  defp dispatch_rpc("session.prompt", %{"sessionId" => sid, "text" => text}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.prompt(pid, text)
      {:ok, %{accepted: true}}
    end
  end

  defp dispatch_rpc("session.cancel", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.interrupt(pid)
      {:ok, %{interrupted: true}}
    end
  end

  defp dispatch_rpc("session.state", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      {:ok, Newbee.Web.Session.state(pid)}
    end
  end

  defp dispatch_rpc("session.selectModel", %{"sessionId" => sid, "provider" => provider, "model" => model}) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.switch_model(pid, provider, model) do
        :ok -> {:ok, %{provider: provider, model: model}}
        {:error, r} -> {:error, "model_error", inspect(r)}
      end
    end
  end

  # 兼容旧调用：仅 modelId
  defp dispatch_rpc("session.selectModel", %{"sessionId" => sid, "modelId" => mid}) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.switch_model(pid, mid) do
        :ok -> {:ok, %{model: mid}}
        {:error, r} -> {:error, "model_error", inspect(r)}
      end
    end
  end


  # 权限回复（server-request 象限的 respond 语义）
  defp dispatch_rpc("respond", %{"sessionId" => sid, "permission" => ok}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.permission_reply(pid, ok)
      {:ok, %{delivered: true}}
    end
  end

  # 模型目录
  defp dispatch_rpc("llm.models", p) do
    opts = if p["refresh"] == true, do: [refresh: true], else: []
    cat = Newbee.LLM.Config.model_catalog(opts)
    {:ok, %{providers: cat.providers, current: current_model_info(p["sessionId"])}}
  end

  # 按厂商刷新模型列表（只拉指定 provider）
  defp dispatch_rpc("llm.providerModels", p) do
    name = p["provider"] || ""
    opts = if p["refresh"] == true, do: [refresh: true], else: []

    case Newbee.LLM.Config.provider_models_by_name(name, opts) do
      nil -> {:error, "unknown_provider", name}
      models -> {:ok, %{provider: name, models: models}}
    end
  end



  # 进化域（左侧进化面板数据）
  defp dispatch_rpc("evolution.feed", p) do
    n = min(max(p["n"] || 100, 1), 500)

    topics = [
      "evolution_published",
      "evolution_rejected",
      "release_observation",
      "change_activated",
      "change_rejected",
      "change_rolled_back",
      "revision_advanced",
      "revision_degraded",
      "snapshot_created",
      "snapshot_restored",
      "generation_switched",
      "generation_switch_failed",
      "audit"
    ]

    events =
      Newbee.EventLog.read(n * 3, topics)
      |> Enum.take(n)
      |> Enum.map(&json_safe/1)

    {:ok, %{events: events}}
  end

  defp dispatch_rpc("evolution.status", _p) do
    autonomy = Newbee.Environment.Autonomy.get()

    {coord_state, active_releases} =
      case Process.whereis(Newbee.Environment.Coordinator) do
        nil ->
          {:down, []}

        _pid ->
          try do
            current = Newbee.Environment.Coordinator.current(Newbee.Environment.Coordinator)
            changes = Newbee.Environment.Coordinator.changes(Newbee.Environment.Coordinator)

            releases =
              (current && current.active && Enum.map(current.active, fn {plugin_id, release_id} ->
                %{
                  "plugin" => plugin_id,
                  "release" => release_id,
                  "kind" => plugin_id |> String.split(".") |> List.first(),
                  "name" => plugin_id |> String.split(".") |> Enum.drop(1) |> Enum.join(".")
                }
              end)) || []

            {%{
               active_revision: current && current.rev,
               changes: length(changes),
               active_count: length(releases)
             }, releases}
          rescue
            _ -> {:error, []}
          catch
            :exit, _ -> {:error, []}
          end
      end

    # 最近一轮 adapter 运行痕迹：从 EventLog 找最近的 evolution_* 事件
    recent_evo =
      Newbee.EventLog.read(50, ["evolution_published", "evolution_rejected"])
      |> List.first()

    # 每个 release 的使用统计（fitness 聚合）
    release_stats =
      active_releases
      |> Enum.map(fn rel ->
        rid = rel["release"]

        obs =
          try do
            Newbee.Environment.Fitness.observations(rid)
          rescue
            _ -> []
          catch
            :exit, _ -> []
          end

        n = length(obs)

        if n > 0 do
          succ = Enum.count(obs, & &1["success"])
          avg_tok = obs |> Enum.map(&(&1["tokens"] || 0)) |> Enum.sum() |> div(max(n, 1))

          Map.merge(rel, %{
            "uses" => n,
            "success_rate" => Float.round(succ / n, 2),
            "avg_tokens" => avg_tok
          })
        else
          Map.merge(rel, %{"uses" => 0})
        end
      end)
      # 按使用次数倒序
      |> Enum.sort_by(&(-Map.get(&1, "uses", 0)))

    {:ok,
     %{
       autonomy: autonomy,
       coordinator: json_safe(coord_state),
       active_releases: json_safe(release_stats),
       last_evolution: json_safe(recent_evo),
       event_log_bytes: Newbee.EventLog.size()
     }}
  end

  # 主机域
  defp dispatch_rpc("host.describe", _p) do

    {:ok,
     %{
       cwd: File.cwd!(),
       model: current_model_label(),
       policy: Newbee.Environment.Autonomy.get(),
       version: "0.1.0"
     }}
  end

  defp dispatch_rpc(method, _p), do: {:error, "unknown_method", "未知 RPC 方法: #{method}"}

  # ── helpers ──

  defp find_session(sid) do
    case Newbee.Web.Session.ensure(sid) do
      {:ok, pid, _sid} -> {:ok, pid}
      {:error, r} -> {:error, "session_error", inspect(r)}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp current_model(sid \\ nil) do
    try do
      if sid do
        case Newbee.Web.Session.lookup(sid) do
          {:ok, pid} -> Newbee.Web.Session.state(pid)["model"]
          _ -> Newbee.LLM.Config.client_for().model
        end
      else
        Newbee.LLM.Config.client_for().model
      end
    rescue
      _ -> nil
    end
  end

  defp current_model_info(sid) do
    provider = if sid, do: Newbee.Session.provider(sid), else: nil
    model = if sid, do: Newbee.Session.model(sid), else: nil

    if provider do
      %{provider: provider, model: model}
    else
      cfg = Newbee.LLM.Config.load()
      default = get_in(cfg, ["roles", "default"]) || %{}
      %{provider: default["provider"], model: model || default["model"]}
    end
  end

  defp current_model_label do
    info = current_model_info(nil)
    if info.model, do: "#{info.provider}/#{info.model}", else: nil
  end



  # transcript 消息 → 前端可渲染结构
  defp history_msg(%{"role" => "user", "content" => c}) when is_binary(c),
    do: %{role: "user", content: c}

  defp history_msg(%{"role" => "assistant"} = m) do
    calls =
      for c <- m["tool_calls"] || [],
          do: %{
            name: get_in(c, ["function", "name"]),
            title: args_field(c, "title"),
            code: args_field(c, "code")
          }

    %{role: "assistant", content: m["content"] || "", reasoning: m["reasoning"] || "", toolCalls: calls}
  end

  defp history_msg(%{"role" => "tool", "content" => c}) when is_binary(c),
    do: %{role: "tool", content: String.slice(c, 0, 4000)}

  defp history_msg(_), do: nil

  defp args_field(call, key) do
    case get_in(call, ["function", "arguments"]) do
      args when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, m} -> m[key] || ""
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp reply(conn, status, payload) do
    body = Jason.encode_to_iodata!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(status, body)
  end

  # JSON 安全化（atom key / datetime / tuple）
  defp json_safe(%{__struct__: _} = v), do: v |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = v), do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> json_safe()
  defp json_safe(v) when is_boolean(v), do: v
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v)
end
