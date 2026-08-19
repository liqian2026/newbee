defmodule Newbee.Tools.Json do
  @moduledoc """
  JSON 处理工具 (DESIGN §3.2 工具库)：解码/编码/美化/路径提取。
  路径语法：`a.b[0].c`（点分 + 数组下标），模型常用它从 API 响应抠字段。
  """

  @doc "解析 JSON 字符串。返回 {:ok, value} | {:error, reason}。"
  def decode(text) when is_binary(text), do: Jason.decode(text)

  @doc "编码为 JSON 字符串（美化可选）。"
  def encode(value, pretty \\ false) do
    if pretty, do: Jason.encode!(value, pretty: true), else: Jason.encode!(value)
  rescue
    _ -> {:error, :encode_failed}
  end

  @doc "按路径从 JSON 取值：Json.get!(resp, \"data.items[0].name\")。"
  def get!(value, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn seg, acc ->
      case Regex.run(~r/^(.+?)\[(\d+)\]$/, seg) do
        [_, key, idx] ->
          case Map.get(acc, key) do
            list when is_list(list) -> Enum.at(list, String.to_integer(idx))
            _ -> nil
          end

        _ ->
          Map.get(acc, seg)
      end
    end)
  end

  @doc "按路径取值（不抛错）。返回 {:ok, v} | :error。"
  def get(value, path) do
    {:ok, get!(value, path)}
  rescue
    _ -> :error
  end
end
