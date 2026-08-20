defmodule Newbee.Agent.LoopProgressTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  # fake verifier：按脚本返回分数
  defp verifier(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    fn _client, _msgs, _opts ->
      case Agent.get_and_update(agent, fn
             [v | rest] -> {v, rest}
             [] -> {nil, []}
           end) do
        score when is_binary(score) -> {:ok, "<score>#{score}</score>", %{usage: %{}, logprobs: nil}}
        _ -> {:error, :exhausted}
      end
    end
  end

  test "每 every 步打分并发出 progress 事件（不停滞）" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    # 4 次 run_elixir + done；every=2 → 第 2、4 步各打一次分
    script = [
      fn _m, _o -> {:ok, tool_msg("1 + 1"), %{}} end,
      fn _m, _o -> {:ok, tool_msg("2 + 2"), %{}} end,
      fn _m, _o -> {:ok, tool_msg("3 + 3"), %{}} end,
      fn _m, _o -> {:ok, tool_msg("4 + 4"), %{}} end,
      fn _m, _o -> {:ok, done_msg("ok"), %{}} end
    ]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: scripted(script),
        progress: %{
          client: :fake_verifier,
          every: 2,
          min_steps: 3,
          complete_fn: verifier(["D", "D", "E", "E"])
        }
      )

    assert {:done, "ok"} = Loop.submit(kernel, "task")

    assert_received {:newbee_event, :progress, {:progress, s1, _scores1}}
    assert s1 > 0
    assert_received {:newbee_event, :progress, {:progress, _s2, scores2}}
    assert length(scores2) == 2
    refute_received {:newbee_event, :progress_stall, _}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "停滞时注入干预提醒（仅一次）" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    # 5 次 run_elixir + done；every=2，min_steps=2 → 第 2、4 步打分后判停滞
    script =
      Enum.map(1..5, fn i -> fn _m, _o -> {:ok, tool_msg("x = #{i}"), %{}} end end) ++
        [fn _m, _o -> {:ok, done_msg("ok"), %{}} end]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: scripted(script),
        progress: %{
          client: :fake_verifier,
          every: 2,
          min_steps: 2,
          window: 3,
          complete_fn: verifier(["D", "D", "D"])
        }
      )

    assert {:done, "ok"} = Loop.submit(kernel, "task")

    assert_received {:newbee_event, :progress, {:progress, _, _}}
    assert_received {:newbee_event, :progress, {:progress, _, _}}
    assert_received {:newbee_event, :progress_stall, {:progress_stall, scores}}
    assert length(scores) >= 2

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end
