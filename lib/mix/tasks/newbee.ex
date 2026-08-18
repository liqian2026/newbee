defmodule Mix.Tasks.Newbee do
  @shortdoc "启动 newbee CLI（单列流式）"
  @moduledoc """
  启动 newbee CLI。

      mix newbee              # 交互式 CLI
      mix newbee -r <id>      # 恢复会话
  """
  use Mix.Task

  @impl true
  def run(args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")

    case args do
      ["-r", id] -> Newbee.CLI.resume(id)
      [] -> Newbee.CLI.start()
      other -> Mix.raise("未知参数: #{inspect(other)}（用法: mix newbee [-r <session-id>]）")
    end
  end
end
