defmodule Newbee.Daemon do
  @moduledoc """
  常驻 daemon (DESIGN §3.8) ⭐：环境是常驻生命体，TUI 只是探视窗。

  - 订阅事件总线，后台记录环境活动；
  - 定时触发 evolver（heartbeat）：worker 线索 + 指标 → 合成 → bench 裁判 → 按 policy 发布；
  - 关掉 TUI 只是 detach，环境继续存活、记忆、进化。
  """

  use GenServer
  require Logger

  @evolve_interval :timer.minutes(10)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "立即触发一轮 evolver（/evolve 也走这里）。"
  def evolve_now do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :evolve_now)
    else
      spawn(fn -> run_evolver_cycle() end)
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
    run_evolver_cycle()
    {:noreply, state}
  end

  @impl true
  def handle_info(:evolve_tick, state) do
    run_evolver_cycle()
    Process.send_after(self(), :evolve_tick, @evolve_interval)
    {:noreply, state}
  end

  def handle_info({:newbee_event, topic, event}, state) do
    # 审计/进化事件记日志（EventLog 已落盘；这里只打 Logger）
    if topic in [:evolution_published, :evolution_rejected, :snapshot_created, :snapshot_restored] do
      Logger.info("daemon event #{topic}: #{inspect(event, limit: 4)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_evolver_cycle do
    case Newbee.Evolution.Evolver.run_once() do
      {:skipped, reason} ->
        Logger.info("evolver skipped: #{reason}")

      results when is_list(results) ->
        Logger.info("evolver cycle: #{inspect(results, limit: 6)}")

      other ->
        Logger.warning("evolver cycle: #{inspect(other)}")
    end
  rescue
    error ->
      Logger.error("evolver cycle crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      :error
  catch
    kind, reason ->
      Logger.error("evolver cycle halted: #{inspect({kind, reason})}")
      :error
  end

  @doc "启动 daemon（阻塞运行，Ctrl-C 退出）。"
  def start do
    IO.puts("newbee daemon: 常驻中（每 #{div(@evolve_interval, 60_000)} 分钟检查一次进化线索）")
    IO.puts("Ctrl-C 退出。环境与记忆继续保留在 ~/.newbee/")

    receive do
      _ -> :ok
    end
  end
end
