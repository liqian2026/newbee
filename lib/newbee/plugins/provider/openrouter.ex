defmodule Newbee.Plugins.Provider.OpenRouter do
  @moduledoc "无凭证 OpenRouter 协议适配器（DESIGN §12）。只产出经校验的请求计划，不读 env、不持 key。"

  @default_base_url "https://openrouter.ai/api/v1"

  @spec plan(String.t(), [map()], String.t()) :: {:ok, map()} | {:error, term()}
  def plan(model, messages, base_url \\ @default_base_url) do
    body = %{
      model: model,
      messages: messages,
      tools: Newbee.Codec.tools(),
      stream: true,
      stream_options: %{include_usage: true}
    }

    {:ok,
     %{
       method: :post,
       url: base_url <> "/chat/completions",
       headers: %{"content-type" => "application/json"},
       json: body,
       credential_env: "OPENROUTER_API_KEY",
       stream: true,
       receive_timeout: 120_000
     }}
  end
end
