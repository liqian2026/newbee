defmodule Newbee.TUI.Cards do
  @moduledoc """
  工具块/命令卡片渲染（TUI 与 CLI 共用）：┌─ 标题 ─ 代码预览 ─ └─ 状态徽章 · 智能摘要 ─。
  统一两端的展示，避免样式漂移。
  """

  @doc "工具块头：┌─ ⏺ name · title"
  def tool_header(name, title) do
    "\e[36m┌─\e[0m \e[1m⏺ #{name}\e[0m\e[2m · #{title}\e[0m"
  end

  @doc """
  工具块代码预览（前 3 行，语法高亮，│ 缩进，超长省略）。
  返回 nil 表示无代码可显示。
  """
  def tool_preview(code) when is_binary(code) do
    preview = code |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")
    ellipsis = if String.contains?(code, "\n"), do: " …", else: ""

    if preview == "" do
      nil
    else
      "\n\e[2m│  \e[0m" <>
        Newbee.TUI.Highlight.elixir(preview) <>
        if ellipsis == "", do: "", else: "\e[2m" <> ellipsis <> "\e[0m"
    end
  end

  def tool_preview(_), do: nil

  @doc "工具块脚：└─ ✓/✗/⎿ · 智能摘要"
  def tool_footer(text) when is_binary(text) do
    {status, body} =
      case text do
        "✓ ok\n" <> rest -> {:ok, rest}
        "✗ error\n" <> rest -> {:error, rest}
        other -> {:info, other}
      end

    badge =
      case status do
        :ok -> "\e[32m└─ ✓\e[0m"
        :error -> "\e[31m└─ ✗\e[0m"
        :info -> "\e[36m└─ ⎿\e[0m"
      end

    badge <> " \e[2m#{smart_summary(status, body)}\e[0m"
  end

  @doc "错误详情卡内行（│ 前缀，去掉 ✗ error 头，避免双重 ✗）。"
  def error_line(text) when is_binary(text) do
    body = String.replace_prefix(text, "✗ error\n", "")
    "\e[31m│\e[0m " <> String.slice(body, 0, 400)
  end

  @doc """
  diff 卡片：标题 + 带行号/语法高亮的行 + 脚。返回渲染行列表（TUI/CLI 共用）。
  行号：上下文行双号、删除行旧号、新增行新号；.ex/.exs 内容做 Elixir 语法高亮。
  """
  def diff_card(path, diff, stats) do
    header = "\e[36m┌─ diff #{path} (+#{stats.added} -#{stats.removed}) ─\e[0m"

    body =
      diff
      |> String.split("\n")
      |> Enum.take(60)
      |> numbered()
      |> Enum.map(&render_diff_line(&1, path))

    [header | body] ++ ["\e[36m└─\e[0m"]
  end

  # 逐行推进 old/new 行号：{old_no, new_no, raw_line}
  defp numbered(lines) do
    {rev, _} =
      Enum.reduce(lines, {[], {0, 0}}, fn line, {acc, {old, new}} ->
        cond do
          String.starts_with?(line, "+ ") -> {[{old, new + 1, line} | acc], {old, new + 1}}
          String.starts_with?(line, "- ") -> {[{old + 1, new, line} | acc], {old + 1, new}}
          true -> {[{old + 1, new + 1, line} | acc], {old + 1, new + 1}}
        end
      end)

    Enum.reverse(rev)
  end

  defp render_diff_line({old, new, line}, path) do
    # Newbee.Diff 上下文行不带 "  " 前缀，只有 +/- 行带；别误切内容
    {marker, color, content} =
      cond do
        String.starts_with?(line, "+ ") -> {"+", "\e[32m", String.slice(line, 2, max(String.length(line) - 2, 0))}
        String.starts_with?(line, "- ") -> {"-", "\e[31m", String.slice(line, 2, max(String.length(line) - 2, 0))}
        true -> {" ", "\e[2m", line}
      end

    content = if path =~ ~r/\.exs?$/, do: Newbee.TUI.Highlight.elixir(content), else: content
    color <> gutter(old, new) <> marker <> " " <> content <> "\e[0m"
  end

  # 行号栏：旧号(3) 新号(3) │  未变行双号、删除行旧号、新增行新号
  defp gutter(old, new) do
    o = if old == 0, do: "   ", else: String.pad_leading(Integer.to_string(old), 3)
    n = if new == 0, do: "   ", else: String.pad_leading(Integer.to_string(new), 3)
    o <> " " <> n <> " │ "
  end

  @doc "shell 命令卡片头：┌─ $ cmd"
  def shell_header(cmd) do
    "\e[36m┌─\e[0m \e[1m$\e[0m \e[2m#{cmd}\e[0m"
  end

  @doc "shell 结果脚：└─ ✓/✗ exit N · 智能摘要"
  def shell_footer(%{exit: exit, output: output}) do
    badge = if exit == 0, do: "\e[32m└─ ✓\e[0m", else: "\e[31m└─ ✗\e[0m"
    summary = if exit == 0, do: smart_summary(:ok, output), else: smart_summary(:error, output)
    badge <> " \e[2mexit #{exit} · #{summary}\e[0m"
  end

  @doc "智能摘要：ExUnit 测试统计 / 错误首行 / 首个非空行。"
  def smart_summary(:ok, body) do
    case Regex.run(~r/(\d+) tests?, (\d+) failures?/, body) do
      [_, t, f] -> "#{t} tests, #{f} failures"
      nil -> first_line(body) || "ok"
    end
  end

  def smart_summary(:error, body), do: first_line(body) || "error"
  def smart_summary(:info, body), do: first_line(body) || "ok"

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> nil
      line -> line |> String.trim() |> String.slice(0, 100)
    end
  end
end
