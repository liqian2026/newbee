defmodule Newbee.Tools.Edit do
  @moduledoc """
  哈希锚点编辑 (DESIGN §3.2 文本轨)：
  `show/2` 给出的每行带 `N#hash` 锚点，`patch/1` 按锚点打补丁；
  锚点或文件快照过期 → 整体拒绝，绝不改坏文件。原子：全部验证通过才落盘。

  补丁语法（节头 + 操作，行号与哈希锚点必须来自最近一次 show）：

      [lib/foo.ex#9F2C]
      PUT 3.=5:          # 用 + 行替换 3..5 行
      +newline
      PUT <2:            # 在第 2 行前插入 + 行
      +head
      CUT 8              # 删除第 8 行
  """

  @line_re ~r/^(PUT|CUT)\s+(.+?)(:)?$/

  # ── 读 ──

  @doc "带锚点显示文件。返回 %{tag, text}；tag 是全文件快照哈希。"
  def show(path, range \\ :all) do
    content = File.read!(path)
    lines = String.split(content, "\n", trim: false)

    lines =
      case range do
        :all -> lines
        {a, b} -> Enum.slice(lines, (a - 1)..(b - 1)//1)
      end

    start = case range do :all -> 1; {a, _} -> a end

    text =
      lines
      |> Enum.with_index(start)
      |> Enum.map(fn {line, n} -> "#{n}##{line_hash(line)}| #{line}" end)
      |> Enum.join("\n")

    %{tag: file_tag(content), path: path, text: text, lines: length(lines)}
  end

  # ── 改 ──

  @doc """
  应用锚点补丁。成功返回 %{applied, paths, warnings}。
  快照 tag 过期只警告不拒绝（锚点对才是新鲜度检查，DESIGN §3.2）；
  锚点不匹配抛 Newbee.Tools.Edit.AnchorError。多节补丁全部验证通过才统一落盘（原子）。
  """
  def patch(patch_text) do
    sections = parse_sections(patch_text)

    {warnings, writes} =
      Enum.reduce(sections, {[], []}, fn section, {warns, acc} ->
        {new_lines, sec_warns} = prepare_section(section)
        {warns ++ sec_warns, acc ++ [{section.path, new_lines}]}
      end)

    Enum.each(writes, fn {path, lines} ->
      File.write!(path, Enum.join(lines, "\n"))
    end)

    %{applied: length(sections), paths: Enum.map(sections, & &1.path), warnings: warnings}
  end

  defmodule AnchorError do
    defexception [:message]
  end

  # ── 解析 ──

  defp parse_sections(text) do
    text
    |> String.split(~r/^\[/m)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn chunk ->
      [header | body] = String.split("[" <> chunk, "\n")

      [path, tag] =
        header
        |> String.trim_trailing("]")
        |> String.trim_leading("[")
        |> String.split("#")

      ops = parse_ops(body)

      %{path: String.trim(path), tag: String.trim(tag), ops: ops}
    end)
  end

  defp parse_ops(lines) do
    {ops, _} =
      Enum.reduce(lines, {[], nil}, fn line, {ops, cur} ->
        cond do
          String.starts_with?(line, "+") and cur ->
            {put_in_ops(ops, cur, String.trim_leading(line, "+")), cur}

          match = Regex.run(@line_re, line) ->
            [_, op, arg | _] = match
            cur = parse_op(op, arg)
            {ops ++ [cur], cur}

          String.trim(line) == "" ->
            {ops, cur}

          true ->
            {ops, cur}
        end
      end)

    ops
  end

  defp parse_op("PUT", arg) do
    case arg do
      "<" <> rest ->
        {n, h} = parse_anchor(rest)
        {:insert_before, n, [], h}

      ">" <> rest ->
        {n, h} = parse_anchor(rest)
        {:insert_after, n, [], h}

      range ->
        case String.split(range, "=") do
          [a, b] ->
            {na, ha} = parse_anchor(a)
            {_nb, hb} = parse_anchor(b)
            {:replace, na, String.to_integer(strip_hash(b)), [], {ha, hb}}

          [a] ->
            {na, ha} = parse_anchor(a)
            {:replace, na, na, [], {ha, nil}}
        end
    end
  end

  defp parse_op("CUT", arg) do
    case String.split(arg, "=") do
      [a, b] ->
        {na, ha} = parse_anchor(a)
        {:delete, na, String.to_integer(strip_hash(b)), ha}

      [a] ->
        {na, ha} = parse_anchor(a)
        {:delete, na, na, ha}
    end
  end

  defp parse_anchor(s) do
    case s |> String.trim_trailing(".") |> String.split("#") do
      [n, h] -> {String.to_integer(n), String.trim_trailing(h, ".")}
      [n] -> {String.to_integer(n), nil}
    end
  end

  defp strip_hash(s), do: s |> String.split("#") |> hd()

  # 注意：不能用 cur 的 lines 累积（cur 在 reduce 里不更新，永远是 []），
  # 必须基于 ops 里最后一个 op 的当前状态追加，否则多行内容只剩最后一行。
  defp put_in_ops(ops, _cur, new) do
    List.update_at(ops, -1, fn
      {:replace, a, b, lines, h} -> {:replace, a, b, lines ++ [new], h}
      {:insert_before, n, lines, h} -> {:insert_before, n, lines ++ [new], h}
      {:insert_after, n, lines, h} -> {:insert_after, n, lines ++ [new], h}
      op -> op
    end)
  end

  # ── 应用 ──

  defp prepare_section(%{path: path, tag: tag, ops: ops}) do
    content = File.read!(path)
    current_tag = file_tag(content)

    warnings =
      if current_tag != tag do
        ["快照过期: #{path} (期望 #{tag}, 实际 #{current_tag})——锚点对仍生效，已照常应用"]
      else
        []
      end

    lines = String.split(content, "\n", trim: false)

    # 按行号从大到小排序应用，避免位移
    new_lines =
      ops
      |> Enum.sort_by(&op_line/1, :desc)
      |> Enum.reduce(lines, &apply_op(&2, &1))

    {new_lines, warnings}
  end

  defp op_line({:replace, a, _, _, _}), do: a
  defp op_line({:delete, a, _, _}), do: a
  defp op_line({:insert_before, n, _, _}), do: n
  defp op_line({:insert_after, n, _, _}), do: n

  defp apply_op(lines, {:replace, a, b, new, hashes}) do
    verify_anchor!(lines, a, elem(hashes, 0))
    verify_anchor!(lines, b, elem(hashes, 1))
    Enum.take(lines, a - 1) ++ new ++ Enum.drop(lines, b)
  end

  defp apply_op(lines, {:delete, a, b, hash}) do
    verify_anchor!(lines, a, hash)
    Enum.take(lines, a - 1) ++ Enum.drop(lines, b)
  end

  defp apply_op(lines, {:insert_before, n, new, hash}) do
    verify_anchor!(lines, n, hash)
    Enum.take(lines, n - 1) ++ new ++ Enum.drop(lines, n - 1)
  end

  defp apply_op(lines, {:insert_after, n, new, hash}) do
    verify_anchor!(lines, n, hash)
    Enum.take(lines, n) ++ new ++ Enum.drop(lines, n)
  end

  defp verify_anchor!(_lines, _n, nil), do: :ok

  defp verify_anchor!(lines, n, expected) do
    actual = lines |> Enum.at(n - 1, "") |> line_hash()

    if actual != expected do
      raise AnchorError,
        message: "锚点不匹配: 第 #{n} 行期望 ##{expected} 实际 ##{actual}——模型可能数错了行，请重新 show"
    end
  end

  # ── 哈希 ──

  defp file_tag(content), do: hash4(content)
  defp line_hash(line), do: hash4(line)

  defp hash4(s) do
    :crypto.hash(:md5, s) |> binary_part(0, 2) |> Base.encode16(case: :lower)
  end
end
