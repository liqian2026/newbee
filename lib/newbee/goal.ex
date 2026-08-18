defmodule Newbee.Goal do
  @moduledoc """
  自主目标驱动（/goal 的同步版）：逐轮 submit 直到 done / ask / 轮数上限。
  Kernel 内置的 set_goal 是异步模式（事件流驱动）；本模块提供
  阻塞式驱动（调用方进程内循环），供 CLI 直连场景使用。
  """

  @max_rounds 50

  @doc "同步跑完整 goal。返回 {:done, summary} | {:ask, q} | {:goal_limit, rounds} | {:error, e}。"
  def run(kernel, text, opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, @max_rounds)
    do_run(kernel, text, max_rounds, 1)
  end

  @doc "单轮驱动：提交一段文本（或继续指令），返回 submit 结果。"
  def continue(kernel, text) do
    Newbee.DEE.Kernel.submit(kernel, text)
  end

  defp do_run(_kernel, _text, max_rounds, round) when round > max_rounds do
    {:goal_limit, round - 1}
  end

  defp do_run(kernel, text, max_rounds, round) do
    input = if round == 1, do: text, else: "（自主模式第 #{round} 轮：目标未达成，请继续工作。达成后调用 done。）"

    case Newbee.DEE.Kernel.submit(kernel, input) do
      {:done, summary} -> {:done, summary}
      {:ask, q} -> {:ask, q}
      {:text, _} -> do_run(kernel, text, max_rounds, round + 1)
      {:interrupted, _} -> {:interrupted, :user}
      {:error, e} -> {:error, e}
    end
  end
end
