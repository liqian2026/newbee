defmodule Newbee.Environment.BindingGC do
  @moduledoc """
  绑定 GC（DESIGN §9.1）：极简主义也约束环境侧状态。

  - 按**大小 + 最近访问 turn** 做 LRU 预算（默认驻留上限 512KB）；
  - 可序列化冷值逐出到 Artifact Store（`.newbee/bindings/gc/`），
    binding 名保留为显式 `ArtifactRef`（仅对 codec 白名单内可序列化的值）；
  - 不可序列化的大值（PID/闭包等）不逐出——访问即 tombstone 语义已足够；
  - 用户或 workflow 可 `pin/1`：`pin` 的活跃值不静默删除；
  - `/bindings` 显示驻留/逐出状态（`inventory/1`）。
  """

  alias Newbee.ArtifactRef
  alias Newbee.Environment.{BindingCodec, Store}

  # 驻留预算（字节）；超过则按 LRU 逐出冷值
  @default_resident_budget 512_000

  @doc "pin 一个 binding 名（活跃值不静默删除）。"
  def pin(name), do: :persistent_term.put(pin_key(name), true)

  @doc "取消 pin。"
  def unpin(name), do: :persistent_term.erase(pin_key(name))

  @doc "是否 pinned。"
  def pinned?(name), do: :persistent_term.get(pin_key(name), false)

  defp pin_key(name), do: {__MODULE__, :pin, to_string(name)}

  @doc """
  GC 入口（Evaluator 每次 cell 后调用）。
  binding = keyword list；turn = 当前 cell 计数（LRU 时钟）。
  返回 {new_binding, evicted_names}。
  """
  def maybe_gc(binding, turn, opts \\ []) do
    budget = Keyword.get(opts, :resident_budget, @default_resident_budget)
    track_access(binding, turn)

    total = resident_bytes(binding)

    if total <= budget do
      {binding, []}
    else
      evict(binding, budget, turn, [])
    end
  end

  @doc "驻留/逐出清单（/bindings 用）：%{name, type, bytes, state: :resident | :evicted, pinned?}。"
  def inventory(binding) do
    Enum.map(binding, fn {name, value} ->
      %{
        name: name,
        type: type_of(value),
        bytes: value_bytes(value),
        state: if(match?(%ArtifactRef{}, value), do: :evicted, else: :resident),
        pinned?: pinned?(name)
      }
    end)
  end

  # ── 逐出 ──

  defp evict(binding, budget, turn, evicted), do: evict(binding, budget, turn, evicted, MapSet.new())

  defp evict(binding, budget, _turn, evicted, skip) do
    # 候选：非 pin、非 ArtifactRef、可序列化、未失败过；LRU（最久未访问优先，同序取大）
    candidates =
      binding
      |> Enum.reject(fn {name, value} ->
        pinned?(name) or match?(%ArtifactRef{}, value) or
          MapSet.member?(skip, name) or not serializable?(value)
      end)
      |> Enum.sort_by(fn {name, value} -> {last_access(name), -value_bytes(value)} end)

    if resident_bytes(binding) <= budget or candidates == [] do
      # 达标，或全是 pin/不可序列化（不静默删除活跃值）
      {binding, Enum.reverse(evicted)}
    else
      {name, value} = hd(candidates)

      case evict_value(name, value) do
        {:ok, ref} ->
          binding = Keyword.put(binding, name, ref)
          Newbee.Events.emit(:binding_evicted, %{name: name, bytes: value_bytes(value), artifact: ref.id})
          evict(binding, budget, 0, [name | evicted], skip)

        :error ->
          # 序列化失败：跳过该值，不再尝试
          evict(binding, budget, 0, evicted, MapSet.put(skip, name))
      end
    end
  end

  # 逐出到 Artifact Store：codec 编码后落盘，binding 名保留为 ArtifactRef
  defp evict_value(name, value) do
    case BindingCodec.encode([{name, value}]) do
      {:ok, snapshot} ->
        dir = Path.join(Store.dir(:bindings), "gc")
        File.mkdir_p!(dir)

        body = Jason.encode_to_iodata!(snapshot.entries)
        sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
        path = Path.join(dir, "#{name}.#{String.slice(sha, 0, 12)}.json")
        Store.write_atomic!(path, body)

        ref = %ArtifactRef{
          id: "art_" <> String.slice(sha, 0, 16),
          path: path,
          bytes: byte_size(body),
          sha256: sha,
          media_type: "application/x-newbee-binding"
        }

        {:ok, ref}

      {:error, _} ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # ── LRU 时钟（访问追踪：每次 cell 后记录当前 turn）──

  defp track_access(binding, turn) do
    Enum.each(binding, fn {name, _} ->
      :persistent_term.put({__MODULE__, :access, name}, turn)
    end)
  end

  defp last_access(name), do: :persistent_term.get({__MODULE__, :access, name}, 0)

  @doc "touch：模型引用某 binding 时更新访问时钟（Tools/Introspect 可调用）。"
  def touch(name, turn), do: :persistent_term.put({__MODULE__, :access, name}, turn)

  # ── 度量 ──

  defp resident_bytes(binding) do
    Enum.reduce(binding, 0, fn {_name, value}, acc -> acc + value_bytes(value) end)
  end

  defp value_bytes(value), do: :erts_debug.size(value) * 8

  defp serializable?(value) do
    not (is_pid(value) or is_port(value) or is_reference(value) or is_function(value))
  end

  defp type_of(v) when is_binary(v), do: :binary
  defp type_of(v) when is_list(v), do: :list
  defp type_of(%ArtifactRef{}), do: :artifact_ref
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_tuple(v), do: :tuple
  defp type_of(v) when is_atom(v), do: :atom
  defp type_of(v) when is_number(v), do: :number
  defp type_of(_), do: :other

  def default_resident_budget, do: @default_resident_budget
end
