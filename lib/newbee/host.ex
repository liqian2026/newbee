defmodule Newbee.Host do
  @moduledoc """
  宿主契约 (DESIGN §3.4) ⭐：求值器节点不持有任何凭证、不直连 provider、
  不直写 transcript——一切权威操作（事件广播、暂存区、配置）经本模块
  代理到主节点校验后执行。

  - **节点侧透明**：`Host.emit` 在主 VM 直接广播，在求值器节点自动 rpc
    回主 VM 的 Bus——节点上的工具（Fs/Edit 等）发出的事件不再丢失；
  - **凭证防护**：`safe_config/0` 返回脱敏后的模型配置（apiKey 打码），
    模型代码应读它而非直接读 model.json（节点 env 已剥离 key，这是第二道闸）；
  - **主节点名注入**：Evaluator.boot_node 通过 env `NEWBEE_MAIN_NODE` 注入。
  """

  @env "NEWBEE_MAIN_NODE"

  @doc "主节点名。主 VM 上为自身节点，节点上为注入的 env。"
  def main_node do
    case System.get_env(@env) do
      nil -> Node.self()
      name -> String.to_atom(name)
    end
  end

  @doc "当前进程是否运行在主 VM。"
  def on_main?, do: main_node() == Node.self()

  @doc "广播事件：节点上自动 rpc 回主 VM 的 Bus（§4.6 全系统一条总线）。"
  def emit(topic, event) do
    if on_main?() do
      if Process.whereis(Newbee.Bus), do: Newbee.Bus.emit(topic, event)
    else
      :rpc.call(main_node(), Newbee.Bus, :emit, [topic, event], 30_000)
    end

    :ok
  end

  @doc "跨节点调用主 VM 的 GenServer（如 Newbee.Staging）。"
  def call(module, fun, args) when is_atom(module) and is_atom(fun) and is_list(args) do
    if on_main?() do
      apply(module, fun, args)
    else
      :rpc.call(main_node(), module, fun, args, 30_000)
    end
  end

  @doc "脱敏后的模型配置（apiKey 打码）。模型代码用这个，不读原始 model.json。"
  def safe_config do
    cfg =
      try do
        Newbee.LLM.Config.load()
      rescue
        _ -> %{}
      end

    redact_config(cfg)
  end

  defp redact_config(%{"providers" => providers} = cfg) do
    providers =
      Map.new(providers, fn {name, p} ->
        {name, Map.update(p, "apiKey", "[未配置]", fn k -> redact_key(k) end)}
      end)

    Map.put(cfg, "providers", providers)
  end

  defp redact_config(other), do: other

  defp redact_key(nil), do: "[未配置]"

  defp redact_key(key) when is_binary(key) do
    if byte_size(key) <= 8 do
      "[已配置]"
    else
      String.slice(key, 0, 4) <> "…" <> String.slice(key, -4, 4)
    end
  end

  defp redact_key(_), do: "[已配置]"
end
