defmodule Newbee.HotReloader do
  @moduledoc """
  自动热载 newbee 自身的已编译 BEAM。

  监控应用 ebin 目录的内容哈希；编译产物变化后先 soft purge 旧版本，
  再 load_binary 新版本。仍有进程执行旧代码时不会硬 purge，而是在后续
  扫描中重试，避免为了热载杀掉活动会话。
  """

  use GenServer
  require Logger

  @default_interval 1_000

  defstruct dirs: [], fingerprints: %{}, interval: @default_interval, timer: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "立即扫描一次（诊断和测试用）。"
  def scan_now(server \\ __MODULE__), do: GenServer.call(server, :scan, 30_000)

  @doc "安全加载一个 BEAM 文件。"
  def reload_file(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, module} <- beam_module(path),
         true <- :code.soft_purge(module),
         {:module, ^module} <- :code.load_binary(module, String.to_charlist(path), binary) do
      {:ok, module}
    else
      false -> {:error, :old_code_in_use}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:load_failed, other}}
    end
  rescue
    error -> {:error, {:exception, error}}
  end

  @impl true
  def init(opts) do
    dirs = Keyword.get(opts, :dirs, default_dirs())
    interval = Keyword.get(opts, :interval, @default_interval)
    fingerprints = fingerprints(dirs)
    {:ok, schedule(%__MODULE__{dirs: dirs, fingerprints: fingerprints, interval: interval})}
  end

  @impl true
  def handle_call(:scan, _from, state) do
    {state, results} = scan(state)
    {:reply, results, state}
  end

  @impl true
  def handle_info(:scan, state) do
    {state, _results} = scan(%{state | timer: nil})
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp scan(state) do
    current = fingerprints(state.dirs)

    changed =
      current
      |> Enum.filter(fn {path, fingerprint} -> state.fingerprints[path] != fingerprint end)
      |> Enum.sort_by(&elem(&1, 0))

    {fingerprints, results} =
      Enum.reduce(changed, {state.fingerprints, []}, fn {path, fingerprint}, {known, results} ->
        case reload_file(path) do
          {:ok, module} = result ->
            Logger.info("hot reloaded #{inspect(module)} from #{path}")
            Newbee.Events.emit(:hot_reload, {:hot_reload, module, path})
            {Map.put(known, path, fingerprint), [result | results]}

          {:error, reason} = result ->
            Logger.warning("hot reload deferred #{path}: #{inspect(reason)}")
            {known, [result | results]}
        end
      end)

    # 删除的 BEAM 不主动 purge：运行中的模块可能仍被会话使用。
    fingerprints = Map.take(fingerprints, Map.keys(current))
    {%{state | fingerprints: fingerprints}, Enum.reverse(results)}
  end

  defp fingerprints(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, binary} -> Map.put(acc, path, :crypto.hash(:sha256, binary))
        {:error, _} -> acc
      end
    end)
  end

  defp beam_module(path) do
    case :beam_lib.info(String.to_charlist(path))[:module] do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  defp default_dirs do
    [Application.app_dir(:newbee, "ebin")]
  rescue
    _ -> []
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :scan, state.interval)}
  end
end
