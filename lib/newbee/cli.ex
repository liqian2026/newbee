defmodule Newbee.CLI do
  @moduledoc """
  M1 极简 CLI（codex 式单列流式，DESIGN §5.1）。
  渲染订阅事件总线（§4.6），主循环同步提交；命令走 Newbee.Commands。
  """

  def start do
    client = Newbee.LLM.Config.client_for()

    unless client.api_key do
      IO.puts("\e[31m缺少 API key：检查 ~/.newbee/model.json\e[0m")
      System.halt(1)
    end

    IO.puts("\e[1mnewbee\e[0m — 会自我进化的 Elixir 编程 Agent")
    IO.puts("\e[2mmodel: #{client.model} · policy: #{Newbee.Evolution.Policy.get()} · cwd: #{File.cwd!()}\e[0m")
    IO.puts("命令: #{Enum.join(Newbee.Commands.commands(), " ")}")

    # 预热：假 IP 代理 TLS 握手慢，先建立连接入池复用
    Task.start(fn -> Newbee.LLM.Client.prewarm(client) end)

    Newbee.Bus.subscribe()
    spawn_link(fn -> printer() end)

    {:ok, kernel} = Newbee.DEE.Kernel.start_link(client: client, render: fn _ -> :ok end)
    IO.puts("\e[2msession: #{session_id(kernel)}\e[0m")

    loop(kernel, client)
  end

  # ── 事件打印（独立进程，实时流式） ──

  defp printer do
    receive do
      {:newbee_event, :text, {:text, delta}} ->
        IO.write(delta)

      {:newbee_event, :reasoning, {:reasoning, delta}} ->
        IO.write("\e[2m" <> delta <> "\e[0m")

      {:newbee_event, :tool_start, {:tool_start, "run_elixir", title, code}} ->
        preview = code |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")
        ellipsis = if String.contains?(code, "\n"), do: " …", else: ""
        IO.puts("\n\e[36m⏺\e[0m \e[1mrun_elixir\e[0m \e[2m#{title}\e[0m\n#{preview}#{ellipsis}")

      {:newbee_event, :tool_result, {:tool_result, _, text}} ->
        {mark, body} =
          case text do
            "✓ ok\n" <> rest -> {"\e[32m  ⎿ ✓\e[0m", rest}
            "✗ error\n" <> rest -> {"\e[31m  ⎿ ✗\e[0m", rest}
            other -> {"\e[36m  ⎿\e[0m", other}
          end

        preview = body |> String.split("\n") |> Enum.take(6) |> Enum.join("\n    ")
        IO.puts(mark <> " " <> preview <> "\n")

      {:newbee_event, :rule_hit, {:rule_hit, hits}} ->
        Enum.each(hits, fn r ->
          IO.puts("\e[33m⚑ 沉睡规则命中 [#{r.id}]\e[0m \e[2m#{r.injection}\e[0m")
        end)

      {:newbee_event, :audit, {:audit, verdict, actor, target, ring}} ->
        IO.puts("\e[2m⚖ 审计: #{verdict} #{actor} → ring#{ring} #{inspect(target) |> String.slice(0, 60)}\e[0m")

      {:newbee_event, :audit, {:audit, :dangerous_code, hits}} ->
        IO.puts("\e[31m⚖ 审计: 危险代码模式 #{inspect(hits)}\e[0m")

      {:newbee_event, :error, {:error, e}} ->
        IO.puts("\e[31m#{inspect(e)}\e[0m")

      {:newbee_event, _, _} ->
        :ok
    end

    printer()
  end

  # ── 输入循环 ──

  defp loop(kernel, client) do
    case IO.gets("\e[32m›\e[0m ") do
      nil ->
        :ok

      input ->
        ctx = %{say: &IO.puts/1}

        case Newbee.Commands.handle(input, ctx |> Map.put(:kernel, kernel)) do
          :quit ->
            System.halt(0)

          :ok ->
            loop(kernel, client)

          :handled ->
            loop(kernel, client)

          {:resume, id} ->
            GenServer.stop(kernel)
            {:ok, kernel2} = resume_kernel(client, id)
            loop(kernel2, client)

          {:resume_picker, metas} ->
            print_metas(metas)

            case IO.gets("\e[36m选择编号或 id 前缀（回车取消）›\e[0m ") do
              nil ->
                loop(kernel, client)

              sel ->
                sel = String.trim(sel)

                if sel == "" do
                  loop(kernel, client)
                else
                  case Newbee.Commands.resolve(sel) do
                    {:ok, id} ->
                      GenServer.stop(kernel)
                      {:ok, kernel2} = resume_kernel(client, id)
                      loop(kernel2, client)

                    {:candidates, ids} ->
                      IO.puts("匹配多个: #{Enum.join(ids, " ")}")
                      loop(kernel, client)

                    :none ->
                      IO.puts("没有匹配的会话")
                      loop(kernel, client)
                  end
                end
            end


          {:submit, text} ->
            run_submit(kernel, text)
            loop(kernel, client)
        end
    end
  end

  defp resume_kernel(client, id) do
    {:ok, kernel} = Newbee.DEE.Kernel.start_link(client: client, session_id: id, render: fn _ -> :ok end)
    meta = Newbee.Session.meta(id)
    IO.puts("\e[2m已恢复会话 #{id} · #{meta.messages} 条消息 · #{meta.title}\e[0m")
    {:ok, kernel}
  end

  defp print_metas(metas) do
    IO.puts("最近会话:")

    Enum.with_index(metas, 1)
    |> Enum.each(fn {m, i} ->
      IO.puts("  [#{i}] #{m.id} · #{m.when_str} · #{m.messages} 条 · #{m.title}")
    end)
  end
  defp run_submit(kernel, text) do
    case Newbee.DEE.Kernel.submit(kernel, text) do
      {:done, summary} -> IO.puts("\n\e[1m● \e[0m" <> summary <> "\n")
      {:ask, q} -> IO.puts("\n\e[33m? \e[0m" <> q <> "\n")
      {:text, _} -> IO.puts("")
      {:error, e} -> IO.puts("\e[31merror: #{inspect(e)}\e[0m")
    end

    # 暂存区有改动时提示
    case Newbee.Staging.list() do
      [] -> :ok
      staged ->
        IO.puts("\e[36m◆ #{length(staged)} 项改动待批准:\e[0m")
        IO.puts(Newbee.Staging.render())
        IO.puts("\e[2m/approve 全部落盘 · /reject 丢弃\e[0m")
    end
  end

  defp session_id(kernel) do
    :sys.get_state(kernel).session |> case do
      nil -> "(off)"
      s -> s.id
    end
  end
end
