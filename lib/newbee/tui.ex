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
            submit_kind: nil,
            pending_inputs: [],
            picker: nil,
            screen: nil,
            page: 0,
            streaming: false,
            stream_kind: nil,
            render_pending: false,
            tool_blocks: %{},
            last_block_id: nil,
            show_reasoning: true,
            tool_open: %{},
            usage: %{},
            pane: nil,
            out: nil,
            awaiting_permission: false,
            text_buffer: <<>>,
            last_paint: 0,
            bindings_cache: [],
            bindings_cache_at: 0,
            spinner_idx: 0

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

    {:ok, kernel} =
      Newbee.DEE.Kernel.start_link(client: client, auto_antibodies: true, render: fn _ -> :ok end)

    # 输出走独立 fd 端口：IO.getn 挂起时 group leader 会排队所有输出
    # （"不输入就不输出"的根因），端口直写 tty 与输入解耦。
    out = Screen.open_port()

    # 备用屏 + 隐藏光标 + 括号粘贴模式（粘贴不再被逐键解释）
    Port.command(out, "\e[?1049h\e[?25l\e[?2004h")

    hist = Newbee.TUI.History.load()

    state = %__MODULE__{
      kernel: kernel,
      client: client,
      out: out,
      line_ed: %Line{hist: hist, hcur: length(hist)}
    }

    state =
      state
      |> push_line("\e[1mnewbee\e[0m TUI - #{client.model} · policy=#{Newbee.Evolution.Policy.get()}")
      |> push_line("\e[2m命令: #{Enum.join(Newbee.Commands.commands(), " ")}\e[0m")
      |> push_line("\e[2m↑↓ 历史 · PgUp/PgDn 翻屏 · Tab 补全 · Esc 中断 · Ctrl-C 退出 · Ctrl-L 重绘 · Ctrl-T 窗格/队列\e[0m")
      |> push_line("\e[2msession: #{session_id(kernel)}\e[0m")

    parent = self()
    # 字节泵（独占阻塞读）+ 事件 reader（receive 驱动）：
    # reader 的 50ms 空闲超时消歧孤立 ESC——Esc 中断才能即时响应。
    # 泵必须把原始字节发给 reader，而不是发给 TUI 主循环；主循环只接收
    # reader 解码后的 {:key, ...} 事件，否则输入会被静默丢弃。
    reader = spawn_link(fn -> reader_loop(parent, <<>>, :normal, <<>>) end)
    spawn_link(fn -> pump(reader) end)

    try do
      loop(paint(state, true), reader)
    after
      # reader 此刻可能仍阻塞在 IO.getn：绝不能用 IO.write（会死锁到下一按键）
      Port.command(out, "\e[?2004l\e[?25h\e[?1049l")
      Newbee.Bus.unsubscribe()
    end
  end

  # ── 输入：字节泵 + 事件 reader（tty_sl 字节 -> 事件）──

  # 字节泵：独占阻塞读（IO.getn），字节即时消息化发给 reader。
  # 与 reader 分离后，reader 才能用 receive-timeout 消歧孤立 ESC。
  defp pump(parent) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:tty_eof, :ok})

      {:error, _} ->
        :ok

      ch ->
        send(parent, {:tty, ch})
        pump(parent)
    end
  end

  # paste 态：累积可打印字符，直到 :paste_end
  defp reader_loop(parent, buf, :paste, paste_buf) do
    receive do
      {:tty, ch} ->
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

      {:tty_eof, :ok} ->
        send(parent, {:paste, paste_buf})
    end
  end

  defp reader_loop(parent, buf, :normal, _) do
    # 缓冲里只有孤立 ESC 时启用 50ms 空闲超时（xterm 同款消歧）：
    # 无后续字节 → 裸 Esc（中断即时响应）；有后续字节（方向键等）→ 正常解析
    timeout = if buf == <<27>>, do: 50, else: :infinity

    receive do
      {:tty, ch} ->
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

      {:tty_eof, :ok} ->
        send(parent, {:key, :ctrl_d})
    after
      timeout ->
        # 孤立 ESC 空闲超时：Key.flush 按裸 Esc 发出
        {events, rest} = Key.flush(buf)
        Enum.each(events, &send(parent, &1))
        reader_loop(parent, rest, :normal, <<>>)
    end
  end

  # ── 主循环 ──

  defp loop(state, reader) do
    receive do
      {:key, key} ->
        if state.picker do
          case handle_picker_key(state, key) do
            :quit ->
              :ok

            {state, force} ->
              loop(paint(state, force), reader)
          end
        else
          if state.awaiting_permission do
            # 权限确认流（§8 ask 档）：y/Enter 允许，其余拒绝
            ok = key in [?y, ?Y] or key == :enter
            send(state.kernel, {:permission_reply, ok})

            state =
              state
              |> Map.put(:awaiting_permission, false)
              # 权限回复只是结束询问，当前 kernel 回合仍在继续；保持 busy，
              # 之后按 Enter 的内容进入显式队列。
              |> Map.put(:busy, true)
              |> push_line(if ok, do: "\e[32m✓ 已允许执行\e[0m", else: "\e[31m✗ 已拒绝执行\e[0m")

            loop(paint(state), reader)
          else
            case handle_key(state, reader, key) do
              :quit ->
                :ok

              {state, force} ->
                loop(paint(state, force), reader)
            end
          end
        end

      {:paste, text} when byte_size(text) > 0 ->
        state = %{state | line_ed: Line.insert(state.line_ed, text)}
        loop(paint(state), reader)

      {:paste, _empty} ->
        loop(state, reader)

      {:newbee_event, topic, payload} ->
        state = state |> render_event(topic, payload) |> schedule_paint()
        state = if topic == :turn_done, do: maybe_start_next(state), else: state
        loop(state, reader)

      {:shell_done, cmd, result} ->
        output = String.slice(result.output, 0, 8_000)

        state =
          state
          |> push_line(Newbee.TUI.Cards.shell_header(cmd))
          |> then(fn s -> Enum.reduce(String.split(output, "\n"), s, &push_line(&2, &1)) end)
          |> push_line(Newbee.TUI.Cards.shell_footer(result))
          |> Map.merge(%{busy: false, submit_pid: nil, submit_kind: nil})
          |> maybe_start_next()

        loop(paint(state), reader)

      {:paint, :now} ->
        loop(paint(state), reader)

      :spinner_tick ->
        if state.busy do
          Process.send_after(self(), :spinner_tick, 80)
          loop(paint(state), reader)
        else
          loop(state, reader)
        end
    end
  end

  # 普通按键处理（权限确认由 loop 先拦截）。返回 :quit | {state, force_paint?}。
  defp handle_key(state, reader, key) do
    case key do
      :ctrl_a ->
        {%{state | line_ed: Line.home(state.line_ed)}, false}

      :ctrl_e ->
        {%{state | line_ed: Line.to_end(state.line_ed)}, false}

      :ctrl_b ->
        {%{state | line_ed: Line.left(state.line_ed)}, false}

      :ctrl_f ->
        {%{state | line_ed: Line.right(state.line_ed)}, false}

      :ctrl_h ->
        {%{state | line_ed: Line.backspace(state.line_ed)}, false}

      :ctrl_d ->
        # 空行时 Ctrl-D 退出（unix 习惯），否则删后一字符
        if state.line_ed.text == "" do
          :quit
        else
          {%{state | line_ed: Line.delete(state.line_ed)}, false}
        end

      :ctrl_p ->
        {%{state | line_ed: Line.hist_prev(state.line_ed)}, false}

      :ctrl_n ->
        {%{state | line_ed: Line.hist_next(state.line_ed)}, false}

      :ctrl_c ->
        # 空输入时 Ctrl-C 退出（codex 行为）
        if state.line_ed.text == "", do: :quit, else: {%{state | line_ed: Line.clear(state.line_ed)}, false}

      :ctrl_l ->
        {state, true}

      :enter ->
        {submit(state, reader), false}

      :backspace ->
        {%{state | line_ed: Line.backspace(state.line_ed)}, false}

      :delete ->
        {%{state | line_ed: Line.delete(state.line_ed)}, false}

      :left ->
        {%{state | line_ed: Line.left(state.line_ed)}, false}

      :right ->
        {%{state | line_ed: Line.right(state.line_ed)}, false}

      :home ->
        {%{state | line_ed: Line.home(state.line_ed)}, false}

      :end ->
        {%{state | line_ed: Line.to_end(state.line_ed)}, false}

      :ctrl_u ->
        {%{state | line_ed: Line.cut_to_start(state.line_ed)}, false}

      :ctrl_k ->
        {%{state | line_ed: Line.cut_to_end(state.line_ed)}, false}

      :ctrl_y ->
        {%{state | line_ed: Line.yank(state.line_ed)}, false}

      :ctrl_t ->
        # Ctrl+T 切换可选窗格（DESIGN §5.2）：绑定 / 事件日志 / 工具块
        {%{state | pane: next_pane(state.pane)}, true}

      :ctrl_w ->
        {%{state | line_ed: Line.cut_word(state.line_ed)}, false}

      :tab ->
        # 空输入时 Tab = 展开/收起最近工具块（§5.1 折叠块）；有输入时 Tab = 补全
        if state.line_ed.text == "" and state.last_block_id do
          case Map.get(state.tool_blocks, state.last_block_id) do
            nil ->
              {%{state | line_ed: Line.complete(state.line_ed)}, false}

            block ->
              if Map.get(state.tool_open, block.id) do
                {state, false}
              else
                state = expand_block(state, block)
                {state, true}
              end
          end
        else
          {%{state | line_ed: Line.complete(state.line_ed)}, false}
        end

      :up ->
        {%{state | line_ed: Line.hist_prev(state.line_ed)}, false}

      :down ->
        {%{state | line_ed: Line.hist_next(state.line_ed)}, false}

      :page_up ->
        {%{state | page: min(state.page + 1, 50)}, true}

      :page_down ->
        {%{state | page: max(state.page - 1, 0)}, true}

      :escape ->
        if state.busy do
          # 无论当前焦点在输入行、输出区、模型流还是 run_elixir，
          # 都走同一个非阻塞取消面。
          Newbee.DEE.Kernel.interrupt(state.kernel)

          if state.submit_kind == :shell and is_pid(state.submit_pid) do
            Process.exit(state.submit_pid, :kill)

            state =
              state
              |> push_line("\e[31m⏹ shell 已中断\e[0m")
              |> Map.merge(%{busy: false, submit_pid: nil, submit_kind: nil})
              |> maybe_start_next()

            {state, false}
          else
            state = state |> push_line("\e[31m⏹ 已请求中断…\e[0m")
            {state, false}
          end
        else
          # 清输入
          {%{state | line_ed: Line.clear(state.line_ed)}, false}
        end

      {:alt, ?b} ->
        {%{state | line_ed: Line.word_left(state.line_ed)}, false}

      {:alt, ?f} ->
        {%{state | line_ed: Line.word_right(state.line_ed)}, false}

      {:alt, ?d} ->
        {%{state | line_ed: Line.delete_word_forward(state.line_ed)}, false}

      ch when is_integer(ch) ->
        {%{state | line_ed: Line.insert(state.line_ed, <<ch::utf8>>)}, false}

      _unknown ->
        {state, false}
    end
  end

  # ── 提交 ──

  defp submit(state, reader), do: submit_text(state, reader, true)

  # 当前回合运行时不再把请求直接扔进 Kernel mailbox；显式保存在 TUI，
  # 这样用户能看到内容，Esc 取消当前回合后也不会丢失后续输入。
  defp submit_text(state, reader, record_history?) do
    text = String.trim_trailing(state.line_ed.text)

    if text == "" do
      state
    else
      if record_history?, do: Newbee.TUI.History.append(text)

      if state.busy do
        enqueue_input(state, text)
      else
        submit_now(state, reader, text)
      end
    end
  end

  defp enqueue_input(state, text) do
    n = length(state.pending_inputs) + 1

    state
    |> push_line("\e[2m⏳ 已排队 [##{n}] #{String.slice(text, 0, 160)}\e[0m")
    |> Map.put(:line_ed, %Line{hist: state.line_ed.hist, hcur: length(state.line_ed.hist)})
    |> Map.update!(:pending_inputs, &(&1 ++ [text]))
  end

  defp submit_now(state, reader, text) do
    case String.trim(text) do
      # TUI 内建命令：思考流开关（Ctrl+T 已让位给窗格切换）
      "/reasoning" ->
        state = %{state | show_reasoning: not state.show_reasoning}
        push_line(state, if(state.show_reasoning, do: "\e[2m思考流：显示\e[0m", else: "\e[2m思考流：隐藏\e[0m"))

      _ ->
        state =
          state
          |> push_line("\e[32m›\e[0m " <> text)
          |> Map.put(:line_ed, %Line{hist: state.line_ed.hist, hcur: length(state.line_ed.hist)})
          |> Map.put(:busy, true)
          |> Map.put(:page, 0)

        state = paint(state)

        ctx =
          %{say: fn line -> send(self(), {:newbee_event, :tui_say, {:tui_say, line}}) end, kernel: state.kernel}

        case Newbee.Commands.handle(text, ctx) do
          :quit ->
            if is_pid(reader), do: send(reader, {:key, :ctrl_c}), else: send(self(), {:key, :ctrl_c})
            %{state | busy: false}

          :ok ->
            %{state | busy: false}

          :handled ->
            %{state | busy: false}

          {:shell, cmd} ->
            # !shell 也异步执行，否则主循环被同步 shell 卡住时无法处理 Esc。
            parent = self()

            shell_pid =
              spawn(fn ->
                result = Newbee.Tools.Run.sh(cmd, timeout: 300_000)
                send(parent, {:shell_done, cmd, result})
              end)

            %{state | submit_pid: shell_pid, submit_kind: :shell}

          {:submit, text} ->
            run_submit(state, text)

          {:restart} ->
            # 兼容：旧版 Commands 曾返回 {:restart} 重建内核，现已改为热切（Commands 直接 :handled）
            # 保留分支仅作兜底：热切失败才重建。
            ctx.say.("（兼容分支）热切失败，尝试重建内核…")
            %{state | busy: false}

          {:resume, id} ->
            GenServer.stop(state.kernel)
            {:ok, kernel2} = resume_kernel(state.client, id)
            %{state | kernel: kernel2, busy: false}

          {:resume_picker, metas} ->
            %{state | picker: %{items: metas, index: 0}, busy: false}
        end
    end
  end

  # 当前任务完成后按 FIFO 启动下一条；命令类输入也经过同一入口。
  defp maybe_start_next(%{busy: false, pending_inputs: [text | rest]} = state) do
    state =
      state
      |> Map.put(:pending_inputs, rest)
      |> Map.put(:line_ed, %{state.line_ed | text: text, cur: String.length(text)})
      |> push_line("\e[2m▶ 执行排队输入: #{String.slice(text, 0, 160)}\e[0m")
      |> submit_text(nil, false)

    if state.busy, do: state, else: maybe_start_next(state)
  end

  defp maybe_start_next(state), do: state

  # ── 会话选择器：/resume、/session list/load 共用 ──

  defp handle_picker_key(state, :up) do
    picker = %{state.picker | index: max(state.picker.index - 1, 0)}
    {%{state | picker: picker}, true}
  end

  defp handle_picker_key(state, :down) do
    last = max(length(state.picker.items) - 1, 0)
    picker = %{state.picker | index: min(state.picker.index + 1, last)}
    {%{state | picker: picker}, true}
  end

  defp handle_picker_key(state, :escape) do
    {push_line(%{state | picker: nil}, "\e[2m已取消会话选择\e[0m"), true}
  end

  defp handle_picker_key(_state, :ctrl_c), do: :quit

  defp handle_picker_key(state, :enter) do
    case Enum.at(state.picker.items, state.picker.index) do
      nil ->
        {%{state | picker: nil} |> push_line("\e[2m（没有可恢复的会话）\e[0m"), true}

      meta ->
        GenServer.stop(state.kernel)
        {:ok, kernel} = resume_kernel(state.client, meta.id)
        {%{state | picker: nil, kernel: kernel, busy: false}, true}
    end
  end

  defp handle_picker_key(state, _key), do: {state, false}

  # Ctrl+T 窗格轮转：nil → 绑定 → 事件日志 → 工具块 → 队列 → nil
  defp next_pane(nil), do: :bindings
  defp next_pane(:bindings), do: :events
  defp next_pane(:events), do: :tools
  defp next_pane(:tools), do: :queue
  defp next_pane(:queue), do: nil

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

    Process.send_after(self(), :spinner_tick, 80)
    %{state | busy: true, submit_pid: caller, submit_kind: :turn}
  end

  defp resume_kernel(client, id) do
    {:ok, kernel} =
      Newbee.DEE.Kernel.start_link(client: client, session_id: id, auto_antibodies: true, render: fn _ -> :ok end)

    meta = Newbee.Session.meta(id)
    send(self(), {:newbee_event, :tui_say, {:tui_say, "已恢复会话 #{id} · #{meta.messages} 条消息 · #{meta.title}"}})
    {:ok, kernel}
  end

  # ── 事件渲染（公开 API，测试契约）──

  @doc "追加一行到 transcript；重置 streaming 状态。"
  def push_line(%__MODULE__{} = state, line) do
    lines = (state.lines ++ [line]) |> Enum.take(-@scrollback)
    %{state | lines: lines, streaming: false, stream_kind: nil, render_pending: false}
  end

  @doc """
  渲染一个总线事件。返回新 state。
    - :text      正文流（首 delta 开新行，后续追加；stream_kind=:text）
    - :reasoning 思考流（灰色，独立流）
    - 其余 topic 渲染成一行后 push_line
  """
  def render_event(%__MODULE__{} = state, :text, {:text, delta}) do
    # 缓冲 delta 中的文本, 遇到换行符时渲染完整行
    combined = state.text_buffer <> delta

    case String.split(combined, "\n") do
      [_] ->
        # 没有换行, 继续缓冲
        if state.streaming and state.stream_kind == :text do
          %{state | text_buffer: combined}
        else
          state
          |> push_line("")
          |> Map.put(:streaming, true)
          |> Map.put(:stream_kind, :text)
          |> Map.put(:text_buffer, combined)
        end

      parts ->
        {completed, [remaining]} = Enum.split(parts, -1)

        # 渲染完整行通过 Markdown
        state =
          if not (state.streaming and state.stream_kind == :text) do
            state |> push_line("") |> Map.put(:streaming, true) |> Map.put(:stream_kind, :text)
          else
            state
          end

        state =
          Enum.reduce(completed, state, fn line, acc ->
            push_line(acc, Newbee.Markdown.render(line))
          end)

        # 重新开始缓冲剩余文本
        %{state | text_buffer: remaining}
    end
  end

  def render_event(%__MODULE__{} = state, :reasoning, {:reasoning, delta}) do
    state = flush_text_buffer(state)

    if not state.show_reasoning do
      state
    else
      if state.streaming and state.stream_kind == :reasoning do
        append_text(state, delta)
      else
        state
        |> push_line("")
        |> Map.put(:streaming, true)
        |> Map.put(:stream_kind, :reasoning)
        |> append_text(delta, "\e[2m")
      end
    end
  end

  def render_event(%__MODULE__{} = state, :usage, {:usage, usage}) do
    %{state | usage: merge_usage(state.usage, usage)}
  end

  def render_event(%__MODULE__{} = state, :tool_start, {:tool_start, name, title, code}) do
    state = flush_text_buffer(state)
    id = :erlang.unique_integer([:positive])
    block = %{id: id, name: name, title: title, code: code, result: nil}
    line = tool_block_line(block)
    %{push_line(state, line) | tool_blocks: Map.put(state.tool_blocks, id, block), last_block_id: id}
  end

  def render_event(%__MODULE__{} = state, :tool_result, {:tool_result, _name, text}) do
    state = flush_text_buffer(state)
    id = Map.get(state, :last_block_id)

    state =
      if id do
        case Map.get(state.tool_blocks, id) do
          nil -> state
          block -> %{state | tool_blocks: Map.put(state.tool_blocks, id, %{block | result: text})}
        end
      else
        state
      end

    line = Newbee.TUI.Cards.tool_footer(text)
    push_line(state, line)
  end

  def render_event(%__MODULE__{} = state, :permission_ask, {:permission_ask, preview}) do
    first_line = preview |> String.split("\n") |> hd() |> String.slice(0, 80)

    state =
      push_line(state, "\e[33m? 允许执行以下代码？[y 允许 / 任意键拒绝]\e[0m \e[2m#{first_line}\e[0m")

    %{state | awaiting_permission: true, busy: true}
  end

  def render_event(%__MODULE__{} = state, :file_diff, {:file_diff, path, diff, stats}) do
    state = flush_text_buffer(state)
    # 内联 diff（§5.1）：行号 + 语法高亮，渲染逻辑在 Newbee.TUI.Cards.diff_card
    Enum.reduce(Newbee.TUI.Cards.diff_card(path, diff, stats), state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :tool_error, {:tool_error, text}) do
    state = flush_text_buffer(state)
    # 卡内错误详情行（状态徽章由紧随的 tool_result 脚给出）
    push_line(state, Newbee.TUI.Cards.error_line(text))
  end

  def render_event(%__MODULE__{} = state, :rule_hit, {:rule_hit, hits}) do
    state = flush_text_buffer(state)
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
    state = flush_text_buffer(state)
    push_line(state, "\e[31m#{inspect(e)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :done, {:done, summary}) do
    state = flush_text_buffer(state)
    push_line(state, "\e[1m● \e[0m" <> Newbee.Markdown.render(summary))
  end

  def render_event(%__MODULE__{} = state, :ask, {:ask, q}) do
    state = flush_text_buffer(state)
    push_line(state, "\e[33m? \e[0m" <> Newbee.Markdown.render(q))
  end

  def render_event(%__MODULE__{} = state, :interrupted, {:interrupted, content}) do
    state = flush_text_buffer(state)
    state = push_line(state, "\e[31m⏹ 已中断\e[0m")
    if content, do: push_line(state, content), else: state
  end

  def render_event(%__MODULE__{} = state, :turn_done, _) do
    state = flush_text_buffer(state)
    notify("newbee", "回合完成")
    %{state | busy: false, submit_pid: nil, submit_kind: nil}
  end

  def render_event(%__MODULE__{} = state, :tui_say, {:tui_say, text}) do
    Enum.reduce(String.split(text, "\n"), state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :advisor_note, {:advisor_note, text}) do
    push_line(state, "\e[38;5;117m◉ advisor\e[0m #{text}")
  end

  def render_event(%__MODULE__{} = state, :worker_hint, {:worker_hint, sig}) do
    push_line(state, "\e[2m⚑ 进化线索已记录（重复失败模式）: #{String.slice(sig, 0, 60)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :compacted, {:compacted, n}) do
    push_line(state, "\e[2m⏳ 历史已压缩 #{n} 条（事件日志原样保留）\e[0m")
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
    state = flush_text_buffer(state)
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

  # Flush 缓冲的 markdown 文本到显示行
  defp flush_text_buffer(%__MODULE__{text_buffer: <<>>} = state), do: state

  defp flush_text_buffer(%__MODULE__{} = state) do
    if String.trim_leading(state.text_buffer) != <<>> do
      state
      |> push_line(Newbee.Markdown.render(state.text_buffer))
    else
      state
    end
    |> Map.put(:text_buffer, <<>>)
  end

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

  # Tab 展开工具块：完整代码 + 完整结果追加进 transcript（§5.1 折叠块）
  defp expand_block(state, block) do
    state =
      state
      |> Map.put(:tool_open, Map.put(state.tool_open, block.id, true))
      |> push_line("")
      |> push_line("\e[36m┌─\e[0m \e[1m⏺ 完整代码 [#{block.name} #{block.title}]\e[0m")

    # 整体先高亮再分行：跨行 heredoc/字符串的颜色不断裂
    state =
      Enum.reduce(String.split(Newbee.TUI.Highlight.elixir(block.code), "\n"), state, &push_line(&2, &1))

    case block.result do
      nil ->
        state

      result ->
        state
        |> push_line("\e[36m└─⎿\e[0m 完整结果")
        |> then(fn s -> Enum.reduce(String.split(result, "\n"), s, &push_line(&2, &1)) end)
    end
  end

  # ── 工具块卡片（渲染逻辑在 Newbee.TUI.Cards，TUI/CLI 共用）──

  defp tool_block_line(block) do
    header = Newbee.TUI.Cards.tool_header(block.name, block.title)
    header <> (Newbee.TUI.Cards.tool_preview(block.code) || "")
  end

  # ── 渲染 ──

  defp schedule_paint(state) do
    now = System.monotonic_time(:millisecond)
    # 16ms≈60fps，忙时 spinner 每帧都有机会转；闲时 30ms 也够平滑
    thresh = if state.busy, do: 16, else: 30

    if now - state.last_paint > thresh do
      send(self(), {:paint, :now})
      %{state | last_paint: now}
    else
      unless state.render_pending do
        Process.send_after(self(), {:paint, :now}, thresh + 5)
      end

      %{state | render_pending: true}
    end
  end

  defp paint(state, force \\ false) do
    # spinner 动画：忙时每帧递增，闲时归零
    state = if state.busy, do: %{state | spinner_idx: state.spinner_idx + 1}, else: %{state | spinner_idx: 0}
    # 绑定缓存：busy 时跳过查询，避免 GenServer 排队卡 paint；闲时 500ms TTL
    {_, state} = cached_bindings(state)
    {cols, rows} = terminal_size()
    {input_view, cur_col} = input_view(state)
    status = {status_line(state), {rows, cur_col}}
    lines = state.lines ++ pane_lines(state.pane, state) ++ picker_lines(state.picker)

    screen =
      if state.screen == nil or force or state.screen.cols != cols do
        Screen.paint_full(state.out, lines, input_view, status, cols, rows, state.page)
      else
        Screen.paint_delta(state.screen, lines, input_view, status, cols, rows, state.page)
      end

    %{state | screen: screen, render_pending: false}
  end

  # Ctrl-T 窗格：绑定清单 / 事件日志 / 工具块

  defp pane_lines(:bindings, state) do
    # 模型/工具运行时 evaluator 正在占用 GenServer，不排队同步查询。
    bs = if state.busy, do: [], else: safe_bindings_summary()
    ["\e[1;36m[窗格] 绑定 (#{length(bs)})\e[0m" | Enum.map(bs, &"  #{&1.name} : #{&1.type} (#{&1.size} bytes)")]
  end

  defp pane_lines(:events, _state) do
    events = Newbee.EventLog.read(20)

    [
      "\e[1;36m[窗格] 事件日志 (最近 20)\e[0m"
      | Enum.map(events, &"  [#{&1["topic"]}] #{inspect(&1["event"]) |> String.slice(0, 60)}")
    ]
  end

  defp pane_lines(:tools, state) do
    blocks = Map.values(state.tool_blocks)
    ["\e[1;36m[窗格] 工具块 (#{length(blocks)})\e[0m" | Enum.map(blocks, &"  #{&1}")]
  end

  defp pane_lines(:queue, state) do
    lines =
      state.pending_inputs
      |> Enum.with_index(1)
      |> Enum.map(fn {text, i} -> "  [#{i}] #{String.slice(text, 0, 200)}" end)

    ["\e[1;36m[窗格] 输入队列 (#{length(lines)})\e[0m" | lines]
  end

  defp pane_lines(nil, _state), do: []

  defp picker_lines(nil), do: []

  defp picker_lines(%{items: items, index: index}) do
    header = "\e[1;33m[会话选择] ↑/↓ 移动 · Enter 恢复 · Esc 取消 (#{length(items)})\e[0m"

    rows =
      items
      |> Enum.with_index()
      |> Enum.map(fn {meta, i} ->
        marker = if i == index, do: "\e[36m❯\e[0m", else: " "
        "#{marker} [#{i + 1}] #{meta.id} · #{meta.when_str} · #{meta.messages} 条 · #{meta.title}"
      end)

    [header | rows]
  end

  defp notify(title, msg) do
    # 桌面通知（可选）：长任务完成提醒，失败静默
    case System.find_executable("notify-send") do
      nil -> :ok
      _ -> spawn(fn -> System.cmd("notify-send", [title, msg], stderr_to_stdout: true) end)
    end

    :ok
  end

  # 首帧可能早于 evaluator peer 完成启动；状态栏/窗格不能把一次超时升级成 TUI 崩溃。
  defp safe_bindings_summary do
    case Process.whereis(Newbee.DEE.Evaluator) do
      nil ->
        []

      pid ->
        try do
          case Newbee.DEE.Evaluator.bindings_summary(pid, 50) do
            bs when is_list(bs) -> bs
            _ -> []
          end
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
    end
  end

  # 缓存 bindings（500ms TTL + busy 时跳过查询，避免每帧 GenServer.call 卡 paint）
  @bindings_ttl 500
  defp cached_bindings(state) do
    now = System.monotonic_time(:millisecond)

    if state.busy do
      {state.bindings_cache, state}
    else
      if now - state.bindings_cache_at < @bindings_ttl and state.bindings_cache != [] do
        {state.bindings_cache, state}
      else
        bs = safe_bindings_summary()
        {bs, %{state | bindings_cache: bs, bindings_cache_at: now}}
      end
    end
  end

  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  defp spinner(state) do
    if state.busy, do: Enum.at(@spinner, rem(state.spinner_idx, length(@spinner))) <> " ", else: ""
  end

  defp status_line(state) do
    usage = state.usage
    tokens = Map.get(usage, "total_tokens", 0)
    bs = if state.busy, do: [], else: state.bindings_cache
    bindings = length(bs)
    dots = spinner(state)
    page_hint = if state.page > 0, do: " · \e[33m↕ #{state.page} PgDn回底\e[0m\e[2m", else: ""
    q = length(state.pending_inputs)
    qpart = if q > 0, do: " · queue:#{q}", else: ""
    "\e[2m#{dots}#{state.client.model} · #{Path.basename(File.cwd!())} · " <>
      "tok:#{tokens} · bind:#{bindings}#{qpart} · #{Newbee.Evolution.Policy.get()}#{page_hint}\e[0m"
  end

  defp input_view(state) do
    prefix = if state.busy, do: "\e[33m…\e[0m ", else: "\e[32m›\e[0m "

    if state.line_ed.text == "" and not state.busy do
      {prefix <> "\e[2m试试 /model /bindings /compact  ·  @文件  ·  !shell  ·  ?帮助\e[0m", 2}
    else
      {line, cur_col} = Line.scroll_view(state.line_ed, terminal_cols() - 4)
      {prefix <> line, 2 + cur_col}
    end
  end

  defp terminal_size do
    # erl -noshell 下无法 ioctl；尺寸由 bin/newbee 探测注入（NEWBEE_ROWS/COLS），
    # 回退到交互 shell 的 COLUMNS/LINES，最后 80x24
    cols = int_env("NEWBEE_COLS") || int_env("COLUMNS") || 80
    rows = int_env("NEWBEE_ROWS") || int_env("LINES") || 24
    {cols, rows}
  end

  defp terminal_cols do
    int_env("NEWBEE_COLS") || int_env("COLUMNS") || 80
  end

  defp int_env(name) do
    case System.get_env(name) do
      nil ->
        nil

      "" ->
        nil

      v ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
    end
  end

  defp tty? do
    case :file.read_link(~c"/proc/self/fd/0") do
      {:ok, target} ->
        target = List.to_string(target)
        not String.starts_with?(target, "/dev/null") and not String.starts_with?(target, "pipe")

      _ ->
        true
    end
  end

  defp session_id(kernel) do
    :sys.get_state(kernel).session
    |> case do
      nil -> "(off)"
      s -> s.id
    end
  end
end
