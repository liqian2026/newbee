defmodule Mix.Tasks.Newbee.Web do
  @shortdoc "启动 newbee WebUI（浏览器界面）"
  @moduledoc """
  启动 newbee WebUI：`mix newbee.web [port]`（默认 127.0.0.1:4173）。

  浏览器打开 http://127.0.0.1:4173 即可使用。等价 dsh 的 `dsh web`。
  """
  use Mix.Task

  @impl true
  def run(args) do
    Newbee.Cwd.apply!()

    port =
      case args do
        [p | _] -> String.to_integer(p)
        [] -> 4173
      end

    ensure_distributed!(port)
    Mix.Task.run("app.start")

    {:ok, _} = Newbee.Web.Server.start_link(port: port, host: {127, 0, 0, 1})

    IO.puts("\e[1mnewbee webui\e[0m 已启动：")
    IO.puts("  \e[36mhttp://127.0.0.1:#{port}\e[0m")
    IO.puts("\e[2mCtrl+C 退出\e[0m")

    # 前台挂起（mix task 语义：像 TUI 一样占住终端）
    Process.sleep(:infinity)
  end

  # 启用分布式节点（OTP 热更/远程 RPC 的前提）。若未以 -sname/--name 启动，
  # 用 Node.start 动态起分布式——节点名按端口派生避免冲突。
  defp ensure_distributed!(port) do
    unless Node.alive?() do
      port_for_name = System.get_env("NEWBEE_WEB_PORT") || Integer.to_string(port)
      name = "newbee_web_" <> port_for_name
      {:ok, _} = Node.start(String.to_atom(name <> "@" <> hostname()), :shortnames)
      true = Node.alive?()
    end

    :ok
  end

  defp hostname do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end
end
