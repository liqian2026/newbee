defmodule Newbee.Agent.Advisor do
  @moduledoc """
  Advisor（DESIGN §7.4，可选第三角色，默认关）：只读旁观的第二模型，
  读 worker 每轮输出内联插评（concern/blocker），worker 看到后自我纠偏。
  advisor 管当下质量，adapter 管长期进化。**永不写环境。**
  """

  @doc """
  审阅一轮 worker 输出，返回 %{verdict: :ok | :concern | :blocker, notes: [...]}。
  client_fun 可注入；无客户端时返回 :ok（advisor 是增强不是门槛）。
  """
  def review(step_output, opts \\ []) do
    client_fun = Keyword.get(opts, :client_fun)

    if client_fun do
      prompt = """
      你是 newbee 的 advisor（只读旁观者）。审阅 worker 的这一步输出。
      只在有实质问题时插评。输出 JSON：{"verdict":"ok|concern|blocker","notes":["..."]}
      输出：#{String.slice(to_string(step_output), 0, 4_000)}
      """

      case client_fun.([%{"role" => "user", "content" => prompt}]) do
        {:ok, content} -> parse(content)
        {:error, _} -> %{verdict: :ok, notes: []}
      end
    else
      %{verdict: :ok, notes: []}
    end
  rescue
    _ -> %{verdict: :ok, notes: []}
  end

  defp parse(content) do
    content
    |> String.split(~r/```[a-z]*/, trim: true)
    |> Enum.find_value(fn chunk ->
      case Jason.decode(String.trim(chunk)) do
        {:ok, %{"verdict" => v} = m} when v in ["ok", "concern", "blocker"] ->
          %{verdict: String.to_atom(v), notes: m["notes"] || []}

        _ ->
          nil
      end
    end)
    |> case do
      nil -> %{verdict: :ok, notes: []}
      parsed -> parsed
    end
  end
end
