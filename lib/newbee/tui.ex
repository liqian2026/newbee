defmodule Newbee.TUI do
  @moduledoc """
  codex 式单列流式 TUI (DESIGN §5.1/§5.2)：全屏 ANSI 渲染。
  布局：上方滚动输出区 + 底部分隔线 + 输入行。

  架构（M6 重写）：
  - Newbee.TUI.Key    按键解码（转义序列/UTF-8/粘贴）
  - Newbee.TUI.Line   行编辑（双宽光标/历史/横向滚动）
  - Newbee.TUI.Screen 双缓冲渲染（diff 重画，无闪烁）

  终端底层（关键经验，零 C 依赖的唯一可行组合）：
  - elixir wrapper 以 `erl -noshell` 启动：BEAM stdin=/dev/null 且失去 ctty，
    子进程 stty / /dev/tty 全部不可用（"Inappropriate ioctl" / ENXIO）
  - 因此 raw 模式由外层启动脚本预设（`stty raw -echo` + trap 恢复），
    见 ~/.local/bin/newbee；TUI 进程内不再改 termios
  - 按键经 IO.getn 走 BEAM tty_sl 端口读入（getopts 显示 terminal: true），
    该路径逐字节即时返回，转义序列/中文流均完整

  启动：`newbee`（推荐）或 `mix newbee.tui`（需在真实终端手动保证 raw）。
  """

  alias Newbee.TUI.{Key, Line, Screen}

  defstruct lines: [],
            line_ed: %Line{},
            kernel: nil,
            client: nil,
            busy: false,
            screen: nil,
            page: 0,
            streaming: false,
            stream_kind: nil,
            md_buf: "",
            md_start: 0,
            render_pending: false

  @scrollback 5_000

  def start do
    client = Newbee.LLM.Config.client_for()

    unless client.api_key do
      IO.puts("\e[31m缺少 API key：检查 ~/.newbee/model.json\e[0m")
      System.halt(1)
    end

    unless tty?() do
      IO.puts("\e[31mTUI 需要真实终端（tty）。请直接运行 mix newbee 使用 CLI。\e[0m")
      System.halt(1)
    end

    Task.start(fn -> Newbee.LLM.Client.prewarm(client) end)
    Newbee.Bus.subscribe()

    {:ok, kernel} = Newbee.DEE.Kernel.start_link(client: client, render: fn _ -> :ok end)

    # 备用屏 + 隐藏光标 + 括号粘贴模式（粘贴不再被逐键解释）
    IO.write("\e[?1049h\e[?25l\e[?2004h")

    hist = Newbee.TUI.History.load()
    state = %__MODULE__{kernel: kernel, client: client, line_ed: %Line{hist: hist, hcur: length(hist)}}

    state =
      state
      |> push_line("\e[1mnewbee\e[0m TUI - #{client.model} · policy=#{Newbee.Evolution.Policy.get()}")
      |> push_line("\e[2m命令: #{Enum.join(Newbee.Commands.commands(), " ")}\e[0m")
      |> push_line("\e[2m↑↓ 历史(跨会话) · PgUp/PgDn 翻屏 · Ctrl-W 删词 · Ctrl-U 清行 · Ctrl-C 退出 · Esc 中断/清输入\e[0m")
      |> push_line("\e[2msession: #{session_id(kernel)}\e[0m")

    # parent 必须在 spawn 之外捕获：fn 里的 self() 是 reader 自己
    parent = self()
    reader = spawn_link(fn -> reader_loop(parent, <<>>, :normal, <<>>) end)

    try do
      paint(state, true)
      loop(state, reader)
    after
      IO.write("\e[?2004l\e[?25h\e[?1049l")
      Newbee.Bus.unsubscribe()
    end
  end

  # ── 输入 reader 进程：tty_sl 字节 -> 事件 ──

  # buf: 未决序列缓冲；paste 态下 paste_buf 累积粘贴正文
  defp reader_loop(parent, buf, :normal, _) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:key, :ctrl_d})

      {:error, _} ->
        :ok

      ch ->
        {events, rest} = Key.feed(buf, ch)
        dispatch_events(parent, events, rest)
    end
  end

  defp reader_loop(parent, buf, :paste, paste_buf) do
    case IO.getn("", 1) do
      :eof -> send(parent, {:paste, Key.extract_paste(paste_buf)})
      {:error, _} -> :ok
      ch -> consume_paste(parent, buf <> ch, paste_buf)
   
… [compressed: 10015 bytes, 2 lines; 用 binding 变量或写文件后再局部读取] …
3a3b|         submit(state, reader)

      {:key, :backspace} ->
        state = %{state | line_ed: Line.backspace(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :delete} ->
        state = %{state | line_ed: Line.delete(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :left} ->
        state = %{state | line_ed: Line.left(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :right} ->
        state = %{state | line_ed: Line.right(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :home} ->
        state = %{state | line_ed: Line.home(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :end} ->
        state = %{state | line_ed: Line.to_end(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :ctrl_u} ->
        state = %{state | line_ed: Line.cut_to_start(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :ctrl_w} ->
        state = %{state | line_ed: Line.cut_word(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :up} ->
        state = %{state | line_ed: Line.hist_prev(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :down} ->
        state = %{state | line_ed: Line.hist_next(state.line_ed)}
        paint(state)
        loop(state, reader)

      {:key, :page_up} ->
        state = %{state | page: min(state.page + 1, 50)}
        paint(state, true)
        loop(state, reader)

      {:key, :page_down} ->
        state = %{state | page: max(state.page - 1, 0)}
        paint(state, true)
        loop(state, reader)

      {:key, ch} when is_integer(ch) ->
        state = %{state | line_ed: Line.insert(state.line_ed, <<ch::utf8>>)}
        paint(state)
        loop(state, reader)

      {:key, _unknown} ->
        loop(state, reader)

      {:paste, text} when byte_size(text) > 0 ->
        state = %{state | line_ed: Line.insert(state.line_ed, text)}
        paint(state)
        loop(state, reader)

      {:paste, _empty} ->
        loop(state, reader)

      {:newbee_event, topic, payload} when topic in [:text, :reasoning] ->
        state = state |> render_event(topic, payload) |> schedule_paint()
        loop(st…(truncated)