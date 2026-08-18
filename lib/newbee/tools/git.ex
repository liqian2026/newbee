defmodule Newbee.Tools.Git do
  @moduledoc "Git 工具集 (DESIGN M3)：DEE 里的版本化操作。"

  def status(dir \\ "."), do: run(dir, ["status", "--short"])
  def diff(dir \\ "."), do: run(dir, ["diff", "--stat"])
  def diff_full(dir \\ "."), do: run(dir, ["diff"])
  def log(dir \\ ".", n \\ 10), do: run(dir, ["log", "--oneline", "-#{n}"])

  def add_all(dir \\ "."), do: run(dir, ["add", "-A"])
  def commit(dir \\ ".", msg), do: run(dir, ["-c", "user.email=newbee@local", "-c", "user.name=newbee", "commit", "-m", msg])

  @doc "回滚工作区到 HEAD（宽松沙箱的撤销键，§8）。"
  def rollback(dir \\ ".") do
    run(dir, ["checkout", "--", "."])
    run(dir, ["clean", "-fd", "lib/", "test/"])
  end

  @doc "worktree 隔离：为子代理开独立工作树。"
  def worktree_add(path, ref \\ "HEAD"), do: run(".", ["worktree", "add", path, ref])
  def worktree_remove(path), do: run(".", ["worktree", "remove", "--force", path])

  defp run(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end
end


:ok