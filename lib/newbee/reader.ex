defmodule Newbee do
  @moduledoc """
  统一寻址读取 (DESIGN §3.2)：`Newbee.read/1` 通吃文件、目录、URL 与内部 scheme。
  只教模型一个接口。

  scheme 一览:
    - 裸路径        → 文件或目录
    - `file://`     → 文件
    - `tool://M`    → 模块文档（@moduledoc + 公开函数 @doc）
    - `rules://`    → 沉睡规则清单
    - `memory://k`  → 全局记忆条目
    - `bindings://` → 求值器绑定摘要
    - `events://`   → 事件日志（可选 ?n= 条数）
    - `http(s)://`  → 网页（Req 拉取）
  """

  @doc """
  统一读取。返回 {:ok, content} | {:error, reason}。

    - 目录 → 一层列表（目录名带 / 后缀）
    - 文件 → 文本内容（≤512KB，超出截断并标注）
    - URL → 网页文本
    - 内部 scheme → 见 @moduledoc
  """
  def read(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "tool://") ->
        read_tool(String.trim_leading(path, "tool://"))

      path == "rules://" or String.starts_with?(path, "rules://") ->
        read_rules()

      String.starts_with?(path, "memory://") ->
        read_memory(String.trim_leading(path, "memory://"))

      path == "bindings://" ->
        read_bindings()

      String.starts_with?(path, "events://") ->
        read_events(String.trim_leading(path, "events://"))

      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        read_url(path)

      String.starts_with?(path, "file://") ->
        read_path(String.trim_leading(path, "file://"))

      true ->
        read_path(path)
    end
  end

  def read(_), do: {:error, :invalid_path}

  # ── 各实现 ──

  defp read_path(path) do
    cond do
      File.regular?(path) ->
        case File.read(path) do
          {:ok, body} when byte_size(body) <= 512 * 1024 ->
            {:ok, body}

          {:ok, body} ->
            {:ok,
             binary_part(body, 0, 512 * 1024) <>
               "\n… [截断: #{byte_size(body)} bytes > 512KB，用 Fs 分段读取] …\n"}

          {:error, reason} ->
            {:error, reason}
        end

      File.dir?(path) ->
        {:ok, Newbee.Tools.Fs.ls(path) |> Enum.join("\n")}

      true ->
        {:error, :enoent}
    end
  end

  defp read_rules do
    if Process.whereis(Newbee.DEE.Rules) do
      case Newbee.DEE.Rules.list() do
        [] -> {:ok, "（无沉睡规则）"}
        rules -> {:ok, Enum.map_join(rules, "\n", &"[#{&1.id}] /#{&1.pattern}/ → #{&1.injection}")}
      end
    else
      {:ok, "（规则服务未启动）"}
    end
  end

  defp read_memory(key) do
    case Newbee.Memory.read(key) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_bindings do
    if Process.whereis(Newbee.DEE.Evaluator) do
      case Newbee.DEE.Evaluator.bindings_summary() do
        [] -> {:ok, "（空）"}
        bs -> {:ok, Enum.map_join(bs, "\n", &"#{&1.name} : #{&1.type} (#{&1.size} bytes)")}
      end
    else
      {:ok, "（求值器未启动）"}
    end
  end

  defp read_events(query) do
    n =
      case Regex.run(~r/[?&]n=(\d+)/, query) do
        [_, n] -> String.to_integer(n)
        _ -> 200
      end

    events = Newbee.EventLog.read(n)
    {:ok, Enum.map_join(events, "\n", &"[#{&1["topic"]}] #{inspect(&1["event"]) |> String.slice(0, 200)}")}
  end

  defp read_url(url) do
    case Req.get(url, receive_timeout: 30_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, String.slice(body, 0, 512 * 1024)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  defp read_tool(module_name) do
    module = String.to_atom(module_name)

    if Code.ensure_loaded?(module) do
      docs =
        case Code.fetch_docs(module) do
          {:docs_v1, _, _, _, _, docs} when is_list(docs) -> docs
          _ -> []
        end

      moduledoc =
        Enum.find_value(docs, "", fn
          {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) -> doc
          _ -> nil
        end) || ""

      funcs =
        docs
        |> Enum.filter(fn
          {{:function, name, _arity}, _, _, _, doc} when name not in [:__info__, :module_info] ->
            is_binary(doc) or doc != :none

          _ ->
            false
        end)
        |> Enum.map_join("\n", fn {{:function, name, arity}, _, _, _, doc} ->
          doc = if is_binary(doc), do: doc, else: ""
          "  #{name}/#{arity}: #{String.slice(doc, 0, 200)}"
        end)

      {:ok, "## #{module_name}\n" <> moduledoc <> "\n" <> funcs}
    else
      {:error, :module_not_loaded}
    end
  rescue
    _ -> {:error, :module_not_found}
  end
end
