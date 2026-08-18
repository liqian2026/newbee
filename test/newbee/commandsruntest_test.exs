defmodule Newbee.CommandsRunTest do
  use ExUnit.Case, async: true
  alias Newbee.Commands

  # 回归：run_command 曾把前导 "/" 传给 run/3，导致所有真实命令都报"未知命令"
  test "带斜杠命令正确分发（/rules 输出规则而非未知命令）" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/rules", %{say: say})
    assert_received {:said, msg}
    refute msg =~ "未知命令"
  end

  test "带参数命令正确分发（/policy off）" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/policy off", %{say: say})
    assert_received {:said, msg}
    refute msg =~ "未知命令"
    Newbee.Evolution.Policy.set(:background)
  end

  test "未知命令仍然报错" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/nope", %{say: say})
    assert_received {:said, msg}
    assert msg =~ "未知命令"
  end
end
