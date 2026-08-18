defmodule Mix.Tasks.Newbee.Bench do
  @shortdoc "跑公开基准（bench 任务集 + 抗体回放）"
  @moduledoc "跑公开基准任务集（真实 LLM）。"
  use Mix.Task

  @impl true
  def run(_args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")

    IO.puts("抗体回放（反事实裁判）…")
    {passed, failed, details} = Newbee.Evolution.Bench.replay()
    IO.puts("antibodies: #{passed} passed / #{failed} failed")

    if failed > 0 do
      Enum.each(details, fn {id, ok, detail} ->
        if !ok, do: IO.puts("  ❌ #{id}: #{String.slice(detail, 0, 200)}")
      end)
    end

    IO.puts("\n任务集（真实 LLM，可能要几分钟）…")
    client = Newbee.LLM.Config.client_for()
    report = Newbee.Evolution.Bench.run_tasks(client)
    IO.puts("bench: #{report.passed}/#{report.total} 通过, #{report.tokens} tokens")

    Enum.each(report.details, fn d ->
      IO.puts("  #{if d.passed, do: "✅", else: "❌"} #{d.id} (#{d.tokens} tok)")
    end)
  end
end
