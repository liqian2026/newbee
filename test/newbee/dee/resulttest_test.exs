defmodule Newbee.DEE.ResultTest do
  use ExUnit.Case, async: true
  alias Newbee.DEE.Result

  test "短输出原样保留" do
    out = Result.render(%{status: :ok, value: "42", output: "hello\n"})
    assert out =~ "hello"
    assert out =~ "42"
    assert out =~ "✓"
  end

  test "长输出被压缩，头尾保留" do
    big = String.duplicate("line\n", 10_000)
    out = Result.render(%{status: :ok, value: ":done", output: big})
    assert byte_size(out) < 10_000
    assert out =~ "compressed"
    assert out =~ "line"
  end

  test "错误渲染" do
    out = Result.render(%{status: :error, error: "boom", output: ""})
    assert out =~ "✗"
    assert out =~ "boom"
  end
end
