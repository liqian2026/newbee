defmodule Newbee.Evolution.MetricsTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.Metrics

  test "从总线采集指标" do
    before = Metrics.summary()

    Newbee.Bus.emit(:usage, {:usage, %{"prompt_tokens" => 100, "completion_tokens" => 20}})

    Newbee.Bus.emit(
      :usage,
      {:usage,
       %{"prompt_tokens" => 100, "uncached_prompt_tokens" => 20, "cache_read_tokens" => 80, "cache_write_tokens" => 10}}
    )

    Newbee.Bus.emit(:tool_start, {:tool_start, "run_elixir", "t", "c"})
    Newbee.Bus.emit(:tool_error, {:tool_error, "boom"})
    Newbee.Bus.emit(:rule_hit, {:rule_hit, [%{id: "r1"}]})
    Newbee.Bus.emit(:turn_end, {:turn_end, :done, 123})
    Process.sleep(50)

    s = Metrics.summary()
    assert s.tokens_out == before.tokens_out + 20
    assert s.tokens_in == before.tokens_in + 120
    assert s.cache_read_tokens == before.cache_read_tokens + 80
    assert s.cache_write_tokens == before.cache_write_tokens + 10

    assert s.cache_hit_rate ==
             (before.cache_read_tokens + 80) /
               (before.tokens_in + 120 + before.cache_read_tokens + 80 + before.cache_write_tokens + 10)

    assert s.tool_calls == before.tool_calls + 1
    assert s.errors == before.errors + 1
    assert s.rule_hits == before.rule_hits + 1
    assert s.turns == before.turns + 1
    assert s.dones == before.dones + 1
  end
end
