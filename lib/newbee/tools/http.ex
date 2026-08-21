defmodule Newbee.Tools.Http do
  @moduledoc """
  HTTP 工具 (DESIGN §3.2 工具库)：GET/POST 封装，超时 + 响应截断。
  URL 读取也可用统一寻址 `Newbee.read/1`（§3.2）。
  """

  @default_timeout 30_000
  @max_body 512 * 1024

  @doc "GET 请求。返回 {:ok, %{status, body}} | {:error, reason}。"
  def get(url, headers \\ []) do
    request(:get, url, nil, headers)
  end

  @doc "POST 请求（json 可为 map/string）。"
  def post(url, json, headers \\ []) do
    request(:post, url, json, headers)
  end

  defp request(method, url, json, headers) do
    req =
      Req.new(
        url: url,
        method: method,
        headers:
          (headers
           |> Enum.reject(fn {k, _} -> String.downcase(to_string(k)) == "user-agent" end)
           |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)) ++
            [{"user-agent", "newbee"}],
        json: json,
        receive_timeout: @default_timeout,
        retry: false
      )

    case Req.request(req) do
      {:ok, %{status: status, body: body}} when is_binary(body) ->
        {:ok, %{status: status, body: String.slice(body, 0, @max_body)}}

      {:ok, %{status: status}} ->
        {:ok, %{status: status, body: ""}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :request_failed}
  end
end
