defmodule Newbee.Evolution.JITTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.JIT

  setup do
    :sys.replace_state(JIT, fn _ -> %Newbee.Evolution.JIT{} end)
    on_exit(fn -> :sys.replace_state(JIT, fn _ -> %Newbee.Evolution.JIT{} end) end)
    :ok
  end

  test "learn 登记 L1" do
    :ok = JIT.learn("l1", "改完必须 mix compile 验证")
    assert [%{id: "l1", level: :l1}] = JIT.list()
  end

  test "命中 3 次升 L2（落成沉睡规则）" do
    JIT.learn("hot", "不要用 IO.inspect 调试")
    JIT.hit("hot")
    JIT.hit("hot")
    assert {:promoted, :l2} = JIT.hit("hot")
    assert [%{id: "hot", level: :l2}] = JIT.list()
    assert [%{id: "hot"}] = Newbee.DEE.Rules.check("IO.inspect(x)")
    Newbee.DEE.Rules.remove("hot")
  end

  test "L3 失败 2 次 deopt 回 L2" do
    JIT.learn("t1", "某工具教训")
    JIT.promote_to_tool("t1", "Newbee.Tools.Fake")
    assert [%{level: :l3}] = JIT.list()
    JIT.fail("t1")
    assert {:deopted, :l2} = JIT.fail("t1")
    assert [%{level: :l2}] = JIT.list()
    Newbee.DEE.Rules.remove("t1")
  end

  test "持久化到 jit.json" do
    JIT.learn("persisted", "note")
    path = Path.join(System.user_home!(), ".newbee/evolution/jit.json")
    assert File.read!(path) =~ "persisted"
  end
end
