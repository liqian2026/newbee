defmodule Newbee.DEE.RepoMap do
  @moduledoc """
  工程结构图 (DESIGN §3.6)：注入紧凑的模块/函数签名大纲而非整文件，
  模型凭图定位，再对目标区域精确取细节。
  M1 支持 Elixir 工程（AST 提取）；其他语言退化为文件树。
  """

  @max_entries 60

  @doc "构建工程结构图（紧凑字符串）。非 Elixir 工程退化为目录树。"
  def build(dir \\ ".") do
    if File.exists?(Path.join(dir, "mix.exs")) do
      elixir_map(dir)
    else
      tree_map(dir)
    end
  end

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
        nil -> nil
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