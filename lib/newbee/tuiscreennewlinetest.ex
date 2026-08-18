defmodule Newbee.TUIScreenNewlineTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Screen

  # 回归：流式回复含 \n 时必须硬断行（:nl 语义），不能当作普通字符
  # 与终端自动换行错位（历史 bug：多行输出行乱）。
  test "内嵌换行硬断行为多行" do
    assert Screen.wrap(["a\nb"], 20) == ["a", "b"]
  end

  test "连续空行也各占一行" do
    assert Screen.wrap(["a\n\nb"], 20) == ["a", "", "b"]
  end

  test "多行输入正确展开为多屏幕行" do
    assert length(Screen.wrap(["l1\nl2\nl3"], 20)) == 3
  end

  test "ANSI 样式跨硬换行独立成行" do
    [first, second] = Screen.wrap(["\e[31mred\e[0m\nplain"], 20)
    assert first =~ "red"
    assert second == "plain"
  end

  test "硬换行与超宽折行组合" do
    rows = Screen.wrap([String.duplicate("x", 30) <> "\n" <> "y"], 10)
    # 30 个 x 在 10 列宽折 3 行 + y 1 行
    assert length(rows) == 4
  end

  test "wrap_tail 只折尾部，行序正确" do
    lines = ["head", "tail1\ntail2"]
    {rows, complete?} = Screen.wrap_tail(lines, 20, 3)
    assert complete? == true
    # 显示顺序：head, tail1, tail2
    assert rows == ["head", "tail1", "tail2"]
  end
end
