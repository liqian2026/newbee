defmodule Newbee.Evolution.Policy do
  @moduledoc """
  进化策略档位 (DESIGN §6.6)：控制 evolver 的激进程度。

    :off        不做任何进化
    :hint       只产出建议，用户逐个 /approve
    :background 验证通过的补丁自动热载，事后可 /undo
    :auto       全自动（含 prompt/策略层变更），仅 bench 成熟后开启

  持久化在 ~/.newbee/config.json（与模型配置同文件）。
  """

  @levels [:off, :hint, :background, :auto]
  @default :background
  @config Path.join(System.user_home!(), ".newbee/config.json")

  @doc "合法档位列表。"
  def levels, do: @levels

  @doc "当前档位（默认 :background）。"
  def get do
    case File.read(@config) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"policy" => p}} when is_binary(p) -> String.to_atom(p)
          {:ok, %{"policy" => p}} when p in @levels -> p
          _ -> @default
        end

      _ ->
        @default
    end
  end

  @doc "设置并持久化档位。返回 :ok。"
  def set(level) when level in @levels do
    File.mkdir_p!(Path.dirname(@config))

    config =
      case File.read(@config) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.write!(@config, Jason.encode_to_iodata!(Map.put(config, "policy", level)))
    :ok
  end

  def set(other), do: {:error, {:invalid_level, other}}
end
