defmodule Newbee.TUIReasoningTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI

  # 回归：DeepSeek 思考流折叠为「▸ Think 思考中…」单行原地更新，正文另起一行
  test "reasoning 折叠为 Think 摘要行，text 另起一行" do
    state = %TUI{} |> TUI.push_line("› 你好")

    s1 = TUI.render_event(state, :reasoning, {:reasoning, "想"})
    assert s1.stream_kind == nil
    assert List.last(s1.lines) =~ "思考中…想"

    s2 = TUI.render_event(s1, :reasoning, {:reasoning, "考中"})
    assert List.last(s2.lines) =~ "思考中…想考中"

    # 正文切流：开新行
    s3 = TUI.render_event(s2, :text, {:text, "你好"})
    assert List.last(s3.lines) == "你好"
    assert s3.stream_kind == :text

    s4 = TUI.render_event(s3, :text, {:text, "！"})
    assert List.last(s4.lines) == "你好！"
  end

  test "工具输出打断思考流后，新思考仍在 Think 行更新" do
    state = %TUI{} |> TUI.push_line("› x")
    s1 = TUI.render_event(state, :reasoning, {:reasoning, "a"})
    s2 = TUI.render_event(s1, :tool_result, {:tool_result, :r, "out"})
    assert s2.stream_kind == nil

    s3 = TUI.render_event(s2, :reasoning, {:reasoning, "b"})
    # Think 行恢复更新（工具行之后），累积 a+b
    think_line = Enum.find(s3.lines, &String.contains?(&1, "思考中…"))
    assert think_line != nil
    assert think_line =~ "outb"
  end
end
