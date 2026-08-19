defmodule Newbee.ReaderSchemeTest do
  use ExUnit.Case, async: true

  test "skill:// 不存在的技能返回错误" do
    assert {:error, :skill_not_found} = Newbee.read("skill://definitely-not-here")
  end

  test "agent:// 不存在的子代理返回错误" do
    assert {:error, :agent_not_found} = Newbee.read("agent://nope/findings")
  end

  test "conflict:// 在 git 仓库返回清单" do
    assert {:ok, _} = Newbee.read("conflict://")
  end

  test "tool:// 拉取模块文档含函数签名" do
    {:ok, docs} = Newbee.read("tool://Newbee.Tools.Edit")
    assert docs =~ "patch"
    assert docs =~ "show"
  end
end
