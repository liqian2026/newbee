defmodule Newbee.Session do
  @moduledoc """
  会话持久化 (DESIGN §5.3/§3.8)：transcript JSONL 追加写 + 制品目录
  （bindings 快照）。恢复的是状态与绑定值——进程/闭包 tombstone。
  """

  defstruct id: nil, dir: nil, transcript: nil

  @root Path.join(System.user_home!(), ".newbee/sessions")
  @artifacts Path.join(System.user_home!(), ".newbee/session-artifacts")
  @index Path.join(@root, ".index.json")

  @doc "当前活动会话 id（kernel 启动时登记；无会话返回 nil）。"
  def current_id, do: :persistent_term.get({__MODULE__, :current}, nil)

  @doc "登记当前活动会话（kernel init 调用；nil 清除）。"
  def set_current(nil), do: :persistent_term.erase({__MODULE__, :current})
  def set_current(id) when is_binary(id), do: :persistent_term.put({__MODULE__, :current}, id)

  @doc "新会话或恢复已有会话。"
  def open(id \\ nil) do
    id = id || gen_id()
    dir = Path.join(@artifacts, id)
    File.mkdir_p!(dir)

    %__MODULE__{id: id, dir: dir, transcript: Path.join(@root, "#{id}.jsonl")}
    |> tap(fn _ -> File.mkdir_p!(@root) end)
  end

  @doc "追加一条消息到 transcript。"
  def append(%__MODULE__{transcript: t, id: id}, %{"role" => _} = msg) do
    File.write!(t, [Jason.encode_to_iodata!(msg), "\n"], [:append])
    touch_index(id)
  end

  @doc "重写整个 transcript（/compact 用：摘要 + 最近消息）。"
  def rewrite(%__MODULE__{transcript: t}, messages) do
    body = Enum.map_join(messages, "\n", &Jason.encode!/1)
    File.write!(t, body <> "\n")
  end

  @doc "读取全部历史消息。坏行（崩溃写了一半的）跳过而非崩 init。"
  def messages(%__MODULE__{transcript: t}) do
    case File.read(t) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, msg} -> [msg | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  @doc "读取会话首次请求的稳定 system prompt；旧会话没有时返回 nil。"
  def system_prompt(%__MODULE__{dir: dir}) do
    case File.read(Path.join(dir, "system-prompt.md")) do
      {:ok, prompt} -> prompt
      {:error, :enoent} -> nil
      {:error, _} -> nil
    end
  end

  @doc "持久化会话首次请求的 system prompt，供同会话恢复时原样复用。"
  def save_system_prompt(%__MODULE__{dir: dir}, prompt) when is_binary(prompt) do
    File.write!(Path.join(dir, "system-prompt.md"), prompt)
    prompt
  end

  @doc "绑定快照：落两份——`bindings.json`(JSON 可读，tombstone 标注) + `bindings.etf`(ETF 全量，term_to_binary，覆盖 PID/Ref/Fun 等，/resume 优先用 ETF)。"
  def save_bindings(%__MODULE__{dir: d}, binding) do
    safe =
      Enum.map(binding, fn
        {name, v} when is_binary(v) or is_number(v) or is_atom(v) or is_map(v) or is_list(v) ->
          case serializable?(v) do
            true -> [to_string(name), ["ok", v]]
            false -> [to_string(name), "tombstone"]
          end

        {name, _} ->
          [to_string(name), "tombstone"]
      end)

    File.write!(Path.join(d, "bindings.json"), Jason.encode_to_iodata!(safe))
    persist_etf(d, binding)
    persist_beam_snapshot(d, binding)
  end

  @doc "加载绑定：优先 `bindings.etf`（全量反序列化，safe_binary_to_term），否则回退 JSON。"
  def load_bindings(%__MODULE__{dir: d}) do
    case load_etf(d) do
      {:ok, binding} -> binding
      :no_etf -> load_json_bindings(d)
    end
  end

  defp load_json_bindings(d) do
    case File.read(Path.join(d, "bindings.json")) do
      {:ok, body} ->
        body
        |> Jason.decode!()
        |> Enum.flat_map(fn
          [name, ["ok", v]] -> [{String.to_atom(name), v}]
          _ -> []
        end)

      _ ->
        []
    end
  end

  # ── ETF 全量 dump：term_to_binary（可保 PID/Ref/简单 Fun/Port 等的"值语义"快照）──
  # 注意 BEAM 硬限制：外部资源（打开的文件/ETS 表/Port/NIF 资源/跨节点 PID）反序列化后
  # 为"死句柄"，只能做值检查不能继续操作——ETf 侧已尽量保存，tombstone 仅用于不可 term_to_binary 的项。
  defp persist_etf(dir, binding) do
    payload = %{
      version: 1,
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      saved_at: local_iso(),
      bindings: encode_etf_bindings(binding)
    }

    File.write!(Path.join(dir, "bindings.etf"), :erlang.term_to_binary(payload, compressed: 9))
  rescue
    _ -> :ok
  end

  defp encode_etf_bindings(binding) do
    Enum.flat_map(binding, fn {name, v} ->
      if migratable?(v) do
        try do
          bin = :erlang.term_to_binary(v, compressed: 1)
          _ = :erlang.binary_to_term(bin, [:safe])
          [{to_string(name), {:etf, Base.encode64(bin)}}]
        rescue
          _ -> []
        catch
          _, _ -> []
        end
      else
        []
      end
    end)
  end

  defp migratable?(v) when is_pid(v) or is_port(v) or is_reference(v) or is_function(v), do: false
  defp migratable?(_), do: true

  defp load_etf(dir) do
    path = Path.join(dir, "bindings.etf")

    case File.read(path) do
      {:ok, bin} ->
        try do
          payload = :erlang.binary_to_term(bin, [:safe])
          validate_etf_version(payload)
          bindings = decode_etf_bindings(payload[:bindings] || payload["bindings"] || [])
          {:ok, bindings}
        rescue
          _ -> :no_etf
        catch
          _, _ -> :no_etf
        end

      _ ->
        :no_etf
    end
  end

  defp decode_etf_bindings(list) when is_list(list) do
    Enum.flat_map(list, fn
      {name, {:etf, b64}} when is_binary(b64) ->
        decode_etf_entry(name, b64)

      [name, %{"etf" => b64}] when is_binary(b64) ->
        decode_etf_entry(name, b64)

      [name, ["etf", b64]] when is_binary(b64) ->
        decode_etf_entry(name, b64)

      _ ->
        []
    end)
  end

  defp decode_etf_bindings(_), do: []

  defp decode_etf_entry(name, b64) do
    bin = Base.decode64!(b64)
    v = :erlang.binary_to_term(bin, [:safe])
    if migratable?(v), do: [{String.to_atom(name), v}], else: []
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp validate_etf_version(%{otp: _otp, elixir: _elixir}), do: :ok
  defp validate_etf_version(%{"otp" => _otp, "elixir" => _elixir}), do: :ok
  defp validate_etf_version(_), do: :ok

  # ── Beam 快照（诊断/可观测）：文本摘要，非反序列化还原，仅供 /resume 时提示环境差异 ──
  defp persist_beam_snapshot(dir, binding) do
    snapshot = %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      erts: :erlang.system_info(:version) |> List.to_string(),
      nodes: Node.list() |> Enum.map(&to_string/1),
      self_node: Node.self() |> to_string(),
      bindings_summary:
        Enum.map(binding, fn {name, v} ->
          %{name: to_string(name), type: type_of(v), size: byte_size_safe(v)}
        end),
      saved_at: local_iso()
    }

    File.write!(Path.join(dir, "beam_snapshot.json"), Jason.encode_to_iodata!(snapshot, pretty: true))
  rescue
    _ -> :ok
  end

  defp type_of(v) when is_binary(v), do: "binary"
  defp type_of(v) when is_list(v), do: "list"
  defp type_of(v) when is_map(v), do: "map"
  defp type_of(v) when is_tuple(v), do: "tuple"
  defp type_of(v) when is_pid(v), do: "pid"
  defp type_of(v) when is_port(v), do: "port"
  defp type_of(v) when is_reference(v), do: "reference"
  defp type_of(v) when is_function(v), do: "function"
  defp type_of(_), do: "other"

  defp byte_size_safe(v) do
    try do
      byte_size(:erlang.term_to_binary(v))
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  @doc "会话总数（廉价：单次 File.ls；/status 用）。"
  def count do
    case File.ls(@root) do
      {:ok, files} -> Enum.count(files, &String.ends_with?(&1, ".jsonl"))
      _ -> 0
    end
  end

  @doc "列出会话元信息（新→旧，默认最多 20 个）：id / when_str / mtime / messages / title。"
  def list_with_meta(n \\ 20) do
    # 读索引（O(1)），只对最近 n 个读消息——避免 stat 全部会话文件（§9.1 极简）
    recent =
      case File.read(@index) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, entries} when is_list(entries) ->
              entries |> Enum.sort_by(& &1["mtime"], :desc) |> Enum.take(n)

            _ ->
              build_index()
          end

        _ ->
          build_index()
      end

    recent
    |> Enum.flat_map(fn entry ->
      id = entry["id"]
      fp = Path.join(@root, "#{id}.jsonl")

      case File.stat(fp) do
        {:ok, stat} ->
          msgs = messages(%__MODULE__{id: id, dir: Path.join(@artifacts, id), transcript: fp})

          [
            %{
              id: id,
              mtime: stat.mtime,
              when_str: when_str(stat.mtime),
              messages: length(msgs),
              title: title(msgs)
            }
          ]

        _ ->
          []
      end
    end)
  end

  # 首次无索引时构建（一次性成本；后续 append 增量维护）
  defp build_index do
    entries =
      @root
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.flat_map(fn fp ->
        case File.stat(fp) do
          {:ok, stat} -> [%{"id" => Path.basename(fp, ".jsonl"), "mtime" => posix_mtime(stat.mtime)}]
          _ -> []
        end
      end)

    File.mkdir_p!(@root)
    File.write!(@index, Jason.encode_to_iodata!(entries))

    entries |> Enum.sort_by(& &1["mtime"], :desc)
  end

  defp touch_index(id) do
    entries =
      case File.read(@index) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        _ ->
          []
      end

    now = System.system_time(:second)
    rest = Enum.reject(entries, &(&1["id"] == id))
    File.write!(@index, Jason.encode_to_iodata!([%{"id" => id, "mtime" => now} | rest]))
  rescue
    _ -> :ok
  end

  defp posix_mtime(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp posix_mtime({{_, _, _}, {_, _, _}} = t) do
    :calendar.datetime_to_gregorian_seconds(t) -
      :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  end

  defp posix_mtime(n) when is_integer(n), do: n
  defp posix_mtime(_), do: 0

  @doc "单个会话的元信息（时间 / 消息数 / 标题）。"
  def meta(id) do
    s = open(id)
    stat = File.stat!(s.transcript)
    msgs = messages(s)

    %{
      id: id,
      mtime: stat.mtime,
      when_str: when_str(stat.mtime),
      messages: length(msgs),
      title: title(msgs)
    }
  end

  @doc "会话标题：首条用户消息（太短则用最近一条），单行化 + 截断。"
  def title(msgs) do
    users = msgs |> Enum.filter(&(&1["role"] == "user")) |> Enum.map(&(&1["content"] || ""))

    pick =
      case users do
        [] -> ""
        [first | _] -> if String.length(first) < 4, do: List.last(users), else: first
      end

    pick |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 48)
  end

  @doc "按 id 精确或前缀匹配，返回匹配的 id 列表。"
  def find(input) do
    ids = list()

    case Enum.filter(ids, &(&1 == input)) do
      [] -> Enum.filter(ids, &String.starts_with?(&1, input))
      exact -> exact
    end
  end

  def list do
    @root
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".jsonl"))
    |> Enum.sort(:desc)
  end

  # 文件 mtime 为本地时间。相对化：今天/昨天显示时段，跨年显示日期。
  defp when_str({{y, m, d}, {h, mi, _}}) do
    {{ny, nm, nd}, _} = :calendar.local_time()
    yesterday = (:calendar.date_to_gregorian_days({ny, nm, nd}) - 1) |> :calendar.gregorian_days_to_date()
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    cond do
      {y, m, d} == {ny, nm, nd} -> "今天 #{pad.(h)}:#{pad.(mi)}"
      {y, m, d} == yesterday -> "昨天 #{pad.(h)}:#{pad.(mi)}"
      y == ny -> "#{pad.(m)}-#{pad.(d)} #{pad.(h)}:#{pad.(mi)}"
      true -> "#{y}-#{pad.(m)}-#{pad.(d)}"
    end
  end

  defp serializable?(v) do
    try do
      Jason.encode!(v)
      true
    rescue
      _ -> false
    end
  end

  defp gen_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  # 本地时间 ISO（无 tz database 时 :calendar.local_time 即系统本地时区）
  defp local_iso do
    {{y, m, d}, {h, mi, sec}} = :calendar.local_time()
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B", [y, m, d, h, mi, sec]) |> IO.iodata_to_binary()
  end
end
