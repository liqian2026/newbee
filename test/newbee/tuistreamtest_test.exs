defmodule Newbee.TUIStreamTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI

  # 回归：回复文本必须从 "› 输入" 的下一行开始，不能拼在回显行尾
  test "首个 :text 事件开新行，后续增量追加到回复行" do
    state = %TUI{} |> TUI.push_line("› 你好")

    s1 = TUI.render_event(state, :text, {:text, "你"})
    # 开了新行，增量落进新行
    assert List.last(s1.lines) == "你"
    refute List.last(s1.lines) =~ "› 你好"
    assert length(s1.lines) == length(state.lines) + 1

    s2 = TUI.render_event(s1, :text, {:text, "好"})
    s3 = TUI.render_event(s2, :text, {:text, "！"})
    assert List.last(s3.lines) == "你好！"
    assert length(s3.lines) == length(state.lines) + 1
  end

  test "非 :text 事件后 streaming 重置，下一个回复仍开新行" do
    state = %TUI{} |> TUI.push_line("› a")
    s1 = TUI.render_event(state, :text, {:text, "x"})
    assert List.last(s1.lines) == "x"

    # 工具输出打断流
    s2 = TUI.render_event(s1, :tool_result, {:tool_result, :ref, "out"})
    assert List.last(s2.lines) =~ "out"

    s3 = TUI.render_event(s2, :text, {:text, "y"})
    assert List.last(s3.lines) == "y"
    # 新回复行与上一行分离
    assert length(s3.lines) == length(s2.lines) + 1
  end

  test "push_line 重置 streaming（提交回显后新回复开新行）" do
    state = %TUI{}
    s1 = TUI.render_event(state, :text, {:text, "a"})
    s2 = TUI.push_line(s1, "● done")
    assert s2.streaming == false

    s3 = TUI.render_event(s2, :text, {:text, "b"})
    assert List.last(s3.lines) == "b"
    assert length(s3.lines) == length(s2.lines) + 1
  end
end
