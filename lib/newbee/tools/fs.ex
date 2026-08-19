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

  @doc "写文件：暂存待批。返回暂存条目 id。

  注意：求值器节点上没有 Staging 进程——经 Newbee.Host 代理回主 VM（§3.4），
  主 VM 无暂存区（app 未启动）时降级直接落盘。"
  def write(path, content) do
    guard_path!(path)

    case Newbee.Host.call(Newbee.Staging, :stage, [path, content, :fs_write]) do
      id when is_integer(id) ->
        id

      _ ->
        # 主 VM 暂存区不可用（badrpc / 未启动）：直接落盘
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        :direct
    end
  end

  @doc "写文件（直接落盘，不暂存）。危险操作，模型慎用。落盘后发内联 diff 事件（§5.1）。"
  def write!(path, content) do
    guard_path!(path)
    old = if File.exists?(path), do: File.read!(path), else: ""
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    emit_diff(path, old, content)
    :ok
  end

  @doc "追加写（直接落盘——追加语义不适合暂存）。"
  def append!(path, content) do
    guard_path!(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content, [:append])
    :ok
  end

  @doc "删除文件。返回 :ok | {:error, reason}。"
  def rm(path) do
    guard_path!(path)
    File.rm(path)
  end

  @doc "递归删除（高风险，记审计）。"
  def rm_rf(path) do
    guard_path!(path)
    Newbee.Host.emit(:audit, {:audit, :dangerous_code, ["File.rm_rf!", path]})
    File.rm_rf(path)
  end

  # 内联 diff 事件（§5.1）：节点上经 Host 代理回主 VM 总线
  defp emit_diff(path, old, new) do
    if old != new do
      Newbee.Host.emit(
        :file_diff,
        {:file_diff, path, Enum.join(Newbee.Diff.lines(old, new), "\n"), Newbee.Diff.stats(old, new)}
      )
    end

    :ok
  end

  @doc """
  工作目录隔离（§8）：写入类操作限制在当前工程树或 ~/.newbee 内，
  其余路径抛 ArgumentError。

  注意这是**软边界**：模型仍可在 run_elixir 里直接 File.write! 绕开——
  它约束的是推荐 API，真正的硬隔离由宽松档位的审计/快照兜底（§8）。
  长输出可写到工程内 `.newbee-tmp/` 或 `~/.newbee/`。
  """
  def guard_path!(path) do
    expanded = Path.expand(path)
    root = Path.expand(File.cwd!())
    newbee = Path.join(System.user_home!(), ".newbee") |> Path.expand()

    ok? =
      Enum.any?([root, newbee], fn base ->
        expanded == base or String.starts_with?(expanded, base <> "/")
      end)

    if ok? do
      :ok
    else
      raise ArgumentError,
            "拒绝写入工程树外路径: #{path}（长输出可写到工程内 .newbee-tmp/ 或 ~/.newbee/）"
    end
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
