defmodule Newbee.DEE.Rules do
  @moduledoc """
  沉睡规则 (DESIGN §4.5) ⭐：环境的免疫系统。

  规则平时沉睡、不占 context；kernel 在每个 run_elixir 代码提交前调用
  `check/1`——命中即中断工具执行、把规则作为 system reminder 注入。
  "平时零成本、犯病才出现"：教训编译成规则而非 prompt 文本。

  持久化：~/.newbee/rules.json。重启后重新载入。
  """

  use GenServer

  @path Path.join(System.user_home!(), ".newbee/rules.json")

  defstruct rules: []

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "注册一条规则（同 id 覆盖）。opts: source（:evolver | :user | :auto）。"
  def add(id, pattern, injection, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:add, %{id: to_string(id), pattern: pattern, injection: injection, source: Keyword.get(opts, :source, :user)}}
    )
  end

  @doc "检查代码是否命中规则。返回命中列表（按注册序）。"
  def check(code) when is_binary(code) do
    GenServer.call(__MODULE__, {:check, code})
  end

  @doc "全部规则。"
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "删除规则。"
  def remove(id) do
    GenServer.call(__MODULE__, {:remove, to_string(id)})
  end

  @impl true
  def init(_) do
    {:ok, %__MODULE__{rules: load()}}
  end

  @impl true
  def handle_call({:add, rule}, _from, state) do
    rules = Enum.reject(state.rules, &(&1.id == rule.id)) ++ [rule]
    state = %{state | rules: rules}
    persist(state.rules)
    {:reply, :ok, state}
  end

  def handle_call({:check, code}, _from, state) do
    hits =
      Enum.filter(state.rules, fn rule ->
        case Regex.compile(rule.pattern) do
          {:ok, re} -> Regex.match?(re, code)
          {:error, _} -> false
        end
      end)

    {:reply, hits, state}
  end

  def handle_call(:list, _from, state), do: {:reply, state.rules, state}

  def handle_call({:remove, id}, _from, state) do
    rules = Enum.reject(state.rules, &(&1.id == id))
    state = %{state | rules: rules}
    persist(state.rules)
    {:reply, :ok, state}
  end

  defp persist(rules) do
    File.mkdir_p!(Path.dirname(@path))
    File.write!(@path, Jason.encode_to_iodata!(rules))
    :ok
  end

  defp load do
    case File.read(@path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, rules} when is_list(rules) ->
            Enum.map(rules, fn r ->
              %{
                id: r["id"],
                pattern: r["pattern"],
                injection: r["injection"],
                source: (r["source"] || "user") |> String.to_atom()
              }
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
