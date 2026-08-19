defmodule Newbee.Commands do
  @moduledoc """
  CLI/TUI 共用的命令处理 (DESIGN §5.3)。命令对当前 kernel pid 操作；
  /resume 需要重建 kernel ——由调用方传入 restart fun。
  """

  @commands ~w(/model /bindings /tokens /rules /dump /resume /reset /approve
    /reject /log /snapshot /rollback /evolve /policy /genes /bench /goal /diff
    /undo /session /init /tools /permissions /compact /quit)

  def commands, do: @commands

  @doc "处理输入。返回 :ok | :handled | :quit | {:submit, text} | {:resume, id} | {:resume_picker, metas} | {:shell, cmd}。"
  @spec handle(String.t(), map()) ::
          :ok
          | :handled
          | :quit
          | {:submit, String.t()}
          | {:resume, String.t()}
          | {:resume_picker, list(map())}
          | {:shell, String.t()}
  def handle(input, ctx) do
    case String.trim(input) do
      "" ->
        :ok

      "/quit" ->
        :quit

      "!" <> cmd when cmd != "" ->
        # codex 式 !shell：直接在 DEE 里执行 shell 命令（DESIGN §5.3）
        {:shell, cmd}

      "/" <> _ = cmd ->
        run_command(cmd, ctx)

      text ->
        {:submit, expand_at_files(text)}
    end
  end

  @doc "执行 !shell 命令并渲染结果（CLI/TUI 共用）。返回输出文本。"
  def run_shell(cmd) do
    result = Newbee.Tools.Run.sh(cmd, timeout: 300_000)
    output = String.slice(result.output, 0, 8_000)

    case result.exit do
      0 -> "⎿ $ #{cmd}\n" <> output
      code -> "⎿ $ #{cmd} (exit #{code})\n" <> output
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

  @doc "/resume 选择解析：数字编号（1 起，对应最近会话）或会话 id 精确/前缀。
  返回 {:ok, id} | {:candidates, ids} | :none。"
  def resolve(sel) do
    case Integer.parse(sel) do
      {n, ""} when n >= 1 ->
        case Newbee.Session.list_with_meta(20) |> Enum.at(n - 1) do
          nil -> :none
          meta -> {:ok, meta.id}
        end

      _ ->
        case Newbee.Session.find(sel) do
          [id] -> {:ok, id}
          ids when ids != [] -> {:candidates, ids}
          [] -> :none
        end
    end
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

  defp run("model", "", ctx) do
    Newbee.LLM.Config.describe() |> Enum.each(&ctx.say.("  " <> &1))
    ctx.say.("evolution policy: #{Newbee.Evolution.Policy.get()}")
    ctx.say.("用法: /model <provider/model-id> 切换默认模型（会重建会话内核）")
    :handled
  end

  defp run("model", id, ctx) when id != "" do
    id = String.trim(id)

    case Newbee.LLM.Config.set_default_model(id) do
      :ok ->
        ctx.say.("已切换默认模型为 #{id}，重建会话内核…")
        {:restart}

      {:error, reason} ->
        ctx.say.("切换失败: #{inspect(reason)}")
        :handled
    end
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

  defp run("resume", "", _ctx) do
    {:resume_picker, Newbee.Session.list_with_meta(20)}
  end

  defp run("resume", id, _ctx) do
    id = String.trim(id)

    case Newbee.Session.find(id) do
      # 精确或唯一前缀 → 返回完整 id（会话恢复用）
      [found] -> {:resume, found}
      # 无匹配：原样透传（kernel 会报错提示）
      [] -> {:resume, id}
    end
  end

  defp run("approve", arg, ctx) do
    id = if arg == "", do: :all, else: String.to_integer(arg)

    case Newbee.Staging.approve(id) do
      {:ok, []} -> ctx.say.("（无暂存改动）")
      {:ok, written} -> ctx.say.("已落盘: #{Enum.join(written, ", ")}")
      {:error, :not_staged} -> ctx.say.("没有对应暂存项")
      {:error, :outside_project} -> ctx.say.("有暂存项在工程树外，已拒绝落盘")
    end

    :handled
  end

  defp run("reject", arg, ctx) do
    id = if arg == "", do: :all, else: String.to_integer(arg)

    case Newbee.Staging.reject(id) do
      {:ok, []} -> ctx.say.("（无暂存改动）")
      {:ok, dropped} -> ctx.say.("已丢弃: #{Enum.join(dropped, ", ")}")
      {:error, :not_staged} -> ctx.say.("没有对应暂存项")
    end

    :handled
  end

  defp run("diff", arg, ctx) do
    range = if arg == "", do: "HEAD", else: String.trim(arg)

    case System.cmd("git", ["diff", "--stat", range, "HEAD"], stderr_to_stdout: true) do
      {out, 0} ->
        ctx.say.("会话累计 diff（#{range}..HEAD）:")
        ctx.say.(String.trim(out) |> String.slice(0, 2_000))

      _ ->
        ctx.say.("git diff 不可用（非 git 仓库？）")
    end

    :handled
  end

  defp run("log", arg, ctx) do
    lines = Newbee.DebugLog.tail(if arg == "", do: 50, else: String.to_integer(arg))
    Enum.each(lines, &ctx.say.("  " <> &1))
    :handled
  end

  defp run("snapshot", arg, ctx) do
    if arg == "" do
      ctx.say.("快照: #{inspect(Newbee.Evolution.Snapshot.list())}")
      ctx.say.("用法: /snapshot <name> 创建快照")
    else
      case Newbee.Evolution.Snapshot.create(arg) do
        {:ok, name} -> ctx.say.("已创建快照: #{name}")
        {:error, reason} -> ctx.say.("快照失败: #{inspect(reason)}")
      end
    end

    :handled
  end

  defp run("rollback", arg, ctx) do
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
      {:skipped, reason} ->
        ctx.say.("跳过: #{reason}")

      {:suggested, proposals} ->
        # 档位 :hint：只产出建议，不自动发布
        ctx.say.("进化建议（档位 :hint，未自动发布；/policy background 可自动合并）:")

        Enum.each(proposals, fn p ->
          ctx.say.("  💡 #{p["type"]} #{p["id"] || p["name"] || inspect(p)}")
        end)

      results ->
        Enum.each(results, fn
          {:published, what} -> ctx.say.("  ✅ 已发布: #{inspect(what)}")
          {:rejected, what, why} -> ctx.say.("  ❌ 否决: #{inspect(what)} — #{inspect(why)}")
        end)
    end

    :handled
  end

  defp run("init", _, ctx) do
    if File.exists?("NEWBEE.md") do
      ctx.say.("NEWBEE.md 已存在（跳过；删除后可重新生成）")
    else
      map = Newbee.DEE.RepoMap.build(".")

      content =
        "# NEWBEE.md\n\n## 项目说明\n（由 newbee /init 生成，可编辑——本文件会被注入会话 prompt，§5.4）\n\n## 工程结构\n" <>
          map <>
          "\n\n## 常用命令\n- 测试: mix test\n- 编译: mix compile\n- 格式化: mix format\n"

      File.write!("NEWBEE.md", content)
      ctx.say.("已生成 NEWBEE.md（会注入会话 prompt；同样支持 AGENTS.md / CLAUDE.md）")
    end

    :handled
  end

  defp run("tools", "", ctx) do
    files = Newbee.DEE.Tools.HotLoader.tool_files()
    ctx.say.("热载工具（#{length(files)} 个，全局+项目）:")

    Enum.each(files, fn f ->
      mod = f |> Path.basename(".ex") |> Macro.camelize()
      ctx.say.("  #{mod} ← #{f}")
    end)

    ctx.say.("内置工具见 Newbee.DEE.Tools.list()；/tools <模块名> 看详情")
    :handled
  end

  defp run("tools", name, ctx) do
    mod = String.to_atom("Elixir.Newbee.Tools." <> Macro.camelize(String.trim(name)))

    if Code.ensure_loaded?(mod) do
      docs = Newbee.DEE.Tools.describe(mod)
      ctx.say.("#{docs.name}: #{docs.summary}")

      case :code.which(mod) do
        path when is_binary(path) or is_list(path) ->
          ctx.say.("  源码: #{if is_list(path), do: List.to_string(path), else: path}")

        _ ->
          :ok
      end
    else
      ctx.say.("未找到工具模块: #{name}")
    end

    :handled
  end

  defp run("permissions", "", ctx) do
    ctx.say.(
      "当前权限档位: #{Newbee.Permissions.get()}（可选: #{inspect(Newbee.Permissions.levels())}；lenient 放行+审计 / ask 危险操作询问 / deny 危险操作拒绝）"
    )

    :handled
  end

  defp run("permissions", arg, ctx) do
    level = String.to_atom(String.trim(arg))

    if level in Newbee.Permissions.levels() do
      Newbee.Permissions.set(level)
      ctx.say.("权限档位: #{level}")
    else
      ctx.say.("非法档位，可选: #{inspect(Newbee.Permissions.levels())}")
    end

    :handled
  end

  defp run("compact", _, ctx) do
    if ctx.kernel do
      case Newbee.DEE.Kernel.compact(ctx.kernel) do
        {:ok, n} -> ctx.say.("已压缩 #{n} 条历史（环境状态与绑定不受影响，§5.3/§6.5）")
        {:error, e} -> ctx.say.("压缩失败: #{inspect(e)}")
      end
    else
      ctx.say.("（无 kernel 上下文）")
    end

    :handled
  end

  # ── 自主目标（/goal）：Kernel 已内置 set_goal/clear_goal/goal，这里接线 ──

  defp run("goal", arg, ctx) do
    if ctx.kernel do
      case String.trim(arg) do
        "" ->
          case Newbee.DEE.Kernel.goal(ctx.kernel) do
            nil ->
              ctx.say.("（无自主目标）用法: /goal <目标描述> 启动 · /goal clear 取消")

            g ->
              ctx.say.("自主目标: #{g.text}（第 #{g.rounds}/#{g.max_rounds} 轮）")
          end

        "clear" ->
          Newbee.DEE.Kernel.clear_goal(ctx.kernel)
          ctx.say.("自主目标已取消")

        text ->
          case Newbee.DEE.Kernel.set_goal(ctx.kernel, text) do
            :ok ->
              ctx.say.("已启动自主目标（异步运行；/goal 查看状态 · /goal clear 取消）")

            {:error, reason} ->
              ctx.say.("启动失败: #{inspect(reason)}")
          end
      end
    else
      ctx.say.("（无 kernel 上下文，/goal 不可用）")
    end

    :handled
  end

  # ── /undo：回滚到最近快照（快照即"上一个 git/工具版本"的回滚单元）──

  defp run("undo", _, ctx) do
    case Newbee.Evolution.Snapshot.list() do
      [] ->
        ctx.say.("没有可回滚的快照——先用 /snapshot <name> 创建；也可 /rollback <name> 指定")

      [latest | _] ->
        case Newbee.Evolution.Snapshot.restore(latest) do
          {:ok, name} ->
            ctx.say.("已回滚到快照 #{name}（求值器已重建，工具/规则/提示按快照恢复）")

          {:error, reason} ->
            ctx.say.("回滚失败: #{inspect(reason)}")
        end
    end

    :handled
  end

  # ── /session：会话挂起/恢复（§5.3）──

  defp run("session", arg, ctx) do
    [cmd | rest] = String.split(String.trim(arg), " ", parts: 2)

    case cmd do
      "" ->
        case current_session(ctx.kernel) do
          nil ->
            ctx.say.("（无会话——kernel 以 session: false 启动）")

          s ->
            ctx.say.("当前会话: #{s.id}（/session save 固化绑定 · /session list 列出 · /session load <id> 恢复）")
        end

        :handled

      "save" ->
        case current_session(ctx.kernel) do
          nil ->
            ctx.say.("（无会话）")

          s ->
            binding = Newbee.DEE.Evaluator.dump_bindings()
            Newbee.Session.save_bindings(s, binding)
            ctx.say.("已保存会话 #{s.id} 的绑定快照（#{length(binding)} 个变量）")
        end

        :handled

      "list" ->
        {:resume_picker, Newbee.Session.list_with_meta(20)}

      "load" ->
        case rest do
          [id] -> {:resume, String.trim(id)}
          [] -> {:resume_picker, Newbee.Session.list_with_meta(20)}
        end

      other ->
        # 裸 id 直接恢复（/session <id> 等价 /resume <id>）
        {:resume, other}
    end
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
      [] ->
        ctx.say.("（基因库为空；/evolve 产出后可 export 打包）")

      genes ->
        Enum.each(genes, &ctx.say.("  #{&1.name}@#{&1.version} fitness=#{inspect(&1.fitness)} from=#{&1.provenance}"))
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

  defp current_session(nil), do: nil

  defp current_session(kernel) do
    case :sys.get_state(kernel) do
      %{session: %Newbee.Session{} = s} -> s
      _ -> nil
    end
  end
end
