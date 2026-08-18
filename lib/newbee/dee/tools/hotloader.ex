defmodule Newbee.DEE.Tools.HotLoader do
  @moduledoc """
  工具热载 (DESIGN §3.5) ⭐：工具不写进主应用源码，放
  `~/.newbee/tools/*.ex`（全局）与 `<project>/.newbee/tools/*.ex`（项目级），
  运行时 `Code.compile_file` 热加载。

  - **git 版本化**：工具目录是 git 仓库，每次新增/修改 = 一次 commit，
    天然获得回滚与审计；
  - **主内核只读**：模型能改的只有工具层，自我进化破坏核心系统的风险
    在架构上直接消除（§3.7 权限环）；
  - **热替换失败不影响旧版本**（BEAM 语义）。
  """

  require Logger

  @doc "全局工具目录。"
  def global_dir do
    Path.join(System.user_home!(), ".newbee/tools")
  end

  @doc "项目级工具目录。"
  def project_dir do
    Path.join(File.cwd!(), ".newbee/tools")
  end

  @doc "全部工具文件（全局 + 项目，项目优先同名覆盖）。"
  def tool_files do
    (Path.wildcard(Path.join(global_dir(), "*.ex")) ++ Path.wildcard(Path.join(project_dir(), "*.ex")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  发布一个新工具：写文件 + git commit + 热载到求值器节点。
  opts: node（目标节点，默认当前主节点）、message（commit message）。
  返回 {:ok, path} | {:error, reason}。
  """
  def publish(name, source, opts \\ []) do
    name = validate_name!(name)
    path = Path.join(global_dir(), "#{name}.ex")
    message = Keyword.get(opts, :message, "add tool #{name}")

    with :ok <- validate_source(source),
         :ok <- ensure_git_repo(),
         :ok <- write_file(path, source),
         :ok <- git_commit(path, message),
         :ok <- load_into_node(Keyword.get(opts, :node)) do
      {:ok, path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "把工具目录全部编译加载到目标节点（不存在则跳过）。"
  def load_into_node(nil), do: :ok
  def load_into_node(node) when not is_atom(node), do: :ok

  def load_into_node(node) do
    files = tool_files()

    results =
      Enum.map(files, fn f ->
        # 注意：路径必须传 string（charlist 在 OTP 29 的 Code.compile_file 会 function_clause）
        :rpc.call(node, Code, :compile_file, [f], 60_000)
      end)

    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, {:compile_failed, Enum.filter(results, &match?({:error, _}, &1))}}
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("hot load into node failed: #{inspect(e)}")
      {:error, {:load_failed, e}}
  end

  # ── internals ──

  defp validate_name!(name) do
    name = to_string(name)

    if Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]*$/, name) do
      name
    else
      raise ArgumentError, "invalid tool name: #{inspect(name)}"
    end
  end

  defp validate_source(source) do
    case Code.string_to_quoted(source) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :bad_source}
    end
  end

  defp ensure_git_repo do
    dir = global_dir()
    File.mkdir_p!(dir)

    if File.dir?(Path.join(dir, ".git")) do
      :ok
    else
      case System.cmd("git", ["-C", dir, "init", "-q"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, {:git_init, String.slice(out, 0, 200)}}
      end
    end
  end

  defp write_file(path, source) do
    File.write!(path, source)
    :ok
  end

  defp git_commit(path, message) do
    dir = global_dir()

    with {_, 0} <- System.cmd("git", ["-C", dir, "add", path], stderr_to_stdout: true) do
      case System.cmd("git", ["-C", dir, "commit", "-q", "-m", message], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        # 内容与上次相同（残留发布）——没有新提交，视为成功
        {out, _} when is_binary(out) ->
          if out =~ "nothing to commit" or out =~ "无文件要提交" or out =~ "no changes added" do
            :ok
          else
            {:error, {:git_commit, String.slice(out, 0, 200)}}
          end

        {out, _} ->
          {:error, {:git_commit, String.slice(out, 0, 200)}}
      end
    else
      {out, _} -> {:error, {:git_add, String.slice(out, 0, 200)}}
    end
  rescue
    e -> {:error, {:git, e}}
  end
end
