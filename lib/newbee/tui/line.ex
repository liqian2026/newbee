defmodule Newbee.TUI.Line do
  @moduledoc """
  输入行编辑器（纯逻辑）：文本 + 光标（codepoint 索引）+ 历史栈。

  双宽感知：中文/emoji 在终端占 2 列。所有列宽计算走 char_width/width，
  光标屏幕列 = 前缀可见宽 + 2，避免旧实现"光标飘进半个字"的错位。
  """

  defstruct text: "", cur: 0, hist: [], hcur: 0, draft: nil

  @type t :: %__MODULE__{}

  # ── 编辑操作 ──

  @doc "插入文本（粘贴同路径），光标落到插入内容之后。"
  def insert(%__MODULE__{text: t, cur: c} = l, ins) do
    {pre, post} = String.split_at(t, c)
    %{l | text: pre <> ins <> post, cur: c + String.length(ins)}
  end

  @doc "退格：删光标前一字符；行首不动。"
  def backspace(%__MODULE__{cur: 0} = l), do: l

  def backspace(%__MODULE__{text: t, cur: c} = l) when c > 0 do
    {pre, post} = String.split_at(t, c)
    pre = String.slice(pre, 0, c - 1)
    %{l | text: pre <> post, cur: c - 1}
  end

  @doc "Delete：删光标后一字符。"
  def delete(%__MODULE__{text: t, cur: c} = l) do
    {pre, post} = String.split_at(t, c)
    %{l | text: pre <> String.slice(post, 1, String.length(post))}
  end

  def left(%__MODULE__{cur: 0} = l), do: l
  def left(%__MODULE__{cur: c} = l), do: %{l | cur: c - 1}

  def right(%__MODULE__{text: t, cur: c} = l) do
    if c < String.length(t), do: %{l | cur: c + 1}, else: l
  end

  def home(%__MODULE__{} = l), do: %{l | cur: 0}
  def to_end(%__MODULE__{text: t} = l), do: %{l | cur: String.length(t)}

  @doc "Ctrl-U：删到行首。"
  def cut_to_start(%__MODULE__{cur: 0} = l), do: l
  def cut_to_start(%__MODULE__{text: t, cur: c} = l), do: %{l | text: String.slice(t, c..-1//1), cur: 0}

  @doc "Ctrl-W：删光标前一个词（含尾部空白，到下一处空白边界）。"
  def cut_word(%__MODULE__{cur: 0} = l), do: l

  def cut_word(%__MODULE__{text: t, cur: c} = l) do
    {pre, post} = String.split_at(t, c)
    # bash 式：空白 → 词 → 空白 一起删（"a b  c" Ctrl-W -> "a b"）
    {p1, n1} = trim_trailing_while(pre, &(&1 == "\s" or &1 == "\t"), 0)
    {p2, n2} = trim_trailing_while(p1, &(&1 != "\s" and &1 != "\t"), 0)
    {p3, n3} = trim_trailing_while(p2, &(&1 == "\s" or &1 == "\t"), 0)
    %{l | text: p3 <> post, cur: max(c - n1 - n2 - n3, 0)}
  end

  defp trim_trailing_while(s, pred, n) do
    case String.last(s) do
      nil -> {s, n}
      last -> if pred.(last), do: trim_trailing_while(String.slice(s, 0, String.length(s) - 1), pred, n + 1), else: {s, n}
    end
  end

  @doc "清空（提交后 / Esc）。"
  def clear(%__MODULE__{} = l), do: %{l | text: "", cur: 0, draft: nil}

  @doc "提交入历史（空行不记，与最后一条相同跳过）。"
  def push_hist(%__MODULE__{hist: h} = l, text) when text != "" do
    if List.last(h) == text do
      l
    else
      %{l | hist: h ++ [text], hcur: length(h) + 1}
    end
  end

  # ── 历史（↑/↓，codex 式：编辑中的行先存草稿）──

  def push_hist(l, _), do: l

  @doc "↑：向更早翻。hcur == length(hist) 表示正在编辑新行。"
  def hist_prev(%__MODULE__{hist: h, hcur: hc} = l) when hc > 0 do
    draft = if hc == length(h), do: l.text, else: l.draft
    idx = hc - 1
    entry = Enum.at(h, idx)
    %{l | hcur: idx, text: entry, cur: String.length(entry), draft: draft}
  end

  def hist_prev(l), do: l

  @doc "↓：向更新翻；翻到底恢复草稿。"
  def hist_next(%__MODULE__{hist: h, hcur: hc} = l) when hc < length(h) do
    idx = hc + 1

    if idx == length(h) do
      text = l.draft || ""
      %{l | hcur: idx, text: text, cur: String.length(text)}
    else
      entry = Enum.at(h, idx)
      %{l | hcur: idx, text: entry, cur: String.length(entry)}
    end
  end

  def hist_next(l), do: l

  @doc """
  Tab 补全：光标前 token 以 @ 开头 → 补全文件/目录路径；
  以 / 开头且光标在行首 → 补全命令；否则不变。
  补全候选取"最长公共前缀"；无候选原样返回。
  """
  def complete(%__MODULE__{text: t, cur: c} = l) do
    {prefix, rest} = split_at(t, c)
    {candidates, base} = complete_candidates(prefix)

    case candidates do
      [] ->
        l

      cands ->
        common = longest_common_prefix(cands)

        if String.length(common) > String.length(base) do
          %{l | text: prefix <> common <> rest, cur: c + (String.length(common) - String.length(base))}
        else
          l
        end
    end
  end

  defp split_at(t, c) do
    {String.slice(t, 0, c), String.slice(t, c..-1//1)}
  end

  defp complete_candidates(prefix) do
    cond do
      # @ 路径补全
      String.starts_with?(prefix, "@") ->
        base = String.trim_leading(prefix, "@")
        dir = Path.dirname(base)
        stem = Path.basename(base)

        entries =
          case File.ls(dir) do
            {:ok, list} -> list
            _ -> []
          end

        cands =
          Enum.filter(entries, &String.starts_with?(&1, stem))
          |> Enum.map(fn e ->
            p = Path.join(dir, e)
            if File.dir?(p), do: "@" <> p <> "/", else: "@" <> p
          end)

        {cands, prefix}

      # 命令补全：行首 / 
      Regex.match?(~r{^/[a-z]*$}, prefix) and String.starts_with?(prefix, "/") ->
        cmds = Newbee.Commands.commands()
        cands = Enum.filter(cmds, &String.starts_with?(&1, prefix))
        {cands, prefix}

      true ->
        {[], prefix}
    end
  end

  defp longest_common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn s, acc -> common_prefix(acc, s) end)
  end

  defp common_prefix(a, b) do
    a
    |> String.to_charlist()
    |> Enum.zip(String.to_charlist(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map(&elem(&1, 0))
    |> List.to_string()
  end

  # ── 宽度（CJK 双宽 / 组合符 0 / 其余 1）──

  @doc "字符显示宽度。"
  def char_width(ch) do
    cond do
      ch < 0x20 -> 0
      ch in 0x300..0x36F -> 0
      ch in 0x1100..0x115F -> 2
      ch in 0x2E80..0x303E -> 2
      ch == 0x303F -> 1
      ch in 0x3041..0x33FF -> 2
      ch in 0x3400..0x4DBF -> 2
      ch in 0x4E00..0x9FFF -> 2
      ch in 0xA000..0xA4CF -> 2
      ch in 0xAC00..0xD7A3 -> 2
      ch in 0xF900..0xFAFF -> 2
      ch in 0xFE30..0xFE4F -> 2
      ch in 0xFF00..0xFF60 -> 2
      ch in 0xFFE0..0xFFE6 -> 2
      ch in 0x1F300..0x1FAFF -> 2
      ch in 0x20000..0x3FFFD -> 2
      true -> 1
    end
  end

  @doc "字符串可见宽度。"
  def width(s), do: do_width(String.to_charlist(s), 0)

  defp do_width([], acc), do: acc
  defp do_width([cp | rest], acc), do: do_width(rest, acc + char_width(cp))

  @doc "光标屏幕列（含 “› ” 前缀 2 列）。"
  def cursor_col(%__MODULE__{text: t, cur: c}), do: 2 + width(String.slice(t, 0, c))

  @doc """
  横向滚动窗口：{可见文本, 光标在窗口内的列}。
  行宽超出 max_cols 时以光标为中心开窗，模拟 readline 滚动。
  """
  def scroll_view(%__MODULE__{text: t, cur: c}, max_cols) do
    total = width(t)

    if total <= max_cols do
      {t, width(String.slice(t, 0, c))}
    else
      cur_w = width(String.slice(t, 0, c))
      start = max(cur_w - div(max_cols, 2), 0) |> min(total - max_cols)
      {slice_by_width(t, start, max_cols), max(cur_w - start, 0)}
    end
  end

  defp slice_by_width(s, offset, w) do
    s
    |> String.to_charlist()
    |> do_slice(offset, w, [])
    |> List.to_string()
  end

  defp do_slice([], _off, _w, acc), do: Enum.reverse(acc)

  defp do_slice([cp | rest], off, w, acc) do
    cw = char_width(cp)

    cond do
      off > 0 -> do_slice(rest, off - cw, w, acc)
      w >= cw -> do_slice(rest, 0, w - cw, [cp | acc])
      true -> Enum.reverse(acc)
    end
  end
end