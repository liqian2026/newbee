defmodule Newbee.DiffTest do
  use ExUnit.Case, async: true
  alias Newbee.Diff

  test "无变更时 diff 为空" do
    assert Diff.empty?("a\nb", "a\nb")
    assert Diff.lines("a\nb", "a\nb") == ["a", "b"]
  end

  test "局部修改标记 +/-" do
    ls = Diff.lines("line one\nline two\nline three\n", "line one\nLINE TWO\nline three\n")
    assert "- line two" in ls
    assert "+ LINE TWO" in ls
    assert "line one" in ls
    assert "line three" in ls
  end

  test "插入与删除" do
    ls = Diff.lines("a\nc", "a\nb\nc")
    assert "+ b" in ls
    assert Diff.stats("a\nc", "a\nb\nc") == %{added: 1, removed: 0}

    ls2 = Diff.lines("a\nb\nc", "a\nc")
    assert "- b" in ls2
    assert Diff.stats("a\nb\nc", "a\nc") == %{added: 0, removed: 1}
  end

  test "空文件" do
    ls = Diff.lines("", "hello\n")
    assert "+ hello" in ls
    refute Diff.empty?("", "hello\n")
  end
end
