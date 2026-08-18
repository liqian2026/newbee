defmodule Newbee.Evolution.EvolverTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.Evolver

  setup do
    hints = Path.join(System.user_home!(), ".newbee/hints.jsonl")
    backup = if File.exists?(hints), do: File.read!(hints), else: nil
    File.rm(hints)

    on_exit(fn ->
      if backup, do: File.write!(hints, backup)
      Newbee.DEE.Rules.remove("evo-rule-test")
    end)

    :ok
  end

  test "hint 记录与消费" do
    Evolver.hint("模型经常忘了跑 mix test")
    assert [%{"hint" => "模型经常忘了跑 mix test"}] = Evolver.take_hints()
    assert [] = Evolver.take_hints()
  end

  test "无线索时跳过" do
    assert {:skipped, :nothing_to_evolve} = Evolver.run_once(client_fun: fn _, _ -> {:error, :no_call} end)
  end

  test "合成规则提案并发布（假 LLM 出 JSON）" do
    Evolver.hint("总忘加文档")

    canned = fn _messages, _on_text ->
      {:ok,
       %{
         "role" => "assistant",
         "content" => ~s([{"type":"rule","id":"evo-rule-test","pattern":"defmodule.*do$","injection":"记得写 moduledoc"}]),
         "tool_calls" => []
       }, %{}}
    end

    results = Evolver.run_once(client_fun: canned)
    assert Enum.any?(results, &match?({:published, {:rule, "evo-rule-test"}}, &1))
    assert [%{id: "evo-rule-test"}] = Newbee.DEE.Rules.check("defmodule X do")
  end

  test "policy=:off 时整体跳过" do
    Newbee.Evolution.Policy.set(:off)
    Evolver.hint("x")
    assert {:skipped, :policy_off} = Evolver.run_once()
    Newbee.Evolution.Policy.set(:background)
    Evolver.take_hints()
  end


  describe "Best-of-N (PPT)" do
    test "rank_tool_candidates 用 PPT 选最优候选" do
      cands = [
        %{"type" => "tool", "id" => "evo-ppt", "name" => "GoodTool", "source" => "defmodule GoodTool do\n  def run, do: :good\nend"},
        %{"type" => "tool", "id" => "evo-ppt", "name" => "BadTool", "source" => "defmodule BadTool do\n  def run, do: :bad\nend"}
      ]

      # mock completer：按候选源码内容打分（good 高分 / bad 低分）
      complete_fn = fn _client, msgs, _opts ->
        prompt = hd(msgs)["content"]

        sa =
          if prompt =~ "Trajectory A:\ndefmodule GoodTool", do: 13, else: 4

        sb =
          if prompt =~ "Trajectory B:\ndefmodule BadTool", do: 4, else: 13

        {:ok, "<score_A>#{Newbee.Evolution.Progress.value_to_token(:letters, sa)}</score_A><score_B>#{Newbee.Evolution.Progress.value_to_token(:letters, sb)}</score_B>",
         %{usage: %{}, logprobs: nil}}
      end

      r = Evolver.rank_tool_candidates(cands, complete_fn: complete_fn, client: :fake)
      assert r.idx == 0
      assert r.best["name"] == "GoodTool"
    end

    test "publish 对同 id 多候选只发布 top-1" do
      # 直接测分组+发布逻辑（用 PPT 失败回退第一个验证只发一个）
      proposals = [
        %{"type" => "tool", "id" => "evo-ppt-x", "name" => "XTool", "source" => "defmodule XTool do\n  def run, do: :x\nend"},
        %{"type" => "tool", "id" => "evo-ppt-x", "name" => "XTool", "source" => "defmodule XTool do\n  def run, do: :y\nend"}
      ]

      # PPT 会真实调用（complete_fn 报错 → 回退第一个）
      results = Evolver.publish(proposals, complete_fn: fn _, _, _ -> {:error, :mock_fail} end, client: :fake)

      # 结果是一个列表，每项是发布结果；2 个候选 → 1 个发布决策
      assert length(results) == 1
    end
  end

end