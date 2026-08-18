defmodule Newbee.TUI do
  @moduledoc """
  codex 式单列流式 TUI (DESIGN §5.1/§5.2)：全屏 ANSI 渲染。
  布局：上方滚动输出区 + 底部分隔线 + 输入行 + 状态栏。

  架构（M6 重写）：
  - Newbee.TUI.Key    按键解码（转义序列/UTF-8/粘贴）
  - Newbee.TUI.Line   行编辑（双宽光标/历史/横向滚动/Tab 补全）
  - Newbee.TUI.Screen 双缓冲渲染（diff 重画，无闪烁）
  - Newbee.Markdown   markdown 渲染（done/ask 摘要）

  终端底层（零 C 依赖的唯一可行组合）：
  - elixir wrapper 以 `erl -noshell` 启动：BEAM stdin=/dev/null 且失去 ctty，
    子进程 stty / /dev/tty 全部不可用；raw 模式由外层启动脚本预设
    （`stty raw -echo` + trap 恢复），见 bin/newbee
  - 按键经 IO.getn 走 BEAM tty_sl 端口读入，逐字节即时返回

  交互（对齐 codex / pi）：
  - Enter 发送 · `\` 续行 · ↑/↓ 历史 · Tab 补全（@路径 / 命令）
  - Esc 中断模型执行 · Ctrl-C 清输入/退出 · Ctrl-L 重绘
  - PgUp/PgDn 翻屏 · Tab 展开/折叠工具块
  """

  alias Newbee.TUI.{Key, Line, Screen}

  defstruct lines: [],
            line_ed: %Line{},
            kernel: nil,
            client: nil,
            busy: false,
            submit_pid: nil,
            screen: nil,
            page: 0,
            streaming: false,
            stream_kind: nil,
            render_pending: false,
            tool_blocks: %{},
            tool_open: %{},
            usage: %{},
            last_paint: 0

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
      |> push_line("\e[2m↑↓ 历史 · PgUp/PgDn 翻屏 · Tab 补全 · Esc 中断 · Ctrl-C 退出 · Ctrl-L 重绘\e[0m")
      |> push_line("\e[2msession: #{session_id(kernel)}\e[0m")

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

  # paste 态：累积可打印字符，直到 :paste_end
  defp reader_loop(parent, buf, :paste, paste_buf) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:paste, paste_buf})

      {:error, _} ->
        :ok

      ch ->
        {events, rest} = Key.feed(buf, ch)

        {paste_buf, events} =
          Enum.reduce(events, {paste_buf, []}, fn ev, {acc, evs} ->
            case ev do
              {:key, cp} when is_integer(cp) -> {acc <> <<cp::utf8>>, evs}
              :paste_end -> {acc, evs ++ [{:paste_done, acc}]}
              _ -> {acc, evs}
            end
          end)

        Enum.each(events, fn
          {:paste_done, text} -> send(parent, {:paste, text})
          other -> send(parent, other)
        end)

        if :lists.keymember(:paste_done, 1, events) do
          reader_loop(parent, rest, :normal, <<>>)
        else
          reader_loop(parent, rest, :paste, paste_buf)
        end
    end
  end

  defp reader_loop(parent, buf, :normal, _) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:key, :ctrl_d})

      {:error, _} ->
        :ok

      ch ->
        {events, rest} = Key.feed(buf, ch)

        Enum.each(events, fn
          :paste_start -> send(parent, {:paste_start, :ok})
          other -> send(parent, other)
        end)

        if :paste_start in events do
          reader_loop(parent, rest, :paste, <<>>)
        else
          reader_loop(parent, rest, :normal, <<>>)
        end
    end
  end

  # ── 主循环 ──

  defp loop(state, reader) do
    receive do
      {:key, :ctrl_c} ->
        if state.line_ed.text == "" do
          # 空输入时 Ctrl-C 退出（codex 行为）
          :ok
        else
          state = %{state | line_ed: Line.clear(state.line_ed)}
          paint(state)
          loop(state, reader)
        end

      {:key, :ctrl_l} ->
        paint(state, true)
        loop(state, reader)

      {:key, :enter} ->
        state = submit(state, reader)

        if state.busy do
          loop(state, reader)
        else
          loop(state, reader)
        end

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

      {:key, :tab} ->
        state = %{state | line_ed: Line.complete(state.line_ed)}
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

      {:key, :escape} ->
        if state.busy do
          # 中断模型执行
          Newbee.LLM.Client.interrupt()
          state = state |> push_line("\e[31m⏹ 已请求中断…\e[0m")
          paint(state)
          loop(state, reader)
        else
          # 清输入
          state = %{state | line_ed: Line.clear(state.line_ed)}
          paint(state)
          loop(state, reader)
        end

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
        loop(state, reader)

      {:newbee_event, topic, payload} ->
        state = state |> render_event(topic, payload) |> schedule_paint()
        loop(state, reader)

      {:paint, :now} ->
        paint(state)
        loop(state, reader)
    end
  end

  # ── 提交 ──

  defp submit(state, reader) do
    text = String.trim_trailing(state.line_ed.text)

    if text == "" do
      state
    else
      Newbee.TUI.History.append(text)

      state =
        state
        |> push_line("\e[32m›\e[0m " <> text)
        |> Map.put(:line_ed, %Line{hist: state.line_ed.hist, hcur: length(state.line_ed.hist)})
        |> Map.put(:busy, true)

      paint(state)

      ctx = %{say: fn line -> send(self(), {:newbee_event, :tui_say, {:tui_say, line}}) end, kernel: state.kernel}

      case Newbee.Commands.handle(text, ctx) do
        :quit ->
          send(reader, {:key, :ctrl_c})
          state

        :ok ->
          %{state | busy: false}

        :handled ->
          %{state | busy: false}

        {:submit, text} ->
          run_submit(state, text)

        {:resume, id} ->
          GenServer.stop(state.kernel)
          {:ok, kernel2} = resume_kernel(state.client, id)
          %{state | kernel: kernel2, busy: false}

        {:resume_picker, metas} ->
          print_metas(state, metas)
          %{state | busy: false}
      end
    end
  end

  defp run_submit(state, text) do
    parent = self()

    # 异步跑 turn：主循环继续处理输入/中断
    caller =
      spawn_link(fn ->
        case Newbee.DEE.Kernel.submit(state.kernel, text) do
          {:done, summary} ->
            send(parent, {:newbee_event, :done, {:done, summary}})
            send(parent, {:newbee_event, :turn_done, {:turn_done, nil}})

          {:ask, q} ->
            send(parent, {:newbee_event, :ask, {:ask, q}})
            send(parent, {:newbee_event, :turn_done, {:turn_done, nil}})

          {:text, _} ->
            send(parent, {:newbee_event, :turn_done, {:turn_done, nil}})

          {:error, e} ->
            send(parent, {:newbee_event, :error, {:error, e}})
            send(parent, {:newbee_event, :turn_done, {:turn_done, nil}})

          {:interrupted, content} ->
            send(parent, {:newbee_event, :interrupted, {:interrupted, content}})
            send(parent, {:newbee_event, :turn_done, {:turn_done, nil}})
        end
      end)

    %{state | busy: true, submit_pid: caller}
  end

  defp resume_kernel(client, id) do
    {:ok, kernel} = Newbee.DEE.Kernel.start_link(client: client, session_id: id, render: fn _ -> :ok end)
    meta = Newbee.Session.meta(id)
    send(self(), {:newbee_event, :tui_say, {:tui_say, "已恢复会话 #{id} · #{meta.messages} 条消息 · #{meta.title}"}})
    {:ok, kernel}
  end

  defp print_metas(state, metas) do
    lines =
      Enum.with_index(metas, 1)
      |> Enum.map(fn {m, i} -> "  [#{i}] #{m.id} · #{m.when_str} · #{m.messages} 条 · #{m.title}" end)

    send(self(), {:newbee_event, :tui_say, {:tui_say, Enum.join(["最近会话:" | lines], "\n")}})
    state
  end

  # ── 事件渲染（公开 API，测试契约）──

  @doc "追加一行到 transcript；重置 streaming 状态。"
  def push_line(%__MODULE__{} = state, line) do
    lines = state.lines ++ [line] |> Enum.take(-@scrollback)
    %{state | lines: lines, streaming: false, stream_kind: nil, render_pending: false}
  end

  @doc """
  渲染一个总线事件。返回新 state。
    - :text      正文流（首 delta 开新行，后续追加；stream_kind=:text）
    - :reasoning 思考流（灰色，独立流）
    - 其余 topic 渲染成一行后 push_line
  """
  def render_event(%__MODULE__{} = state, :text, {:text, delta}) do
    if state.streaming and state.stream_kind == :text do
      append_text(state, delta)
    else
      state
      |> push_line("")
      |> Map.put(:streaming, true)
      |> Map.put(:stream_kind, :text)
      |> append_text(delta)
    end
  end

  def render_event(%__MODULE__{} = state, :reasoning, {:reasoning, delta}) do
    if state.streaming and state.stream_kind == :reasoning do
      append_text(state, delta, "\e[2m")
    else
      state
      |> push_line("\e[2m")
      |> Map.put(:streaming, true)
      |> Map.put(:stream_kind, :reasoning)
      |> append_text(delta, "\e[2m")
    end
  end

  def render_event(%__MODULE__{} = state, :usage, {:usage, usage}) do
    %{state | usage: merge_usage(state.usage, usage)}
  end

  def render_event(%__MODULE__{} = state, :tool_start, {:tool_start, name, title, code}) do
    {block, line} = tool_block(name, title, code)
    push_line(state, line) |> Map.put(:last_block, block)
  end

  def render_event(%__MODULE__{} = state, :tool_result, {:tool_result, name, text}) do
    line = tool_result_line(name, text)
    push_line(state, line)
  end

  def render_event(%__MODULE__{} = state, :tool_error, {:tool_error, text}) do
    push_line(state, "\e[31m✗\e[0m " <> String.slice(text, 0, 400))
  end

  def render_event(%__MODULE__{} = state, :rule_hit, {:rule_hit, hits}) do
    lines = Enum.map(hits, &"\e[33m⚑ 沉睡规则命中 [#{&1.id}]\e[0m \e[2m#{&1.injection}\e[0m")
    Enum.reduce(lines, state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :audit, {:audit, :dangerous_code, hits}) do
    push_line(state, "\e[31m⚖ 审计: 危险代码模式 #{inspect(hits)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :audit, {:audit, verdict, actor, target, ring}) do
    push_line(state, "\e[2m⚖ 审计: #{verdict} #{actor} → ring#{ring} #{inspect(target) |> String.slice(0, 60)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :error, {:error, e}) do
    push_line(state, "\e[31m#{inspect(e)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :done, {:done, summary}) do
    push_line(state, "\e[1m● \e[0m" <> Newbee.Markdown.render(summary))
  end

  def render_event(%__MODULE__{} = state, :ask, {:ask, q}) do
    push_line(state, "\e[33m? \e[0m" <> Newbee.Markdown.render(q))
  end

  def render_event(%__MODULE__{} = state, :interrupted, {:interrupted, content}) do
    state = push_line(state, "\e[31m⏹ 已中断\e[0m")
    if content, do: push_line(state, content), else: state
  end

  def render_event(%__MODULE__{} = state, :turn_done, _) do
    %{state | busy: false}
  end

  def render_event(%__MODULE__{} = state, :tui_say, {:tui_say, text}) do
    Enum.reduce(String.split(text, "\n"), state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :progress, {:progress, score, scores}) do
    push_line(state, "\e[2m进度 #{Float.round(score, 1)}/20 #{Newbee.Evolution.Progress.render_scores(scores)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :progress_stall, {:progress_stall, scores}) do
    push_line(state, "\e[33m⚠ 进度停滞: #{Newbee.Evolution.Progress.render_scores(scores)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :goal_round, {:goal_round, round}) do
    push_line(state, "\e[2m（自主模式第 #{round} 轮）\e[0m")
  end

  def render_event(%__MODULE__{} = state, :goal_done, {:goal_done, summary}) do
    push_line(state, "\e[1m● 目标完成\e[0m " <> summary)
  end

  def render_event(%__MODULE__{} = state, :goal_limit, {:goal_limit, n}) do
    push_line(state, "\e[31m⏹ 目标达到轮数上限 #{n}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :goal_cancelled, _) do
    push_line(state, "\e[31m⏹ 目标已取消\e[0m")
  end

  def render_event(%__MODULE__{} = state, _topic, _payload) do
    state
  end

  # ── 流式追加 ──

  defp append_text(state, delta), do: append_text(state, delta, "")

  defp append_text(%__MODULE__{lines: lines} = state, delta, prefix) do
    %{state | lines: List.update_at(lines, -1, &(&1 <> prefix <> delta))}
  end

  defp merge_usage(a, b) when is_map(b) do
    Map.merge(a, b, fn _k, x, y -> (to_num(x) || 0) + (to_num(y) || 0) end)
  end

  defp merge_usage(a, _), do: a
  defp to_num(n) when is_number(n), do: n
  defp to_num(_), do: nil

  # ── 工具块 ──

  defp tool_block(name, title, code) do
    preview = code |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")
    ellipsis = if String.contains?(code, "\n"), do: " …", else: ""
    {code, "\e[36m⏺\e[0m \e[1m#{name}\e[0m \e[2m#{title}\e[0m\n\e[2m  #{preview}#{ellipsis}\e[0m"}
  end

  defp tool_result_line(_name, text) do
    {mark, body} =
      case text do
        "✓ ok\n" <> rest -> {"\e[32m  ⎿ ✓\e[0m", rest}
        "✗ error\n" <> rest -> {"\e[31m  ⎿ ✗\e[0m", rest}
        other -> {"\e[36m  ⎿\e[0m", other}
      end

    preview = body |> String.split("\n") |> Enum.take(6) |> Enum.join("\n    ")
    mark <> " " <> preview
  end

  # ── 渲染 ──

  defp schedule_paint(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_paint > 30 do
      send(self(), {:paint, :now})
      %{state | last_paint: now}
    else
      %{state | render_pending: true}
    end
  end

  defp paint(state, force \\ false) do
    {cols, rows} = terminal_size()
    status = {status_line(state), {rows, Line.cursor_col(state.line_ed)}}
    input_view = input_view(state)

    screen =
      if state.screen == nil or force or state.screen.cols != cols do
        Screen.paint_full(state.lines, input_view, status, cols, rows)
      else
        Screen.paint_delta(state.screen, state.lines, input_view, status, cols, rows)
      end

    %{state | screen: screen, render_pending: false}
  end

  defp status_line(state) do
    usage = state.usage
    tokens = Map.get(usage, "total_tokens", 0)

    bindings =
      if Process.whereis(Newbee.DEE.Evaluator) do
        case Newbee.DEE.Evaluator.bindings_summary() do
          bs when is_list(bs) -> length(bs)
          _ -> 0
        end
      else
        0
      end

    "\e[2m#{state.client.model} · #{Path.basename(File.cwd!())} · " <>
      "tokens: #{tokens} · bindings: #{bindings} · policy: #{Newbee.Evolution.Policy.get()}\e[0m"
  end

  defp input_view(state) do
    prefix = if state.busy, do: "\e[33m…\e[0m ", else: "\e[32m›\e[0m "
    {line, _cur_col} = Line.scroll_view(state.line_ed, terminal_cols() - 4)
    prefix <> line
  end

  defp terminal_size do
    # erl -noshell 下无法 ioctl；外层脚本传入或默认 80x24
    cols = terminal_cols()
    rows = String.to_integer(System.get_env("NEWBEE_ROWS") || "24")
    {cols, rows}
  end

  defp terminal_cols do
    String.to_integer(System.get_env("NEWBEE_COLS") || "100")
  end

  defp tty? do
    case :file.read_link("/proc/self/fd/0") do
      {:ok, target} -> not String.starts_with?(target, "/dev/null") and not String.starts_with?(target, "pipe")
      _ -> true
    end
  end

  defp session_id(kernel) do
    :sys.get_state(kernel).session |> case do
      nil -> "(off)"
      s -> s.id
    end
  end
end
