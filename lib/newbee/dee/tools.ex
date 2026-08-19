defmodule Newbee.DEE.Tools do
  @moduledoc """
  工具注册表 (DESIGN §7 dee/tools.ex) ⭐：集中登记环境内全部工具
  （内置 + 热载），提取一行签名摘要。

  - **工具即文档**（§3.5）：每个工具的 @moduledoc 首行自动成为签名；
  - **渐进式披露**（§9.12）：prompt 只注入一行签名清单，模型按需
    `Newbee.read("tool://Module")` 拉全文；
  - **价签**（§9.11）：签名清单附带实测成功率/耗时（见 PriceTags）。
  """

  @builtin [
    Newbee.Tools.Edit,
    Newbee.Tools.Structural,
    Newbee.Tools.Fs,
    Newbee.Tools.Run,
    Newbee.Tools.Git,
    Newbee.Tools.Search,
    Newbee.Tools.Json,
    Newbee.Tools.Http,
    Newbee.Tools.Scaffold,
    Newbee.Tools.Introspect,
    Newbee.Tools.JSpace,
    Newbee.DEE.RepoMap
  ]

  @doc "内置工具模块列表。"
  def builtin, do: @builtin

  @doc "热载工具模块名列表（按文件名推导）。"
  def hot_modules do
    Newbee.DEE.Tools.HotLoader.tool_files()
    |> Enum.map(fn f ->
      f |> Path.basename(".ex") |> Macro.camelize()
    end)
  end

  @doc """
  全部工具清单：[%{name, summary, hot?}]（name 为模块全名或短名，按热载先后）。
  summary 取 @moduledoc 首行（≤120 字符），无文档则空。
  """
  def list do
    builtin_modules = Enum.map(@builtin, fn m -> {m, false} end)
    hot_modules = Enum.map(hot_modules(), &{String.to_atom("Elixir.Newbee.Tools." <> &1), true})

    (builtin_modules ++ hot_modules)
    |> Enum.map(fn {mod, hot?} ->
      %{name: inspect(mod), summary: summary(mod), hot?: hot?}
    end)
  end

  @doc "单个工具签名。"
  def describe(module) when is_atom(module) do
    %{name: inspect(module), summary: summary(module), hot?: module not in @builtin}
  end

  defp summary(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        doc |> String.split("\n") |> hd() |> String.trim() |> String.slice(0, 120)

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  @doc "prompt 注入用的一行签名清单（含价签，渐进式披露）。"
  def prompt_section do
    list()
    |> Enum.map_join("\n", fn t ->
      "  - #{t.name}#{if t.hot?, do: " (热载)", else: ""}: #{t.summary}"
    end)
    |> case do
      "" -> ""
      body -> "\n## 工具清单（一行签名；按需 Newbee.read(\"tool://模块名\") 取全文）\n" <> body <> "\n"
    end
  end
end
