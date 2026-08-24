defmodule Newbee.LLM.Config do
  @moduledoc """
  模型配置 (model.json)。schema 学习 prime-agent 的 models.json：

      {
        "providers": { "<name>": { "baseUrl", "api", "apiKey", "models": [...] } },
        "roles":     { "<role>": { "provider": "<name>", "model": "<id>" } }
      }

  - apiKey 支持 `"${ENV_VAR}"` 环境变量展开、`"${prime:NAME}"` 从 ~/.prime/agent/auth.json 取 key，密钥不必落盘。
  - roles 对应 DESIGN §3.8 的模型角色路由（default/worker/adapter/explorer...）。
  - 解析顺序：$NEWBEE_MODEL_JSON → ./model.json → ./model.local.json → ~/.newbee/model.json。
  """

  @roles ["default", "worker", "adapter", "explorer", "plan", "advisor", "verifier"]

  def roles, do: @roles

  @doc "加载配置；找不到文件时回退到内置默认（OpenRouter + env key）。"
  def load do
    case resolve_path() do
      nil -> default()
      path -> parse(path)
    end
  end

  @doc "按角色构建 Client。"
  def client_for(role \\ "default", opts \\ []) do
    cfg = load()
    role_cfg = get_in(cfg, ["roles", role]) || get_in(cfg, ["roles", "default"])
    provider_name = Keyword.get(opts, :provider, role_cfg["provider"])
    model = Keyword.get(opts, :model, role_cfg["model"])
    provider = cfg["providers"][provider_name]

    unless provider, do: raise("model.json: 未知 provider #{inspect(provider_name)}")

    Newbee.LLM.Client.new(
      base_url: provider["baseUrl"],
      model: model,
      api_key: expand_env(provider["apiKey"]),
      reasoning_effort: role_cfg["reasoningEffort"],
      context_window: role_cfg["contextWindow"] || provider["contextWindow"],
      vision: Map.get(role_cfg, "vision", Map.get(provider, "vision", true))
    )
  end

  @doc "WebUI 模型目录：按厂家分组的完整列表 + 当前默认（provider/model）。"
  def model_catalog(opts \\ []) do
    cfg = load()
    providers_cfg = for {name, p} <- cfg["providers"] || %{}, is_map(p), do: {name, p}

    providers =
      providers_cfg
      |> Task.async_stream(
        fn {name, p} ->
          %{name: name, models: provider_models(name, p, opts)}
        end,
        max_concurrency: 8,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> %{name: "unknown", models: []}
      end)

    default = get_in(cfg, ["roles", "default"]) || %{}
    %{providers: providers, current: %{provider: default["provider"], model: default["model"]}}
  end


  @doc """
  切换默认模型（/model <id>）：
    * "provider/model-id" —— 首段须是已配置 provider 名，其余整体为模型 id
      （如 openrouter/deepseek/deepseek-v4-flash-0731 → provider=openrouter，
      model=deepseek/deepseek-v4-flash-0731）
    * "model-id"（不含斜杠）—— 保留当前 provider，只改型号
  首段不是已知 provider 时报错拒绝，绝不把带前缀的 id 写进 roles.default.model。
  落盘到当前生效的配置文件（找不到则创建 ~/.newbee/model.json）。
  """
  def set_default_model(model_id) do
    id = if is_binary(model_id), do: String.trim(model_id), else: ""
    cfg = load()

    case split_model_id(id, cfg) do
      {:error, _reason} = err ->
        err

      {provider_name, model} ->
        default = get_in(cfg, ["roles", "default"]) || %{"provider" => provider_name}
        default = default |> Map.put("provider", provider_name) |> Map.put("model", model)
        cfg = put_in(cfg, ["roles", "default"], default)

        target =
          Enum.find(
            [
              System.get_env("NEWBEE_MODEL_JSON"),
              "model.json",
              "model.local.json",
              Path.join([System.user_home!(), ".newbee", "model.json"])
            ],
            &(&1 && File.exists?(&1))
          ) || Path.join(System.user_home!(), ".newbee/model.json")

        File.mkdir_p!(Path.dirname(target))
        File.write!(target, Jason.encode_to_iodata!(cfg, pretty: true))
        :ok
    end
  end

  # "a/b/c" → {"a", "b/c"}（a 是已知 provider）；"c" → {当前 provider, "c"}
  defp split_model_id("", _cfg), do: {:error, :bad_model_id}

  defp split_model_id(id, cfg) do
    case String.split(id, "/", parts: 2) do
      [model] ->
        {get_in(cfg, ["roles", "default", "provider"]) || "openrouter", model}

      [head, rest] ->
        if Map.has_key?(cfg["providers"] || %{}, head),
          do: {head, rest},
          else: {:error, {:unknown_provider, head}}
    end
  end

  @doc "当前配置的人类可读描述（给 /model 命令用）。"
  def describe do
    cfg = load()

    for {role, rc} <- cfg["roles"] || %{} do
      p = cfg["providers"][rc["provider"]] || %{}
      "#{role}: #{rc["provider"]}/#{rc["model"]} @ #{p["baseUrl"]}"
    end
  end

  @doc "已知型号候选（供 TUI Tab 补全）：汇总各 provider 的 models 列表 + 当前 roles 已用型号，去重排序。"
  def model_candidates do
    cfg = load()

    from_providers =
      for {_pname, p} <- cfg["providers"] || %{}, m <- p["models"] || [], is_binary(m), do: m

    from_roles =
      for {_role, rc} <- cfg["roles"] || %{}, is_binary(rc["model"]), do: rc["model"]

    (from_providers ++ from_roles)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── 模型列表自动拉取 ──

  @models_cache :newbee_llm_models_cache
  @models_ttl 300_000

  @doc """
  取某 provider 的模型列表：优先缓存（5 分钟），其次 GET {baseUrl}/models
  （OpenAI 兼容 data[].id），失败回退配置里的静态 models 列表。
  """
  def provider_models(name, provider, opts \\ []) do
    ensure_cache_table()
    key = {name, provider["baseUrl"]}
    force = Keyword.get(opts, :refresh, false)

    case :ets.lookup(@models_cache, key) do
      [{^key, ids, ts}] when not force ->
        # 有缓存、未过期且非强制：直接返回缓存
        if :erlang.monotonic_time(:millisecond) - ts < @models_ttl do
          ids
        else
          do_fetch_and_cache(name, provider, key)
        end

      _ when force ->
        # 强制刷新：同步拉取
        do_fetch_and_cache(name, provider, key)
      _ ->
        # 无缓存非强制：返回静态列表（不自动拉取）
        static_models(provider)
    end
  end

  defp do_fetch_and_cache(_name, provider, key) do
    ids = fetch_models(provider) || static_models(provider)
    :ets.insert(@models_cache, {key, ids, :erlang.monotonic_time(:millisecond)})
    ids
  end

  @doc """
  按名字取某 provider 的模型列表（供按厂商刷新）。provider 名不存在时返回 nil。
  """
  def provider_models_by_name(name, opts \\ []) do
    cfg = load()
    provider = get_in(cfg, ["providers", name])

    if is_map(provider) do
      provider_models(name, provider, opts)
    else
      nil
    end
  end

  # 从 provider 的 OpenAI 兼容 /models 接口拉取模型 id 列表
  defp fetch_models(provider) do
    base = provider["baseUrl"]
    key = expand_env(provider["apiKey"])

    if is_binary(base) and String.trim(base) != "" do
      url = String.trim_trailing(base, "/") <> "/models"

      with {:ok, %{"data" => data}} when is_list(data) <- http_get(url, key) do
        data
        |> Enum.map(fn m -> m["id"] end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> case do
          [] -> nil
          ids -> ids
        end
      else
        _ -> nil
      end
    else
      nil
    end
  end

  defp static_models(provider) do
    Enum.filter(provider["models"] || [], &is_binary/1)
  end

  defp ensure_cache_table do
    case :ets.whereis(@models_cache) do
      :undefined ->
        try do
          :ets.new(@models_cache, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  defp http_get(url, api_key) do
    headers =
      if is_binary(api_key) and api_key != "" do
        [{"authorization", "Bearer " <> api_key}]
      else
        []
      end

    case Req.get(url, headers: headers, receive_timeout: 8_000) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
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
