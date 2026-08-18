defmodule Newbee.DEE.Result do
  @moduledoc """
  结果压缩 (DESIGN §4.3)：回填给模型的输出默认做头尾截断，
  长输出引导模型用 binding 或文件引用，而非全文塞回上下文。
  """

  @max_chars 8_000
  @head_ratio 0.6

  @doc "压缩文本为 head+tail 形式，附行数统计。"
  def compress(text, opts \\ []) when is_binary(text) do
    max = Keyword.get(opts, :max_chars, @max_chars)

    if byte_size(text) <= max do
      text
    else
      head = floor(max * @head_ratio)
      tail = max - head
      total_lines = text |> String.split("\n") |> length()

      binary_part(text, 0, head) <>
        "\n… [compressed: #{byte_size(text)} bytes, #{total_lines} lines; " <>
        "用 binding 变量或写文件后再局部读取] …\n" <>
        binary_part(text, byte_size(text) - tail, tail)
    end
  end

  @doc "把求值结果 map 渲染成回填给模型的字符串。"
  def render(%{status: :ok, value: value, output: output}) do
    body = sanitize(output <> "\n" <> value) |> compress() |> sanitize()
    "✓ ok\n" <> body
  end

  def render(%{status: :error, error: error, output: output}) do
    body = sanitize(output <> "\n" <> error) |> compress() |> sanitize()
    "✗ error\n" <> body
  end

  @doc """
  清洗非法 UTF-8：工具输出可能是任意字节（读二进制文件等），
  直接回填会让 Session.append 的 Jason 编码崩溃（kernel 死亡）。
  非法字节替换为 U+FFFD，且每次至少消费一个坏字节，保证终止。
  """
  def sanitize(s) when is_binary(s) do
    case :unicode.characters_to_binary(s, :utf8, :utf8) do
      bin when is_binary(bin) ->
        bin

      {:error, good, <<_invalid, rest::binary>>} ->
        good <> <<0xFFFD::utf8>> <> sanitize(rest)

      {:incomplete, good, _incomplete} ->
        good <> <<0xFFFD::utf8>>
    end
  end

  def sanitize(other), do: inspect(other)
end