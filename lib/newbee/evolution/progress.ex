defmodule Newbee.Evolution.Progress do
  @moduledoc """
  进度验证器 (LLM-as-a-Verifier 落地, DESIGN 新 §6.7)。

  对 agent 轨迹前缀打**连续分数**，三轴齐备：
    - 刻度粒度 G：评分刻度默认为字母 A..T（单 token，可提取 logprob 分布）；
      :cn 用 一..十（中文单字 token）；:digits 用 1..20（无 logprob 场景）。
    - 重复评估 K：logprobs 不可用时降级为 K 次采样平均（论文 repeated evaluation 轴）。
    - 标准分解 C：默认 Specification/Output/Errors 三个子标准 ensemble，
      替代单一整体 rubric（论文 criteria decomposition 轴）。

  logprobs 可用 → 对评分 token 的**全分布取期望**（连续分数，零 tie）；
  不可用 → 自动降级采样模式。两者都产出 1..G 连续分数。
  """

  @scales %{
    # 字母 A..T = 1..20：单 token，logprob 提取最稳（论文 G=20）
    letters: %{symbols: ~w(A B C D E F G H I J K L M N O P Q R S T)},
    # 中文 一..十 = 1..10：单字 token（十一~二十是双字，破坏单 token 假设，故到十）
    cn: %{symbols: ~w(一 二 三 四 五 六 七 八 九 十)},
    # 数字 1..20：tokenizer 兼容性最好，但 10~20 可能多 token，不用于 logprob 分布
    digits: %{symbols: Enum.map(1..20, &to_string/1)}
  }

  @default_criteria [
    %{name: "Specification", desc: "所有任务需求是否都被满足；是否有任何需求缺失或走偏。"},
    %{name: "Output", desc: "最终输出格式与预期结果是否一致；产物是否可用。"},
    %{name: "Errors", desc: "日志与工具输出中是否有失败信号（编译错误/异常/卡死/重复失败）。"}
  ]

  def scales, do: Map.keys(@scales)

  @doc "刻度符号 -> 数值映射（大小写不敏感）。"
  def token_to_value(scale, token) when is_binary(token) do
    case Map.fetch(@scales, scale) do
      {:ok, %{symbols: syms}} ->
        syms
        |> Enum.with_index(1)
        |> Enum.find_value(fn {s, v} -> String.downcase(s) == String.downcase(token) && v end)

      :error ->
        nil
    end
  end

  @doc "数值 -> 刻度符号。"
  def value_to_token(scale, value) when is_integer(value) do
    case Map.fetch(@scales, scale) do
      {:ok, %{symbols: syms}} -> Enum.at(syms, value - 1)
      :error -> nil
    end
  end

  def scale_size(scale), do: @scales[scale][:symbols] |> length()

  @doc """
  对一条轨迹前缀打连续分数。返回：

      %{score: float, variance: float, criteria: [%{name, score, variance}], method: :logprob | :sample}

  opts:
    - `scale`: :letters（默认）| :cn | :digits
    - `criteria`: 子标准列表（默认 @default_criteria）；传 [] 表示单一整体 rubric
    - `k`: 采样次数（logprobs 模式下默认 1；降级采样默认 3）
    - `logprobs`: 是否尝试 logprobs 分布（默认 true；模型不支持时自动降级）
    - `temperature`: 采样温度（默认 0.2）
  """
  def score(client, task, traj, opts \\ []) do
    scale = Keyword.get(opts, :scale, :letters)
    criteria = Keyword.get(opts, :criteria, @default_criteria)
    k = Keyword.get(opts, :k, 1)
    want_logprobs = Keyword.get(opts, :logprobs, true)
    temperature = Keyword.get(opts, :temperature, 0.2)
    complete_fn = Keyword.get(opts, :complete_fn, &Newbee.LLM.Client.complete/3)

    per =
      Enum.map(criteria, fn c ->
        crit_score(client, task, traj, c, scale, k, want_logprobs, temperature, complete_fn)
      end)

    scores = Enum.map(per, & &1.score)
    variances = Enum.map(per, & &1.variance)
    methods = per |> Enum.map(& &1.method) |> Enum.uniq()

    %{
      score: mean(scores),
      variance: mean(variances),
      criteria: per,
      method: if(:logprob in methods, do: :logprob, else: :sample)
    }
  end

  @doc """
  轨迹进度曲线：对 prefixes（从旧到新的前缀列表）逐段打分，返回 [{step, score, variance}]。
  step 从 1 起。整体（完整轨迹）也可作为最后一段传入。
  """
  def track(client, task, prefixes, opts \\ []) do
    prefixes
    |> Enum.with_index(1)
    |> Enum.map(fn {traj, i} ->
      r = score(client, task, traj, opts)
      {i, r.score, r.variance}
    end)
  end

  @doc """
  停滞检测：scores 按时间序（旧→新）。最近 window 步内，最新分没有超过历史峰值
  超过 threshold → 停滞（模型在绕路/原地打转）。返回 boolean。
  """
  def stalled?(scores, opts \\ []) do
    window = Keyword.get(opts, :window, 5)
    min_steps = Keyword.get(opts, :min_steps, 3)
    threshold = Keyword.get(opts, :threshold, 0.0)

    recent = Enum.take(Enum.reverse(scores), window) |> Enum.reverse()

    # 停滞 = 窗口内无净增长（最新分相对窗口起点没有超过 threshold 的进步）
    length(recent) >= min_steps and
      List.last(recent) - hd(recent) <= threshold
  end

  @doc "分数序列的人类可读摘要（给干预消息/日志用）。"
  def render_scores(scores) do
    scores
    |> Enum.with_index(1)
    |> Enum.map_join(" ", fn {s, i} ->
      dir =
        if i > 1 and s > Enum.at(scores, i - 2),
          do: "↑",
          else: if(i > 1 and s < Enum.at(scores, i - 2), do: "↓", else: "→")

      "步#{i}:#{Float.round(s, 2)}#{dir}"
    end)
  end

  # ── internals ──

  defp crit_score(client, task, traj, criterion, scale, k, want_logprobs, temperature, complete_fn) do
    {scores, variances, methods} =
      Enum.reduce(1..k, {[], [], []}, fn _, {ss, vs, ms} ->
        case ask_score(client, task, traj, criterion, scale, want_logprobs, temperature, complete_fn) do
          {:ok, s, v, m} -> {[s | ss], [v | vs], [m | ms]}
          {:error, _} -> {ss, vs, ms}
        end
      end)

    case {scores, variances} do
      {[], _} ->
        %{name: criterion[:name], score: 0.0, variance: 0.0, method: :error}

      {ss, vs} ->
        %{
          name: criterion[:name],
          score: mean(ss),
          variance: mean(vs),
          method: Enum.uniq(methods) |> hd()
        }
    end
  end

  # 单次判分。返回 {:ok, score, variance, method} | {:error, reason}
  defp ask_score(client, task, traj, criterion, scale, want_logprobs, temperature, complete_fn) do
    prompt = score_prompt(task, traj, criterion, scale)

    case complete_fn.(client, [%{"role" => "user", "content" => prompt}],
           logprobs: want_logprobs,
           top_logprobs: scale_size(scale),
           temperature: temperature
         ) do
      {:ok, content, %{logprobs: %{"content" => lp} = _}} when is_list(lp) and lp != [] ->
        case logprob_expectation(lp, scale) do
          {:ok, e, v} -> {:ok, e, v, :logprob}
          :error -> sample_score(content, scale)
        end

      {:ok, content, _} ->
        sample_score(content, scale)

      {:error, e} ->
        {:error, e}
    end
  end

  # 从 logprobs.content 中找 <score> 标签后的评分 token，对刻度符号分布取期望
  defp logprob_expectation(lp, scale) do
    # 拼接 token 文本定位标签
    tokens = Enum.map(lp, & &1["token"])
    text = Enum.join(tokens, "")

    case Regex.run(~r/<score>(.*?)<\/score>/s, text) do
      [_, _inner] ->
        # 评分 token 在 content 中的 char 位置
        pos = String.length(String.split(text, ~r/<score>/) |> hd()) + String.length("<score>")
        # 找到覆盖该位置的 token 索引
        case token_at(tokens, pos) do
          {:ok, idx} ->
            entry = Enum.at(lp, idx)
            topp = entry["top_logprobs"] || []

            # 刻度符号概率表：top_logprobs 里出现的取 exp(logprob)，没出现的视为 0
            probs =
              Map.new(topp, fn t -> {t["token"], :math.exp(t["logprob"])} end)

            syms = @scales[scale][:symbols]

            {total, e, v} =
              Enum.reduce(syms, {0.0, 0.0, 0.0}, fn sym, {tot, acc, accv} ->
                p = Map.get(probs, sym, 0.0)
                val = token_to_value(scale, sym)
                {tot + p, acc + p * val, accv + p * val * val}
              end)

            if total > 0.0 do
              e = e / total
              v = max(v / total - e * e, 0.0)
              {:ok, e, v}
            else
              :error
            end

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp token_at(tokens, pos) do
    Enum.reduce_while(Enum.with_index(tokens), :error, fn {t, _i}, _ ->
      if String.length(t) >= 1 do
        {:cont, :error}
      else
        {:cont, :error}
      end
    end)
    |> case do
      _ ->
        # 逐 token 累计长度
        do_token_at(tokens, pos, 0, 0)
    end
  end

  defp do_token_at([t | rest], pos, acc, idx) do
    if pos >= acc and pos < acc + String.length(t) do
      {:ok, idx}
    else
      do_token_at(rest, pos, acc + String.length(t), idx + 1)
    end
  end

  defp do_token_at([], _, _, _), do: :error

  # 无 logprobs：从文本解析整数分（字母/中文/数字均支持），多次采样由上层平均
  defp sample_score(content, scale) do
    case Regex.run(~r/<score>\s*([^<]+?)\s*<\/score>/s, content) do
      [_, raw] ->
        sym = String.trim(raw)

        val =
          case scale do
            :digits -> parse_digits(sym)
            _ -> token_to_value(scale, sym)
          end

        case val do
          nil ->
            {:error, :parse}

          v ->
            g = scale_size(scale)
            # 单次采样方差近似：均匀分布方差作为不确定性估计的下界
            {:ok, v * 1.0, (g * g - 1) / 12, :sample}
        end

      _ ->
        {:error, :parse}
    end
  end

  defp parse_digits(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 and n <= 20 -> n
      _ -> nil
    end
  end

  defp score_prompt(task, traj, criterion, scale) do
    g = scale_size(scale)

    """
    You are an expert software engineering reviewer. You will see a task description and an agent's trajectory so far.

    Evaluation Criteria: #{criterion[:name]} — #{criterion[:desc]}

    Task:
    #{task}

    Trajectory (so far):
    #{traj}

    Carefully analyze the trajectory, then provide your final score:
    <score>SYMBOL</score>

    Rating Rules: Rate progress on a 1..#{g} scale based on the criterion (1 = no progress / incorrect, #{div(g, 2)} = borderline, #{g} = fully correct).
    """
  end

  defp mean([]), do: 0.0
  defp mean(ls), do: Enum.sum(ls) / length(ls)
end
