defmodule Newbee.Evolution.ProgressTest do
  use ExUnit.Case, async: true
  alias Newbee.Evolution.Progress

  describe "刻度映射" do
    test "字母 A..T = 1..20，大小写不敏感" do
      assert Progress.token_to_value(:letters, "A") == 1
      assert Progress.token_to_value(:letters, "t") == 20
      assert Progress.token_to_value(:letters, "M") == 13
      assert Progress.value_to_token(:letters, 20) == "T"
    end

    test "中文 一..十 = 1..10" do
      assert Progress.token_to_value(:cn, "一") == 1
      assert Progress.token_to_value(:cn, "十") == 10
      assert Progress.token_to_value(:cn, "十一") == nil
    end

    test "未知刻度/符号返回 nil" do
      assert Progress.token_to_value(:letters, "Z") == nil
      assert Progress.token_to_value(:foo, "A") == nil
      assert Progress.value_to_token(:letters, 21) == nil
    end
  end

  describe "停滞检测 stalled?/2" do
    test "严格递增不算停滞" do
      refute Progress.stalled?([1.0, 1.1, 1.2, 1.3])
    end

    test "平台期（窗口内无净增长）算停滞" do
      assert Progress.stalled?([3.0, 3.1, 3.05, 3.0, 3.0])
    end

    test "下降算停滞" do
      assert Progress.stalled?([5.0, 4.0, 3.0])
    end

    test "步数不足不算停滞" do
      refute Progress.stalled?([1.0, 2.0])
      refute Progress.stalled?([], min_steps: 3)
    end

    test "window 决定看多近的窗口" do
      # 窗口 5 内有大涨不算停滞；窗口 3 只看近期平台算停滞
      scores = [1.0, 3.0, 3.1, 3.05, 3.0]
      refute Progress.stalled?(scores, window: 5)
      assert Progress.stalled?(scores, window: 3)
    end
  end

  describe "render_scores/1" do
    test "渲染趋势箭头" do
      assert Progress.render_scores([1.0, 2.5, 2.4, 3.0]) == "步1:1.0→ 步2:2.5↑ 步3:2.4↓ 步4:3.0↑"
    end
  end

  describe "score/4（mock completer）" do
    defp fake_logprob(_client, _msgs, opts) do
      if opts[:logprobs] do
        content = [
          %{"token" => "<score>", "logprob" => -1.0, "top_logprobs" => []},
          %{"token" => "M", "logprob" => -0.35, "top_logprobs" => [
            %{"token" => "M", "logprob" => -0.35},
            %{"token" => "A", "logprob" => -2.3},
            %{"token" => "B", "logprob" => -2.3},
            %{"token" => "T", "logprob" => -2.3}
          ]},
          %{"token" => "</score>", "logprob" => -1.0, "top_logprobs" => []}
        ]

        {:ok, "<score>M</score>", %{usage: %{}, logprobs: %{"content" => content}}}
      else
        {:ok, "<score>M</score>", %{usage: %{}, logprobs: nil}}
      end
    end

    defp fake_sample(content), do: fn _c, _m, _o -> {:ok, content, %{usage: %{}, logprobs: nil}} end

    test "logprobs 路径：对评分 token 分布取期望" do
      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: &fake_logprob/3, k: 1)

      assert r.method == :logprob
      # 期望 = 0.1*1 + 0.1*2 + 0.7*13 + 0.1*20 = 11.4（归一化后）
      assert_in_delta r.score, 11.4, 0.05
    end

    test "采样路径：解析刻度符号得整数分" do
      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: fake_sample("<score>N</score>"), k: 1, logprobs: false)

      assert r.method == :sample
      assert r.score == 14.0
    end

    test "中文刻度采样" do
      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: fake_sample("<score>八</score>"), k: 1, logprobs: false, scale: :cn)

      assert r.score == 8.0
    end

    test "多标准 ensemble 取平均" do
      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "A", desc: "d"}, %{name: "B", desc: "d"}],
        complete_fn: fake_sample("<score>C</score>"), k: 1, logprobs: false)

      assert length(r.criteria) == 2
      assert r.score == 3.0
    end

    test "k 次采样取平均" do
      # 两次采样返回不同值 → 平均
      seq = ["<score>C</score>", "<score>E</score>"]
      counter = :counters.new(1, [])
      fn_completer = fn _c, _m, _o ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        {:ok, Enum.at(seq, rem(n, 2)), %{usage: %{}, logprobs: nil}}
      end

      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: fn_completer, k: 2, logprobs: false)

      assert r.score == 4.0  # (3 + 5) / 2
    end

    test "解析失败 → score 0 且 method :error" do
      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: fake_sample("<score>??</score>"), k: 1, logprobs: false)

      assert r.score == 0.0
      assert hd(r.criteria).method == :error
    end

    test "LLM 调用报错 → score 0" do
      err_fn = fn _c, _m, _o -> {:error, :timeout} end
      r = Progress.score(:fake, "task", "traj",
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: err_fn, k: 1)

      assert r.score == 0.0
    end
  end

  describe "track/3" do
    test "逐前缀打分返回 [{step, score, variance}]" do
      fn_completer = fn _c, _m, _o -> {:ok, "<score>D</score>", %{usage: %{}, logprobs: nil}} end
      result = Progress.track(:fake, "task", ["step1", "step1 step2"],
        criteria: [%{name: "Spec", desc: "d"}],
        complete_fn: fn_completer, k: 1, logprobs: false)

      assert result == [{1, 4.0, 33.25}, {2, 4.0, 33.25}]
    end
  end
end