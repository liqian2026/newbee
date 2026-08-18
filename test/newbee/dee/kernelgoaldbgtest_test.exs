defmodule Newbee.DEE.KernelGoalDbgTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.DEE.{Kernel, Evaluator}

  test "debug: goal state after set_goal" do
    {:ok, ev} = Evaluator.start(mode: :local)
    {:ok, kernel} =
      Kernel.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, %{"role" => "assistant", "content" => "r1", "tool_calls" => []}, %{}} end,
            fn _m, _o -> {:ok, %{"role" => "assistant", "content" => "r2", "tool_calls" => []}, %{}} end
          ])
      )

    IO.inspect(Newbee.DEE.Kernel.__info__(:functions) |> Enum.filter(fn {n, _} -> n in [:set_goal, :clear_goal, :goal, :handle_info] end), label: "kernel fns")
    IO.inspect(Kernel.set_goal(kernel, "目标", max_rounds: 2), label: "set_goal ret")
    Process.sleep(800)
    st = :sys.get_state(kernel)
    IO.inspect(st.goal, label: "goal after sleep")
    IO.inspect(Enum.map(st.messages, &{&1["role"], String.slice(&1["content"] || "", 0, 60)}), label: "messages", limit: :infinity)
  end
end
