defmodule Newbee.History do
  @moduledoc """
  会话恢复时的历史回放渲染：把 transcript 消息（发给 LLM 的结构化 JSON）
  渲染成接近实时输出的终端文本行，供 CLI/TUI 共用。

  样式与实时渲染对齐：
  - user      → 绿色 `›` 提示符
  - assistant → 正文；reasoning 暗色
  - tool_call → `⏺ run_elixir 标题` + 代码预览（前 3 行）
  - tool 结果 → `⎿ ✓/✗` + 输出预览（前 6 行）
  """

  @doc "把历史消息渲染为带 ANSI 的行列表。"
  def render_lines(msgs) when is_list(msgs) do
    Enum.flat_map(msgs, &msg_lines/1)
  end

  # ── 单条消息 → 行列表 ──

  defp msg_lines(%{"role" => "user", "content" => parts}) when is_list(parts) do
    text =
      Enum.find_value(parts, "[图片]", fn
        %{"type" => "text", "text" => text} when is_binary(text) -> text
        _ -> nil
      end)

    ["\e[32m›\e[0m " <> text <> " \e[2m[图片]\e[0m"]
  end

  defp msg_lines(%{"role" => "user", "content" => c}) when is_binary(c) do
    case String.split(c, "\n") do
      [one] -> ["\e[32m›\e[0m " <> one]
      [first | rest] -> ["\e[32m›\e[0m " <> first | Enum.map(rest, fn l -> "  " <> l end)]
    end
  end

  defp msg_lines(%{"role" => "assistant"} = m) do
    reasoning_lines(m["reasoning"]) ++
      content_lines(m["content"]) ++
      tool_call_lines(m["tool_calls"] || [])
  end

  defp msg_lines(%{"role" => "tool", "content" => c}) when is_binary(c) do
    result_lines(c)
  end

  defp msg_lines(_), do: []

  # ── 各片段 ──

  defp reasoning_lines(nil), do: []
  defp reasoning_lines(""), do: []

  defp reasoning_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn l -> "\e[2m" <> l <> "\e[0m" end)
  end

  defp content_lines(nil), do: []
  defp content_lines(""), do: []
  defp content_lines(c), do: String.split(c, "\n")

  defp tool_call_lines(calls) do
    Enum.flat_map(calls, fn
      %{"function" => %{"name" => name, "arguments" => args}} ->
        {title, code} = decode_args(args)
        preview = code |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")
        ellipsis = if String.contains?(code, "\n"), do: " …", else: ""
        ["\e[36m⏺\e[0m \e[1m" <> name <> "\e[0m \e[2m" <> title <> "\e[0m", preview <> ellipsis]

      _ ->
        []
    end)
  end

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{"title" => t, "code" => c}} -> {t, c}
      {:ok, %{"code" => c}} -> {"", c}
      _ -> {"", args}
    end
  end

  defp decode_args(_), do: {"", ""}

  defp result_lines(text) do
    {mark, body} =
      case text do
        "✓ ok\n" <> rest -> {"\e[32m  ⎿ ✓\e[0m", rest}
        "✗ error\n" <> rest -> {"\e[31m  ⎿ ✗\e[0m", rest}
        other -> {"\e[36m  ⎿\e[0m", other}
      end

    preview =
      body
      |> String.trim()
      |> String.split("\n")
      |> Enum.take(6)
      |> Enum.join("\n    ")

    if preview == "", do: [mark], else: [mark <> " " <> preview]
  end
end
