defmodule Mix.Tasks.Newbee.Tui do
  @shortdoc "启动 newbee TUI（全屏）"
  @moduledoc "启动 newbee TUI：`mix newbee.tui`（需在真实终端，raw 模式由 bin/newbee 预设）"
  use Mix.Task

  @impl true
  def run(_args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")
    Newbee.TUI.start()
  end
end
