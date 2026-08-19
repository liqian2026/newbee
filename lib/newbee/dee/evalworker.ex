defmodule Newbee.DEE.EvalWorker do
  @moduledoc """
  求值工人：持有持久 binding、执行 cell、捕获 stdout。
  可跑在本 VM 或求值器节点（§3.4）——Evaluator 负责路由。
  """
  use GenServer

  @default_timeout 60_000
  @active_key :newbee_eval_active_task

  defstruct binding: [], count: 0

  @doc false
  def active_pid(key) do
    :persistent_term.get({@active_key, key}, nil)
  end

  @doc false
  def clear_active(key, pid) do
    active_key = {@active_key, key}

    if :persistent_term.get(active_key, nil) == pid do
      :persistent_term.erase(active_key)
    end

    :ok
  end

  @doc false
  def register_active(key, pid), do: :persistent_term.put({@active_key, key}, pid)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def start(opts \\ []), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:eval, code, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {result, new_binding, count} = run_cell(code, state.binding, timeout, state.count, opts)
    {:reply, result, %{state | binding: new_binding, count: count}}
  end

  def handle_call(:bindings_summary, _from, state) do
    {:reply, summarize(state.binding), state}
  end

  def handle_call(:dump_bindings, _from, state) do
    {:reply, state.binding, state}
  end

  def handle_call({:restore_bindings, binding}, _from, state) do
    {:reply, :ok, %{state | binding: binding}}
  end

  # ── cell 执行 ──

  def run_cell(code, binding, timeout, count, opts \\ []) do
    parent = self()
    interrupt_key = Keyword.get(opts, :interrupt_key)
    interrupt_node = Keyword.get(opts, :interrupt_node, Node.self())

    task =
      Task.async(fn ->
        register_remote_active(interrupt_node, interrupt_key, self())

        try do
          {:ok, io} = StringIO.open("")
          Process.group_leader(self(), io)

          outcome =
            try do
              {value, new_binding} = Code.eval_string(code, binding, file: "cell_#{count}")
              {:ok, value, new_binding}
            rescue
              e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
            catch
              kind, reason -> {:error, "#{kind}: #{safe_inspect(reason)}"}
            end

          {_in, out} = StringIO.contents(io)
          GenServer.stop(io, :normal, 5_000)
          send(parent, {:cell_done, self(), outcome, out})
        after
          clear_remote_active(interrupt_node, interrupt_key, self())
        end
      end)

    # Task.async/1 links the worker; unlink so Esc can kill only the cell,
    # not the long-lived EvalWorker GenServer that owns the bindings.
    Process.unlink(task.pid)

    case Task.yield(task, timeout) do
      nil ->
        Task.shutdown(task, :brutal_kill)
        {%{status: :error, error: "timeout after #{timeout}ms", output: ""}, binding, count + 1}

      {:ok, _} ->
        receive do
          {:cell_done, _, {:ok, value, new_binding}, out} ->
            {%{status: :ok, value: safe_inspect(value), output: out}, new_binding, count + 1}

          {:cell_done, _, {:error, msg}, out} ->
            {%{status: :error, error: msg, output: out}, binding, count + 1}
        after
          1_000 ->
            {%{status: :error, error: "cell result lost", output: ""}, binding, count + 1}
        end

      {:exit, :killed} ->
        {%{status: :error, error: "interrupted", output: ""}, binding, count + 1}

      {:exit, reason} ->
        {%{status: :error, error: "cell task exited: #{inspect(reason)}", output: ""}, binding, count + 1}
    end
  end

  defp register_remote_active(_node, key, _pid) when is_nil(key), do: :ok

  defp register_remote_active(node, key, pid) do
    if node == Node.self() do
      register_active(key, pid)
    else
      :rpc.call(node, __MODULE__, :register_active, [key, pid])
    end
  end

  defp clear_remote_active(_node, key, _pid) when is_nil(key), do: :ok

  defp clear_remote_active(node, key, pid) do
    if node == Node.self() do
      clear_active(key, pid)
    else
      :rpc.call(node, __MODULE__, :clear_active, [key, pid])
    end
  end

  def summarize(binding) do
    Enum.map(binding, fn {name, value} ->
      %{name: name, type: type_of(value), size: byte_size(safe_inspect(value))}
    end)
  end

  defp type_of(v) when is_binary(v), do: :binary
  defp type_of(v) when is_list(v), do: :list
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_tuple(v), do: :tuple
  defp type_of(v) when is_atom(v), do: :atom
  defp type_of(v) when is_number(v), do: :number
  defp type_of(v) when is_pid(v), do: :pid
  defp type_of(v) when is_function(v), do: :function
  defp type_of(_), do: :other

  @max_inspect 10_000
  defp safe_inspect(v) do
    s = inspect(v, limit: 100, printable_limit: @max_inspect)
    if byte_size(s) > @max_inspect, do: binary_part(s, 0, @max_inspect) <> "…(truncated)", else: s
  end
end
