defmodule Newbee.Web.Router do
  @moduledoc """
  WebUI 顶层路由（等价 dsh webserver 的路由分派 + frontend-static 的 fallback）：

  - `POST /api/*`、`GET /api/sessions|health` → Newbee.Web.Api（RPC 面）
  - `GET /ws`（upgrade）→ Newbee.Web.Socket（事件下行）
  - 其余 → priv/web 静态资源，SPA fallback 到 index.html
  """
  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  get "/ws" do
    conn = fetch_query_params(conn)
    sid = conn.query_params["session"] || ""

    conn
    |> WebSockAdapter.upgrade(Newbee.Web.Socket, %{assigns: %{session: sid}}, timeout: :infinity)
    |> halt()
  end

  # API 子路由
  forward("/api", to: Newbee.Web.Api)

  # 静态资源 + SPA fallback
  match _ do
    serve_static(conn)
  end

  # Static assets live in source tree (lib/newbee/web/router.ex -> ../../priv/web).
  # Using __DIR__ avoids :code.priv_dir failures when _build is missing/unsynced.
  @priv_web Path.expand("../../../priv/web", __DIR__)

    @index Path.join(@priv_web, "index.html")

  defp serve_static(conn) do
    path = conn.request_path |> String.trim_leading("/")
    path = if path == "", do: "index.html", else: path
    file = Path.join(@priv_web, path)

    cond do
      # 目录穿越防护
      not String.starts_with?(Path.expand(file), Path.expand(@priv_web)) ->
        send_resp(conn, 403, "forbidden")

      File.regular?(file) ->
        conn
        |> put_resp_content_type(content_type(file))
        |> send_file(200, file)

      File.regular?(@index) ->
        conn
        |> put_resp_content_type("text/html")
        |> send_file(200, @index)

      true ->
        send_resp(conn, 404, "newbee webui 前端未构建：priv/web/index.html 不存在")
    end
  end

  defp content_type(file) do
    case Path.extname(file) do
      ".html" -> "text/html"
      ".js" -> "text/javascript"
      ".css" -> "text/css"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".json" -> "application/json"
      ".webmanifest" -> "application/manifest+json"
      _ -> "application/octet-stream"
    end
  end
end
