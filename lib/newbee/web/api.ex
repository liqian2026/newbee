defmodule Newbee.Web.Api do
  @moduledoc """
  WebUI HTTP API（移植 dsh apiproxy 语义）：`POST /api/<method>` 的
  RPC-over-HTTP 网关。wire 信封对齐 dsh 四象限消息模型的 client-request：

      请求  {"rpcId": "...", "method": "session.prompt", "payload": {...}}
      应答  {"rpcId": "...", "result": {"ok": <value>}} |
            {"rpcId": "...", "result": {"error": {"code": ..., "message": ...}}}

  会话事件下行不走 HTTP，走 WebSocket（见 Newbee.Web.Socket）。
  """
  use Plug.Router

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 20_000_000
  )

  plug(:dispatch)

  # ── RPC envelope ──

post "/:method" do
    rpc_id = get_in(conn.body_params, ["rpcId"]) || "-"
    payload = get_in(conn.body_params, ["payload"]) || %{}

    case dispatch_rpc(method, payload) do
      {:ok, value} ->
        reply(conn, 200, %{rpcId: rpc_id, result: %{ok: json_safe(value)}})

      {:error, code, message} ->
        reply(conn, 200, %{rpcId: rpc_id, result: %{error: %{code: code, message: message}}})
    end
  end

  # 便捷 GET：会话列表 / 健康检查（不进 RPC 信封，等价 dsh downloads 的 GET 面）
get "/sessions" do
    metas = Newbee.Session.list_with_meta(50)
    reply(conn, 200, Enum.map(metas, &json_safe/1))
  end

