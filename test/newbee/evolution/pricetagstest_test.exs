defmodule Newbee.Evolution.PriceTagsTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.PriceTags

  # 全局进程会累积其他测试的事件——用基线做相对断言
  defp baseline do
    Map.get(PriceTags.summary(), "run_elixir", %{calls: 0, errors: 0, avg_bytes: 0})
  end

  test "价签随工具事件累积" do
    b = baseline()
    Newbee.Bus.emit_sync(:tool_start, {:tool_start, "run_elixir", "t", "code"})
    Process.sleep(10)
    Newbee.Bus.emit_sync(:tool_result, {:tool_result, "run_elixir", "hello world"})

    s = Map.get(PriceTags.summary(), "run_elixir")
    assert s.calls == b.calls + 1
    assert s.avg_bytes > 0
  end

  test "错误计入成功率" do
    b = baseline()
    Newbee.Bus.emit_sync(:tool_start, {:tool_start, "run_elixir", "t2", "code"})
    Newbee.Bus.emit_sync(:tool_error, {:tool_error, "boom"})
    Newbee.Bus.emit_sync(:tool_result, {:tool_result, "run_elixir", "x"})

    s = Map.get(PriceTags.summary(), "run_elixir")
    assert s.errors >= b.errors + 1
    assert s.calls == b.calls + 1
    assert s.success_rate < 1.0
  end
end
