defmodule Newbee.TUI.ScreenTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Screen

  test "短行不折" do
    assert ["abc"] = Screen.wrap(["abc"], 20)
  end

  test "超宽 ASCII 行真实折行" do
    rows = Screen.wrap([String.duplicate("a", 30)], 11)
    assert length(rows) >= 3
    # 拼回去内容无损
    assert rows |> Enum.join() |> String.contains?("aaaaaaaaaaa")
  end

  test "中文按可见宽度折（双宽不折进半格）" do
    # 10 列宽：每行最多 4 个中文（8 列）+ 1 空隙
    rows = Screen.wrap(["中文中文中文中文中文"], 10)
    assert length(rows) == 3
    assert Enum.all?(rows, fn r -> Newbee.TUI.Line.width(plain(r)) <= 10 end)
  end

  test "ANSI 颜色段不占宽度" do
    colored = "\e[31m红\e[0m" <> String.duplicate("x", 8)
    assert [_one] = Screen.wrap([colored], 12)
  end

  test "折行保留 ANSI 样式" do
    rows = Screen.wrap(["\e[32m" <> String.duplicate("a", 20) <> "\e[0m"], 8)
    assert Enum.all?(rows, &String.starts_with?(&1, "\e["))
  end

  test "多行输入逐行折" do
    rows = Screen.wrap(["aaaa", "bbbb"], 10)
    assert rows == ["aaaa", "bbbb"]
  end

  test "wrap_tail 保持显示顺序（旧上新下），只折尾部" do
    lines = Enum.map(1..10, &"line#{&1}")
    {rows, complete?} = Screen.wrap_tail(lines, 80, 3)
    assert rows == ["line8", "line9", "line10"]
    refute complete?
  end

  test "wrap_tail 行数不足时 complete?=true（已到顶）" do
    assert {["a", "b"], true} = Screen.wrap_tail(["a", "b"], 80, 5)
  end

  test "wrap_tail 尾部宽行先折行，凑够即停" do
    wide = String.duplicate("x", 30)
    {rows, complete?} = Screen.wrap_tail(["top", wide], 11, 2)
    assert length(rows) == 3
    assert Enum.all?(rows, &String.contains?(&1, "x"))
    refute complete?
  end

  defp plain(s), do: String.replace(s, ~r/\e\[[0-9;]*[A-Za-z~]/, "")
end
