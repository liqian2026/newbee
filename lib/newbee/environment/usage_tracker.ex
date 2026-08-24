defmodule Newbee.Environment.UsageTracker do
  @moduledoc """
  Runtime attribution for active plugin releases.

  A usage is recorded against the release that was active when the operation ran.
  Tracking is best-effort and must never affect the worker execution path.
  """

  alias Newbee.Environment.{Coordinator, Fitness}

  # 只匹配大写开头的模块段：Newbee.Tools.Fs.read! 应归因 tool.fs，
  # 而非把 .read 当作模块名的一部分
  @module_pattern ~r/Newbee\.(?:Tools|Plugins)\.[A-Z]\w*(?:\.[A-Z]\w*)*/

  @doc "Record one use for every active builtin plugin referenced by an Elixir cell."
  def observe_code(code, attrs \\ %{}) when is_binary(code) do
    code
    |> referenced_plugin_ids()
    |> Enum.each(&observe_plugin(&1, attrs))

    :ok
  end

  @doc "Record one use of a logical plugin against its currently active release."
  def observe_plugin(plugin_id, attrs \\ %{}) when is_binary(plugin_id) do
    with {:ok, release_id} <- active_release(plugin_id) do
      Fitness.observe(release_id, %{
        success: Map.get(attrs, :success, true),
        latency_ms: Map.get(attrs, :latency_ms, 0),
        tokens: Map.get(attrs, :tokens, 0),
        output_bytes: Map.get(attrs, :output_bytes, 0),
        model: Map.get(attrs, :model, "runtime"),
        task_type: Map.get(attrs, :task_type, plugin_id)
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Record actual sleeping-rule hits."
  def observe_rules(hits) when is_list(hits) do
    active = active_map()

    Enum.each(hits, fn hit ->
      id = to_string(Map.get(hit, :id) || Map.get(hit, "id") || "")
      plugin_id = rule_plugin_id(id, active)
      if plugin_id, do: observe_plugin(plugin_id, %{task_type: "rule_hit"})
    end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp referenced_plugin_ids(code) do
    @module_pattern
    |> Regex.scan(code)
    |> Enum.map(&hd/1)
    |> Enum.map(&Module.concat([&1]))
    |> Enum.map(&Newbee.Plugins.plugin_id_for/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp active_release(plugin_id) do
    case Map.fetch(active_map(), plugin_id) do
      {:ok, release_id} -> {:ok, release_id}
      :error -> :error
    end
  end

  defp active_map do
    if Process.whereis(Coordinator) do
      Coordinator.current(Coordinator).active || %{}
    else
      %{}
    end
  end

  defp rule_plugin_id(id, active) do
    [id, "rule." <> id]
    |> Enum.find(&Map.has_key?(active, &1))
  end
end
