defmodule Newbee.LLM.Image do
  @moduledoc """
  本地图片到 OpenAI-compatible 多模态 user message 的转换。

  图片以内联 data URL 发送并随 transcript 持久化；默认限制 8 MiB，避免单张图片
  挤满上下文。支持 PNG、JPEG、GIF、WebP。
  """

  @max_bytes 8 * 1024 * 1024
  @mime_by_extension %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  @default_prompt "请分析这张错误截图，定位相关源码中的 bug，直接修复并运行必要的验证。"

  def message(path, prompt \\ nil)

  def message(path, prompt) when is_binary(path) do
    with {:ok, data_url} <- data_url(path),
         {:ok, text} <- normalize_prompt(prompt) do
      {:ok,
       %{
         "role" => "user",
         "content" => [
           %{"type" => "text", "text" => text},
           %{"type" => "image_url", "image_url" => %{"url" => data_url}}
         ]
       }}
    end
  end

  def message(_, _), do: {:error, :invalid_image_path}

  @doc "读取图片并编码为 data URL。"
  def data_url(path) when is_binary(path) do
    extension = path |> Path.extname() |> String.downcase()

    with {:ok, mime} <- Map.fetch(@mime_by_extension, extension),
         {:ok, %{type: :regular, size: size}} <- File.stat(path),
         true <- size <= @max_bytes,
         {:ok, binary} <- File.read(path) do
      {:ok, "data:#{mime};base64," <> Base.encode64(binary)}
    else
      :error -> {:error, {:unsupported_image_type, extension}}
      {:error, :enoent} -> {:error, :image_not_found}
      {:error, reason} -> {:error, {:image_stat_failed, reason}}
      false -> {:error, {:image_too_large, @max_bytes}}
      _ -> {:error, :image_not_found}
    end
  end

  def data_url(_), do: {:error, :invalid_image_path}

  @doc false
  def max_bytes, do: @max_bytes

  defp normalize_prompt(nil), do: {:ok, @default_prompt}

  defp normalize_prompt(prompt) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> {:ok, @default_prompt}
      text -> {:ok, text}
    end
  end

  defp normalize_prompt(_), do: {:error, :invalid_image_prompt}
end
