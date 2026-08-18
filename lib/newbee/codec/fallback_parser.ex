defmodule Newbee.Codec.FallbackParser do
  @moduledoc """
  降级通道 (DESIGN §4.2)：模型偶发在文本里输出 ```elixir 代码块时，
  容错解析器兜底执行（并温和纠偏）。主协议仍是 function calling，
  这是"模型出格式错误也不断链"的保险丝。

  返回的块按出现顺序；清理后的文本保留块外的内容。
  """

  @doc """
  从模型输出文本提取 Elixir 代码块。

  返回 `{blocks, cleaned}`：
    - blocks: 代码字符串列表（```elixir / ``` 围栏，按出现顺序）
    - cleaned: 去掉代码块后的剩余文本（块位置替换为占位提示）
  """
  def extract(text) when is_binary(text) do
    {blocks, cleaned_parts} =
      text
      |> String.split(~r/```(?:elixir)?\s*\n?/)
      |> do_extract()

    {blocks, cleaned_parts}
  end

  def extract(_), do: {[], ""}

  # 围栏把文本切成 奇数段=代码 偶数段=普通（第一段普通）
  defp do_extract(parts) do
    parts
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn
      {part, i}, {blocks, cleaned} when rem(i, 2) == 1 ->
        # 围栏内（注意：闭合 ``` 已作为分隔符被吞，需去掉尾部的 ``` 残片）
        code = String.trim_trailing(part)
        {blocks ++ [code], cleaned}

      {part, _}, {blocks, cleaned} ->
        {blocks, cleaned ++ [part]}
    end)
    |> then(fn {b, c} -> {b, Enum.join(c, "")} end)
  end

  @doc "文本是否含 elixir 代码块。"
  def has_block?(text) when is_binary(text) do
    Regex.match?(~r/```(?:elixir)?\s*\n/, text)
  end

  def has_block?(_), do: false

  @doc "纠偏提示（温和：提示用 run_elixir 工具而非裸代码块）。"
  def correction_reminder do
    "[协议提示] 你刚才在正文里直接输出了 ```elixir 代码块。环境已替你执行，" <>
      "但更高效的做法是调用 run_elixir 工具（代码作为参数）——正文里输出代码" <>
      "会消耗大量 token 且不进入工具结果流。请用 run_elixir。"
  end
end
