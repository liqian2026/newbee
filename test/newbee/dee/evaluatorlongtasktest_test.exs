defmodule Newbee.DEE.EvaluatorLongTaskTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.Evaluator

  # 回归：rpc.call 10s 硬超时曾把长任务（sleep 30s 等）误判节点死亡，
  # 切 standby/重启导致 ① 报 unavailable ② 副作用重复执行。
  # 修复后：async_call + nb_yield 轮询（总上限 300s），超时不重试不切节点。

  @tag :node
  test "长任务（>10s）正常返回，不误判节点死亡" do
    {:ok, ev} = Evaluator.start(mode: :node)
    # 等 standby 起来
    Process.sleep(2_000)

    t0 = System.monotonic_time(:millisecond)
    r = Evaluator.eval(ev, ":timer.sleep(12_000)\n\"long-ok\"", [])
    elapsed = System.monotonic_time(:millisecond) - t0

    assert r.status == :ok
    assert r.value =~ "long-ok"
    assert elapsed >= 11_000, "应等待任务完成而不是超时返回"

    GenServer.stop(ev)
  end

  @tag :node
  test "长任务副作用只执行一次（不重复）" do
    {:ok, ev} = Evaluator.start(mode: :node)
    Process.sleep(2_000)
    marker = Path.join(System.tmp_dir!(), "eval_long_marker_" <> Integer.to_string(System.unique_integer([:positive])))

    code = "File.write!(\"" <> marker <> "\", \"x\")\n:timer.sleep(12_000)\n\"done\""
    r = Evaluator.eval(ev, code, [])
    assert r.status == :ok
    assert File.read!(marker) == "x"
    File.rm(marker)

    GenServer.stop(ev)
  end

  @tag :node
  test "节点真死仍能切 standby（原有兜底不回归）" do
    {:ok, ev} = Evaluator.start(mode: :node)
    Process.sleep(2_000)

    st = :sys.get_state(ev)
    primary = st.node
    # 杀 primary 节点
    :peer.stop(st.peer)
    Process.sleep(500)

    r = Evaluator.eval(ev, "1 + 1", [])
    assert r.status == :ok
    assert r.value == "2"
    # 已切到 standby 且 restarts 累计
    st2 = :sys.get_state(ev)
    assert st2.node != primary
    assert st2.restarts >= 1

    GenServer.stop(ev)
  end
end
