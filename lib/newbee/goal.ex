defmodule Newbee.Goal do
  # 每轮：submit → 根据结果决定继续/停止
  def run(kernel, text, opts)  # 同步跑整个 goal（在调用方进程）
  def continue(kernel, text)   # 单轮驱动
end