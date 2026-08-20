defmodule Newbee.Agent.LoopFinalCheckTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

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

  test "高分终局验证直接 done" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, done_msg("task done"), %{}} end
          ]),
        progress: %{
          client: :fake,
          every: 100,
          final_check: true,
          done_threshold: 12,
          complete_fn: verifier(["T", "T", "T"])
        }
      )

    assert {:done, "task done"} = Loop.submit(kernel, "task")
    assert_received {:newbee_event, :final_check, {:final_check, s}}
    assert s >= 12
    refute_received {:newbee_event, :final_check_low, _}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "低分终局验证被拦，注入提醒后模型重试成功" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    # 第一次 done 低分 → 提醒 → 模型再 done（这次 final_checked=true 直接过）
    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, done_msg("hasty done"), %{}} end,
            fn _m, _o -> {:ok, done_msg("final done"), %{}} end
          ]),
        progress: %{
          client: :fake,
          every: 100,
          final_check: true,
          done_threshold: 12,
          complete_fn: verifier(["D", "D", "D"])
        }
      )

    assert {:done, "final done"} = Loop.submit(kernel, "task")
    assert_received {:newbee_event, :final_check, {:final_check, low}}
    assert low < 12
    assert_received {:newbee_event, :final_check_low, {:final_check_low, ^low}}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "判分失败不阻塞完成" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    err_fn = fn _c, _m, _o -> {:error, :timeout} end

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, done_msg("ok"), %{}} end
          ]),
        progress: %{
          client: :fake,
          every: 100,
          final_check: true,
          complete_fn: err_fn
        }
      )

    assert {:done, "ok"} = Loop.submit(kernel, "task")

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "progress 未开启时终局验证不生效" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, done_msg("ok"), %{}} end
          ])
      )

    assert {:done, "ok"} = Loop.submit(kernel, "task")
    refute_received {:newbee_event, :final_check, _}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end
