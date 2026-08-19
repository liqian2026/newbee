defmodule Newbee.PermissionsTest do
  use ExUnit.Case, async: false
  alias Newbee.Permissions

  setup do
    old = Permissions.get()
    on_exit(fn -> Permissions.set(old) end)
    :ok
  end

  test "lenient 全放行" do
    Permissions.set(:lenient)
    assert Permissions.check("File.write!(\"x\", \"y\")") == :allow
    assert Permissions.check("1 + 1") == :allow
  end

  test "ask 档危险操作询问、普通放行" do
    Permissions.set(:ask)
    assert Permissions.check("File.rm_rf!(\"x\")") == :ask
    assert Permissions.check("Newbee.Tools.Run.sh(\"mix test\")") == :ask
    assert Permissions.check("Enum.map([1], &(&1 + 1))") == :allow
  end

  test "deny 档危险操作拒绝、普通放行" do
    Permissions.set(:deny)
    assert Permissions.check("File.write!(\"x\", \"y\")") == :deny
    assert Permissions.check("1 + 1") == :allow
  end

  test "set/get 持久化" do
    Permissions.set(:ask)
    assert Permissions.get() == :ask
  end
end
