defmodule Newbee.TUIReasoningTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI

  # 回归：DeepSeek 思考流 (:reasoning) 灰色独立行渲染，正文另起一行
  test "reasoning 与 text 各自开行，互不拼接" do
    state = %TUI{} |> TUI.push_line("› 你好")

    s1 = TUI.render_event(state, :reasoning, {:reasoning, "想"})
    assert List.last(s1.lines) == "\e[2m想"
    assert s1.stream_kind == :reasoning

    s2 = TUI.render_event(s1, :reasoning, {:reasoning, "考中"})
    assert List.last(s2.lines) == "\e[2m想考中"

    # 正文切流：开新行，不带灰色前缀
    s3 = TUI.render_event(s2, :text, {:text, "你好"})
    assert List.last(s3.lines) == "你好"
    assert s3.stream_kind == :text

    s4 = TUI.render_event(s3, :text, {:text, "！"})
    assert List.last(s4.lines) == "你好！"
  end

  test "工具输出打断思考流后，新思考仍开新行" do
    state = %TUI{} |> TUI.push_line("› x")
    s1 = TUI.render_event(state, :reasoning, {:reasoning, "a"})
    s2 = TUI.render_event(s1, :tool_result, {:tool_result, :r, "out"})
    assert s2.stream_kind == nil

    s3 = TUI.render_event(s2, :reasoning, {:reasoning, "b"})
    assert List.last(s3.lines) == "\e[2mb"
  end
end
