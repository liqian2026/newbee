defmodule Newbee.TestScripted do
  @moduledoc "测试用：脚本化 LLM 客户端。"

  def scripted(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    fn messages, on_text ->
      fun =
        Agent.get_and_update(agent, fn
          [f | rest] -> {f, rest}
          [] -> {nil, []}
        end)

      if fun, do: fun.(messages, on_text), else: {:error, :script_exhausted}
    end
  end

  def done_msg(summary) do
    %{
      "role" => "assistant",
      "content" => "final",
      "tool_calls" => [
        %{
          "id" => "c_done",
          "type" => "function",
          "function" => %{"name" => "done", "arguments" => Jason.encode!(%{summary: summary})}
        }
      ]
    }
  end

  def tool_msg(code, id \\ "c1") do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code, title: "t"})}
        }
      ]
    }
  end
end


:ok