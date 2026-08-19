defmodule Newbee.Tools.Search do
  @moduledoc """
  搜索工具 (DESIGN M3 工具集)：内容 grep 与文件名查找。
  跳过 _build/deps/.git/node_modules/cover。返回紧凑命中列表。
  """

  @skip ~r{/(_build|deps|\.git|node_modules|cover)/}

  @doc "递归内容搜索。返回 [{path, line_no, line}]（默认最多 100 条命中）。"
  def grep(pattern, dir \\ ".", opts \\ []) when is_binary(pattern) do
    max = Keyword.get(opts, :max, 100)
    re = Regex.compile!(pattern)

    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&(File.dir?(&1) or Regex.match?(@skip, &1)))
    |> Enum.reduce_while([], fn f, acc ->
      if length(acc) >= max do
        {:halt, acc}
      else
        hits =
          try do
            # 二进制文件快速跳过：含 NUL 字节视为二进制
            case File.stat(f) do
              {:ok, %File.Stat{size: s}} when s > 5_000_000 ->
                []

              _ ->
                f
                |> File.stream!([], :line)
                |> Stream.with_index(1)
                |> Enum.reduce_while([], fn {line, n}, inner ->
                  if length(acc) + length(inner) >= max do
                    {:halt, inner}
                  else
                    if String.contains?(line, <<0>>) do
                      {:halt, :binary}
                    else
                      if Regex.match?(re, line),
                        do: {:cont, [{f, n, String.slice(line, 0, 200)} | inner]},
                        else: {:cont, inner}
                    end
                  end
                end)
                |> case do
                  :binary -> []
                  list -> Enum.reverse(list)
                end
            end
          rescue
            _ -> []
          catch
            _, _ -> []
          end

        {:cont, acc ++ hits}
      end
    end)
    |> Enum.take(max)
  end

  @doc "按文件名片段查找。返回路径列表。"
  def find(name, dir \\ ".") do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&(File.dir?(&1) or Regex.match?(@skip, &1)))
    |> Enum.filter(&String.contains?(Path.basename(&1), name))
  end
end
