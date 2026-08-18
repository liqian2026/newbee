defmodule Newbee.Codec do
  @moduledoc """
  模型↔环境协议 (DESIGN §4.2)：function calling 包裹自由代码。
  可见工具面封顶 3 个（§1.1 光头优先）：run_elixir / done / ask。
  """

  @tools [
    %{
      type: "function",
      function: %{
        name: "run_elixir",
        description:
          "在长期存活的 Elixir 环境(DEE)中执行任意 Elixir 代码。" <>
            "变量绑定跨调用持久（像 IEx）；可调用 Newbee.Tools.Fs/Run 等工具库与任意已加载模块。" <>
            "返回值与 stdout 会被压缩回填；大结果请存入变量后续引用，或写文件后局部读取。",
        parameters: %{
          type: "object",
          properties: %{
            code: %{type: "string", description: "要执行的 Elixir 代码"},
            title: %{type: "string", description: "一句话说明这步在做什么"}
          },
          required: ["code"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "done",
        description: "声明本轮目标完成，附带给用户的总结。",
        parameters: %{
          type: "object",
          properties: %{summary: %{type: "string"}},
          required: ["summary"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "ask",
        description: "需要用户确认或澄清时调用，会暂停等待用户回答。",
        parameters: %{
          type: "object",
          properties: %{question: %{type: "string"}},
          required: ["question"]
        }
      }
    }
  ]

  def tools, do: @tools

  @doc "从 LLM 响应 message 中提取 tool_calls，统一为 %{id, name, args} 列表。"
  def extract_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn c ->
      args =
        case c["function"]["arguments"] do
          s when is_binary(s) ->
            case Jason.decode(s) do
              {:ok, m} -> m
              _ -> %{"code" => s}
            end

          m when is_map(m) ->
            m
        end

      %{id: c["id"], name: c["function"]["name"], args: args}
    end)
  end

  def extract_tool_calls(_), do: []
end


:ok