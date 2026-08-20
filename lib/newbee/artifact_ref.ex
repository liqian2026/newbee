defmodule Newbee.ArtifactRef do
  @moduledoc """
  ArtifactRef（DESIGN §4.4）：内容寻址句柄。大值显式 artifactize 后以
  句柄形式存活于 binding，迁移时只搬句柄，按需加载并受背压/总量预算控制。
  """

  @enforce_keys [:id, :path, :bytes, :sha256]
  defstruct [:id, :path, :bytes, :sha256, :media_type]

  def new(path) do
    {:ok, bin} = File.read(path)
    sha = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

    %__MODULE__{
      id: "art_" <> String.slice(sha, 0, 16),
      path: path,
      bytes: byte_size(bin),
      sha256: sha
    }
  end

  @doc "按需加载（校验内容寻址 hash）。"
  def load(%__MODULE__{path: path, sha256: sha}) do
    with {:ok, bin} <- File.read(path),
         ^sha <- :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower) do
      {:ok, bin}
    else
      _ -> {:error, :artifact_corrupt_or_missing}
    end
  end
end
