defmodule Newbee.Plugins.RepoMap do
  @moduledoc """
  工程结构图 (DESIGN §3.6)：注入紧凑的模块/函数签名大纲而非整文件，
  模型凭图定位，再对目标区域精确取细节。
  M1 支持 Elixir 工程（AST 提取）；其他语言退化为文件树。
  """

  @max_entries 60
  @cache_dir Path.join(System.user_home!(), ".newbee/cache")

  @doc """
  构建工程结构图（紧凑字符串）。非 Elixir 工程退化为目录树。

  增量缓存（§3.6）：以 mix.exs + lib 全部文件的 mtime 指纹为 key，
  工程未变更时直接复用缓存，不重复 AST 解析。
  """
  def build(dir \\ ".") do
    key = fingerprint(dir)

    case read_cache(key) do
      {:ok, map} ->
        map

      :miss ->
        map =
          if File.exists?(Path.join(dir, "mix.exs")) do
            elixir_map(dir)
          else
            tree_map(dir)
          end

        write_cache(key, map)
        map
    end
  end

  # 工程指纹：按语言分支收集实际读取的文件集合的 mtime 汇总
  #（Elixir：mix.exs + lib/**/*.{ex,exs}；其他：目录树读取的集合，避免空指纹导致缓存永不失效）
  defp fingerprint(dir) do
    files =
      if File.exists?(Path.join(dir, "mix.exs")) do
        Path.wildcard(Path.join(dir, "lib/**/*.{ex,exs}")) ++ [Path.join(dir, "mix.exs")]
      else
        Path.join(dir, "**/*")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, ~w(_build deps .git node_modules)))
      end

    sig =
      files
      |> Enum.map(fn f ->
        mtime =
          case File.stat(f, time: :posix) do
            {:ok, s} -> s.mtime
            _ -> 0
          end

        "#{f}:#{mtime}"
      end)
      |> Enum.sort()
      |> Enum.join("|")

    :crypto.hash(:md5, sig <> dir) |> Base.encode16(case: :lower)
  end

  defp read_cache(key) do
    file = Path.join(@cache_dir, "repomap-" <> cache_id() <> ".json")

    case File.read(file) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"key" => ^key, "map" => map}} -> {:ok, map}
          _ -> :miss
        end

      _ ->
        :miss
    end
  end

  defp write_cache(key, map) do
    File.mkdir_p!(@cache_dir)
    file = Path.join(@cache_dir, "repomap-" <> cache_id() <> ".json")
    File.write!(file, Jason.encode_to_iodata!(%{"key" => key, "map" => map}))
    :ok
  rescue
    _ -> :ok
  end

  defp cache_id, do: File.cwd!() |> then(&:crypto.hash(:md5, &1)) |> Base.encode16(case: :lower)

  defp elixir_map(dir) do
    (Path.wildcard(Path.join(dir, "lib/**/*.ex")) ++
       Path.wildcard(Path.join(dir, "lib/**/*.exs")))
    |> Enum.take(@max_entries)
    |> Enum.map(&summarize_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp summarize_file(path) do
    with {:ok, src} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(src, columns: false) do
      case extract_module(ast) do
        nil ->
          nil

        {mod, doc, defs} ->
          doc = doc && String.slice(doc, 0, 80)
          header = "▸ #{inspect(mod)}" <> if(doc, do: " — #{doc}", else: "")

          body =
            defs
            |> Enum.take(15)
            |> Enum.map(&"    #{&1}")
            |> Enum.join("\n")

          header <> "\n" <> body <> "\n  @ #{path}"
      end
    else
      _ -> nil
    end
  end

  defp extract_module({:defmodule, _, [{:__aliases__, _, mod}, [do: body]]}) do
    mod = Module.concat(mod)
    {doc, defs} = walk_body(body)
    {mod, doc, defs}
  end

  defp extract_module(_), do: nil

  defp walk_body(body) do
    {docs, defs} =
      body
      |> block_to_list()
      |> Enum.reduce({[], []}, fn
        {:@, _, [{:moduledoc, _, [doc]}]}, {docs, defs} when is_binary(doc) ->
          {[doc |> String.split("\n") |> hd() | docs], defs}

        {:def, _, [head | _]}, {docs, defs} ->
          {docs, [sig("def", head) | defs]}

        {:defp, _, [head | _]}, {docs, defs} ->
          {docs, [sig("defp", head) | defs]}

        {:defstruct, _, [fields]}, {docs, defs} when is_list(fields) ->
          {docs, ["defstruct: " <> Enum.map_join(fields, ", ", &field_name/1) | defs]}

        {:use, _, [{:__aliases__, _, parts} | _]}, {docs, defs} ->
          {docs, ["use " <> (Module.concat(parts) |> inspect()) | defs]}

        {:use, _, [mod | _]}, {docs, defs} when is_atom(mod) ->
          {docs, ["use " <> inspect(mod) | defs]}

        _, acc ->
          acc
      end)

    {docs |> Enum.reverse() |> List.first(), Enum.reverse(defs)}
  end

  defp block_to_list({:__block__, _, xs}), do: xs
  defp block_to_list(x), do: [x]

  defp sig(kind, {:when, _, [head | _]}), do: sig(kind, head)

  defp sig(kind, {name, _, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    "#{kind} #{name}/#{arity}"
  end

  defp sig(kind, _), do: kind

  defp field_name({k, _}), do: to_string(k)
  defp field_name(k), do: to_string(k)

  defp tree_map(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, ~w(_build deps .git node_modules)))
    |> Enum.take(@max_entries)
    |> Enum.join("\n")
  end
end
