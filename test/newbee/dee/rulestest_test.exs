defmodule Newbee.DEE.RulesTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.Rules

  setup do
    # 备份并清空全局规则文件，测试后恢复
    file = Path.join(System.user_home!(), ".newbee/rules.json")
    backup = if File.exists?(file), do: File.read!(file), else: nil
    File.rm(file)
    :sys.replace_state(Rules, fn _ -> %Newbee.DEE.Rules{} end)

    on_exit(fn ->
      if backup, do: File.write!(file, backup), else: File.rm(file)
      :sys.replace_state(Rules, fn _ -> %Newbee.DEE.Rules{} end)
    end)

    :ok
  end

  test "注册规则并命中检查" do
    :ok = Rules.add("no-io-inspect", "IO\\.inspect", "生产代码路径不要用 IO.inspect 调试", source: :evolver)

    assert [%{id: "no-io-inspect"}] = Rules.check("IO.inspect(x)")
    assert [] = Rules.check("IO.puts(x)")
  end

  test "规则持久化到磁盘（沉睡——不占 prompt）" do
    :ok = Rules.add("persist-test", "danger", "小心")
    file = Path.join(System.user_home!(), ".newbee/rules.json")
    assert File.read!(file) =~ "persist-test"
    assert File.read!(file) =~ "小心"
  end

  test "重复 id 覆盖，remove 删除" do
    :ok = Rules.add("x", "a", "v1")
    :ok = Rules.add("x", "a", "v2")
    assert [%{injection: "v2"}] = Rules.check("a")
    Rules.remove("x")
    assert Rules.list() == []
  end
end