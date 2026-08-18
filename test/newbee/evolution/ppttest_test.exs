defmodule Newbee.Evolution.PPTTest do
  use ExUnit.Case, async: true
  alias Newbee.Evolution.PPT

  # mock：按候选内容（轨迹字符串）返回分数，评分反映真实质量
  # 候选内容含 "GOOD" → 高分 M(13)；"BAD" → 低分 D(4)；"MID" → I(9)
  defp quality_completer(_client, msgs, opts) do
    # 从 prompt 里提取 A/B 轨迹内容（简化：按出现顺序）
    prompt = hd(msgs)["content"]

    {ta, tb} =
      case Regex.run(~r/Trajectory A:\n(.*?)\n\nTrajectory B:\n(.*?)\n\nCarefully/s, prompt) do
        [_, a, b] -> {a, b}
        _ -> {"", ""}
      end

    sa = score_of(ta)
    sb = score_of(tb)

    if opts[:logprobs] do
      # 构造 logprobs：两个评分 token 各带确定分布
      content = [
        %{"token" => "<score_A>", "logprob" => -1.0, "top_logprobs" => []},
        %{"token" => sym_of(sa), "logprob" => 0.0, "top_logprobs" => [%{"token" => sym_of(sa), "logprob" => 0.0}]},
        %{"token" => "</score_A>", "logprob" => -1.0, "top_logprobs" => []},
        %{"token" => "<score_B>", "logprob" => -1.0, "top_logprobs" => []},
        %{"token" => sym_of(sb), "logprob" => 0.0, "top_logprobs" => [%{"token" => sym_of(sb), "logprob" => 0.0}]},
        %{"token" => "</score_B>", "logprob" => -1.0, "top_logprobs" => []}
      ]

      {:ok, "<score_A>#{sym_of(sa)}</score_A><score_B>#{sym_of(sb)}</score_B>",
       %{usage: %{}, logprobs: %{"content" => content}}}
    else
      {:ok, "<score_A>#{sym_of(sa)}</score_A><score_B>#{sym_of(sb)}</score_B>", %{usage: %{}, logprobs: nil}}
    end
  end

  defp score_of(traj) do
    cond do
      traj =~ "GOOD" -> 13
      traj =~ "MID" -> 9
      traj =~ "BAD" -> 4
      true -> 7
    end
  end

  defp sym_of(v), do: Newbee.Evolution.Progress.value_to_token(:letters, v)

  test "从 N 个候选中选出最佳（logprob 路径）" do
    cands = ["BAD candidate", "MID candidate", "GOOD candidate", "MID2 candidate"]

    r =
      PPT.select(:fake, "task", cands,
        complete_fn: &quality_completer/3,
        k: 2,
        logprobs: true
      )

    # GOOD
    assert r.best == 2
    assert hd(r.ranking) == 2
    assert r.scores[2] > r.scores[0]
    assert r.method == :ppt
  end

  test "采样路径同样选出最佳" do
    cands = ["GOOD candidate", "BAD candidate"]

    r =
      PPT.select(:fake, "task", cands,
        complete_fn: &quality_completer/3,
        logprobs: false,
        k: 1
      )

    assert r.best == 0
    assert r.scores[0] > r.scores[1]
  end

  test "单候选时直接返回" do
    r = PPT.select(:fake, "task", ["only"], complete_fn: &quality_completer/3)
    assert r.best == 0
    assert r.method == :trivial
    assert r.comparisons == 0
  end

  test "比较次数受 k 控制（O(Nk)）" do
    cands = Enum.map(1..10, &"candidate #{&1}")

    r =
      PPT.select(:fake, "task", cands,
        complete_fn: &quality_completer/3,
        k: 3,
        logprobs: false
      )

    # ring pass: 10 次；tournament: (10-3)*3 + C(3,2) = 21+3 = 24；共 34
    assert r.comparisons == 34
  end

  test "ranking 是全排列且首元素即 best" do
    cands = Enum.map(1..5, &"candidate #{&1}")
    r = PPT.select(:fake, "task", cands, complete_fn: &quality_completer/3, k: 2, logprobs: false)

    assert Enum.sort(r.ranking) == [0, 1, 2, 3, 4]
    assert hd(r.ranking) == r.best
  end
end
