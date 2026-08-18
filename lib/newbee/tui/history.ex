defmodule Newbee.TUI.History do
  @moduledoc """
  提示词历史持久化（~/.newbee/history，一行一条，最早的在前）。

  与 codex 一致：退出 TUI 后重进，↑ 仍能翻出之前提交过的提示词。
  提交时即时追加（非退出时批量写），进程被杀也不丢。
  """

  @path Path.join(System.user_home!(), ".newbee/history")

  @doc "历史文件路径（测试可用 Application env :newbee,:history_path 覆盖）。"
  def path do
    Application.get_env(:newbee, :history_path) || @path
  end

  @doc """
  读取全部历史。文件不存在返回 []。
  条目按提交时间升序（最早在前），与 Line.hist 的存储顺序一致。
  """
  def load do
    case File.read(path()) do
      {:ok, content} ->
        content
        |> String.split("
")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  追加一条历史。与最后一条相同则跳过（bash 式去重）。
  幂等且即时落盘：TUI 每次提交调用，无需退出时批量写。
  """
  def append(text) do
    text = String.trim(text)

    if text == "" do
      :ok
    else
      case load() do
        [] ->
          write(text)

        hist ->
          # load 按时间升序，"最后一条"在末尾（旧代码比较了头部，去重对象错误）
          if List.last(hist) == text do
            {:ok, hist}
          else
            write(text)
          end
      end
    end
  end

  defp write(text) do
    File.mkdir_p!(Path.dirname(path()))

    with {:ok, f} <- File.open(path(), [:append, :utf8]) do
      try do
        IO.write(f, text <> "\n")
      after
        File.close(f)
      end
    end
  end
end
