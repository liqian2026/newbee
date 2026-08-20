defmodule Newbee.Environment.Jit do
  @moduledoc """
  认知 JIT（DESIGN §8.5）：环境是 JIT 编译器——持续把"需要模型推理的智能"
  编译成"不需要推理的确定性产物"。

  ```text
  L1 教训       kind: prompt release（读到要花 token 推理）
  L2 沉睡规则   kind: rule release（平时零成本，触发才注入）
  L3 蒸馏工具   kind: tool release（纯函数+测试，调用零 token）
  ```

  三个机制的运行时落位：

  - **热度剖析**：事件流统计 模式频率 × 单次 token 成本 = **编译收益**；
    越过阈值（收益 > 编译成本）才作为高优 need 进 adapter 队列——
    不热的模式永不编译，避免过度工程。价签数据让阈值计算越用越准。
  - **编译（compile）**：adapter 执行晋升——同 plugin release 演进或派生新
    plugin，走标准 Change 生命周期（小补丁纪律，§3.4）。
  - **去优化（deopt）**：L3 工具判退化时降级回上级形态 release 而非删除——
    知识不丢，条件合适重新编译。

  本模块是纯策略：识别热点、判定晋升/降级路径；执行走 Coordinator。
  """

  # 默认阈值：编译收益（token）> 编译成本（token）才晋升（§16 校准项）
  @default_compile_cost 5_000
  # deopt：L3 工具成功率跌破阈值且样本足够 → 降级
  @deopt_success_rate 0.5
  @deopt_min_samples 5

  defstruct patterns: %{}

  @doc "pattern 键：从事件提取可归因的重复模式标识（工具调用名 / 错误类别 / 任务类型）。"
  def pattern_key(%{topic: :tool_start, data: %{name: name}}), do: {:tool_use, to_string(name)}
  def pattern_key(%{"topic" => "tool_start", "data" => %{"name" => name}}), do: {:tool_use, to_string(name)}
  def pattern_key(%{topic: :tool_error, data: %{error_class: cls}}), do: {:error, to_string(cls)}
  def pattern_key(%{"topic" => "tool_error", "data" => %{"error_class" => cls}}), do: {:error, to_string(cls)}
  def pattern_key(_), do: nil

  @doc """
  热度剖析：从事件流统计每个模式的 频率 × 单次 token 成本 = 编译收益。
  events 为事件流（map 列表，含 topic/data/tokens）。
  返回 [%{pattern, count, token_cost, compile_benefit, hot?}]，按收益降序。
  """
  def profile(events, opts \\ []) do
    compile_cost = Keyword.get(opts, :compile_cost, @default_compile_cost)

    events
    |> Enum.reduce(%{}, fn ev, acc ->
      case pattern_key(ev) do
        nil ->
          acc

        key ->
          tokens = ev[:tokens] || ev["tokens"] || estimate_tokens(ev)
          Map.update(acc, key, {1, tokens}, fn {n, t} -> {n + 1, t + tokens} end)
      end
    end)
    |> Enum.map(fn {pattern, {count, tokens}} ->
      benefit = count * max(div(tokens, max(count, 1)), 1)

      %{
        pattern: pattern,
        count: count,
        token_cost: tokens,
        compile_benefit: benefit,
        hot?: benefit > compile_cost
      }
    end)
    |> Enum.sort_by(& -&1.compile_benefit)
  end

  @doc """
  热度阈值判定：越过阈值的模式作为高优 need 进 adapter 队列（§8.5）。
  返回 [%{capability, evidence, urgency: :high}]（need 消息载荷雏形）。
  """
  def hot_needs(events, opts \\ []) do
    events
    |> profile(opts)
    |> Enum.filter(& &1.hot?)
    |> Enum.map(fn p ->
      %{
        capability: "distill #{inspect(p.pattern)}",
        evidence: %{pattern: p.pattern, count: p.count, compile_benefit: p.compile_benefit},
        urgency: :high
      }
    end)
  end

  # ── 晋升/降级路径 ──

  @doc "L1 → L2：教训（prompt release）固化为沉睡规则（rule release）。"
  def promote_l1_to_l2(lesson, pattern, injection, opts \\ []) do
    %{
      plugin_id: Keyword.get(opts, :plugin_id, "rule." <> slug(lesson)),
      kind: :rule,
      derived_from: :l1_prompt,
      spec: %{pattern: pattern, injection: injection, scope: Keyword.get(opts, :scope, :all)},
      reason: "JIT L1→L2: #{lesson}"
    }
  end

  @doc "L2 → L3：沉睡规则/playbook 蒸馏为纯函数工具（带测试）。"
  def promote_l2_to_l3(name, source, test_source, opts \\ []) do
    %{
      plugin_id: Keyword.get(opts, :plugin_id, "tool." <> slug(name)),
      kind: :tool,
      derived_from: :l2_rule,
      source_files: %{"#{slug(name)}.ex" => source, "#{slug(name)}_test.exs" => test_source},
      reason: "JIT L2→L3: #{name}"
    }
  end

  @doc """
  deopt 判定：L3 工具判退化 → 降级回上级形态（L2 rule / L1 prompt）release。
  返回 {:deopt, target_form, reason} | :keep。
  """
  def deopt_decision(release_id, _opts \\ []) do
    f = Newbee.Environment.Fitness.overall(release_id)

    if f.samples >= @deopt_min_samples and (f.success_rate || 1.0) < @deopt_success_rate do
      {:deopt, :l2_rule,
       "success_rate #{Float.round((f.success_rate || 0.0) * 100, 1)}% < #{@deopt_success_rate * 100}% (n=#{f.samples})"}
    else
      :keep
    end
  end

  @doc "deopt 阈值（配置项暴露，§16 校准）。"
  def deopt_thresholds, do: %{success_rate: @deopt_success_rate, min_samples: @deopt_min_samples}

  # ── helpers ──

  defp estimate_tokens(ev) do
    # 无显式 token 记账时按输出大小粗估（价签数据让估计越用越准）
    bytes = ev[:output_bytes] || ev["output_bytes"] || 0
    max(div(bytes, 4), 100)
  end

  defp slug(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end
end
