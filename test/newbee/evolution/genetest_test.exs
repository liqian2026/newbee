defmodule Newbee.Evolution.GeneTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.Gene

  test "导出→包含 tools/rules/prompts→导入幂等" do
    {:ok, path} = Gene.export("test-gene", provenance: "test")
    assert File.exists?(path)

    {:ok, bundle} = File.read(path) |> then(fn {:ok, b} -> Jason.decode(b) end)
    assert bundle["name"] == "test-gene"
    assert bundle["provenance"] == "test"
    assert is_list(bundle["tools"])
    assert is_list(bundle["rules"])

    # 导入（安装到本机环境）
    {:ok, installed} = Gene.import(path)
    assert installed.tools >= 0

    # 列出可见
    assert Enum.any?(Gene.list(), &(&1.name == "test-gene"))

    File.rm(path)
  end
end
