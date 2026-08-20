defmodule Newbee.Environment.Verifier.PPT do
  @moduledoc """
  概率枢轴锦标赛 (Probabilistic Pivot Tournament, LLM-as-a-Verifier 论文)。
  从 N 个候选里选出最佳，成本从 O(N^2) 降到 O(Nk)：

    (1) Ring pass：随机 Hamiltonian 环对相邻对做双槽比较——每个候选在 A 槽和
        B 槽各出现一次，抵消模型的位置偏置（论文的 positional bias 消除）。
    (2) Pivot 选择：按 ring-pass 累计分取 top-k 作为枢轴集 P。
    (3) Pivot tournament：non-pivot vs 每个 pivot、pivot vs pivot 全配对比，
        把预算集中在不确定的头部候选。
    (4) Selection：比较聚合成 w_i（累计分）/ c_i（参与次数），argmax 归一化分。

  比较用双槽评分 prompt（<score_A>/<score_B> 各 1..G 单 token 刻度），
  logprobs 可用时对分布取期望（连续分，零 tie），否则降级解析整数分。
  复用 Newbee.Agent.Progress 的刻度与 logprob 提取。
  """

  alias Newbee.Agent.Progress

  @doc """
  从 candidates（字符串列表，轨迹/源码）选出最佳。返回：

      %{best: idx, ranking: [idx], scores: %{idx => w/c}, comparisons: n, method: atom}

  opts:
    - `k`: 枢轴数（默认 max(2, div(N, 3))）
    - `scale`: 评分刻度（默认 :letters，见 Progress）
    - `complete_fn`: 注入判分函数（默认 Newbee.LLM.Client.complete/3）
    - `logprobs`: 是否尝试 logprobs（默认 true）
    - `temperature`: 采样温度（默认 0.2）
  """
  def select(client, task, candidates, opts \\ []) do
    n = length(candidates)

    if n < 2 do
      %{best: 0, ranking: [0], scores: %{0 => 1.0}, comparisons: 0, method: :trivial}
    else
      k = Keyword.get(opts, :k, max(2, div(n, 3)))
      scale = Keyword.get(opts, :scale, :letters)
      complete_fn = Keyword.get(opts, :complete_fn, &Newbee.LLM.Client.complete/3)
      logprobs = Keyword.get(opts, :logprobs, true)
      temperature = Keyword.get(opts, :temperature, 0.2)

      # (1) ring pass：随机环，相邻对双槽比较
      ring = ring_order(n)
      {ring_scores, ring_comp} = score_ring(client, task, candidates, ring, scale, complete_fn, logprobs, temperature)

      # (2) pivot 选择：ring-pass 累计分 top-k
      pivots =
        ring_scores
        |> Enum.sort_by(fn {_i, w} -> -w end)
        |> Enum.take(k)
        |> Enum.map(&elem(&1, 0))

      # (3) pivot tournament：non-pivot vs pivot 全配 + pivot 内部全配
      {tourney_scores, tourney_comp} =
        score_tournament(client, task, candidates, pivots, scale, complete_fn, logprobs, temperature)

      # (4) 聚合 w_i/c_i
      merged =
        Enum.reduce(Map.to_list(ring_scores) ++ Map.to_list(tourney_scores), %{}, fn {i, w}, acc ->
          Map.update(acc, i, %{w: w, c: 1}, fn e -> %{w: e.w + w, c: e.c + 1} end)
        end)

      normalized =
        Map.new(merged, fn {i, %{w: w, c: c}} -> {i, if(c > 0, do: w / c, else: 0.0)} end)

      if normalized == %{} do
        # 全部比较失败（判分器不可用）：均匀回退，选第一个候选
        %{best: 0, ranking: Enum.to_list(0..(n - 1)), scores: %{0 => 1.0}, comparisons: 0, method: :trivial}
      else
        ranking = Enum.sort_by(normalized, fn {_i, s} -> -s end) |> Enum.map(&elem(&1, 0))
        best = hd(ranking)

        %{
          best: best,
          ranking: ranking,
          scores: normalized,
          comparisons: ring_comp + tourney_comp,
          method: if(ring_comp > 0, do: :ppt, else: :single)
        }
      end
    end
  end

  # ── ring pass ──

  defp ring_order(n) do
    # 随机排列后成环：ring[i] 与 ring[(i+1) mod n] 相邻
    Enum.shuffle(0..(n - 1))
  end

  defp score_ring(client, task, cands, ring, scale, complete_fn, logprobs, temperature) do
    n = length(cands)

    {scores, comp} =
      Enum.reduce(0..(n - 1), {%{}, 0}, fn i, {acc, c} ->
        a = Enum.at(ring, i)
        b = Enum.at(ring, rem(i + 1, n))

        case compare_pair(client, task, Enum.at(cands, a), Enum.at(cands, b), scale, complete_fn, logprobs, temperature) do
          {:ok, sa, sb} ->
            # A 槽得分归 a，B 槽得分归 b
            acc = Map.update(acc, a, sa, &(&1 + sa))
            acc = Map.update(acc, b, sb, &(&1 + sb))
            {acc, c + 1}

          _ ->
            {acc, c}
        end
      end)

    {scores, comp}
  end

  # ── pivot tournament ──

  defp score_tournament(client, task, cands, pivots, scale, complete_fn, logprobs, temperature) do
    pivot_set = MapSet.new(pivots)
    n = length(cands)

    # non-pivot vs 每个 pivot
    # pivot 内部全配（一次方向即可，A/B 槽抵消偏置）
    pairs =
      for(i <- 0..(n - 1), not MapSet.member?(pivot_set, i), p <- pivots, i != p, do: {i, p}) ++
        for({p1, p2} <- pair_combinations(pivots), do: {p1, p2})

    pairs = Enum.uniq(pairs)

    Enum.reduce(pairs, {%{}, 0}, fn {a, b}, {acc, c} ->
      case compare_pair(client, task, Enum.at(cands, a), Enum.at(cands, b), scale, complete_fn, logprobs, temperature) do
        {:ok, sa, sb} ->
          acc = Map.update(acc, a, sa, &(&1 + sa))
          acc = Map.update(acc, b, sb, &(&1 + sb))
          {acc, c + 1}

        _ ->
          {acc, c}
      end
    end)
  end

  defp pair_combinations(list) do
    for {x, i} <- Enum.with_index(list), {y, j} <- Enum.with_index(list), i < j, do: {x, y}
  end

  # ── 双槽比较 ──

  # 返回 {:ok, score_a, score_b} | {:error, reason}
  defp compare_pair(client, task, traj_a, traj_b, scale, complete_fn, logprobs, temperature) do
    prompt = pair_prompt(task, traj_a, traj_b, scale)

    case complete_fn.(client, [%{"role" => "user", "content" => prompt}],
           logprobs: logprobs,
           top_logprobs: Progress.scale_size(scale),
           temperature: temperature
         ) do
      {:ok, content, %{logprobs: %{"content" => lp}}} when is_list(lp) and lp != [] ->
        # 双槽 logprob 提取
        case pair_logprob_expectation(lp, scale) do
          {:ok, sa, sb, _va, _vb} -> {:ok, sa, sb}
          :error -> pair_sample(content, scale)
        end

      {:ok, content, _} ->
        pair_sample(content, scale)

      {:error, e} ->
        {:error, e}
    end
  end

  # 从 logprobs.content 提取 <score_A> 与 <score_B> 两个 token 的分布期望
  defp pair_logprob_expectation(lp, scale) do
    tokens = Enum.map(lp, & &1["token"])
    text = Enum.join(tokens, "")

    with {:ok, idx_a} <- find_tag(tokens, text, "<score_A>"),
         {:ok, idx_b} <- find_tag(tokens, text, "<score_B>") do
      case {expect_at(lp, idx_a, scale), expect_at(lp, idx_b, scale)} do
        {{:ok, ea, va}, {:ok, eb, vb}} -> {:ok, ea, eb, va, vb}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp find_tag(tokens, text, tag) do
    # 找到 tag 在 text 里的位置，再定位覆盖该位置的 token
    case :binary.match(text, tag) do
      {pos, len} ->
        # tag 之后第一个 token 的起点（可能有空白 token，跳到非空白）
        pos_after = pos + len
        token_at(tokens, pos_after)

      :nomatch ->
        :error
    end
  end

  defp expect_at(lp, idx, scale) do
    entry = Enum.at(lp, idx)
    topp = entry["top_logprobs"] || []

    probs = Map.new(topp, fn t -> {t["token"], :math.exp(t["logprob"])} end)
    syms = scale_symbols(scale)

    {total, e, v} =
      Enum.reduce(syms, {0.0, 0.0, 0.0}, fn sym, {tot, acc, accv} ->
        p = Map.get(probs, sym, 0.0)
        val = Progress.token_to_value(scale, sym)
        {tot + p, acc + p * val, accv + p * val * val}
      end)

    if total > 0.0 do
      e = e / total
      v = max(v / total - e * e, 0.0)
      {:ok, e, v}
    else
      :error
    end
  end

  defp scale_symbols(scale) do
    # 复用 Progress 的刻度符号（通过 token_to_value 反查成本高，直接枚举）
    case scale do
      :letters -> ~w(A B C D E F G H I J K L M N O P Q R S T)
      :cn -> ~w(一 二 三 四 五 六 七 八 九 十)
      :digits -> Enum.map(1..20, &to_string/1)
    end
  end

  # 无 logprobs：解析文本里的 <score_A>X</score_A> <score_B>Y</score_B>
  defp pair_sample(content, scale) do
    with {sa, _} <- parse_score(content, "score_A", scale),
         {sb, _} <- parse_score(content, "score_B", scale) do
      {:ok, sa, sb}
    else
      _ -> {:error, :parse}
    end
  end

  defp parse_score(content, tag, scale) do
    case Regex.run(~r/<#{tag}>\s*([^<]+?)\s*<\/#{tag}>/, content) do
      [_, raw] ->
        sym = String.trim(raw)

        val =
          case scale do
            :digits -> parse_digits(sym)
            _ -> Progress.token_to_value(scale, sym)
          end

        case val do
          nil -> :error
          v -> {v * 1.0, :ok}
        end

      _ ->
        :error
    end
  end

  defp parse_digits(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 and n <= 20 -> n
      _ -> nil
    end
  end

  # ── token 定位（与 Progress 一致）──

  defp token_at(tokens, pos), do: do_token_at(tokens, pos, 0, 0)

  defp do_token_at([t | rest], pos, acc, idx) do
    if pos >= acc and pos < acc + String.length(t) do
      {:ok, idx}
    else
      do_token_at(rest, pos, acc + String.length(t), idx + 1)
    end
  end

  defp do_token_at([], _, _, _), do: :error

  # ── prompt ──

  defp pair_prompt(task, traj_a, traj_b, scale) do
    g = Progress.scale_size(scale)

    "You are an expert software engineering reviewer. You will see a task description and two candidate trajectories.\n\n" <>
      "Task:\n#{task}\n\n" <>
      "Trajectory A:\n#{traj_a}\n\n" <>
      "Trajectory B:\n#{traj_b}\n\n" <>
      "Carefully analyze each trajectory, then provide your final scores:\n" <>
      "<score_A>SYMBOL</score_A>\n<score_B>SYMBOL</score_B>\n\n" <>
      "Rating Rules: Rate correctness on a 1..#{g} scale (1 = incorrect, #{div(g, 2)} = borderline, #{g} = correct)."
  end
end
