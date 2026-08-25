defmodule Newbee.Web.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Newbee.Web.Workspace

  test "mkdir 不会把同名普通文件报告为已创建目录" do
    root = Path.join(System.tmp_dir!(), "newbee-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    file = Path.join(root, "already-there")
    File.write!(file, "not a directory")

    assert {:error, "not_a_directory", _} = Workspace.mkdir(root, "already-there")
  end

  test "list_dir 将权限或 IO 错误转换为稳定错误结果" do
    root = Path.join(System.tmp_dir!(), "newbee-missing-#{System.unique_integer([:positive])}")

    assert {:error, "not_a_directory", _} = Workspace.list_dir(root)
  end

  test "mkdir 成功后返回绝对路径且重复调用幂等" do
    root = Path.join(System.tmp_dir!(), "newbee-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, target} = Workspace.mkdir(root, "child")
    assert Path.type(target) == :absolute
    assert File.dir?(target)
    assert {:ok, ^target} = Workspace.mkdir(root, "child")
  end
end
