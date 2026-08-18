defmodule Newbee.DEE.Evaluator do
  @moduledoc """
  求值器 (DESIGN §3.3/§3.4)：模型代码运行在**独立 BEAM 节点**（:peer 启动，同机分布式），
  主进程一对一监督：崩溃只杀节点，自动重启、当前调用重试一次；TUI/会话不受影响。

  **双节点冗余**：同时持有 primary + standby 两个 peer 节点。primary 死亡时
  立即切 standby（零等待），并异步补一个新 standby；standby 死亡也异步补位。
  节点启动失败不设上限——每次用随机新名字重建（"拉不来就生成一个新的"），
  由调用方冷却防抖，绝不永久 unavailable。

  - 绑定持久：存于求值器节点内的 EvalWorker，跨轮存活（节点切换后丢失，可接受）
  - env 过滤：节点启动后剥离 LLM 凭证（denylist 后缀/前缀）
  - reset 语义 = 重置 worker（或重建节点）
  - mode: :node（默认）| :local（调试/测试用本 VM）
  """
  use GenServer
  require Logger

  defstruct mode: :node,
            # primary（保持兼容旧字段名）
            peer: nil,
            node: nil,
            worker: nil,
            # standby：%{peer, node, worker} | nil
            standby: nil,
            restarts: 0,
            boot_error: nil,
            last_boot_attempt: nil

  @env_deny_prefixes ~w(OPENROUTER_ DEEPSEEK_ ANTHROPIC_ OPENAI_)
  @env_deny_suffixes ~w(_KEY _TOKEN _SECRET)

  # peer 启动包含新 BEAM + Elixir application 冷启动，不能使用默认短窗口。
  @peer_boot_timeout 60_000
  @rpc_boot_timeout 60_000
  @reboot_cooldown 5_000

  # ── API ──

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  def start(opts), do: GenServer.start(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "执行一段 Elixir 代码。binding 持久；节点崩溃自动切 standby，无可用节点时重建。"
  def eval(server, code, opts \\ []) do
    GenServer.call(server, {:eval, code, opts}, :infinity)
  end

  def bindings_summary(server \\ __MODULE__), do: GenServer.call(server, :bindings_summary)
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)
  def dump_bindings(server \\ __MODULE__), do: GenServer.call(server, :dump_bindings)
  def restore_bindings(server \\ __MODULE__, binding), do: GenServer.call(server, {:restore_bindings, binding})

  @doc "节点信息（给 /dump 用）"
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  # ── init ──

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :node)
    if mode == :node, do: Process.flag(:trap_exit, true)

    state =
      case mode do
        :local ->
          {:ok, worker} = Newbee.DEE.EvalWorker.start_link()
          %__MODULE__{mode: :local, worker: worker}

        :node ->
          case boot_node(%__MODULE__{mode: :node}) do
            {:ok, s} -> s
            {:error, reason} ->
              Logger.error("evaluator node 初始启动失败: #{inspect(reason)}")
              %__MODULE__{mode: :node, boot_error: reason}
          end
      end

    # 异步补 standby（不阻塞 init）
    if state.mode == :node, do: send(self(), :ensure_standby)
    {:ok, state}
  end

  # ── calls ──

  @impl true
  def handle_call({:eval, code, opts}, _from, state) do
    t0 = System.monotonic_time(:millisecond)
    Newbee.DebugLog.log(:eval, "start code=#{String.slice(code, 0, 120) |> inspect()}")

    result =
      case remote_call(primary_target(state), {:eval, code, opts}) do
        {:ok, result} ->
          {:reply, result, state}

        :dead ->
          Newbee.DebugLog.log(:eval, "primary dead, trying standby")

          case remote_call(state.standby, {:eval, code, opts}) do
            {:ok, result} ->
              # standby 顶替 primary，异步补新 standby
              s = promote_standby(state)
              send(self(), :ensure_standby)
              {:reply, Map.put(result, :node_restarted, true), s}

            :dead ->
              # 双死：冷却防抖重建
              Newbee.DebugLog.log(:eval, "standby also dead, full reboot")
              s = maybe_reboot(state)

              case remote_call(primary_target(s), {:eval, code, opts}) do
                {:ok, result} -> {:reply, Map.put(result, :node_restarted, true), s}

                :dead ->
                  {:reply,
                   %{status: :error, error: "evaluator node unavailable (restarts=#{s.restarts} boot_error=#{inspect(s.boot_error)})", output: ""},
                   s}
              end
          end
      end

    Newbee.DebugLog.log(:eval, "done in #{System.monotonic_time(:millisecond) - t0}ms")
    result
  end

  def handle_call(:bindings_summary, _from, state) do
    case remote_call(state, :bindings_summary) do
      {:ok, summary} ->
        {:reply, summary, state}

      :dead ->
        case remote_call(state.standby, :bindings_summary) do
          {:ok, summary} -> {:reply, summary, promote_standby(state)}
          :dead -> {:reply, [], state}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    state =
      case state.mode do
        :local ->
          GenServer.stop(state.worker)
          {:ok, w} = Newbee.DEE.EvalWorker.start_link()
          %{state | worker: w}

        :node ->
          stopped = stop_all(state)

          case boot_node(stopped) do
            {:ok, next} ->
              send(self(), :ensure_standby)
              next

            {:error, reason} ->
              %{stopped | boot_error: reason}
          end
      end

    {:reply, :ok, state}
  end

  def handle_call(:dump_bindings, _from, state) do
    case remote_call(state, :dump_bindings) do
      {:ok, binding} -> {:reply, binding, state}
      :dead -> {:reply, [], state}
    end
  end

  def handle_call({:restore_bindings, binding}, _from, state) do
    case remote_call(state, {:restore_bindings, binding}) do
      {:ok, res} -> {:reply, res, state}
      :dead -> {:reply, {:error, :node_down}, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       mode: state.mode,
       node: state.node,
       peer: state.peer,
       restarts: state.restarts,
       alive: alive?(state),
       standby: standby_info(state),
       boot_error: state.boot_error
     }, state}
  end

  # ── info ──

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      # primary 死
      state.worker != nil and pid == state.peer ->
        Newbee.DebugLog.log(:node, "primary exited reason=#{inspect(reason)} node=#{inspect(state.node)} restarts=#{state.restarts}")
        Logger.warning("evaluator primary node exited; switching to standby if available")

        if state.standby do
          s = promote_standby(state)
          send(self(), :ensure_standby)
          {:noreply, s}
        else
          {:noreply, %{state | peer: nil, node: nil, worker: nil}}
        end

      # standby 死
      state.standby != nil and pid == state.standby.peer ->
        Newbee.DebugLog.log(:node, "standby exited reason=#{inspect(reason)}; replenishing")
        send(self(), :ensure_standby)
        {:noreply, %{state | standby: nil}}

      true ->
        {:noreply, state}
    end
  end

  # 异步补 standby：boot 一个全新节点（每次随机新名字）
  def handle_info(:ensure_standby, state) do
    if state.mode == :node and state.standby == nil do
      case boot_node(%{state | peer: nil, node: nil, worker: nil, standby: nil, last_boot_attempt: System.monotonic_time(:millisecond)}) do
        {:ok, s} ->
          Newbee.DebugLog.log(:node, "standby up node=#{s.node}")
          {:noreply, %{state | standby: %{peer: s.peer, node: s.node, worker: s.worker}}}

        {:error, reason} ->
          Newbee.DebugLog.log(:node, "standby boot failed #{inspect(reason)}; retry in #{@reboot_cooldown}ms")
          Process.send_after(self(), :ensure_standby, @reboot_cooldown)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.mode == :node, do: stop_all(state)
    :ok
  end

  # ── boot ──


  # 启动失败返回 {:error, reason}，绝不抛异常：抛异常会触发 supervisor
  # 无限重启循环（one_for_one），CPU 打满且 eval call 永久挂起（实际事故）。
  # 不设硬性重启上限：每次用随机新名字重建（"拉不来就生成一个新的"）。
  defp boot_node(state) do
    try do
      ensure_distribution!()
      name = unique_peer_name()
      pa_args = [~c"-noshell", ~c"-noinput" | Enum.flat_map(:code.get_path(), &[~c"-pa", &1])]

      # detached: false —— peer 必须自带独立 user 进程。
      # 默认 detached: true 时 peer 的 standard_io 是 relay，io 请求转发给
      # origin 进程的 group leader；若 origin 是 DEE cell（GL 为 StringIO），
      # elixir 启动时 io:setopts(standard_io, [binary]) 会得到 {error, :enotsup}
      # 导致 elixir application 启动失败（实际事故：在 DEE 里跑 mix test /
      # 嵌套起 evaluator 全部 unavailable）。
      case :peer.start_link(%{name: name, args: pa_args, wait_boot: @peer_boot_timeout, detached: false}) do
        {:ok, peer, node} ->
          Newbee.DebugLog.log(:boot, "peer up node=#{node}")

          case :rpc.call(node, :application, :ensure_all_started, [:elixir], @rpc_boot_timeout) do
            {:ok, _} ->
              filter_env(node)

              case :rpc.call(node, Newbee.DEE.EvalWorker, :start, [[]], @rpc_boot_timeout) do
                {:ok, worker} ->
                  Newbee.DebugLog.log(:boot, "worker up #{inspect(worker)}")
                  Newbee.DEE.Tools.HotLoader.load_into_node(node)
                  {:ok, %{state | peer: peer, node: node, worker: worker, restarts: 0, boot_error: nil}}

                bad ->
                  Newbee.DebugLog.log(:boot, "worker failed #{inspect(bad)}")
                  stop_peer(peer)
                  {:error, {:worker, bad}}
              end

            bad ->
              Newbee.DebugLog.log(:boot, "elixir ensure failed #{inspect(bad)}")
              stop_peer(peer)
              {:error, {:boot, bad}}
          end

        bad ->
          Newbee.DebugLog.log(:boot, "peer.start_link failed #{inspect(bad)}")
          {:error, {:peer, bad}}
      end
    rescue
      e ->
        Newbee.DebugLog.log(:boot, "raised #{inspect(e)}")
        {:error, {:exception, e}}
    catch
      kind, reason ->
        Newbee.DebugLog.log(:boot, "caught #{kind} #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  defp stop_peer(peer) do
    try do
      :peer.stop(peer)
    catch
      _, _ -> :ok
    end
  end

  # 冷却期防抖的全量重建（主备都死时）：boot 失败进入 5s 冷却，冷却后再试。
  defp maybe_reboot(%{mode: :node} = state) do
    now = System.monotonic_time(:millisecond)

    if state.last_boot_attempt && now - state.last_boot_attempt < @reboot_cooldown do
      Newbee.DebugLog.log(:node, "boot cooldown active, skip reboot")
      state
    else
      stopped = stop_all(state)

      case boot_node(%{stopped | restarts: stopped.restarts + 1, last_boot_attempt: now}) do
        {:ok, s} ->
          send(self(), :ensure_standby)
          s

        {:error, reason} ->
          Newbee.DebugLog.log(:node, "boot failed #{inspect(reason)} restarts=#{stopped.restarts + 1}")
          %{stopped | restarts: stopped.restarts + 1, boot_error: reason, last_boot_attempt: now}
      end
    end
  end

  # 停主 + 备
  defp stop_all(state) do
    if state.standby do
      stop_peer(state.standby.peer)
    end

    stop_node(state)
  end

  defp stop_node(state) do
    if state.peer do
      try do
        :peer.stop(state.peer)
      catch
        _, _ -> :ok
      end
    end

    %{state | peer: nil, node: nil, worker: nil}
  end

  # standby 顶替 primary
  defp promote_standby(state) do
    %{state |
      peer: state.standby.peer,
      node: state.standby.node,
      worker: state.standby.worker,
      standby: nil,
      restarts: state.restarts + 1,
      boot_error: nil}
  end

  # ── rpc ──

  defp remote_call(%{mode: :local, worker: w}, msg), do: {:ok, GenServer.call(w, msg, :infinity)}

  defp remote_call(nil, _msg) do
    Newbee.DebugLog.log(:rpc, "worker nil (node down)")
    :dead
  end

  defp remote_call(%{node: node, worker: w}, msg) when is_pid(w) do
    # rpc.call 默认 5s 超时：模型死循环/节点卡住时由此兜底，切 standby/reboot
    case :rpc.call(node, GenServer, :call, [w, msg, :infinity], 10_000) do
      {:badrpc, reason} ->
        Newbee.DebugLog.log(:rpc, "badrpc #{inspect(reason)} msg=#{elem(msg, 0)}")
        :dead

      other ->
        {:ok, other}
    end
  end

  defp alive?(state) do
    state.mode == :local or
      (state.node != nil and :rpc.call(state.node, :erlang, :is_alive, []) == true)
  end

  defp standby_info(state) do
    case state.standby do
      nil -> nil
      %{node: node} -> %{node: node, alive: :rpc.call(node, :erlang, :is_alive, []) == true}
    end
  end

  # ── env ──

  defp ensure_distribution! do
    unless Node.alive?() do
      name = String.to_atom("newbee_#{:crypto.strong_rand_bytes(8) |> Base.encode32(case: :lower, padding: false)}")
      {:ok, _} = :net_kernel.start([name, :shortnames])
    end

    :ok
  end

  defp unique_peer_name do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode32(case: :lower, padding: false)
    String.to_atom("newbee_eval_#{suffix}")
  end

  defp filter_env(node) do
    :rpc.call(node, __MODULE__, :__filter_env__, [@env_deny_prefixes, @env_deny_suffixes])
  end

  @doc false
  def __filter_env__(prefixes, suffixes) do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(fn k ->
      Enum.any?(prefixes, &String.starts_with?(k, &1)) or
        Enum.any?(suffixes, &String.ends_with?(k, &1))
    end)
    |> Enum.each(&:os.unsetenv(String.to_charlist(&1)))
  end
end
