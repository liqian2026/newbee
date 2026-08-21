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
    Mix.Task.run("app.start")

    port =
      case args do
        [p | _] -> String.to_integer(p)
        [] -> 4173
      end

    {:ok, _} = Newbee.Web.Server.start_link(port: port, host: {127, 0, 0, 1})

    IO.puts("\e[1mnewbee webui\e[0m 已启动：")
    IO.puts("  \e[36mhttp://127.0.0.1:#{port}\e[0m")
    IO.puts("\e[2mCtrl+C 退出\e[0m")

    # 前台挂起（mix task 语义：像 TUI 一样占住终端）
    Process.sleep(:infinity)
  end
end
