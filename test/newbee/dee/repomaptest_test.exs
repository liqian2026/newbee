defmodule Newbee.DEE.RepoMapTest do
  use ExUnit.Case, async: false

  test "提取模块签名与 moduledoc" do
    map = Newbee.DEE.RepoMap.build(".")
    assert map =~ "Newbee.DEE.Evaluator"
    assert map =~ "def eval"
    assert map =~ "@ lib/newbee/dee/evaluator.ex"
  end

  test "非 Elixir 目录退化为文件树" do
    dir = System.tmp_dir!()
    map = Newbee.DEE.RepoMap.build(dir)
    assert is_binary(map)
  end
end