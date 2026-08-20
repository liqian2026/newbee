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
    - blocks: 明确标注为 ```elixir 的代码字符串列表，按出现顺序
    - cleaned: 去掉 Elixir 代码块后的剩余文本
  """
  def extract(text) when is_binary(text) do
    regex = ~r/```elixir[ \t]*\n(?<code>.*?)```/is
    blocks = Regex.scan(regex, text, capture: :all_names) |> Enum.map(&(&1 |> List.first() |> String.trim_trailing()))
    cleaned = Regex.replace(regex, text, "")
    {blocks, cleaned}
  end

  def extract(_), do: {[], ""}

  @doc "文本是否含明确标注的 elixir 代码块。"
  def has_block?(text) when is_binary(text) do
    Regex.match?(~r/```elixir[ \t]*\n/i, text)
  end

  def has_block?(_), do: false

  @doc "纠偏提示（温和：提示用 run_elixir 工具而非裸代码块）。"
  def correction_reminder do
    "[协议提示] 你刚才在正文里直接输出了 ```elixir 代码块。环境已替你执行，" <>
      "但更高效的做法是调用 run_elixir 工具（代码作为参数）——正文里输出代码" <>
      "会消耗大量 token 且不进入工具结果流。请用 run_elixir。"
  end
end
