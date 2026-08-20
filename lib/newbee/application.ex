defmodule Newbee.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Newbee.Bus,
        Newbee.EventLog,
        Newbee.DEE.Rules,
        Newbee.Staging,
        Newbee.Environment.PluginSupervisor
      ] ++
        # test 环境不自动启动 Coordinator/Daemon（避免污染 cwd 的 .newbee；
        # 测试按需 start_link 并在 tmp 目录运行）
        if Mix.env() == :test do
          []
        else
          [Newbee.Environment.Coordinator, Newbee.Daemon]
        end

    opts = [strategy: :one_for_one, name: Newbee.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
