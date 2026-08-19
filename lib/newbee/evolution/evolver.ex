defmodule Newbee.Evolution.Evolver do
  @moduledoc """
  专职 evolver (DESIGN §3.8/§6.6) ⭐：worker 留线索 → evolver 离线合成 →
  bench 裁判 → 通过才发布（热载工具 / 沉睡规则 / JIT 升级）。

  线索来源：/evolve 手动 hint、worker 的 evolution hint、指标异常、抗体缺口。
  合成用 evolver 角色模型（model.json roles.evolver）。
  所有动作受 Policy 档位与 Rings 约束，全程事件审计。
  """

  require Logger
  alias Newbee.Evolution.Policy

  @hints Path.join(System.user_home!(), ".newbee/hints.jsonl")
  @evolog Path.join(System.user_home!(), ".newbee/evolution/log.jsonl")

  @doc "记录一条 worker 线索。"
  def hint(text, meta \\ %{}) do
    File.mkdir_p!(Path.dirname(@hints))
    line = Jason.encode_to_iodata!(%{hint: text, meta: meta, at: DateTime.to_iso8601(DateTime.utc_now())})
    File.write!(@hints, [line, "\n"], [:append])
    :ok
  end

  @doc "读取并清空线索队列。"
  def take_hints do
    case File.read(@hints) do
      {:ok, body} ->
        File.rm!(@hints)
        body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      _ ->
        []
    end
  end

  @doc """
  合成一轮：线索 + 指标 + JIT 热项 → 让 evolver 模型产出提案（JSON），
  校验 → bench 回放（抗体回归否决）→ 发布。
  client_fun 可注入（测试用假客户端）。
  """
  def run_once(opts \\ []) do
    if Policy.get() == :off do
      {:skipped, :policy_off}
    else
      do_run(opts)
    end
  rescue
    error ->
      Logger.error("evolver run failed: #{Exception.format(:error, error, __STACKTRACE__)}")
      {:error, {:exception, error}}
  catch
    kind, reason ->
      Logger.error("evolver run halted: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp do_run(opts) do
    hints = take_hints()
    jit_hot = Newbee.Evolution.JIT.list() |> Enum.filter(&(&1.level == :l2_hot))
    metrics = if Process.whereis(Newbee.Evolution.Metrics), do: Newbee.Evolution.Metrics.summary(), else: %{}

    if hints == [] and jit_hot == [] do
      {:skipped, :nothing_to_evolve}
    else
      proposals = synthesize(hints, jit_hot, metrics, opts)
      route(proposals, opts)
    end
  end

  # 按进化档位路由（§6.6）：
  #   :hint       → 只产出建议，不发布（用户 /policy background 或逐个采纳）
  #   :background / :auto → 验证通过即发布（:auto 含 prompt/策略层变更，暂同 background）
  defp route([], _opts), do: {:skipped, :nothing_to_evolve}

  defp route(proposals, opts) do
    case Policy.get() do
      :hint -> {:suggested, proposals}
      _ -> publish(proposals, opts)
    end
  end

  @doc "让 evolver 模型把线索合成为提案（JSON 数组）。"
  def synthesize(hints, jit_hot, metrics, opts) do
    client_fun =
      Keyword.get(opts, :client_fun, fn messages, _on_text ->
        client = Newbee.LLM.Config.client_for("evolver")
        Newbee.LLM.Client.stream_chat(client, messages, fn _ -> :ok end)
      end)

    prompt = """
    你是 newbee 的 evolver。根据 worker 线索与热教训，产出环境进化提案。
    只输出 JSON 数组，每项:
      {"type":"rule","id":"...","pattern":"正则","injection":"命中时注入给模型的提醒"}
      {"type":"tool","id":"...","name":"模块短名","source":"完整 Elixir 模块源码"}
      {"type":"lesson","id":"...","note":"观察笔记"}

    纪律：补丁要小、要具体、有据（引用线索 id）；不确定就不要产出。
    线索：#{inspect(hints, limit: 5)}
    JIT 热项：#{inspect(jit_hot, limit: 5)}
    指标：#{inspect(metrics)}
    """

    case client_fun.([%{"role" => "user", "content" => prompt}], fn _ -> :ok end) do
      {:ok, msg, _usage} ->
        parse_proposals(msg["content"] || "")

      {:error, e} ->
        Logger.warning("evolver synthesize failed: #{inspect(e)}")
        []
    end
  end

  # 容错解析：模型可能包 ```json 围栏或附加解释文字
  defp parse_proposals(content) do
    content
    |> String.split(~r/```[a-z]*/, trim: true)
    |> Enum.find_value(fn chunk ->
      case Jason.decode(String.trim(chunk)) do
        {:ok, list} when is_list(list) -> list
        _ -> nil
      end
    end)
    |> case do
      nil ->
        Logger.warning("evolver 输出不是可解析的 JSON 数组")
        []

      list ->
        list
    end
  rescue
    _ -> []
  end

  @doc """
  校验并发布提案列表。每项结果:
    {:published, {:rule, id} | {:tool, name} | {:lesson, id}}
    {:rejected, what, reason}
  tool 同 id 多候选 → Best-of-N (PPT) 选 top-1 再进 bench 门（DESIGN §6.8）。
  """
  def publish(proposals, opts \\ []) do
    proposals
    |> Enum.group_by(& &1["type"])
    |> Enum.flat_map(fn {type, group} ->
      case type do
        "rule" -> Enum.map(group, &publish_rule(&1))
        "tool" -> publish_tools(group, opts)
        "lesson" -> Enum.map(group, &publish_lesson(&1))
        other -> Enum.map(group, &{:rejected, &1, {:unknown_type, other}})
      end
    end)
  end

  defp publish_rule(%{"id" => id, "pattern" => pattern, "injection" => injection} = proposal) do
    with :ok <- validate_regex(pattern),
         :ok <- bench_gate(proposal) do
      Newbee.DEE.Rules.add(id, pattern, injection, source: :evolver)
      audit(:published, :rule, id)
      {:published, {:rule, id}}
    else
      {:error, reason} -> {:rejected, {:rule, id}, reason}
    end
  end

  defp publish_rule(proposal), do: {:rejected, proposal, :malformed}

  defp publish_tools(proposals, opts) do
    # 同 id 多候选（Best-of-N）：PPT 选 top-1
    best =
      if length(proposals) > 1 do
        rank_tool_candidates(proposals, opts)
        |> Map.get(:best)
      else
        hd(proposals)
      end

    case publish_tool(best) do
      {:published, _} = ok -> [ok]
      {:rejected, what, why} -> [{:rejected, what, why}]
    end
  end

  @doc """
  Best-of-N：对多个同 id tool 候选用 PPT 排名，返回 %{best, idx, ranking, scores}。
  PPT 判分失败时回退第一个候选（均匀排名）。
  """
  def rank_tool_candidates(cands, opts \\ []) do
    complete_fn = Keyword.get(opts, :complete_fn, &Newbee.LLM.Client.complete/3)
    client = Keyword.get(opts, :client, Newbee.LLM.Config.client_for("verifier"))
    task = "选择最佳的工具实现（可用性、健壮性、Elixir 惯用法）"

    result =
      Newbee.Evolution.PPT.select(client, task, Enum.map(cands, & &1["source"]), complete_fn: complete_fn)

    %{best: idx, ranking: ranking, scores: scores} = result
    %{best: Enum.at(cands, idx), idx: idx, ranking: ranking, scores: scores}
  end

  defp publish_tool(%{"id" => id, "name" => name, "source" => source} = proposal) do
    with :ok <- validate_tool(source),
         :ok <- bench_gate(proposal) do
      case Newbee.DEE.Tools.HotLoader.publish(name, source, message: "evolver: #{id}") do
        {:ok, _path} ->
          Newbee.Evolution.JIT.promote_to_tool(id, name)
          audit(:published, :tool, name)
          {:published, {:tool, name}}

        {:error, reason} ->
          {:rejected, {:tool, name}, reason}
      end
    else
      {:error, reason} -> {:rejected, {:tool, name}, reason}
    end
  end

  defp publish_tool(proposal), do: {:rejected, proposal, :malformed}

  defp publish_lesson(%{"id" => id, "note" => note}) do
    Newbee.Evolution.JIT.learn(id, note)
    audit(:published, :lesson, id)
    {:published, {:lesson, id}}
  end

  defp publish_lesson(proposal), do: {:rejected, proposal, :malformed}

  # ── 校验与裁判 ──

  defp validate_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :bad_regex}
    end
  end

  defp validate_tool(source) do
    case Code.string_to_quoted(source) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :bad_source}
    end
  end

  # bench 门：反事实回放全部失败抗体，任何回归即否决（DESIGN §6.3）
  defp bench_gate(_proposal) do
    {_passed, failed, details} = Newbee.Evolution.Bench.replay()

    if failed > 0 do
      {:error, {:antibody_regression, Enum.take(details, 3)}}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp audit(verdict, what, target) do
    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.emit(:audit, {:audit, verdict, "evolver", target, ring(what)})
    end

    log_event(%{verdict: verdict, what: what, target: target, at: DateTime.to_iso8601(DateTime.utc_now())})
  end

  # 权限环（DESIGN §3.7）：工具/规则 = Ring 3/2，lesson = Ring 1
  defp ring(:rule), do: 2
  defp ring(:tool), do: 3
  defp ring(:lesson), do: 1

  defp log_event(event) do
    File.mkdir_p!(Path.dirname(@evolog))
    File.write!(@evolog, [Jason.encode_to_iodata!(event), "\n"], [:append])
    :ok
  end
end
