defmodule Newbee.TUI.HighlightTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Highlight

  defp plain(s), do: String.replace(s, ~r/\e\[[0-9;]*[A-Za-z~]/, "")

  test "注释染灰" do
    assert Highlight.elixir("# 注释") =~ "\e[2m# 注释\e[0m"
  end

  test "字符串染绿" do
    assert Highlight.elixir(~s("hello")) =~ "\e[32m\"hello\"\e[0m"
  end

  test "关键字染蓝" do
    assert Highlight.elixir("defmodule Foo do") =~ "\e[34mdefmodule\e[0m"
    assert Highlight.elixir("defmodule Foo do") =~ "\e[34mdo\e[0m"
  end

  test "普通标识符不着色" do
    out = Highlight.elixir("foo_bar")
    refute out =~ "\e["
    assert out == "foo_bar"
  end

  test "数字与原子染黄" do
    assert Highlight.elixir("x = 42") =~ "\e[33m42\e[0m"
    assert Highlight.elixir(":ok") =~ "\e[33m:ok\e[0m"
  end

  test "sigil 染绿" do
    assert Highlight.elixir(~s(~r/\\d+/)) =~ "\e[32m"
    assert Highlight.elixir(~s(~w[a b])) =~ "\e[32m"
  end

  test "heredoc 整体染绿（跨行不断裂）" do
    code = "\"\"\"\n第一行\n第二行\n\"\"\""
    out = Highlight.elixir(code)
    assert out =~ "\e[32m\"\"\"\n第一行\n第二行\n\"\"\"\e[0m"
  end

  test "剥 ANSI 后与原文一致（宽度不变）" do
    code = """
    # 注释
    defmodule Foo do
      @doc "文档"
      def run(x) do
        ~r/\\d+/ |> Regex.match?("#{42}")
      end
    end
    """

    assert plain(Highlight.elixir(code)) == code
  end

  test "空串与非法输入安全" do
    assert Highlight.elixir("") == ""
    assert Highlight.elixir(nil) == nil
  end
end
