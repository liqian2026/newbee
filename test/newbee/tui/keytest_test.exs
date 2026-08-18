defmodule Newbee.TUI.KeyTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Key

  describe "feed/2 可打印字符" do
    test "ASCII 逐字符出事件" do
      assert {events, ""} = Key.feed("ab")
      assert events == [{:key, ?a}, {:key, ?b}]
    end

    test "中文 3 字节 UTF-8 解出单 codepoint" do
      assert {events, ""} = Key.feed("中")
      assert events == [{:key, 0x4E2D}]
    end

    test "半截 UTF-8 留缓冲，补齐后解出" do
      <<a, b, c>> = "文"
      {e1, rest} = Key.feed(<<a>>)
      assert e1 == []
      assert byte_size(rest) == 1
      {e2, rest2} = Key.feed(rest, <<b>>)
      assert e2 == []
      {e3, ""} = Key.feed(rest2, <<c>>)
      assert e3 == [{:key, 0x6587}]
    end

    test "孤立续字节（非法 UTF-8）被丢弃不炸" do
      assert {[{:key, :unknown}], ""} = Key.feed(<<0x80>>)
    end
  end

  describe "feed/2 控制键" do
    test "Enter/Backspace/Ctrl 组合" do
      assert {[{:key, :enter}], ""} = Key.feed("\r")
      assert {[{:key, :backspace}], ""} = Key.feed("\x7f")
      assert {[{:key, :ctrl_c}], ""} = Key.feed("\x03")
      assert {[{:key, :ctrl_u}], ""} = Key.feed("\x15")
      assert {[{:key, :ctrl_w}], ""} = Key.feed("\x17")
    end
  end

  describe "feed/2 转义序列" do
    test "方向键完整解出，残片绝不进正文" do
      assert {[{:key, :up}], ""} = Key.feed("\e[A")
      assert {[{:key, :down}], ""} = Key.feed("\e[B")
      assert {[{:key, :right}], ""} = Key.feed("\e[C")
      assert {[{:key, :left}], ""} = Key.feed("\e[D")
    end

    test "半截 CSI 留缓冲等后续字节（旧实现 5ms 窗口丢字根因）" do
      {e1, rest} = Key.feed("\e[")
      assert e1 == []
      assert rest == "\e["
      assert {[{:key, :up}], ""} = Key.feed(rest, "A")
    end

    test "Home/End/Delete/PageUp 各形态" do
      assert {[{:key, :home}], ""} = Key.feed("\e[H")
      assert {[{:key, :home}], ""} = Key.feed("\eOH")
      assert {[{:key, :home}], ""} = Key.feed("\e[1~")
      assert {[{:key, :end}], ""} = Key.feed("\e[F")
      assert {[{:key, :end}], ""} = Key.feed("\e[4~")
      assert {[{:key, :delete}], ""} = Key.feed("\e[3~")
      assert {[{:key, :page_up}], ""} = Key.feed("\e[5~")
      assert {[{:key, :page_down}], ""} = Key.feed("\e[6~")
    end

    test "SGR 鼠标滚轮映射为输出翻页" do
      assert {[{:key, :page_up}], ""} = Key.feed("\e[<64;20;10M")
      assert {[{:key, :page_down}], ""} = Key.feed("\e[<65;20;10M")
    end

    test "带修饰键序列（Ctrl+方向键）按主键处理" do
      assert {[{:key, :up}], ""} = Key.feed("\e[1;5A")
    end

    test "SS3 序列" do
      assert {[{:key, :up}], ""} = Key.feed("\eOA")
      assert {[{:key, :left}], ""} = Key.feed("\eOD")
    end

    test "混合流：方向键后跟中文不出伪字符" do
      assert {[{:key, :left}, {:key, 0x4E2D}], ""} = Key.feed("\e[D中")
    end
  end

  describe "括号粘贴" do
    test "起止边界识别" do
      assert {[:paste_start], ""} = Key.feed("\e[200~")
      assert {[:paste_end], ""} = Key.feed("\e[201~")
    end

    test "extract_paste 规整换行" do
      assert {:paste, "a\nb\nc"} = Key.extract_paste("a\r\nb\rc\n\r\n")
    end

    test "feed_paste 逐字节喂入：结束标记跨片也能识别（粘贴后输入卡死根因）" do
      # 模拟 reader 每次 1 字节：结束标记 \e[201~ 分 6 片到达
      bytes = String.to_charlist("粘贴内容\e[201~")

      result =
        Enum.reduce(bytes, {:more, ""}, fn cp, {:more, acc} ->
          Key.feed_paste(acc, <<cp::utf8>>)
        end)

      assert {:done, "粘贴内容", ""} = result
    end

    test "feed_paste 结束标记后的按键字节原样返回" do
      assert {:done, "abc", "x"} = Key.feed_paste("", "abc\e[201~x")
    end

    test "feed_paste 无结束标记持续累积" do
      assert {:more, "ab"} = Key.feed_paste("a", "b")
    end
  end

  describe "健壮性" do
    test "参数超长的畸形 CSI 被丢弃且不吞后续正文" do
      garbage = "\e[" <> String.duplicate("1", 40) <> "m"
      assert {events, ""} = Key.feed(garbage <> "x")
      assert {:key, ?x} in events
      refute {:key, ?1} in events
    end
  end
end
