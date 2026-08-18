defmodule Newbee.DEE.KernelTest do
  use ExUnit.Case, async: true
  alias Newbee.DEE.{Kernel, Evaluator}

  defp tool_msg(code, id \\ "call_1") do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code})}
        }
      ]
    }
  end

  defp done_msg(summary) do
    %{
      "role" => "assistant",
      "content" => "final text",
      "tool_calls" => [
        %{
          "id" => "call_done",
          "type" => "function",
          "function" => %{"name" => "done", "arguments" => Jason.encode!(%{summary: summary})}
        }
      ]
    }
  end

  test "完整循环：run_elixir → 回填 → done，绑定留在求值器" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, _on_text -> {:ok, tool_msg("x = 40 + 2"), %{"total_tokens" => 10}} end,
      fn messages, _on_text ->
        # 断言工具结果被回填进 messages
        assert Enum.any?(messages, fn m ->
                 m["role"] == "tool" and m["content"] =~ "42"
               end)

        {:ok, done_msg("算完了"), %{"total_tokens" => 5}}
      end
    ]

    {:ok, kernel} =
      Kernel.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: scripted(script)
      )

    assert {:done, "算完了"} = Kernel.submit(kernel, "算个 42")
    # 绑定持久
    assert Enum.any?(Evaluator.bindings_summary(ev), &(&1.name == :x))
    # token 记账
    assert Kernel.usage(kernel)["total_tokens"] == 15
  end

  test "模型只输出文本时 turn 结束" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, on_text ->
        on_text.("直接回答")
        {:ok, %{"role" => "assistant", "content" => "直接回答", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} = Kernel.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:text, "直接回答"} = Kernel.submit(kernel, "hi")
  end

  test "done 工具调用也回填 tool 响应（历史不留悬空 tool_calls）" do
    {:ok, ev} = Evaluator.start(mode: :local)
    script = [fn _m, _t -> {:ok, done_msg("完"), %{}} end]

    {:ok, kernel} =
      Kernel.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))

    assert {:done, "完"} = Kernel.submit(kernel, "x")

    last = :sys.get_state(kernel).messages |> List.last()
    assert last["role"] == "tool"
    assert last["tool_call_id"] == "call_done"
  end

  test "恢复含悬空 tool_calls 的 transcript：载入时补占位（DeepSeek 400 根因）" do
    {:ok, ev} = Evaluator.start(mode: :local)
    sid = "test_repair_#{:erlang.unique_integer([:positive])}"
    s = Newbee.Session.open(sid)
    Newbee.Session.append(s, %{"role" => "user", "content" => "hi"})
    # 崩溃现场：assistant 带了 tool_calls，tool 响应永远没写进去
    Newbee.Session.append(s, tool_msg("1 + 1", "call_orphan"))

    script = [
      fn messages, _t ->
        assert Enum.any?(messages, fn m ->
                 m["role"] == "tool" and m["tool_call_id"] == "call_orphan" and
                   m["content"] =~ "丢失"
               end)

        {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} =
      Kernel.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: scripted(script)
      )

    assert {:text, "ok"} = Kernel.submit(kernel, "继续")
    File.rm(s.transcript)
  end

  test "恢复会话逐字复用首次 system prompt" do
    {:ok, ev} = Evaluator.start(mode: :local)
    sid = "test_prefix_resume_#{System.unique_integer([:positive, :monotonic])}_#{System.system_time(:microsecond)}"

    {:ok, first} =
      Kernel.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: fn messages, _on_text ->
          assert List.first(messages)["role"] == "system"
          {:ok, %{"role" => "assistant", "content" => "one", "tool_calls" => []}, %{}}
        end
      )

    assert {:text, "one"} = Kernel.submit(first, "first")
    first_prompt = :sys.get_state(first).messages |> List.first() |> Map.fetch!("content")
    GenServer.stop(first)

    {:ok, resumed} =
      Kernel.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: fn messages, _on_text ->
          assert List.first(messages)["content"] == first_prompt
          {:ok, %{"role" => "assistant", "content" => "two", "tool_calls" => []}, %{}}
        end
      )

    assert {:text, "two"} = Kernel.submit(resumed, "second")
  end

  test "Esc 中断：client 返回 {:interrupted, content} 时 turn 立即终止" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, on_text ->
        on_text.("部分生成")
        {:interrupted, "部分生成"}
      end
    ]

    {:ok, kernel} = Kernel.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:interrupted, "部分生成"} = Kernel.submit(kernel, "hi")

    # 部分生成的 assistant 消息不入历史（避免悬空 tool_calls）
    msgs = :sys.get_state(kernel).messages
    refute Enum.any?(msgs, &(&1["role"] == "assistant" and &1["content"] == "部分生成"))
  end

  test "中断标志：新一轮提交自动清除（上一轮残留不影响下一轮）" do
    Newbee.LLM.Client.interrupt()
    assert Newbee.LLM.Client.interrupted?()

    {:ok, ev} = Evaluator.start(mode: :local)
    script = [fn _messages, on_text -> {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}} end]
    {:ok, kernel} = Kernel.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:text, "ok"} = Kernel.submit(kernel, "hi")
    refute Newbee.LLM.Client.interrupted?()
  end

  test "中断标志在 execute_calls 阶段生效：不发起下一个工具调用" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, _on_text ->
        {:ok, tool_msg("1 + 1", "call_1"), %{}}
      end
    ]

    {:ok, kernel} = Kernel.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))

    # 提交前预置中断：第一个工具调用前就会 halt
    Newbee.LLM.Client.interrupt()
    assert {:interrupted, nil} = Kernel.submit(kernel, "hi")
    refute Newbee.LLM.Client.interrupted?()
  end

  defp scripted(script) do
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
end


:ok