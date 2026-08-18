defmodule Newbee.DEE.ResultSanitizeTest do
  use ExUnit.Case, async: true
  alias Newbee.DEE.Result

  # 回归：工具输出含非法 UTF-8（读二进制）时，回填必须可序列化，不能崩 kernel
  test "sanitize 替换非法字节为 U+FFFD" do
    bad = <<0x8C, "abc">>
    assert String.valid?(Result.sanitize(bad))
    assert Result.sanitize(bad) == <<0xFFFD::utf8, "abc">>
  end

  test "合法 UTF-8 原样保留" do
    s = "中文 ✓ ok"
    assert Result.sanitize(s) == s
  end

  test "render 对含非法字节的输出不抛异常" do
    result = %{status: :ok, value: <<0x8C>>, output: "run ok\n"}
    assert is_binary(Result.render(result))
    # 整条可被 Jason 编码（Session.append 的路径）
    assert {:ok, _} = Jason.encode(%{"role" => "tool", "content" => Result.render(result)})
  end
end


:ok