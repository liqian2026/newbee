defmodule Newbee.Tools.Run do
  @moduledoc "命令执行工具 (DESIGN §3.2)：超时 + 输出上限，结果返回 exit code 与输出。"

  @default_timeout 120_000
  @max_output 32_000

  @dangerous_re ~r/(rm\s+.*-rf|rm\s+-r\s+\/|git\s+push|rm\s+-rf\s+\/)/i

  @doc "在工程根下执行 shell 命令。返回 %{exit, output}。"
  def sh(cmd, opts \\ []) do
    case gate(cmd) do
      :allow -> do_sh(cmd, opts)
      {:deny, msg} -> %{exit: :denied, output: msg}
    end
  end

  defp gate(cmd) do
    if Regex.match?(@dangerous_re, cmd) do
      case Newbee.Permissions.get() do
        :lenient ->
          :allow

        :ask ->
          {:deny, "[denied: ask 档 — 高危命令需 /permissions lenient 或 /approve 后执行: " <> String.slice(cmd, 0, 120) <> "]"}

        :deny ->
          {:deny, "[denied: deny 档 — 高危命令已拦截: " <> String.slice(cmd, 0, 120) <> "]"}
      end
    else
      :allow
    end
  end

  defp do_sh(cmd, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", cmd],
          cd: File.cwd!(),
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )
      end)

    case Task.yield(task, timeout) do
      {:ok, {out, code}} ->
        %{exit: code, output: truncate(out)}

      nil ->
        Task.shutdown(task, :brutal_kill)
        %{exit: :timeout, output: ""}
    end
  end

  @doc "跑 mix compile。返回 {:ok, output} | {:error, output}。"
  def mix_compile(opts \\ []) do
    result = sh("mix compile", opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "跑 mix test（可传文件列表）。返回 {:ok, output} | {:error, output}。"
  def mix_test(files \\ [], opts \\ []) do
    cmd = "mix test " <> Enum.join(files, " ")
    result = sh(cmd, opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "跑 mix format 检查。返回 {:ok, output} | {:error, output}。"
  def mix_format(files \\ []) do
    cmd = "mix format --check-formatted " <> Enum.join(files, " ")
    result = sh(cmd)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "Django test helper: auto picks python3.11 when cgi missing."
  def django_test(args \\ "apps.ha_bridge", opts \\ []) do
    py = if System.find_executable("python3.11"), do: "python3.11", else: "python3"
    sh(py <> " BackCode/manage.py test " <> args, opts)
  end

  @doc "Long-running variant: default 180s for harness run-group."
  def sh_long(cmd, opts \\ []) do
    sh(cmd, Keyword.put_new(opts, :timeout, 180_000))
  end

  defp truncate(s) when byte_size(s) <= @max_output, do: s

  defp truncate(s) do
    head = binary_part(s, 0, div(@max_output, 2))
    tail = binary_part(s, byte_size(s) - div(@max_output, 2), div(@max_output, 2))
    head <> "\n… [输出截断: " <> to_string(byte_size(s)) <> " bytes] …\n" <> tail
  end
end
