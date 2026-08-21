defmodule Newbee.Web.Server do
  @moduledoc """
  WebUI HTTP 服务器（移植 dsh webserver 语义）：Bandit 承载 Router，
  受监督生命周期。默认绑定 127.0.0.1:4173。
  """

  @default_port 4173

  def child_spec(opts) do
    port = Keyword.get(opts, :port, @default_port)
    host = Keyword.get(opts, :host, {127, 0, 0, 1})

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[port: port, host: host]]}
    }
  end

  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    ip = Keyword.fetch!(opts, :host)

    Bandit.start_link(
      plug: Newbee.Web.Router,
      port: port,
      ip: ip,
      thousand_island_options: [num_acceptors: 8]
    )
  end
end
