defmodule Newbee.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 事件总线 (§4.6)
      Newbee.Bus,
      # 事件日志（审计/回放源）
      Newbee.EventLog,
      # 沉睡规则 (§4.5)
      Newbee.DEE.Rules,
      # 指标采集 (§6.1)
      Newbee.Evolution.Metrics,
      # JIT 认知阶梯 (§6.2)
      Newbee.Evolution.JIT,
      # 编辑暂存区（/approve）
      Newbee.Staging,
      # 求值器（默认独立节点模式）
      {Newbee.DEE.Evaluator, [name: Newbee.DEE.Evaluator]}
    ]

    opts = [strategy: :one_for_one, name: Newbee.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
