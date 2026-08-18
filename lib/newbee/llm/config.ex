defmodule Newbee.LLM.Config do
  @moduledoc """
  模型配置 (model.json)。schema 学习 prime-agent 的 models.json：

      {
        "providers": { "<name>": { "baseUrl", "api", "apiKey", "models": [...] } },
        "roles":     { "<role>": { "provider": "<name>", "model": "<id>" } }
      }

  - apiKey 支持 `"${ENV_VAR}"` 环境变量展开、`"${prime:NAME}"` 从 ~/.prime/agent/auth.json 取 key，密钥不必落盘。
  - roles 对应 DESIGN §3.8 的模型角色路由（default/worker/evolver/explorer...）。
  - 解析顺序：$NEWBEE_MODEL_JSON → ./model.json → ./model.local.json → ~/.newbee/model.json。
  """

  @roles ["default", "worker", "evolver", "explorer", "plan", "advisor", "verifier"]

  def roles, do: @roles

  @doc "加载配置；找不到文件时回退到内置默认（OpenRouter + env key）。"
  def load do
    case resolve_path() do
      nil -> default()
      path -> parse(path)
    end
  end

  @doc "按角色构建 Client。"
  def client_for(role \\ "default") do
    cfg = load()
    role_cfg = get_in(cfg, ["roles", role]) || get_in(cfg, ["roles", "default"])
    provider_name = role_cfg["provider"]
    provider = cfg["providers"][provider_name]

    unless provider, do: raise("model.json: 未知 provider #{inspect(provider_name)}")

    Newbee.LLM.Client.new(
      base_url: provider["baseUrl"],
      model: role_cfg["model"],
      api_key: expand_env(provider["apiKey"]),
      reasoning_effort: role_cfg["reasoningEffort"]
    )
  end

  @doc "当前配置的人类可读描述（给 /model 命令用）。"
  def describe do
    cfg = load()

    for {role, rc} <- cfg["roles"] || %{} do
      p = cfg["providers"][rc["provider"]] || %{}
      "#{role}: #{rc["provider"]}/#{rc["model"]} @ #{p["baseUrl"]}"
    end
  end

  # ── internals ──

  defp resolve_path do
    Enum.find(
      [
        System.get_env("NEWBEE_MODEL_JSON"),
        "model.json",
        "model.local.json",
        Path.join([System.user_home!(), ".newbee", "model.json"])
      ],
      &(&1 && File.exists?(&1))
    )
  end

  defp parse(path) do
    case File.read(path) |> then(fn {:ok, b} -> Jason.decode(b) end) do
      {:ok, cfg} -> cfg
      {:error, e} -> raise "model.json 解析失败 #{path}: #{inspect(e)}"
    end
  end

  defp default do
    %{
      "providers" => %{
        "openrouter" => %{
          "baseUrl" => "https://openrouter.ai/api/v1",
          "apiKey" => "${OPENROUTER_API_KEY}",
          "models" => []
        }
      },
      "roles" => %{
        "default" => %{"provider" => "openrouter", "model" => "deepseek/deepseek-v4-flash-0731"}
      }
    }
  end

  defp expand_env(nil), do: nil

  defp expand_env("${" <> rest) do
    var = String.trim_trailing(rest, "}")

    case String.split(var, ":", parts: 2) do
      ["prime", name] -> prime_key(name)
      [env_var] -> System.get_env(env_var)
    end
  end

  defp expand_env(literal), do: literal

  defp prime_key(name) do
    path = Path.join([System.user_home!(), ".prime", "agent", "auth.json"])

    with {:ok, body} <- File.read(path),
         {:ok, auth} <- Jason.decode(body),
         %{"key" => key} <- Map.get(auth, name) do
      key
    else
      _ -> nil
    end
  end
end
