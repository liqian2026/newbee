defmodule Newbee.TUI.CardsTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Cards

  test "tool_header 含边框与名称" do
    assert Cards.tool_header("run_elixir", "mix test") =~ "┌─"
    assert Cards.tool_header("run_elixir", "mix test") =~ "run_elixir"
    assert Cards.tool_header("run_elixir", "mix test") =~ "mix test"
  end

  test "tool_preview 高亮并加 │ 前缀，空代码返回 nil" do
    preview = Cards.tool_preview("def foo, do: \"s\"")
    assert preview =~ "│"
    # 关键字高亮
    assert preview =~ "\e[34mdef\e[0m"
    assert Cards.tool_preview("") == nil
  end

  test "tool_preview 折叠态前 3 行，仅超 3 行才省略号" do
    p3 = Cards.tool_preview("l1\nl2\nl3")
    assert p3 =~ "l1"
    assert p3 =~ "l3"
    refute p3 =~ "…"

    p5 = Cards.tool_preview("l1\nl2\nl3\nl4\nl5")
    assert p5 =~ "l1"
    assert p5 =~ "l3"
    refute p5 =~ "l4"
    assert p5 =~ "…"
  end

  test "tool_footer 成功显示测试统计" do
    footer = Cards.tool_footer("✓ ok\nCompiling 1 file\n8 tests, 0 failures")
    assert footer =~ "└─ ✓"
    assert footer =~ "8 tests, 0 failures"
  end

  test "tool_footer 失败显示错误首行" do
    footer = Cards.tool_footer("✗ error\n** (CompileError) lib/x.ex:1: undefined function foo/0")
    assert footer =~ "└─ ✗"
    assert footer =~ "** (CompileError) lib/x.ex:1: undefined function foo/0"
  end

  test "error_line 去掉 ✗ error 头避免双重 ✗" do
    line = Cards.error_line("✗ error\n** (CompileError) boom")
    refute line =~ "✗ error"
    assert line =~ "│"
    assert line =~ "** (CompileError) boom"
  end

  test "shell_header / shell_footer 显示 exit 与摘要" do
    assert Cards.shell_header("mix test") =~ "┌─"
    assert Cards.shell_header("mix test") =~ "mix test"

    ok = Cards.shell_footer(%{exit: 0, output: "8 tests, 0 failures"})
    assert ok =~ "└─ ✓"
    assert ok =~ "exit 0"

    bad = Cards.shell_footer(%{exit: 2, output: "** (CompileError) boom"})
    assert bad =~ "└─ ✗"
    assert bad =~ "exit 2"
  end

  test "smart_summary 测试统计 / 错误 / 默认" do
    assert Cards.smart_summary(:ok, "8 tests, 0 failures") == "8 tests, 0 failures"
    assert Cards.smart_summary(:ok, "nothing") == "nothing"
    assert Cards.smart_summary(:error, "** (CompileError) x") == "** (CompileError) x"
    assert Cards.smart_summary(:ok, "") == "ok"
  end

  test "diff_card 带行号 + 语法高亮" do
    old = "a\nb\nc"
    new = "a\nX\nc"
    diff = Enum.join(Newbee.Diff.lines(old, new), "\n")
    lines = Cards.diff_card("lib/x.ex", diff, %{added: 1, removed: 1})

    assert hd(lines) =~ "┌─ diff lib/x.ex (+1 -1)"
    assert List.last(lines) =~ "└─"
    # 上下文行双号、删除行旧号、新增行新号
    assert Enum.any?(lines, &(&1 =~ "  1   1 │   a"))
    assert Enum.any?(lines, &(&1 =~ "  2   1 │ - b"))
    assert Enum.any?(lines, &(&1 =~ "  2   2 │ + X"))
    assert Enum.any?(lines, &(&1 =~ "  3   3 │   c"))
  end

  test "diff_card .ex 内容语法高亮，非 elixir 文件不染" do
    diff = "- old\n+ defmodule Foo do"
    ex_lines = Cards.diff_card("lib/a.ex", diff, %{added: 1, removed: 1})
    assert Enum.any?(ex_lines, &(&1 =~ "\e[34mdefmodule\e[0m"))

    md_lines = Cards.diff_card("README.md", diff, %{added: 1, removed: 1})
    # 非 elixir 文件不产生语法高亮色（\e[34m 关键字蓝是 Highlight 专属）
    refute Enum.any?(md_lines, &(&1 =~ "\e[34m"))
  end
end
