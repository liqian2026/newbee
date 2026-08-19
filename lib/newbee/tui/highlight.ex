defmodule Newbee.TUI.Highlight do
  @moduledoc """
  Elixir 代码语法高亮（ANSI）：注释/字符串/sigil/数字/原子/关键字/模块属性着色。

  - 零依赖正则扫描，一次 pass；
  - 高亮只插入 ANSI 转义，不改变字符宽度——Screen 折行/光标列不受影响；
  - 非 Elixir 文本原样返回（不崩溃、不加色）。
  """

  @keywords ~w(def defp defmacro defmacrop defguard defguardp defmodule defimpl defprotocol
    defdelegate defoverridable do end fn if else unless case cond with for try rescue catch
    after when and or not in true false nil import alias require use quote unquote super
    raise throw return struct module receive)

  # 组序: 1注释 2/3heredoc 4串 5字符表 6-10 sigil 11进制数 12小数 13原子 14模块属性 15标识符 16单字符
  @token ~r/(#[^\n]*)|("""[\s\S]*?""")|('''[\s\S]*?''')|("(?:[^"\\]|\\.)*")|('(?:[^'\\]|\\.)*')|(~[a-zA-Z]?\/[^\/\\]*(?:\\.[^\/\\]*)*\/[a-zA-Z]*)|(~[a-zA-Z]?\([^)\\]*(?:\\.[^)\\]*)*\)[a-zA-Z]*)|(~[a-zA-Z]?\[[^\]\\]*(?:\\.[^\]\\]*)*\][a-zA-Z]*)|(~[a-zA-Z]?\{[^}\\]*(?:\\.[^}\\]*)*\}[a-zA-Z]*)|(~[a-zA-Z]?<[^>\\]*(?:\\.[^>\\]*)*>[a-zA-Z]*)|(0[xXbBoO][0-9a-fA-F_]+)|(\b\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?\b)|(:[a-zA-Z_]\w*[?!]?)|(@[a-zA-Z_]\w*[?!]?)|(\b[a-zA-Z_]\w*[?!]?\b)|(.)/s

  @doc "把 Elixir 代码染成 ANSI 彩色；非二进制原样返回。"
  def elixir(code) when is_binary(code) do
    Regex.scan(@token, code, capture: :all_but_first)
    |> Enum.map_join(&color/1)
  end

  def elixir(other), do: other

  # 组序与颜色（Regex.scan 未参与组为 "" 且尾部截断，故 zip 后找首个非空）
  @types [
    :comment,
    :heredoc,
    :heredoc,
    :string,
    :charlist,
    :sigil,
    :sigil,
    :sigil,
    :sigil,
    :sigil,
    :num,
    :num,
    :atom,
    :attribute,
    :ident,
    :single
  ]

  # 注释灰 / 字符串系绿 / 数字黄 / 原子黄 / 模块属性紫 / 关键字蓝 / 其余原样
  defp color(caps) do
    case caps |> Enum.zip(@types) |> Enum.find(fn {c, _t} -> c != "" end) do
      {text, :comment} -> gray(text)
      {text, t} when t in [:heredoc, :string, :charlist, :sigil] -> green(text)
      {text, t} when t in [:num, :atom] -> yellow(text)
      {text, :attribute} -> "\e[35m" <> text <> "\e[0m"
      {text, :ident} -> if text in @keywords, do: blue(text), else: text
      {text, :single} -> text
      nil -> ""
    end
  end

  defp gray(t), do: "\e[2m" <> t <> "\e[0m"
  defp green(t), do: "\e[32m" <> t <> "\e[0m"
  defp yellow(t), do: "\e[33m" <> t <> "\e[0m"
  defp blue(t), do: "\e[34m" <> t <> "\e[0m"
end
