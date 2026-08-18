defmodule Newbee.DEE.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Newbee.DEE.Evaluator

  setup do
    {:ok, pid} = Evaluator.start(mode: :local)
    %{ev: pid}
  end

  test "求值并返回值", %{ev: ev} do
    r = Evaluator.eval(ev, "1 + 1", [])
    assert r.status == :ok
    assert r.value == "2"
  end

  test "绑定跨调用持久（模型的 IEx）", %{ev: ev} do
    Evaluator.eval(ev, "content = \"hello dee\"", [])
    r = Evaluator.eval(ev, "String.upcase(content)", [])
    assert r.status == :ok
    assert r.value =~ "HELLO DEE"
  end

  test "stdout 被捕获", %{ev: ev} do
    r = Evaluator.eval(ev, "IO.puts(\"from cell\")", [])
    assert r.output =~ "from cell"
  end

  test "错误返回格式化信息，绑定不污染", %{ev: ev} do
    Evaluator.eval(ev, "good = 1", [])
    r = Evaluator.eval(ev, "raise \"boom\"", [])
    assert r.status == :error
    assert r.error =~ "boom"
    # 失败调用前的绑定仍在
    assert Enum.any?(Evaluator.bindings_summary(ev), &(&1.name == :good))
  end

  test "超时返回错误", %{ev: ev} do
    r = Evaluator.eval(ev, "Process.sleep(:infinity)", timeout: 100)
    assert r.status == :error
    assert r.error =~ "timeout"
  end

  test "bindings_summary 只给摘要不给内容", %{ev: ev} do
    Evaluator.eval(ev, "secret = \"x\" |> String.duplicate(100_000)", [])
    [b] = Evaluator.bindings_summary(ev)
    assert b.name == :secret
    assert b.type == :binary
    assert b.size >= 10_000
  end

  test "reset 清空绑定", %{ev: ev} do
    Evaluator.eval(ev, "x = 1", [])
    Evaluator.reset(ev)
    assert Evaluator.bindings_summary(ev) == []
  end
end
