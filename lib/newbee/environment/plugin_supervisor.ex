defmodule Newbee.Environment.PluginSupervisor do
  @moduledoc """
  Plugin Runtime 监督器（DESIGN §4.5）：有状态插件的受监督生命周期 + effect 登记。

  - `DynamicSupervisor` 管有状态插件进程；
  - 启动/停止经有界任务池执行并设超时，单个插件阻塞不占住 Coordinator；
  - **Effect 登记表**：ETS、进程、pg、PubSub、Registry、外部连接必须经
    `register_effect/3` 登记；停止时按登记表回收并做 leak check；
  - 绕过 wrapper 的任意直接调用无法保证自动回收——contract 违规会令
    health gate 失败，而不是承诺无条件"零悬挂"。
  """

  use DynamicSupervisor
  require Logger

  @max_start_ms 10_000
  @max_stop_ms 10_000
  @max_concurrency 8

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    :ets.new(effect_table(), [:named_table, :public, :set])
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp effect_table, do: :newbee_plugin_effects

  # ── 有状态插件生命周期（有界 + 超时）──

  @doc "启动插件（contract 的 start/1 包装为 child spec），超时 #{@max_start_ms}ms。"
  def start_plugin(mod, context \\ %{}, supervisor \\ __MODULE__) do
    task =
      Task.async(fn ->
        DynamicSupervisor.start_child(supervisor, %{
          id: {Newbee.Plugin, mod.id()},
          start: {__MODULE__, :boot, [mod, context]},
          restart: :transient
        })
      end)

    case Task.yield(task, @max_start_ms) || Task.shutdown(task) do
      {:ok, {:ok, pid}} -> {:ok, pid}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :start_timeout}
    end
  end

  @doc false
  def boot(mod, context) do
    case mod.start(context) do
      {:ok, state} ->
        Agent.start_link(fn -> %{plugin_id: mod.id(), mod: mod, contract_state: state} end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "插件 contract state。"
  def plugin_state(pid) when is_pid(pid) do
    Agent.get(pid, & &1.contract_state)
  end

  @doc "停止插件：调 contract stop/1 → 回收登记的 effect → leak check。"
  def stop_plugin(pid, supervisor \\ __MODULE__) when is_pid(pid) do
    task =
      Task.async(fn ->
        %{plugin_id: plugin_id, mod: mod, contract_state: state} = Agent.get(pid, & &1)

        if function_exported?(mod, :stop, 1) do
          try do
            mod.stop(state)
          catch
            kind, reason ->
              Logger.warning("plugin #{plugin_id} stop raised: #{inspect({kind, reason})}")
          end
        end

        reclaim_effects(plugin_id)
        DynamicSupervisor.terminate_child(supervisor, pid)
        leaks = leak_check(plugin_id)

        if leaks != [] do
          Logger.warning("plugin #{plugin_id} leaked effects: #{inspect(leaks)}")
          {:error, {:leaked_effects, leaks}}
        else
          :ok
        end
      end)

    case Task.yield(task, @max_stop_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :stop_timeout}
    end
  end

  # ── Effect 登记表 ──

  @doc """
  登记 effect：`register_effect(plugin_id, kind, ref)`，
  kind ∈ ets | pg | pubsub | registry | process | external。
  """
  def register_effect(plugin_id, kind, ref)
      when kind in [:ets, :pg, :pubsub, :registry, :process, :external] do
    ensure_table()
    :ets.insert(effect_table(), {{plugin_id, kind, inspect(ref)}, %{kind: kind, ref: ref, at: now_iso()}})
    :ok
  end

  @doc "撤销登记（插件主动回收后调用）。"
  def unregister_effect(plugin_id, kind, ref) do
    ensure_table()
    :ets.delete(effect_table(), {plugin_id, kind, inspect(ref)})
    :ok
  end

  @doc "插件登记的全部 effect。"
  def effects(plugin_id) do
    ensure_table()

    :ets.match_object(effect_table(), {{plugin_id, :_, :_}, :_})
    |> Enum.map(fn {_key, meta} -> meta end)
  end

  @doc "按登记表回收 effect（尽力而为：ETS 删除、进程退出、其余标记）。"
  def reclaim_effects(plugin_id) do
    for %{kind: kind, ref: ref} <- effects(plugin_id) do
      reclaim(kind, ref)
    end

    :ok
  end

  defp reclaim(:ets, tid) do
    if is_reference(tid) or is_atom(tid) do
      try do
        :ets.delete(tid)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  defp reclaim(:process, pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp reclaim(_kind, _ref), do: :ok

  @doc "leak check：回收后仍登记的 effect（应由 reclaim 清空）。"
  def leak_check(plugin_id) do
    remaining = effects(plugin_id)

    # reclaim 已处理的从表中移除；剩下的是"无法自动回收"的真泄漏
    Enum.each(remaining, fn %{kind: kind, ref: ref} ->
      unregister_effect(plugin_id, kind, ref)
    end)

    Enum.filter(remaining, fn %{kind: kind} -> kind not in [:ets, :process] end)
  end

  def which_children(sup \\ __MODULE__), do: DynamicSupervisor.which_children(sup)

  defp ensure_table do
    case :ets.whereis(effect_table()) do
      :undefined -> :ets.new(effect_table(), [:named_table, :public, :set])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # 有界并发：插件启动/停止批处理入口
  @doc "批量启动（有界并发 #{@max_concurrency}）。"
  def start_all(mods, context \\ %{}, supervisor \\ __MODULE__) do
    mods
    |> Task.async_stream(&start_plugin(&1, context, supervisor),
      max_concurrency: @max_concurrency,
      timeout: @max_start_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(mods)
    |> Map.new(fn {result, mod} -> {mod.id(), result} end)
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
