defmodule Newbee.Evolution.BenchTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.Bench

  setup do
    dir = Path.join(System.user_home!(), ".newbee/antibodies")
    backup = if File.dir?(dir), do: File.ls!(dir), else: []

    on_exit(fn ->
      for f <- File.ls!(dir) -- backup, do: File.rm(Path.join(dir, f))
    end)

    :ok
  end

  test "沉淀抗体并回放通过" do
    :ok = Bench.add_antibody("ab_ok", "1 + 1", {:expect_ok, "2"})

    {passed, failed, details} = Bench.replay()
    assert failed == 0
    assert passed >= 1
    assert Enum.any?(details, fn {id, ok, _} -> id == "ab_ok" and ok end)
  end

  test "expect_error 抗体" do
    :ok = Bench.add_antibody("ab_err", "raise \"boom\"", {:expect_error, "boom"})
    {_, failed, _} = Bench.replay()
    assert failed == 0
  end

  test "auto 抗体不再复现 → 过期删除且不判回归（自愈）" do
    :ok = Bench.add_antibody("ab_stale", "1 + 1", {:expect_error, "NEVER_MATCHES"}, provenance: "auto")
    {_passed, failed, details} = Bench.replay()
    assert failed == 0
    # 文件已被删除
    refute Enum.any?(Bench.antibodies(), &(&1["id"] == "ab_stale"))
    assert Enum.any?(details, fn {id, ok, d} -> id == "ab_stale" and ok and d =~ "stale" end)
  end

  test "auto 抗体仍复现 → 保留且通过" do
    :ok = Bench.add_antibody("ab_still", "raise \"still-boom\"", {:expect_error, "still-boom"}, provenance: "auto")
    {_, failed, _} = Bench.replay()
    assert failed == 0
    assert Enum.any?(Bench.antibodies(), &(&1["id"] == "ab_still"))
  end

  test "人工 expect_error 抗体失效 → 如实判回归（不自愈）" do
    :ok = Bench.add_antibody("ab_manual", "1 + 1", {:expect_error, "NEVER_MATCHES"})
    {_, failed, details} = Bench.replay()
    assert failed >= 1
    assert Enum.any?(details, fn {id, ok, _} -> id == "ab_manual" and not ok end)
    # 不被删除
    assert Enum.any?(Bench.antibodies(), &(&1["id"] == "ab_manual"))
  end

  test "回归能被检出（故意失败的抗体）" do
    :ok = Bench.add_antibody("ab_fail", "1 + 1", {:expect_ok, "999"})
    {_, failed, details} = Bench.replay()
    assert failed >= 1
    assert Enum.any?(details, fn {id, ok, _} -> id == "ab_fail" and not ok end)
  end

  describe "连续分数回归 (score_ge)" do
    test "分数达标通过" do
      :ok = Bench.add_antibody("ab_score_ok", "1 + 1", {:score_ge, 12})

      # 注入 mock 判分：返回高分 18
      score_fn = fn _a, _ev -> %{score: 18.0} end
      {passed, failed, _} = Bench.replay(score_fn: score_fn)
      assert failed == 0
      assert passed >= 1
    end

    test "分数跌破阈值即否决（连续回归检出）" do
      :ok = Bench.add_antibody("ab_score_low", "1 + 1", {:score_ge, 12})

      score_fn = fn _a, _ev -> %{score: 5.0} end
      {_, failed, details} = Bench.replay(score_fn: score_fn)
      assert failed >= 1
      assert Enum.any?(details, fn {id, ok, _} -> id == "ab_score_low" and not ok end)
    end

    test "判分失败降级为 expect_ok（代码能跑不否决）" do
      :ok = Bench.add_antibody("ab_score_degrade", "1 + 1", {:score_ge, 12})

      # score_fn 报错 → 降级检查代码能跑
      score_fn = fn _a, _ev -> %{error: :score_failed} end
      {_, failed, _} = Bench.replay(score_fn: score_fn)
      assert failed == 0
    end

    test "阈值边界：恰好等于阈值通过" do
      :ok = Bench.add_antibody("ab_score_edge", "1 + 1", {:score_ge, 10})
      score_fn = fn _a, _ev -> %{score: 10.0} end
      {_, failed, _} = Bench.replay(score_fn: score_fn)
      assert failed == 0
    end
  end
end
