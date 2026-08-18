defmodule Newbee.Staging do
  @moduledoc """
  编辑暂存区（/approve 流程，DESIGN §5.3）：模型写文件先进暂存，
  用户 `/approve` 统一落盘、`/reject` 丢弃。宽松沙箱的"可回滚"兜底之一。

  存储：`~/.newbee/staging/<id>.json`。条目: %{id, path, content, when, source}。
  """

  use GenServer

  @dir Path.join(System.user_home!(), ".newbee/staging")

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "暂存一个文件写入。返回条目 id。"
  def stage(path, content, source \\ :model) do
    GenServer.call(__MODULE__, {:stage, path, content, source})
  end

  @doc "批准落盘。id = :all | 整数 | 条目 id。返回 {:ok, written_paths} | {:error, :not_staged}。"
  def approve(id \\ :all) do
    GenServer.call(__MODULE__, {:approve, id})
  end

  @doc "丢弃。返回 {:ok, dropped_paths} | {:error, :not_staged}。"
  def reject(id \\ :all) do
    GenServer.call(__MODULE__, {:reject, id})
  end

  @doc "暂存清单（新→旧）。"
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "渲染暂存区为文本（CLI 提示用）。"
  def render do
    list()
    |> Enum.map_join("\n", fn s ->
      "  [#{s.id}] #{s.path}（#{byte_size(s.content)} bytes, #{s.source}）"
    end)
  end

  @impl true
  def init(_) do
    File.mkdir_p!(@dir)
    {:ok, load()}
  end

  @impl true
  def handle_call({:stage, path, content, source}, _from, state) do
    id = :erlang.unique_integer([:positive])
    entry = %{id: id, path: path, content: content, source: source, when: DateTime.to_iso8601(DateTime.utc_now())}
    state = put_entry(state, entry)
    {:reply, id, state}
  end

  def handle_call({:approve, :all}, _from, state) do
    entries = Map.values(state) |> Enum.sort_by(& &1.id)

    written =
      Enum.map(entries, fn e ->
        File.mkdir_p!(Path.dirname(e.path))
        File.write!(e.path, e.content)
        e.path
      end)

    state = %{}
    persist(state)
    {:reply, {:ok, written}, state}
  end

  def handle_call({:approve, id}, _from, state) when is_integer(id) do
    case Map.pop(state, id) do
      {nil, _} ->
        {:reply, {:error, :not_staged}, state}

      {entry, rest} ->
        File.mkdir_p!(Path.dirname(entry.path))
        File.write!(entry.path, entry.content)
        persist(rest)
        {:reply, {:ok, [entry.path]}, rest}
    end
  end

  def handle_call({:reject, :all}, _from, state) do
    dropped = state |> Map.values() |> Enum.map(& &1.path)
    state = %{}
    persist(state)
    {:reply, {:ok, dropped}, state}
  end

  def handle_call({:reject, id}, _from, state) when is_integer(id) do
    case Map.pop(state, id) do
      {nil, _} -> {:reply, {:error, :not_staged}, state}
      {entry, rest} ->
        persist(rest)
        {:reply, {:ok, [entry.path]}, rest}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  defp put_entry(state, entry) do
    state = Map.put(state, entry.id, entry)
    persist(state)
    state
  end

  defp persist(state) do
    File.mkdir_p!(@dir)
    # 简单：每个条目一个文件
    existing = Path.wildcard(Path.join(@dir, "*.json"))
    keep = Map.keys(state) |> MapSet.new()

    Enum.each(existing, fn f ->
      if f |> Path.basename(".json") |> String.to_integer() |> then(&(not MapSet.member?(keep, &1))) do
        File.rm(f)
      end
    end)

    Enum.each(state, fn {id, entry} ->
      File.write!(Path.join(@dir, "#{id}.json"), Jason.encode_to_iodata!(entry))
    end)
  end

  defp load do
    @dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn f, acc ->
      case File.read(f) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, entry} -> Map.put(acc, entry["id"], entry)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
