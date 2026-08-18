defmodule Mix.Tasks.Newbee.Daemon do
  @shortdoc "启动 newbee 常驻 daemon（后台自动进化）"
  @moduledoc "启动常驻 daemon：环境在终端关闭后依然存活、记忆、进化。"
  use Mix.Task

  @impl true
  def run(_args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")
    Newbee.Daemon.start()
  end
end
