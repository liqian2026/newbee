defmodule Mix.Tasks.Newbee.Doctor do
  @shortdoc "环境体检"
  @moduledoc "检查工具链、配置、目录结构，输出体检报告。"
  use Mix.Task

  @impl true
  def run(_args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")

    IO.puts("newbee doctor")
    IO.puts("───────────")

    elixir_v = System.version()
    IO.puts("Elixir: #{elixir_v}")

    otp_v =
      :erlang.system_info(:otp_release)
      |> List.to_string()

    IO.puts("OTP: #{otp_v}")

    case Newbee.LLM.Config.load() do
      {:ok, config} ->
        IO.puts("模型配置: #{config["model"] || "（未设置）"}")

      {:error, reason} ->
        IO.puts("模型配置: 缺失 (#{inspect(reason)}) —— 创建 ~/.newbee/model.json")
    end

    IO.puts("工具目录: #{Newbee.DEE.Tools.HotLoader.global_dir()} (#{length(Newbee.DEE.Tools.HotLoader.tool_files())} 个工具)")
    IO.puts("会话: #{length(Newbee.Session.list())} 个")
    IO.puts("规则: #{length(Newbee.DEE.Rules.list())} 条")
    IO.puts("快照: #{length(Newbee.Evolution.Snapshot.list())} 个")
    IO.puts("基因: #{length(Newbee.Evolution.Gene.list())} 个")
  end
end
