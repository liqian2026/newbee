defmodule Newbee.DEE.Tools.HotLoaderTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.Tools.HotLoader

  setup do
    # 清理历史残留（测试可能失败后留下工具文件，污染 git log 断言）
    path = Path.join(HotLoader.global_dir(), "HotTestX.ex")
    if File.exists?(path), do: File.rm(path)
    :ok
  end

  test "发布工具：写文件 + git 版本化 + 热载到节点可调用" do
    src = """
    defmodule Newbee.Tools.HotTestX do
      @doc "测试工具"
      def ping, do: :pong
    end
    """

    # 注入求值器节点（用 named evaluator 的当前节点）
    {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :node)
    node = Newbee.DEE.Evaluator.info(ev).node

    {:ok, path} = HotLoader.publish("HotTestX", src, node: node, message: "test tool")
    assert File.exists?(path)
    assert path =~ ".newbee/tools"

    # git 版本化
    {log, 0} = System.cmd("git", ["-C", HotLoader.global_dir(), "log", "--oneline", "-1"], stderr_to_stdout: true)
    assert log =~ "test tool"

    # 节点内可调用
    r = Newbee.DEE.Evaluator.eval(ev, "apply(Newbee.Tools.HotTestX, :ping, [])")
    assert r.status == :ok
    assert r.value =~ "pong"

    GenServer.stop(ev)
    File.rm(path)
  end
end
