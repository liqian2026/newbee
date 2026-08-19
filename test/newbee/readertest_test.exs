defmodule Newbee.ReaderTest do
  use ExUnit.Case, async: true

  test "read 裸路径读文件" do
    {:ok, body} = Newbee.read("mix.exs")
    assert body =~ "newbee"
  end

  test "read 不存在文件返回错误" do
    assert {:error, _} = Newbee.read("no/such/file.txt")
  end

  test "read tool:// 拉取模块文档" do
    {:ok, docs} = Newbee.read("tool://Newbee.Tools.Edit")
    assert docs =~ "patch"
  end

  test "read rules:// 返回规则清单" do
    {:ok, rules} = Newbee.read("rules://")
    assert is_binary(rules)
  end

  test "read memory:// 不存在的记忆返回错误" do
    assert {:error, _} = Newbee.read("memory://definitely-not-here")
  end
end
