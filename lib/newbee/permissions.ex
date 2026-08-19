defmodule Newbee.Permissions do
  @moduledoc """
  权限档位 (DESIGN §8)：`lenient`（默认，放行+审计）/ `ask`（危险操作询问用户）/
  `deny`（危险操作直接拒绝）。持久化 `~/.newbee/config.json` 的 "permissions" 键。

  危险操作 = 写文件/删除/shell 命令/端口/外部进程（regex 静态检测——宽松档位的
  务实实现：约束推荐 API 与明显危险调用，run_elixir 任意代码无法静态穷尽，
  硬隔离仍靠审计 + 快照回滚兜底）。
  """

  @levels [:lenient, :ask, :deny]
  @default :lenient
  @config Path.join(System.user_home!(), ".newbee/config.json")

  @risky_patterns [
    ~r/File\.(write|write!|rm|rm_rf|mkdir|cp|mv|rename|touch)/,
    ~r/Newbee\.Tools\.(Fs\.(write|write!|append!|rm|rm_rf)|Edit\.patch|Structural\.(insert|replace|format))/,
    ~r/System\.cmd|Port\.open|:os\.cmd/,
    ~r/Newbee\.Tools\.Run\.sh/,
    ~r/HotLoader\.publish/,
    ~r/mix (test|compile|deps|format)|git (push|reset|rebase|clean|checkout|commit)/
  ]

  @doc "合法档位列表。"
  def levels, do: @levels

  @doc "当前档位（默认 :lenient）。"
  def get do
    case File.read(@config) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"permissions" => p}} when p in ~w(lenient ask deny) -> String.to_atom(p)
          {:ok, %{"permissions" => p}} when p in @levels -> p
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

    File.write!(@config, Jason.encode_to_iodata!(Map.put(config, "permissions", level)))
    :ok
  end

  def set(other), do: {:error, {:invalid_level, other}}

  @doc "代码是否含危险操作。"
  def risky?(code) when is_binary(code) do
    Enum.any?(@risky_patterns, &Regex.match?(&1, code))
  end

  @doc "执行检查：:allow | :ask | :deny。"
  def check(code) when is_binary(code) do
    case get() do
      :lenient -> :allow
      :ask -> if risky?(code), do: :ask, else: :allow
      :deny -> if risky?(code), do: :deny, else: :allow
    end
  end
end
