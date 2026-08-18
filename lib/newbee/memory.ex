defmodule Newbee.Memory do
  @moduledoc """
  全局记忆 (DESIGN §6.4.3)：按 topic 索引的持久化记忆条目。
  `~/.newbee/memory/<topic>.md`。自动脱敏：写入时剥离形如
  sk-xxx / Bearer xxx / key=xxx 的密钥片段。
  """

  @dir Path.join(System.user_home!(), ".newbee/memory")

  @doc "读一条记忆。返回 {:ok, content} | {:error, :not_found}。"
  def read(topic) do
    path = Path.join(@dir, sanitize_topic(topic) <> ".md")

    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "写一条记忆（自动脱敏）。"
  def write(topic, content) do
    File.mkdir_p!(@dir)
    File.write!(Path.join(@dir, sanitize_topic(topic) <> ".md"), redact(content))
    :ok
  end

  @doc "删除一条记忆。"
  def delete(topic) do
    File.rm(Path.join(@dir, sanitize_topic(topic) <> ".md"))
    :ok
  end

  @doc "记忆主题列表。"
  def topics do
    @dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".md")))
    |> Enum.sort()
  end

  # 密钥形态：sk-<token> / Bearer <token> / <KEY>=<value> 长值
  @secret ~r/(sk-[A-Za-z0-9_\-]{8,}|Bearer\s+[A-Za-z0-9_\-\.]{8,}|\b[A-Z_]{3,}_KEY\s*=\s*[^\s]{8,})/
  @redacted "…[已脱敏]…"

  defp redact(content) do
    Regex.replace(@secret, content, @redacted)
  end

  defp sanitize_topic(topic) do
    topic
    |> String.replace(~r/[^A-Za-z0-9_\-\.]/, "_")
    |> String.slice(0, 64)
  end
end
