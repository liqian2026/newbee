defmodule Newbee.TUI.Key do
  @moduledoc """
  终端输入解码（纯函数）：字节流 -> 按键事件序列。

  职责：
  - UTF-8 多字节字符按 codepoint 解码（中文输入）
  - xterm 转义序列（方向键/Home/End/Delete/PageUp…）完整解析，残片绝不进正文
  - 括号粘贴模式（\e[200~…\e[201~）识别，粘贴正文整块交付
  - CSI 参数超长/畸形时安全丢弃，绝不死循环

  事件约定（发给 TUI 主循环）：
  - `{:key, ch}`            可打印字符（codepoint，含中文）
  - `{:key, name}`          :enter :backspace :esc :tab
                             :up :down :left :right :home :end
                             :delete :insert :page_up :page_down
  - 鼠标滚轮（SGR 模式）映射为 :page_up / :page_down。
  - `:paste_start` / `:paste_end`  括号粘贴边界（reader 维护粘贴缓冲）
  - `{:key, :unknown}`      识别不了的组合键（安全吞掉）
  """

  @type key ::
          char()
          | :enter
          | :backspace
          | :esc
          | :tab
          | :unknown
          | :up
          | :down
          | :left
          | :right
          | :home
          | :end
          | :delete
          | :insert
          | :page_up
          | :page_down

  @csi_final ~c"ABCDHFMPQR~abcdefghijklnopqsu@`|}{"

  # ── 对外 API ──

  @doc """
  喂入一段字节，返回 {事件列表, 剩余缓冲}。
  缓冲非空表示序列未完成（半截 UTF-8 / 半截 CSI），留给下一次喂。
  """
  @spec feed(binary(), binary()) :: {list(term()), binary()}
  def feed(buf \\ <<>>, data) do
    do_feed(buf <> data, [])
  end

  # ── 主状态机 ──

  defp do_feed(<<>>, events), do: {Enum.reverse(events), <<>>}

  defp do_feed(buf, events) do
    case next_event(buf) do
      {:event, ev, rest} -> do_feed(rest, [ev | events])
      :need_more -> {Enum.reverse(events), buf}
    end
  end

  defp next_event(<<3>> <> rest), do: {:event, {:key, :ctrl_c}, rest}
  defp next_event(<<4>> <> rest), do: {:event, {:key, :ctrl_d}, rest}
  defp next_event(<<1>> <> rest), do: {:event, {:key, :ctrl_a}, rest}
  defp next_event(<<5>> <> rest), do: {:event, {:key, :ctrl_e}, rest}
  defp next_event(<<9>> <> rest), do: {:event, {:key, :tab}, rest}
  defp next_event(<<12>> <> rest), do: {:event, {:key, :ctrl_l}, rest}
  defp next_event(<<13>> <> rest), do: {:event, {:key, :enter}, rest}
  # LF 也视为 Enter（部分终端/模拟输入发 \n 而非 \r）
  defp next_event(<<10>> <> rest), do: {:event, {:key, :enter}, rest}
  defp next_event(<<21>> <> rest), do: {:event, {:key, :ctrl_u}, rest}
  defp next_event(<<23>> <> rest), do: {:event, {:key, :ctrl_w}, rest}
  defp next_event(<<20>> <> rest), do: {:event, {:key, :ctrl_t}, rest}
  defp next_event(<<127>> <> rest), do: {:event, {:key, :backspace}, rest}

  # ESC：进入序列解析（必须在通用 C0 吞咽子句之前）
  defp next_event(<<27>> <> rest) do
    case parse_escape(rest) do
      {:seq, ev, remaining} -> {:event, ev, remaining}
      :need_more -> :need_more
    end
  end

  # 其余 C0 控制字节：吞掉
  defp next_event(<<ch>> <> rest) when ch < 32, do: {:event, {:key, :unknown}, rest}

  # 可打印 ASCII
  defp next_event(<<ch>> <> rest) when ch < 127, do: {:event, {:key, ch}, rest}

  # UTF-8 多字节
  defp next_event(<<first>> <> _ = buf) when first in 0xC0..0xF7 do
    case buf do
      <<ch::utf8, rest::binary>> -> {:event, {:key, ch}, rest}
      _ -> :need_more
    end
  end

  # 非法 UTF-8 首字节（0x80-0xBF 孤立续字节 / 0xF8+）：丢弃一字节
  defp next_event(<<_>> <> rest), do: {:event, {:key, :unknown}, rest}

  # ── 转义序列 ──

  # 括号粘贴边界在 CSI 首位特判
  defp parse_escape(<<"[", "200~", rest::binary>>), do: {:seq, :paste_start, rest}
  defp parse_escape(<<"[", "201~", rest::binary>>), do: {:seq, :paste_end, rest}
  # CSI 通用
  defp parse_escape(<<"[", rest::binary>>), do: parse_csi(rest, "")
  # SS3：\eO + 终结
  defp parse_escape(<<"O", final::binary-size(1), rest::binary>>) do
    ev =
      case final do
        "A" -> {:key, :up}
        "B" -> {:key, :down}
        "C" -> {:key, :right}
        "D" -> {:key, :left}
        "H" -> {:key, :home}
        "F" -> {:key, :end}
        _ -> {:key, :unknown}
      end

    {:seq, ev, rest}
  end

  # \e\e：Alt 组合常见双 Esc，按一次裸 Esc
  defp parse_escape(<<"\e", rest::binary>>), do: {:seq, {:key, :esc}, rest}
  # ESC + 单字节（Alt-x 等）：安全吞
  defp parse_escape(<<_::binary-size(1), rest::binary>>), do: {:seq, {:key, :unknown}, rest}
  # 只有 ESC，后续未到
  defp parse_escape(<<>>), do: :need_more

  # ── CSI：参数区 + 终结字节 ──

  defp parse_csi(<<ch>> <> rest, params) when ch in ?0..?9 or ch == ?;,
    do: parse_csi(rest, params <> <<ch>>)

  # 私有模式前缀（? : < = >）与中间字节
  defp parse_csi(<<ch>> <> rest, params) when ch in [??, ?:, ?<, ?=, ?>, ?\s, ?!],
    do: parse_csi(rest, params <> <<ch>>)

  # 终结字节
  defp parse_csi(<<ch>> <> rest, params) when ch in @csi_final do
    {:seq, {:key, csi_key(params, ch)}, rest}
  end

  defp parse_csi(<<>>, _params), do: :need_more
  # 参数超长：序列作废，余下从零解析
  defp parse_csi(buf, params) when byte_size(params) > 16,
    do: {:seq, {:key, :unknown}, buf}

  # 参数位置出现怪字节：吞一字节继续吞序列
  defp parse_csi(<<_::binary-size(1), rest::binary>>, params),
    do: parse_csi(rest, params <> "?")

  defp csi_key("", ?A), do: :up
  defp csi_key("", ?B), do: :down
  defp csi_key("", ?C), do: :right
  defp csi_key("", ?D), do: :left
  defp csi_key("", ?H), do: :home
  defp csi_key("", ?F), do: :end
  defp csi_key("1", ?~), do: :home
  defp csi_key("7", ?~), do: :home
  defp csi_key("4", ?~), do: :end
  defp csi_key("8", ?~), do: :end
  defp csi_key("2", ?~), do: :insert
  defp csi_key("3", ?~), do: :delete
  defp csi_key("5", ?~), do: :page_up
  defp csi_key("6", ?~), do: :page_down
  # SGR 鼠标：64/65 分别是滚轮上/下；点击和移动事件不影响输入。
  defp csi_key("<64;" <> _rest, ?M), do: :page_up
  defp csi_key("<65;" <> _rest, ?M), do: :page_down
  # 带修饰（\e[1;5A 等）：mod=2 Shift、5 Ctrl——统一按主键处理
  defp csi_key("1", final) when final in ~c"ABCDHF", do: mod_key(final)
  defp csi_key(_, ?A), do: :up
  defp csi_key(_, ?B), do: :down
  defp csi_key(_, ?C), do: :right
  defp csi_key(_, ?D), do: :left
  defp csi_key(_, ?H), do: :home
  defp csi_key(_, ?F), do: :end
  defp csi_key(_, _), do: :unknown

  defp mod_key(?A), do: :up
  defp mod_key(?B), do: :down
  defp mod_key(?C), do: :right
  defp mod_key(?D), do: :left
  defp mod_key(?H), do: :home
  defp mod_key(?F), do: :end
  defp mod_key(_), do: :unknown

  @paste_end "\e[201~"

  @doc """
  粘贴态喂入：累积到 `\e[201~` 为止。
  返回 `{:done, paste_text, rest}` 或 `{:more, acc}`。

  必须对**累积缓冲**整体匹配结束标记：reader 每次只读 1 字节，
  对单字节分片匹配 6 字节标记永远不中（粘贴后输入全死的根因）。
  """
  def feed_paste(acc, data) do
    buf = acc <> data

    case String.split(buf, @paste_end, parts: 2) do
      [before, rest] -> {:done, before, rest}
      [_] -> {:more, buf}
    end
  end

  @doc """
  空闲超时触发时解析残留缓冲（reader 的 50ms 消歧窗口用）：
  孤立 ESC → 裸 Esc；其余（半截 UTF-8/CSI）继续等待。
  """
  def flush(<<27>>), do: {[{:key, :esc}], <<>>}
  def flush(buf), do: {[], buf}

  @doc """
  规整粘贴正文：\r\n -> \n、孤立 \r -> \n、去尾换行。
  reader 在 :paste_end 后调用，把累积缓冲一次性交付。
  """
  def extract_paste(buf) do
    text =
      buf
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.trim_trailing("\n")

    {:paste, text}
  end
end
