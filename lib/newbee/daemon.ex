defmodule Newbee.Daemon do
  @moduledoc """
  常驻 daemon (DESIGN §3.8) ⭐：环境是常驻生命体，TUI 只是探视窗。

  - 订阅事件总线，后台记录环境活动；
  - 定时触发 adapter（heartbeat）：need 消息 + JIT 热度 → 合成候选 →
    Verifier 门 → 按 Autonomy 档位经 Coordinator 激活（无旁路）；
  - 关掉 TUI 只是 detach，环境继续存活、记忆、进化；
  - `newbee attach` 随时接回。
  """

  use GenServer
  require Logger

  @evolve_interval :timer.minutes(10)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "立即触发一轮 adapter 进化（/evolve 也走这里）。"
  def evolve_now do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :evolve_now)
    else
      spawn(fn -> run_adapter_cycle() end)
    end

    :ok
  end

  @impl true
  def init(_) do
    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.subscribe()
    end

    Process.send_after(self(), :evolve_tick, @evolve_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:evolve_now, state) do
    run_adapter_cycle()
    {:noreply, state}
  end

  @impl true
  def handle_info(:evolve_tick, state) do
    run_adapter_cycle()
    Process.send_after(self(), :evolve_tick, @evolve_interval)
    {:noreply, state}
  end

  def handle_info({:newbee_event, topic, event}, state) do
    # 审计/进化事件记日志（EventLog 已落盘；这里只打 Logger）
    if topic in [:change_activated, :change_rejected, :change_rolled_back, :revision_advanced, :revision_degraded] do
      Logger.info("daemon event #{topic}: #{inspect(event, limit: 4)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_adapter_cycle do
    case Newbee.Agent.Adapter.run_once() do
      {:skipped, reason} ->
        Logger.info("adapter skipped: #{reason}")

      {:suggested, proposals} ->
        # 档位 observe：只产出建议，不激活
        Logger.info("adapter suggestions (#{length(proposals)}): #{inspect(proposals, limit: 3)}")

      {:processed, results} ->
        Logger.info("adapter cycle: #{inspect(results, limit: 6)}")

      other ->
        Logger.warning("adapter cycle: #{inspect(other)}")
    end
  rescue
    error ->
      Logger.error("adapter cycle crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      :error
  catch
    kind, reason ->
      Logger.error("adapter cycle halted: #{inspect({kind, reason})}")
      :error
  end

  @doc """
  `mix newbee daemon` 入口：确保 Daemon GenServer 在跑（监督树已带则复用，
  否则自行 start_link 拉起，不绕过 GenServer），随后常驻阻塞（Ctrl-C 退出）。
  """
  def start do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end

    IO.puts("newbee daemon: 常驻中（每 #{div(@evolve_interval, 60_000)} 分钟检查一次进化线索）")
    IO.puts("Ctrl-C 退出。环境与记忆继续保留在项目 .newbee/")
    Process.sleep(:infinity)
  end
end
