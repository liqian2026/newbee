defmodule Newbee.Environment.Revision do
  @moduledoc """
  Environment Revision (DESIGN §3.1)：active release 图的一份快照。

  `revision` 单调递增；任何 active 变化产生新 revision；
  **回退 = 移动 active 指针到历史 revision**，历史永不删除。

  revision 内容 = `%{plugin_id => release_id}` 全图——回退是 release graph
  级操作（§8.4），不是单插件指针移动。
  """

  defstruct rev: 0,
            active: %{},
            change_id: nil,
            created_at: nil,
            health: :unknown

  @type t :: %__MODULE__{}

  def new(rev, active, change_id \\ nil) when is_integer(rev) and is_map(active) do
    %__MODULE__{
      rev: rev,
      active: active,
      change_id: change_id,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      health: :unknown
    }
  end

  def mark_health(%__MODULE__{} = r, health) when health in [:healthy, :degraded] do
    %{r | health: health}
  end

  def to_map(%__MODULE__{} = r) do
    %{
      "rev" => r.rev,
      "active" => r.active,
      "change_id" => r.change_id,
      "created_at" => r.created_at,
      "health" => to_string(r.health)
    }
  end

  def from_map(m) when is_map(m) do
    %__MODULE__{
      rev: m["rev"] || 0,
      active: m["active"] || %{},
      change_id: m["change_id"],
      created_at: m["created_at"],
      health: String.to_atom(m["health"] || "unknown")
    }
  end
end
