defmodule Newbee.EnvironmentCase do
  @moduledoc """
  环境测试基座：tmp 项目目录 + File.cd!（Store 以 cwd 为项目根）。

  ⚠️ File.cwd 是 VM 全局——用此基座的测试必须 async: false。
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Newbee.EnvironmentCase
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "newbee_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original_cwd = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf(tmp)
    end)

    # 无论测试内部是否重启过 Coordinator，退出时按名字兜底停止（防泄漏）
    on_exit(fn ->
      case Process.whereis(Newbee.Environment.Coordinator) do
        nil -> :ok
        pid -> Newbee.EnvironmentCase.stop_coordinator(pid)
      end
    end)

    {:ok, project_dir: tmp}
  end

  @doc "启动具名 Coordinator（默认名，供 CapabilityGate/Worker 等全局引用）。"
  def start_coordinator!(opts \\ []) do
    case Process.whereis(Newbee.Environment.Coordinator) do
      nil ->
        # 测试默认 manual 档（不依赖用户 ~/.newbee/config.json）
        {:ok, pid} = Newbee.Environment.Coordinator.start(Keyword.put_new(opts, :autonomy, :manual))
        pid

      pid ->
        pid
    end
  end

  def stop_coordinator(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    Newbee.Events.unregister_store()
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "一个合法的 tool release 源码（实现 PluginContract 静态子集）。"
  def tool_source(mod_name \\ "DemoTool", plugin_id \\ "tool.demo") do
    """
    defmodule Newbee.Plugins.#{mod_name} do
      @moduledoc "demo tool"
      @behaviour Newbee.Environment.PluginContract

      @impl true
      def id, do: "#{plugin_id}"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def describe, do: %{kind: :tool}
      @impl true
      def dependencies, do: []

      def hello, do: :world
    end
    """
  end

  @doc "一个合法的 rule release 源码。"
  def rule_source(id \\ "demo", pattern \\ "foo", injection \\ "别写 foo") do
    slug = String.replace(id, ~r/[^a-z0-9]/, "_")

    """
    defmodule Newbee.Plugins.Rules.#{Macro.camelize(slug)} do
      @moduledoc "demo rule"
      @behaviour Newbee.Environment.PluginContract

      @impl true
      def id, do: "rule.#{slug}"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def describe, do: %{kind: :rule, pattern: #{inspect(pattern)}, injection: #{inspect(injection)}, scope: :all}
      @impl true
      def dependencies, do: []
    end
    """
  end
end
