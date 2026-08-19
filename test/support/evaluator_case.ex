defmodule Newbee.EvaluatorCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :node
    end
  end

  setup_all do
    # 单例 peer：全 suite 共享一次 :peer boot，省 N×60s
    {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :node)
    on_exit(fn -> if Process.alive?(ev), do: GenServer.stop(ev) end)
    %{shared_ev: ev}
  end
end
