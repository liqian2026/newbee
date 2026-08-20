defmodule Newbee.Codec.FallbackParserTest do
  use ExUnit.Case, async: true
  alias Newbee.Codec.FallbackParser

  test "提取 ```elixir 块并清理正文" do
    text = "先看代码：\n```elixir\nx = 1 + 1\n```\n然后继续"

    {blocks, cleaned} = FallbackParser.extract(text)
    assert blocks == ["x = 1 + 1"]
    assert cleaned =~ "先看代码"
    assert cleaned =~ "然后继续"
  end

  test "裸围栏和 ASCII 图不执行" do
    text = "```\n┌─────┐\n│ 图表 │\n└─────┘\n```"
    assert {[], ^text} = FallbackParser.extract(text)
    refute FallbackParser.has_block?(text)
  end

  test "多块按顺序提取" do
    text = "```elixir\na = 1\n```\n中\n```elixir\nb = 2\n```"
    {blocks, _} = FallbackParser.extract(text)
    assert blocks == ["a = 1", "b = 2"]
  end

  test "无块时返回空" do
    assert FallbackParser.extract("普通文本") == {[], "普通文本"}
    refute FallbackParser.has_block?("普通文本")
    assert FallbackParser.has_block?("```elixir\nx\n```")
  end

  test "纠偏提示存在" do
    assert FallbackParser.correction_reminder() =~ "run_elixir"
  end
end
