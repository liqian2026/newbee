defmodule Newbee.Environment.Release do
  @moduledoc """
  Release (DESIGN §3.3)：不可变版本。`source_hash` 不变则内容一字不动。

  实测数据**不属于** Release 本体——价签 = ReleaseObservation 事件流 +
  fitness 投影（见 Environment.Fitness），绝不写回 Release。
  """

  @kinds ~w(tool rule prompt workflow adapter provider evaluator verifier projection stateful_service)a

  defstruct release_id: nil,
            plugin_id: nil,
            kind: :tool,
            parent_release: nil,
            source_files: %{},
            source_hash: nil,
            contract_version: 1,
            dependencies: [],
            usage: "",
            capabilities: [],
            effects: [],
            state_policy: :stateless,
            replay_policy: :rerun,
            author: :system,
            change_id: nil,
            evaluation_ids: [],
            created_at: nil

  @type t :: %__MODULE__{}

  def kinds, do: @kinds

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    kind = to_atom(Map.get(attrs, :kind, :tool))

    unless kind in @kinds do
      raise ArgumentError, "invalid plugin kind: #{inspect(kind)}"
    end

    source_files = Map.get(attrs, :source_files, %{}) |> Map.new()
    # builtin release 可显式给 source_hash（如模块 md5）；否则由源码内容寻址
    src_hash = Map.get(attrs, :source_hash) || source_hash(source_files)

    release = %__MODULE__{
      plugin_id: Map.fetch!(attrs, :plugin_id) |> to_string(),
      kind: kind,
      parent_release: Map.get(attrs, :parent_release),
      source_files: source_files,
      source_hash: src_hash,
      contract_version: Map.get(attrs, :contract_version, 1),
      dependencies: Map.get(attrs, :dependencies, []),
      usage: Map.get(attrs, :usage, ""),
      capabilities: Enum.map(Map.get(attrs, :capabilities, []), &to_atom/1),
      effects: Enum.map(Map.get(attrs, :effects, []), &to_atom/1),
      state_policy: to_atom(Map.get(attrs, :state_policy, :stateless)),
      replay_policy: to_atom(Map.get(attrs, :replay_policy, :rerun)),
      author: to_atom(Map.get(attrs, :author, :system)),
      change_id: Map.get(attrs, :change_id),
      evaluation_ids: Map.get(attrs, :evaluation_ids, []),
      created_at: Map.get(attrs, :created_at) || now_iso()
    }

    %{release | release_id: release_id(release)}
  end

  @doc "release_id = plugin_id@hash12。内容寻址，天然不可变。"
  def release_id(%__MODULE__{plugin_id: plugin_id, source_hash: hash}) do
    "#{plugin_id}@#{String.slice(hash, 0, 12)}"
  end

  def source_hash(source_files) when map_size(source_files) == 0, do: hash("")

  def source_hash(source_files) do
    source_files
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.map(fn {name, content} -> "#{name}:#{byte_size(content)}:#{hash(content)}" end)
    |> Enum.join("\n")
    |> hash()
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # ── JSON 序列化（存 manifest / 事件流）──

  def to_map(%__MODULE__{} = r) do
    %{
      "release_id" => r.release_id,
      "plugin_id" => r.plugin_id,
      "kind" => to_string(r.kind),
      "parent_release" => r.parent_release,
      "source_files" => Map.new(r.source_files, fn {k, v} -> {to_string(k), v} end),
      "source_hash" => r.source_hash,
      "contract_version" => r.contract_version,
      "dependencies" => r.dependencies,
      "usage" => r.usage,
      "capabilities" => Enum.map(r.capabilities, &to_string/1),
      "effects" => Enum.map(r.effects, &to_string/1),
      "state_policy" => to_string(r.state_policy),
      "replay_policy" => to_string(r.replay_policy),
      "author" => to_string(r.author),
      "change_id" => r.change_id,
      "evaluation_ids" => r.evaluation_ids,
      "created_at" => r.created_at
    }
  end

  def from_map(m) when is_map(m) do
    %__MODULE__{
      release_id: m["release_id"],
      plugin_id: m["plugin_id"],
      kind: to_atom(m["kind"] || "tool"),
      parent_release: m["parent_release"],
      source_files: Map.new(m["source_files"] || %{}),
      source_hash: m["source_hash"],
      contract_version: m["contract_version"] || 1,
      dependencies: m["dependencies"] || [],
      usage: m["usage"] || "",
      capabilities: Enum.map(m["capabilities"] || [], &to_atom/1),
      effects: Enum.map(m["effects"] || [], &to_atom/1),
      state_policy: to_atom(m["state_policy"] || "stateless"),
      replay_policy: to_atom(m["replay_policy"] || "rerun"),
      author: to_atom(m["author"] || "system"),
      change_id: m["change_id"],
      evaluation_ids: m["evaluation_ids"] || [],
      created_at: m["created_at"]
    }
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
