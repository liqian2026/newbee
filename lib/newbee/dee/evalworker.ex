defmodule Newbee.DEE.EvalWorker do
  @moduledoc """
  求值工人：持有持久 binding、执行 cell、捕获 stdout。
  可跑在本 VM 或求值器节点（§3.4）——Evaluator 负责路由。
  """
  use GenServer

  @default_timeout 60_000

  defstruct binding: [], count: 0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def start(opts \\ []), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:eval, code, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {result, new_binding, count} = run_cell(code, state.binding, timeout, state.count)
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

  def run_cell(code, binding, timeout, count) do
    parent = self()

    task =
      Task.async(fn ->
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
      end)

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