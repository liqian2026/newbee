defmodule Newbee.DebugLog do
  @moduledoc """
  调试日志（文件，不污染 TUI 全屏）：
  `~/.newbee/debug.log`，追加写，带 UTC 时间戳与调用方 tag。

  埋点纪律：
  - 只记"决策点与异常"，不记高频数据（SSE 每个 delta 不记）
  - 每个跨进程调用（Evaluator.eval / Kernel.submit / Client.stream_chat）
    记录 开始 / 结束(耗时) / 异常，形成完整时序
  - 故障排查顺序：debug.log 的时间线 → events.jsonl 的领域事件
  """

  @path Path.join(System.user_home!(), ".newbee/debug.log")
  @max_bytes 5_000_000

  @doc "追加一条日志。tag 用短冒号链如 :eval/:boot/:ok。"
  def log(tag, msg) do
    line = [
      DateTime.utc_now() |> DateTime.to_iso8601(),
      " ",
      format_tag(tag),
      " ",
      msg,
      "\n"
    ]

    File.mkdir_p!(Path.dirname(@path))
    File.write!(@path, line, [:append])
    trim()
  rescue
    _ -> :ok
  end

  @doc "计时包装：f 返回 {result, elapsed_ms} 或直接 result；记录耗时。"
  def timed(tag, fun) do
    t0 = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      log([tag, :ok], "took #{System.monotonic_time(:millisecond) - t0}ms")
      result
    rescue
      e ->
        log([tag, :error], "raised #{inspect(e)} after #{System.monotonic_time(:millisecond) - t0}ms")
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        log([tag, :error], "caught #{kind} #{inspect(reason)} after #{System.monotonic_time(:millisecond) - t0}ms")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "读取日志尾部 n 行（/log 命令用）。"
  def tail(n \\ 50) do
    case File.read(@path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.take(-n)
      _ -> []
    end
  end

  # 超过上限截断到一半（保留最新）
  defp trim do
    case File.stat(@path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        case File.read(@path) do
          {:ok, body} ->
            keep = String.slice(body, -div(@max_bytes, 2)..-1//1)
            File.write!(@path, keep)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp format_tag(tag) when is_atom(tag), do: "[#{tag}]"
  defp format_tag(tag) when is_list(tag), do: "[" <> Enum.map_join(tag, ".", &format_tag/1) <> "]"
  defp format_tag(tag), do: inspect(tag)
end


:ok