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

    cfg = Newbee.LLM.Config.load()
    default = cfg["roles"]["default"] || %{}
    provider = cfg["providers"][default["provider"]] || %{}
    IO.puts("模型配置: #{default["provider"]}/#{default["model"]} @ #{provider["baseUrl"]}")

    client = Newbee.LLM.Config.client_for("default")
    key_hint = if client.api_key, do: "已配置", else: "缺失!"
    IO.puts("API key: #{key_hint}（#{String.slice(client.api_key || "", 0, 8)}…）")

    IO.puts("工具目录: #{Newbee.DEE.Tools.HotLoader.global_dir()} (#{length(Newbee.DEE.Tools.HotLoader.tool_files())} 个工具)")
    IO.puts("会话: #{length(Newbee.Session.list())} 个")
    IO.puts("规则: #{length(Newbee.DEE.Rules.list())} 条")
    IO.puts("快照: #{length(Newbee.Evolution.Snapshot.list())} 个")
    IO.puts("基因: #{length(Newbee.Evolution.Gene.list())} 个")
  end
end
