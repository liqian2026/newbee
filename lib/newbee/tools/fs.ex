defmodule Newbee.Tools.Fs do
  @moduledoc """
  文件系统工具 (DESIGN §3.2 代码 IO)：模型在 DEE 里调用的读写 API。

  - 写操作**先进暂存区**（Newbee.Staging），用户 /approve 统一落盘——
    宽松沙箱的"可回滚"承诺（§8）；
  - 读操作直接返回内容，路径限制在当前工程树内（§8 工作目录隔离）。
  """

  @doc "读文件。返回 {:ok, content} | {:error, reason}。"
  def read(path) do
    File.read(path)
  end

  @doc "读文件（不存在抛错）。"
  def read!(path), do: File.read!(path)

  @doc "写文件：暂存待批。返回暂存条目 id。"
  def write(path, content) do
    if Process.whereis(Newbee.Staging) do
      Newbee.Staging.stage(path, content, :fs_write)
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      :direct
    end
  end

  @doc "写文件（直接落盘，不暂存）。危险操作，模型慎用。"
  def write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    :ok
  end

  @doc "追加写（直接落盘——追加语义不适合暂存）。"
  def append!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content, [:append])
    :ok
  end

  @doc "删除文件。返回 :ok | {:error, reason}。"
  def rm(path) do
    File.rm(path)
  end

  @doc "递归删除（高风险，记审计）。"
  def rm_rf(path) do
    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.emit(:audit, {:audit, :dangerous_code, ["File.rm_rf!", path]})
    end

    File.rm_rf(path)
  end

  @doc "文件是否存在。"
  def exists?(path), do: File.exists?(path)

  @doc "列出目录（一层）。"
  def ls(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.map(entries, fn e ->
          p = Path.join(dir, e)
          if File.dir?(p), do: e <> "/", else: e
        end)

      {:error, _} = err ->
        err
    end
  end

  @doc "遍历工程树（跳过 _build/deps/.git）。返回相对路径列表。"
  def tree(root \\ ".") do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(fn p ->
      p =~ ~r{/(_build|deps|\.git|node_modules|cover)/}
    end)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  @doc "文件大小（字节）。"
  def size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end
end
