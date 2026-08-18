defmodule Newbee.Commands do
  @moduledoc """
  CLI/TUI 共用的命令处理 (DESIGN §5.3)。命令对当前 kernel pid 操作；
  /resume 需要重建 kernel ——由调用方传入 restart fun。
  """

  @commands ~w(/model /bindings /tokens /rules /dump /resume /reset /approve
    /reject /log /snapshot /rollback /evolve /policy /genes /bench /quit)

  def commands, do: @commands

  @doc "处理输入。返回 :ok | :handled | :quit | {:submit, text} | {:resume, id}。"
  def handle(input, ctx) do
    case String.trim(input) do
      "" -> :ok
      "/quit" -> :quit
      "/" <> _ = cmd -> run_command(cmd, ctx)
      text -> {:submit, expand_at_files(text)}
    end
  end

  @doc "codex 式 @文件语法：@path 展开为文件内容块（≤10KB）。"
  def expand_at_files(text) do
    Regex.replace(~r/@([\w\.\-\/]+)/, text, fn _, path ->
      if File.exists?(path) and File.regular?(path) do
        body = File.read!(path) |> String.slice(0, 10_240)
        "\n\n[文件 #{path}]\n```\n" <> body <> "\n```\n"
      else
        "@" <> path
      end
    end)
  end

  defp run_command(cmd, ctx) do
    [name | rest] = String.split(cmd, " ", parts: 2)
    arg = List.first(rest) || ""
    run(String.trim_leading(name, "/"), arg, ctx)
  end

  defp run("reset", _, ctx) do
    Newbee.DEE.Evaluator.reset()
    ctx.say.("求值器节点已重建（绑定清空，热载工具重新加载）")
    :handled
  end

  defp run("bindings", _, ctx) do
    case Newbee.DEE.Evaluator.bindings_summary() do
      [] -> ctx.say.("（空）")
      bs -> Enum.each(bs, &ctx.say.("  #{&1.name} : #{&1.type} (#{&1.size} bytes)"))
    end

    :handled
  end

  defp run("tokens", _arg, ctx) do
    usage = Newbee.DEE.Kernel.usage(ctx.kernel)
    ctx.say.("usage: #{inspect(usage)}")

    if Process.whereis(Newbee.Evolution.Metrics) do
      ctx.say.("metrics: #{inspect(Newbee.Evolution.Metrics.summary())}")
    end

    :handled
  end

  defp run("model", _, ctx) do
    Newbee.LLM.Config.describe() |> Enum.each(&ctx.say.("  " <> &1))
    ctx.say.("evolution policy: #{Newbee.Evolution.Policy.get()}")
    :handled
  end

  defp run("rules", _, ctx) do
    case Newbee.DEE.Rules.list() do
      [] -> ctx.say.("（无沉睡规则）")
      rules -> Enum.each(rules, &ctx.say.("  [#{&1.id}] /#{&1.pattern}/ → #{&1.injection}"))
    end

    :handled
  end

  defp run("dump", _, ctx) do
    info = Newbee.DEE.Evaluator.info()
    ctx.say.("环境自画像")
    ctx.say.("  求值器: #{info.mode} #{inspect(info.node)} restarts=#{info.restarts} alive=#{info.alive}")
    ctx.say.("  热载工具: #{length(Newbee.DEE.Tools.HotLoader.tool_files())} 个")
    ctx.say.("  沉睡规则: #{length(Newbee.DEE.Rules.list())} 条")
    ctx.say.("  JIT 阶梯: #{inspect(Enum.map(Newbee.Evolution.JIT.list(), &{&1.id, &1.level}))}")
    ctx.say.("  快照: #{inspect(Newbee.Evolution.Snapshot.list() |> Enum.take(3))}")
    ctx.say.("  会话: #{inspect(Newbee.Session.list() |> Enum.take(5))}")
    :handled
  end

  defp run("resume", "", ctx) do
    ctx.say.("最近会话: #{inspect(Newbee.Session.list() |> Enum.take(8))}")
    ctx.say.("用法: /resume <id>")
    :handled
  end

  defp run("resume", id, _ctx), do: {:resume, String.trim(id)}

  defp run("approve", arg, ctx) do
    id = if arg == "", do: :all, else: String.to_integer(arg)

    case Newbee.Staging.approve(id) do
      {:ok, []} -> ctx.say.("（无暂存改动）")
      {:ok, written} -> ctx.say.("已落盘: #{Enum.join(written, ", ")}")
      {:error, :not_staged} ->
… [compressed: 8890 bytes, 2 lines; 用 binding 变量或写文件后再局部读取] …
n132#9d72|   defp run("rollback", arg, ctx) do
    if arg == "" do
      ctx.say.("快照: #{inspect(Newbee.Evolution.Snapshot.list())}")
      ctx.say.("用法: /rollback <name>")
    else
      {:ok, name} = Newbee.Evolution.Snapshot.restore(arg)
      ctx.say.("已回滚到: #{name}（求值器已重建，工具按快照热载）")
    end

    :handled
  end

  defp run("evolve", hint, ctx) do
    if hint != "", do: Newbee.Evolution.Evolver.hint(hint, %{source: :user})

    ctx.say.("evolver 开始合成（线索+热教训+指标）…")

    case Newbee.Evolution.Evolver.run_once() do
      {:skipped, reason} -> ctx.say.("跳过: #{reason}")
      results ->
        Enum.each(results, fn
          {:published, what} -> ctx.say.("  ✅ 已发布: #{inspect(what)}")
          {:rejected, what, why} -> ctx.say.("  ❌ 否决: #{inspect(what)} — #{inspect(why)}")
        end)
    end

    :handled
  end

  defp run("policy", arg, ctx) do
    if arg == "" do
      ctx.say.("当前档位: #{Newbee.Evolution.Policy.get()}（可选: #{inspect(Newbee.Evolution.Policy.levels())}）")
    else
      level = String.to_atom(arg)

      if level in Newbee.Evolution.Policy.levels() do
        Newbee.Evolution.Policy.set(level)
        ctx.say.("进化档位: #{level}")
      else
        ctx.say.("非法档位，可选: #{inspect(Newbee.Evolution.Policy.levels())}")
      end
    end

    :handled
  end

  defp run("genes", _, ctx) do
    case Newbee.Evolution.Gene.list() do
      [] -> ctx.say.("（基因库为空；/evolve 产出后可 export 打包）")
      genes -> Enum.each(genes, &ctx.say.("  #{&1.name}@#{&1.version} fitness=#{inspect(&1.fitness)} from=#{&1.provenance}"))
    end

    :handled
  end

  defp run("bench", _, ctx) do
    ctx.say.("跑 bench 任务集（真实 LLM，可能要几分钟）…")
    client = Newbee.LLM.Config.client_for()
    report = Newbee.Evolution.Bench.run_tasks(client)
    ctx.say.("bench: #{report.passed}/#{report.total} 通过, #{report.tokens} tokens")

    Enum.each(report.details, fn d ->
      ctx.say.("  #{if d.passed, do: "✅", else: "❌"} #{d.id} (#{d.tokens} tok)")
    end)

    :handled
  end

  defp run(unknown, _, ctx) do
    ctx.say.("未知命令: /#{unknown}（#{Enum.join(@commands, " ")}）")
    :handled
  end
end
", lines: 205}