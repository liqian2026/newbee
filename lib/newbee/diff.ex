defmodule Newbee.Diff do
  @moduledoc """
  行级 diff（简化版，DESIGN §5.1 内联 diff 渲染的底座）。

  算法：共同前缀 + 共同后缀 + 中间逐行标记。对"编辑场景"（改动集中在
  局部）足够准确且 O(n) 线性；不做 Myers/LCS（整文件重排场景罕见）。
  返回带 `- `/`+ ` 标记的行列表（无 ANSI，渲染层上色）。
  """

  @doc "生成两段文本的行级 diff。返回 [line]（'- ' 删除 / '+ ' 新增 / '  ' 未变）。"
  def lines(old, new) when is_binary(old) and is_binary(new) do
    a = String.split(old, "\n")
    b = String.split(new, "\n")
    {prefix, a2, b2} = common_prefix(a, b)
    {suffix, a3, b3} = common_suffix(a2, b2)

    middle =
      Enum.map(a3, &("- " <> &1)) ++ Enum.map(b3, &("+ " <> &1))

    prefix ++ middle ++ suffix
  end

  @doc "diff 统计：%{added, removed}（内联 diff 标题用）。"
  def stats(old, new) do
    ls = lines(old, new)

    %{
      added: Enum.count(ls, &String.starts_with?(&1, "+ ")),
      removed: Enum.count(ls, &String.starts_with?(&1, "- "))
    }
  end

  @doc "diff 是否为空（无变更）。"
  def empty?(old, new), do: lines(old, new) |> Enum.all?(&(not String.starts_with?(&1, ["+ ", "- "])))

  defp common_prefix([h | a], [h | b]), do: common_prefix(a, b) |> then(fn {p, a2, b2} -> {[h | p], a2, b2} end)
  defp common_prefix(a, b), do: {[], a, b}

  defp common_suffix(a, b) do
    {rev, a2, b2} = common_prefix(Enum.reverse(a), Enum.reverse(b))
    {Enum.reverse(rev), Enum.reverse(a2), Enum.reverse(b2)}
  end
end
