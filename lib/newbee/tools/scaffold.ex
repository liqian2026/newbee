defmodule Newbee.Tools.Scaffold do
  @moduledoc """
  工程脚手架工具 (DESIGN §3.2 工程)：`mix new` / `mix deps.get` 等。
  内部复用 Newbee.Tools.Run.sh（超时 + 输出上限）。
  """

  @doc "创建新 mix 工程（当前目录下）。返回 {:ok, output} | {:error, output}。"
  def new_project(name) do
    result = Newbee.Tools.Run.sh("mix new #{name}")
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "拉取依赖（mix deps.get）。"
  def deps_get do
    result = Newbee.Tools.Run.sh("mix deps.get")
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "编译（mix compile）。"
  def compile do
    Newbee.Tools.Run.mix_compile()
  end

  @doc "跑测试（mix test，可传文件列表）。"
  def test(files \\ []) do
    Newbee.Tools.Run.mix_test(files)
  end
end
