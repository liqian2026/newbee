defmodule Newbee.TUI.LineTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Line

  test "insert/backspace/delete 基本编辑" do
    l = %Line{} |> Line.insert("ab") |> Line.insert("cd")
    assert l.text == "abcd"

    l = Line.backspace(l)
    assert l.text == "abc"
    assert l.cur == 3

    l = %Line{} |> Line.insert("abc") |> Line.left() |> Line.left() |> Line.delete()
    assert l.text == "ac"
  end

  test "行首 backspace 不动" do
    l = Line.backspace(%Line{})
    assert l.text == "" and l.cur == 0
  end

  test "中文按 codepoint 删（一次退格删一个字）" do
    l = %Line{} |> Line.insert("中文")
    l = Line.backspace(l)
    assert l.text == "中"
    assert l.cur == 1
  end

  test "光标移动边界" do
    l = %Line{} |> Line.insert("ab")
    assert Line.left(l).cur == 1
    assert Line.left(Line.left(l)).cur == 0
    assert Line.left(Line.left(Line.left(l))).cur == 0
    assert Line.right(l).cur == 2
    assert Line.right(Line.right(l)).cur == 2
  end

  test "home/to_end" do
    l = %Line{} |> Line.insert("abc")
    assert Line.home(l).cur == 0
    assert Line.to_end(l).cur == 3
  end

  test "cut_to_start / cut_word" do
    l = %Line{} |> Line.insert("hello world") |> Line.home()
    assert Line.cut_to_start(l).text == "hello world"

    l2 = %Line{} |> Line.insert("hello world")
    # bash 式：词 + 前导空白一起删
    assert Line.cut_word(l2).text == "hello"

    l3 = %Line{} |> Line.insert("a b  c")
    assert Line.cut_word(l3).text == "a b"
  end

  test "历史：翻上去/翻回来，草稿保留" do
    l = %Line{} |> Line.insert("first")
    l = Line.push_hist(l, l.text) |> Line.clear()
    l = %{l | text: "second", cur: 6}
    l = Line.push_hist(l, l.text) |> Line.clear()

    # 编辑中的新行：↑ 时存草稿
    l = %{l | text: "draft", cur: 5}
    up = Line.hist_prev(l)
    assert up.text == "second"
    assert up.draft == "draft"

    up2 = Line.hist_prev(up)
    assert up2.text == "first"

    # ↓ 翻回草稿
    down = Line.hist_next(up2)
    assert down.text == "second"
    down2 = Line.hist_next(down)
    assert down2.text == "draft"
    assert down2.cur == 5
  end
end
