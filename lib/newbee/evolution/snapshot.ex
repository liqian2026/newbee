defmodule Newbee.Evolution.Snapshot do
  @moduledoc """
  环境快照与回滚 (DESIGN §8 审计+回滚)：`/snapshot` 与 `/rollback` 的底座。

  快照 = 当前环境状态拷贝（热载工具目录 + 进化状态 + 规则），存到
  `~/.newbee/snapshots/<name>/`，并记录工程 git HEAD（若工程是 git 仓库）。
  restore = 拷回工具/状态 + 重建求值器（绑定清空、工具按快照热载）。
  """

  require Logger

  @root Path.join(System.user_home!(), ".newbee/snapshots")

  @doc "创建快照。name 缺省用时间戳。返回 {:ok, name}。"
  def create(name \\ nil) do
    name = name || DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^\d]/, "") |> then(&"snap_#{&1}")
    dir = Path.join(@root, name)

    if File.exists?(dir) do
      {:error, :exists}
    else
      File.mkdir_p!(dir)
      copy_dir(Path.join(System.user_home!(), ".newbee/tools"), Path.join(dir, "tools"))
      copy_dir(Path.join(System.user_home!(), ".newbee/evolution"), Path.join(dir, "evolution"))
      copy_dir(Path.join(System.user_home!(), ".newbee/prompts"), Path.join(dir, "prompts"))

      meta = %{
        name: name,
        at: DateTime.to_iso8601(DateTime.utc_now()),
        cwd: File.cwd!(),
        git_head: git_head(),
        git_dirty: git_dirty?()
      }

      File.write!(Path.join(dir, "meta.json"), Jason.encode_to_iodata!(meta))
      audit(:snapshot_created, name)
      {:ok, name}
    end
  end

  @doc "快照列表（新→旧）。"
  def list do
    @root
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.sort(:desc)
  end

  @doc "回滚到快照：恢复工具/进化状态 + 重建求值器。返回 {:ok, name} | {:error, reason}。"
  def restore(name) do
    dir = Path.join(@root, name)

    if File.dir?(dir) do
      # 1) 工具与状态目录整体替换
      restore_dir(Path.join(dir, "tools"), Path.join(System.user_home!(), ".newbee/tools"))
      restore_dir(Path.join(dir, "evolution"), Path.join(System.user_home!(), ".newbee/evolution"))
      restore_dir(Path.join(dir, "prompts"), Path.join(System.user_home!(), ".newbee/prompts"))

      # 2) 重建求值器（绑定清空，工具按快照热载）
      if Process.whereis(Newbee.DEE.Evaluator) do
        Newbee.DEE.Evaluator.reset()
      end

      # 3) JIT/规则内存态重载
      if Process.whereis(Newbee.Evolution.JIT) do
        :sys.replace_state(Newbee.Evolution.JIT, fn _ -> %Newbee.Evolution.JIT{} end)
      end

      audit(:snapshot_restored, name)
      {:ok, name}
    else
      {:error, :not_found}
    end
  end

  defp copy_dir(src, dst) do
    if File.dir?(src) do
      File.mkdir_p!(dst)

      for f <- Path.wildcard(Path.join(src, "**/*")), File.regular?(f) do
        rel = Path.relative_to(f, src)
        File.mkdir_p!(Path.dirname(Path.join(dst, rel)))
        File.cp!(f, Path.join(dst, rel))
      end
    end
  end

  defp restore_dir(src, dst) do
    File.rm_rf(dst)
    copy_dir(src, dst)
  end

  defp git_head do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git_dirty? do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  defp audit(kind, name) do
    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.emit(:audit, {:audit, :ok, "snapshot", name, kind})
    end

    Logger.info("#{kind}: #{name}")
  end
end
