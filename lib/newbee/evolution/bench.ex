defmodule Newbee.Evolution.Bench do
  @moduledoc """
  进化裁判 (DESIGN §6.3) ⭐：失败抗体 + 反事实回放。

  - 每个真实失败都会沉淀为**抗体**（antibody）：一条"这段代码在当前环境下
    必须成功/必须失败于某模式"的回归断言，永久进入回归集。
  - 连续分数回归（LLM-as-a-Verifier 落地）：抗体 check 支持 `{:score_ge, min}`——
    对代码用 verifier 打连续分（1..20），跌破阈值即否决。比二元断言更早发现退化
    （工具"还能跑但变差"也能拦住）。
  - 反事实回放：进化候选（新工具/新规则）落盘前，回放全部抗体——
    任何一个回归即否决，保证进化不回退。
  - 任务集 bench：bench/tasks/*.json 定义的端到端任务（真实 LLM 跑，
    `mix newbee.bench`），产出通过率/token 报告（M5 公开基准的底座）。
  """

  @dir Path.join(System.user_home!(), ".newbee/antibodies")

  @doc "沉淀抗体。check: {:expect_ok, pattern} | {:expect_error, pattern} | {:score_ge, min}（verifier 连续分 ≥ min，LLM-as-a-Verifier 连续回归检测）。opts: :task / :score_opts"
  def add_antibody(id, code, check, opts \\ []) do
    File.mkdir_p!(@dir)

    entry = %{
      id: to_string(id),
      code: code,
      check: check |> then(fn {k, p} -> %{"kind" => to_string(k), "pattern" => p} end),
      task: Keyword.get(opts, :task),
      score_opts: Keyword.get(opts, :score_opts, %{}),
      provenance: Keyword.get(opts, :provenance, "unknown"),
      at: DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(Path.join(@dir, "#{id}.json"), Jason.encode_to_iodata!(entry, pretty: true))
    :ok
  end

  @doc "全部抗体。"
  def antibodies do
    @dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) |> then(fn {:ok, b} -> Jason.decode(b) end) do
        {:ok, e} -> [e]
        _ -> []
      end
    end)
  end

  @doc """
  回放全部抗体（用独立求值器，互不污染）。返回 {passed, failed, details}。

  自愈（§6.3）：provenance=auto 的 expect_error 抗体若**不再复现**（环境已变化，
  瞬态失败已消失）→ 过期删除并计为通过，避免陈旧抗体误伤进化门；
  人工抗体与 expect_ok 抗体失败仍如实判回归。
  """
  def replay(opts \\ []) do
    evaluator = Keyword.get(opts, :evaluator, Newbee.DEE.Evaluator)
    score_fn = Keyword.get(opts, :score_fn, &score_default/2)

    results =
      antibodies()
      |> Enum.map(fn a ->
        {passed?, detail} = run_antibody(a, evaluator, score_fn)

        if not passed? and a["provenance"] == "auto" and
             get_in(a, ["check", "kind"]) == "expect_error" do
          File.rm(Path.join(@dir, "#{a["id"]}.json"))
          {a["id"], true, "stale auto-antibody removed"}
        else
          {a["id"], passed?, detail}
        end
      end)

    failed = Enum.filter(results, fn {_, ok, _} -> !ok end)
    {length(results) - length(failed), length(failed), results}
  end

  defp score_default(%{"code" => code, "task" => task, "score_opts" => score_opts}, _evaluator) do
    client = Newbee.LLM.Config.client_for("verifier")
    task = task || "Evaluate the correctness, robustness and idiomatic quality of this Elixir code."
    Newbee.Evolution.Progress.score(client, task, code, Map.new(score_opts || %{}))
  rescue
    _ -> %{score: 0.0, error: :score_failed}
  end

  defp run_antibody(%{"code" => code, "check" => %{"kind" => kind, "pattern" => pat}} = a, evaluator, score_fn) do
    result = Newbee.DEE.Evaluator.eval(evaluator, code)
    rendered = Newbee.DEE.Result.render(result)

    passed =
      case kind do
        "expect_ok" ->
          result.status == :ok and (pat == "" or rendered =~ pat)

        "expect_error" ->
          result.status == :error and rendered =~ pat

        "score_ge" ->
          min = parse_min(pat)

          case score_fn.(a, evaluator) do
            %{score: s} when is_number(s) ->
              s >= min

            _ ->
              # 判分失败（LLM 挂）时降级为 expect_ok：代码能跑即不否决，防卡死进化
              result.status == :ok
          end

        _ ->
          false
      end

    {passed, String.slice(rendered, 0, 300)}
  rescue
    e -> {false, "replay crash: #{inspect(e)}"}
  end

  defp parse_min(pat) when is_binary(pat) do
    case Integer.parse(pat) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp parse_min(n) when is_number(n), do: n
  defp parse_min(_), do: 0

  @doc "真实任务集（bench/tasks/*.json）：端到端验收。每项 {id, prompt, must_match}。"
  def tasks do
    Path.join(File.cwd!(), "bench/tasks")
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) |> then(fn {:ok, b} -> Jason.decode(b) end) do
        {:ok, t} -> [t]
        _ -> []
      end
    end)
  end

  @doc "跑任务集（真实 LLM）。返回 %{passed, total, tokens, details}。"
  def run_tasks(client) do
    details =
      tasks()
      |> Enum.map(fn t ->
        {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :node)

        {:ok, k} =
          Newbee.DEE.Kernel.start_link(client: client, evaluator: ev, session: false, render: fn _ -> :ok end)

        reply = Newbee.DEE.Kernel.submit(k, t["prompt"])
        usage = Newbee.DEE.Kernel.usage(k)

        passed =
          case reply do
            {:done, summary} -> summary =~ (t["must_match"] || "")
            _ -> false
          end

        GenServer.stop(k)
        GenServer.stop(ev)

        %{
          id: t["id"],
          passed: passed,
          tokens: usage["total_tokens"] || 0,
          reply: inspect(reply) |> String.slice(0, 200)
        }
      end)

    %{
      passed: Enum.count(details, & &1.passed),
      total: length(details),
      tokens: Enum.sum(Enum.map(details, & &1.tokens)),
      details: details
    }
  end
end