get "/health" do
    reply(conn, 200, %{ok: true, model: current_model()})
  end

  match _ do
    reply(conn, 404, %{error: "not found"})
  end

  # ── method 分派 ──

  # 会话域
  defp dispatch_rpc("session.list", _p) do
    sessions =
      Newbee.Session.list_with_meta(50)
      |> Enum.map(fn s ->
        id = s[:id] || s["id"]
        busy = Newbee.Web.Session.peek_busy(id)
        running = match?({:ok, _}, Newbee.Web.Session.lookup(id))

        Map.merge(s, %{
          running: running,
          busy: busy
        })
      end)

    {:ok, %{sessions: Enum.map(sessions, &json_safe/1)}}
  end

  defp dispatch_rpc("session.history", %{"sessionId" => sid}) do
    msgs = Newbee.Session.open(sid) |> Newbee.Session.messages()
    {:ok, %{messages: Enum.map(msgs, &history_msg/1)}}
  end

  defp dispatch_rpc("session.create", p) do
    sid = p["sessionId"]
    {:ok, _pid, sid} = Newbee.Web.Session.ensure(blank_to_nil(sid))
    {:ok, %{sessionId: sid}}
  end

  defp dispatch_rpc("session.resume", %{"sessionId" => sid}) do
    case Newbee.Web.Session.ensure(sid) do
      {:ok, _pid, sid} -> {:ok, %{sessionId: sid}}
      {:error, r} -> {:error, "session_error", inspect(r)}
    end
  end

  defp dispatch_rpc("session.delete", %{"sessionId" => sid}) do
    case Newbee.Web.Session.destroy(sid) do
      :ok -> {:ok, %{deleted: sid}}
      {:error, r} -> {:error, "delete_error", inspect(r)}
    end
  end

  defp dispatch_rpc("session.rename", %{"sessionId" => sid, "title" => t}) do
    Newbee.Session.rename(sid, String.trim(t || ""))
    {:ok, %{sessionId: sid, title: t}}
  rescue
    e -> {:error, "rename_error", Exception.message(e)}
  end

  defp dispatch_rpc("session.prompt", %{"sessionId" => sid, "text" => text}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.prompt(pid, text)
      {:ok, %{accepted: true}}
    end
  end

  defp dispatch_rpc("session.promptImage", %{"sessionId" => sid, "images" => images, "text" => text}) do
    with {:ok, pid} <- find_session(sid) do
      if images == nil or images == [] do
        Newbee.Web.Session.prompt(pid, text || "")
      else
        Newbee.Web.Session.prompt_images(pid, images, text || "")
      end

      {:ok, %{accepted: true}}
    end
  end

  defp dispatch_rpc("session.cancel", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.interrupt(pid)
      {:ok, %{interrupted: true}}
    end
  end

  defp dispatch_rpc("session.state", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      {:ok, Newbee.Web.Session.state(pid)}
    end
  end

  defp dispatch_rpc("session.selectModel", %{"sessionId" => sid, "provider" => provider, "model" => model}) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.switch_model(pid, provider, model) do
        :ok -> {:ok, %{provider: provider, model: model}}
        {:error, r} -> {:error, "model_error", inspect(r)}
      end
    end
  end

  # 兼容旧调用：仅 modelId
  defp dispatch_rpc("session.selectModel", %{"sessionId" => sid, "modelId" => mid}) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.switch_model(pid, mid) do
        :ok -> {:ok, %{model: mid}}
        {:error, r} -> {:error, "model_error", inspect(r)}
      end
    end
  end


  # 权限回复（server-request 象限的 respond 语义）
  defp dispatch_rpc("respond", %{"sessionId" => sid, "permission" => ok}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.permission_reply(pid, ok)
      {:ok, %{delivered: true}}
    end
  end

  # 模型目录
  defp dispatch_rpc("llm.models", p) do
    opts = if p["refresh"] == true, do: [refresh: true], else: []
    cat = Newbee.LLM.Config.model_catalog(opts)
    {:ok, %{providers: cat.providers, current: current_model_info(p["sessionId"])}}
  end

  # 按厂商刷新模型列表（只拉指定 provider）
  defp dispatch_rpc("llm.providerModels", p) do
    name = p["provider"] || ""
    opts = if p["refresh"] == true, do: [refresh: true], else: []

    case Newbee.LLM.Config.provider_models_by_name(name, opts) do
      nil -> {:error, "unknown_provider", name}
      models -> {:ok, %{provider: name, models: models}}
    end
  end



  # 进化域（左侧进化面板数据）
  defp dispatch_rpc("evolution.feed", p) do
    n = min(max(p["n"] || 100, 1), 500)

    topics = [
      "evolution_published",
      "evolution_rejected",
      "release_observation",
      "change_activated",
      "change_rejected",
      "change_rolled_back",
      "revision_advanced",
      "revision_degraded",
      "snapshot_created",
      "snapshot_restored",
      "generation_switched",
      "generation_switch_failed",
      "audit"
    ]

    events =
      Newbee.EventLog.read(n * 3, topics)
      |> Enum.take(n)
      |> Enum.map(&json_safe/1)

    {:ok, %{events: events}}
  end

  defp dispatch_rpc("evolution.trigger", _p) do
    case Newbee.Host.on_main?() do
      true ->
        :ok = Newbee.Daemon.evolve_now()
        {:ok, %{triggered: true}}

      false ->
        main = Newbee.Host.main_node()

        if main && Node.ping(main) == :pong do
          r = :rpc.call(main, Newbee.Daemon, :evolve_now, [])
          {:ok, %{triggered: r == :ok, node: main}}
        else
          {:error, :main_node_unreachable}
        end
    end
  end

  defp dispatch_rpc("evolution.status", _p) do
    autonomy = Newbee.Environment.Autonomy.get()

    {coord_state, active_releases} =
      case Process.whereis(Newbee.Environment.Coordinator) do
        nil ->
          {:down, []}

        _pid ->
          try do
            current = Newbee.Environment.Coordinator.current(Newbee.Environment.Coordinator)
            changes = Newbee.Environment.Coordinator.changes(Newbee.Environment.Coordinator)

            releases =
              (current && current.active && Enum.map(current.active, fn {plugin_id, release_id} ->
                %{
                  "plugin" => plugin_id,
                  "release" => release_id,
                  "kind" => plugin_id |> String.split(".") |> List.first(),
                  "name" => plugin_id |> String.split(".") |> Enum.drop(1) |> Enum.join(".")
                }
              end)) || []

            {%{
               active_revision: current && current.rev,
               changes: length(changes),
               active_count: length(releases)
             }, releases}
          rescue
            _ -> {:error, []}
          catch
            :exit, _ -> {:error, []}
          end
      end

    # 最近一轮 adapter 运行痕迹：从 EventLog 找最近的 evolution_* 事件
    recent_evo =
      Newbee.EventLog.read(50, ["evolution_published", "evolution_rejected"])
      |> List.first()

    # 每个 release 的使用统计（fitness 聚合）
    release_stats =
      active_releases
      |> Enum.map(fn rel ->
        rid = rel["release"]

        obs =
          try do
            Newbee.Environment.Fitness.observations(rid)
          rescue
            _ -> []
          catch
            :exit, _ -> []
          end

        n = length(obs)

        if n > 0 do
          succ = Enum.count(obs, & &1["success"])
          avg_tok = obs |> Enum.map(&(&1["tokens"] || 0)) |> Enum.sum() |> div(max(n, 1))

          Map.merge(rel, %{
            "uses" => n,
            "success_rate" => Float.round(succ / n, 2),
            "avg_tokens" => avg_tok
          })
        else
          Map.merge(rel, %{"uses" => 0})
        end
      end)
      # 按使用次数倒序
      |> Enum.sort_by(&(-Map.get(&1, "uses", 0)))

    {:ok,
     %{
       autonomy: autonomy,
       coordinator: json_safe(coord_state),
       active_releases: json_safe(release_stats),
       last_evolution: json_safe(recent_evo),
       event_log_bytes: Newbee.EventLog.size()
     }}
  end

  # ── Git / 文件变更追踪（Mission Control 面板数据源）──

  defp dispatch_rpc("git.diffStat", _p) do
    case git_cmd(["diff", "--numstat", "HEAD", "--"]) do
      {:ok, numstat_out} ->
        tracked = parse_numstat(numstat_out)

        untracked =
          case git_cmd(["ls-files", "--others", "--exclude-standard"]) do
            {:ok, out} ->
              out
              |> String.split("\n", trim: true)
              |> Enum.map(fn path ->
                lines = count_file_lines(path)
                %{path: path, added: lines, deleted: 0, status: "new"}
              end)

            _ ->
              []
          end

        {:ok, %{files: tracked ++ untracked}}

      {:error, msg} ->
        {:error, "git_error", msg}
    end
  end

  defp dispatch_rpc("git.diff", p) do
    path = p["path"]

    args =
      if path && path != "",
        do: ["diff", "HEAD", "--", path],
        else: ["diff", "HEAD"]

    case git_cmd(args) do
      {:ok, diff_text} ->
        untracked_diffs =
          if path && path != "" do
            case git_cmd(["ls-files", "--others", "--exclude-standard", "--", path]) do
              {:ok, out} ->
                if String.trim(out) != "", do: new_file_diff(path), else: ""
              _ -> ""
            end
          else
            case git_cmd(["ls-files", "--others", "--exclude-standard"]) do
              {:ok, out} ->
                out
                |> String.split("\n", trim: true)
                |> Enum.map(&new_file_diff/1)
                |> Enum.join("\n")
              _ -> ""
            end
          end

        full = if untracked_diffs != "", do: diff_text <> "\n" <> untracked_diffs, else: diff_text
        {:ok, %{diff: full}}

      {:error, msg} ->
        {:error, "git_error", msg}
    end
  end


  # ── 文件搜索（@ 引用自动补全）──

  defp dispatch_rpc("files.search", %{"q" => q}) do
    q = String.trim(q || "")

    if String.length(q) < 1 do
      {:ok, %{files: []}}
    else
      # 用 fd 或 find 搜索项目文件
      case System.cmd("find", [".", "-type", "f", "-name", "*#{q}*", "-not", "-path", "*/deps/*", "-not", "-path", "*/.git/*", "-not", "-path", "*/_build/*", "-not", "-path", "*/node_modules/*"], stderr_to_stdout: true) do
        {out, 0} ->
          files =
            out
            |> String.split("\n", trim: true)
            |> Enum.map(&String.trim_leading(&1, "./"))
            |> Enum.take(20)
            |> Enum.map(fn path ->
              ext = Path.extname(path) |> String.trim_leading(".")
              %{path: path, ext: ext}
            end)

          {:ok, %{files: files}}

        _ ->
          {:ok, %{files: []}}
      end
    end
  rescue
    _ -> {:ok, %{files: []}}
  end

  # ── 变更影响分析 ──

  defp dispatch_rpc("git.impact", _p) do
    # 1. 获取变更文件列表
    case git_cmd(["diff", "--numstat", "HEAD", "--"]) do
      {:ok, numstat_out} ->
        changed = parse_numstat(numstat_out)
        
        untracked =
          case git_cmd(["ls-files", "--others", "--exclude-standard"]) do
            {:ok, out} -> String.split(out, "\n", trim: true)
            _ -> []
          end

        # 2. 构建模块依赖图（仅 Elixir 项目）
        dep_map = build_dep_map()

        # 3. 计算每个变更文件的影响
        files =
          (changed ++ Enum.map(untracked, &%{path: &1, added: 0, deleted: 0, status: "new"}))
          |> Enum.map(fn f ->
            path = f.path
            dependents = Map.get(dep_map, path, [])
            risk = risk_level(path, f, length(dependents))

            %{
              path: path,
              added: Map.get(f, :added, 0),
              deleted: Map.get(f, :deleted, 0),
              status: Map.get(f, :status, "modified"),
              dependents: length(dependents),
              dependent_files: Enum.slice(dependents, 0, 5),
              risk: risk,
              is_test: String.contains?(path, "test/"),
              is_config: String.contains?(path, ["config/", "mix.exs", "mix.lock"])
            }
          end)
          |> Enum.sort_by(fn f -> {-risk_score(f.risk), -f.dependents, -(f.added + f.deleted)} end)

        # 4. 汇总
        total_files = length(files)
        total_added = files |> Enum.map(& &1.added) |> Enum.sum()
        total_deleted = files |> Enum.map(& &1.deleted) |> Enum.sum()
        high_risk = Enum.count(files, &(&1.risk == "high"))
        has_tests = Enum.any?(files, & &1.is_test)

        {:ok,
         %{
           files: files,
           summary: %{
             total_files: total_files,
             total_added: total_added,
             total_deleted: total_deleted,
             high_risk: high_risk,
             has_tests: has_tests,
             overall_risk: if(high_risk > 0, do: "high", else: if(total_files > 10, do: "medium", else: "low"))
           }
         }}

      {:error, msg} ->
        {:error, "git_error", msg}
    end
  end

  # ── Impact Analysis helpers ──

  # 构建模块依赖图：{文件路径 => [依赖它的文件列表]}
  defp build_dep_map do
    if File.exists?("mix.exs") do
      # 收集所有 .ex 文件
      ex_files =
        ["lib/**/*.ex", "test/**/*.exs"]
        |> Enum.flat_map(&Path.wildcard/1)

      # 提取每个文件引用的模块
      refs =
        ex_files
        |> Enum.map(fn f ->
          case File.read(f) do
            {:ok, content} ->
              modules = extract_module_refs(content)
              {f, modules}

            _ ->
              {f, []}
          end
        end)

      # 建立模块名 → 文件路径映射
      module_to_file =
        ex_files
        |> Enum.map(fn f ->
          case File.read(f) do
            {:ok, content} ->
              case Regex.run(~r/defmodule\s+([\w.]+)/, content) do
                [_, mod] -> {mod, f}
                _ -> nil
              end

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      # 反转：对每个文件，找出谁引用了它的模块
      refs
      |> Enum.reduce(%{}, fn {file, modules}, acc ->
        Enum.reduce(modules, acc, fn mod, acc2 ->
          case Map.get(module_to_file, mod) do
            nil -> acc2
            target_file ->
              if target_file != file do
                Map.update(acc2, target_file, [file], &[file | &1])
              else
                acc2
              end
          end
        end)
      end)
    else
      %{}
    end
  end

  defp extract_module_refs(content) do
    # 提取 Newbee.Foo.Bar 这样的模块引用
    Regex.scan(~r/\b(Newbee\.[A-Z][\w.]*)/, content)
    |> Enum.map(fn [_, mod] -> mod end)
    |> Enum.uniq()
  end

  defp risk_level(path, f, dependent_count) do
    cond do
      dependent_count >= 5 -> "high"
      String.contains?(path, "config/") or path == "mix.exs" -> "high"
      dependent_count >= 2 -> "medium"
      String.contains?(path, "test/") -> "low"
      Map.get(f, :status) == "new" -> "low"
      Map.get(f, :added, 0) + Map.get(f, :deleted, 0) > 100 -> "medium"
      true -> "low"
    end
  end

  defp risk_score("high"), do: 3
  defp risk_score("medium"), do: 2
  defp risk_score("low"), do: 1
  defp risk_score(_), do: 0

  # ── 工作流闭环：测试 + 提交 ──

  defp dispatch_rpc("project.test", _p) do
    # 检测项目类型并运行对应测试
    {cmd, args} =
      cond do
        File.exists?("mix.exs") -> {"mix", ["test", "--color", "false"]}
        File.exists?("Cargo.toml") -> {"cargo", ["test"]}
        File.exists?("package.json") -> {"npm", ["test"]}
        File.exists?("pytest.ini") or File.exists?("setup.py") -> {"python", ["-m", "pytest", "-x", "--tb=short"]}
        true -> {"echo", ["未检测到项目类型"]}
      end

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: tail(out, 3000), passed: true, cmd: cmd <> " " <> Enum.join(args, " ")}}
      {out, code} -> {:ok, %{output: tail(out, 3000), passed: false, exit: code, cmd: cmd <> " " <> Enum.join(args, " ")}}
    end
  rescue
    e -> {:error, "test_error", Exception.message(e)}
  end

  defp dispatch_rpc("git.commit", %{"message" => msg}) do
    msg = String.trim(msg || "")
    if msg == "" do
      {:error, "empty_message", "提交信息不能为空"}
    else
      with {:ok, add_out} <- git_cmd(["add", "-A"]),
           {:ok, commit_out} <- git_cmd(["commit", "-m", msg]) do
        {:ok, %{output: tail(to_string(add_out) <> to_string(commit_out), 2000), message: msg}}
      else
        {:error, err} -> {:error, "git_error", err}
      end
    end
  end

  # ── Git helpers ──

  defp tail(str, n) when is_binary(str) do
    len = String.length(str)

    if len > n do
      String.slice(str, len - n, n)
    else
      str
    end
  end

  defp tail(v, n), do: v |> to_string() |> tail(n)

  # ── Checkpoint (vibe coding safety net) ──

  defp dispatch_rpc("git.checkpoint.create", %{"description" => desc}) do
    desc = String.trim(desc || "")
    label = if desc == "", do: "checkpoint", else: String.slice(desc, 0, 60)

    case dispatch_rpc("git.diffStat", %{}) do
      {:ok, %{files: files}} when files != [] ->
        case git_cmd(["add", "-A"]) do
          {:ok, _} ->
            msg = "[checkpoint] " <> label
            commit_result = git_cmd(["commit", "-m", msg, "--allow-empty"])

            case commit_result do
              {:ok, out} -> {:ok, %{committed: true, message: msg, output: tail(out, 500)}}
              {:error, e} -> {:error, {:git_error, to_string(e)}}
            end

          {:error, e} ->
            {:error, {:git_error, to_string(e)}}
        end

      {:ok, _} ->
        {:error, :nothing_to_checkpoint}

      err ->
        err
    end
  end

  defp dispatch_rpc("git.checkpoint.list", _p) do
    case git_cmd(["log", "--oneline", "--all", "--grep=[checkpoint]", "-20"]) do
      {:ok, out} ->
        checkpoints =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [sha | rest] = String.split(line, " ", parts: 2)
            msg = Enum.join(rest, " ")
            desc = msg |> String.replace_prefix("[checkpoint] ", "") |> String.slice(0, 80)
            %{sha: sha, description: desc}
          end)

        {:ok, %{checkpoints: checkpoints}}

      {:error, e} ->
        # 无 commits 的 repo 也算正常
        {:ok, %{checkpoints: []}}
    end
  end

  defp tail(str, n) when is_binary(str) do
    len = String.length(str)

    if len > n do
      String.slice(str, len - n, n)
    else
      str
    end
  end

  defp tail(v, n), do: v |> to_string() |> tail(n)

  # ── Checkpoint (vibe coding safety net) ──

  defp dispatch_rpc("git.checkpoint.create", %{"description" => desc}) do
    desc = String.trim(desc || "")
    label = if desc == "", do: "checkpoint", else: String.slice(desc, 0, 60)

    with {:ok, %{files: files}} <- dispatch_rpc("git.diffStat", %{}) do
      has_changes? = files != []

      staged =
        if has_changes? do
          case git_cmd(["add", "-A"]) do
            {_, 0} -> true
            _ -> false
          end
        end

      cond do
        not has_changes? ->
          {:error, :nothing_to_checkpoint}

        has_changes? and staged ->
          msg = "[checkpoint] " <> label
          {out, code} = git_cmd(["commit", "-m", msg, "--allow-empty"])

          if code == 0 do
            {:ok, %{committed: true, message: msg, output: tail(out, 500)}}
          else
            {:error, {:git_error, tail(out, 300)}}
          end

        true ->
          {:ok, %{committed: false}}
      end
    end
  end

  defp dispatch_rpc("git.checkpoint.list", _p) do
    case git_cmd(["log", "--oneline", "--all", "--grep=[checkpoint]", "-20"]) do
      {out, 0} ->
        checkpoints =
          out
          |> String.split("
", trim: true)
          |> Enum.map(fn line ->
            [sha | rest] = String.split(line, " ", parts: 2)
            msg = Enum.join(rest, " ")
            desc = msg |> String.replace_prefix("[checkpoint] ", "") |> String.slice(0, 80)
            %{sha: sha, description: desc}
          end)

        {:ok, %{checkpoints: checkpoints}}

      {out, _} ->
        {:error, {:git_error, tail(out, 300)}}
    end
  end

  defp git_cmd(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "git exit #{code}: #{String.slice(out, 0, 500)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_numstat(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t") do
        [added, deleted, path] ->
          %{
            path: path,
            added: String.to_integer(added),
            deleted: String.to_integer(deleted),
            status: "modified"
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp count_file_lines(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n") |> length()
      _ -> 0
    end
  end

  defp new_file_diff(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        header = "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@"
        body = lines |> Enum.map(&("+" <> &1)) |> Enum.join("\n")
        header <> "\n" <> body
      _ -> ""
    end
  end

    # ── Bindings 可视化 ──

  defp dispatch_rpc("session.bindings", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      bindings =
        try do
          kernel = Newbee.Web.Session.kernel_pid(pid)

          if kernel && Process.alive?(kernel) do
            case Newbee.SessionEvaluators.lookup(kernel) do
              {:ok, evaluator} when is_pid(evaluator) ->
                Newbee.DEE.Evaluator.bindings_summary(evaluator, 3_000)

              _ ->
                []
            end
          else
            []
          end
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      {:ok, %{bindings: json_safe(bindings)}}
    end
  end


  # ── 环境健康（沉睡规则 / 抗体 / JIT）──

  defp dispatch_rpc("env.health", _p) do
    # 沉睡规则
    rules =
      try do
        Newbee.DEE.Rules.list()
        |> Enum.map(fn r ->
          %{
            id: r[:id] || Map.get(r, :id) || "?",
            kind: to_string(r[:kind] || Map.get(r, :kind) || ""),
            pattern: String.slice(to_string(r[:pattern] || Map.get(r, :pattern) || ""), 0, 80),
            hits: r[:hits] || Map.get(r, :hits) || 0
          }
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    rule_hits =
      try do
        Newbee.DEE.Rules.hits()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    # 失败抗体
    antibodies =
      try do
        project = File.cwd!()
        Newbee.Environment.Antibodies.all(project)
        |> Enum.map(fn a ->
          %{
            id: a["id"] || a[:id] || "?",
            error: String.slice(to_string(a["error"] || a[:error] || ""), 0, 100),
            verified: a["verified"] || a[:verified] || false
          }
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    verified =
      try do
        Newbee.Environment.Antibodies.verified_count(File.cwd!())
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    {:ok,
     %{
       rules: %{count: length(rules), items: rules, hits: json_safe(rule_hits)},
       antibodies: %{count: length(antibodies), verified: verified, items: antibodies}
     }}
  end

  # 主机域
  defp dispatch_rpc("host.describe", _p) do

    {:ok,
     %{
       cwd: File.cwd!(),
       model: current_model_label(),
       policy: Newbee.Environment.Autonomy.get(),
       version: "0.1.0"
     }}
  end

  defp dispatch_rpc(method, _p), do: {:error, "unknown_method", "未知 RPC 方法: #{method}"}

  # ── helpers ──

  defp find_session(sid) do
    case Newbee.Web.Session.ensure(sid) do
      {:ok, pid, _sid} -> {:ok, pid}
      {:error, r} -> {:error, "session_error", inspect(r)}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp current_model(sid \\ nil) do
    try do
      if sid do
        case Newbee.Web.Session.lookup(sid) do
          {:ok, pid} -> Newbee.Web.Session.state(pid)["model"]
          _ -> Newbee.LLM.Config.client_for().model
        end
      else
        Newbee.LLM.Config.client_for().model
      end
    rescue
      _ -> nil
    end
  end

  defp current_model_info(sid) do
    provider = if sid, do: Newbee.Session.provider(sid), else: nil
    model = if sid, do: Newbee.Session.model(sid), else: nil

    if provider do
      %{provider: provider, model: model}
    else
      cfg = Newbee.LLM.Config.load()
      default = get_in(cfg, ["roles", "default"]) || %{}
      %{provider: default["provider"], model: model || default["model"]}
    end
  end

  defp current_model_label do
    info = current_model_info(nil)
    if info.model, do: "#{info.provider}/#{info.model}", else: nil
  end



  # transcript 消息 → 前端可渲染结构
  defp history_msg(%{"role" => "user", "content" => c}) when is_binary(c),
    do: %{role: "user", content: c}

  defp history_msg(%{"role" => "user", "content" => content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.find_value(fn part -> if part["type"] == "text", do: part["text"] || "" end) || ""

    images =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn part -> if part["type"] == "image_url", do: get_in(part, ["image_url", "url"]) end)
      |> Enum.reject(&is_nil/1)

    %{role: "user", content: text, images: images}
  end

  defp history_msg(%{"role" => "assistant"} = m) do
    calls =
      for c <- m["tool_calls"] || [],
          do: %{
            name: get_in(c, ["function", "name"]),
            title: args_field(c, "title"),
            code: args_field(c, "code")
          }

    %{role: "assistant", content: m["content"] || "", reasoning: m["reasoning"] || "", toolCalls: calls}
  end

  defp history_msg(%{"role" => "tool", "content" => c}) when is_binary(c),
    do: %{role: "tool", content: String.slice(c, 0, 4000)}

  defp history_msg(_), do: nil

  defp args_field(call, key) do
    case get_in(call, ["function", "arguments"]) do
      args when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, m} -> m[key] || ""
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp reply(conn, status, payload) do
    body = Jason.encode_to_iodata!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(status, body)
  end

  # JSON 安全化（atom key / datetime / tuple）
  defp json_safe(%{__struct__: _} = v), do: v |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = v), do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> json_safe()
  defp json_safe(v) when is_boolean(v), do: v
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v)
end
