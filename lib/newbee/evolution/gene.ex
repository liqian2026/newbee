defmodule Newbee.Evolution.Gene do
  @moduledoc """
  基因库 (DESIGN §6.2 L3 / M5 bundle) ⭐：进化产出的 L3 工具以 bundle 打包
  （工具+规则+prompt 片段），携带 fitness 分数与出处，可跨用户分享/安装。

  一个 bundle = 一个 JSON 文件（~/.newbee/genes/<name>-<version>.json）：
    %{name, version, provenance, fitness, tools: [src], rules: [...], prompts: [...]}
  """

  @dir Path.join(System.user_home!(), ".newbee/genes")

  @doc "导出当前环境为 bundle。返回 {:ok, path}。"
  def export(name, opts \\ []) do
    version = Keyword.get(opts, :version, "1.0.0")
    provenance = Keyword.get(opts, :provenance, "evolver")
    fitness = Keyword.get(opts, :fitness, nil)

    bundle = %{
      name: name,
      version: version,
      provenance: provenance,
      fitness: fitness,
      tools: tool_sources(),
      rules: rule_sources(),
      prompts: prompt_sources(),
      exported_at: DateTime.to_iso8601(DateTime.utc_now())
    }

    File.mkdir_p!(@dir)
    path = Path.join(@dir, "#{name}-#{version}.json")
    File.write!(path, Jason.encode_to_iodata!(bundle, pretty: true))
    {:ok, path}
  end

  @doc "导入 bundle 到本机环境（工具落盘 + 规则注册）。返回 {:ok, %{tools, rules, prompts}}。"
  def import(path) do
    with {:ok, body} <- File.read(path),
         {:ok, bundle} <- Jason.decode(body) do
      tools =
        Enum.map(bundle["tools"] || [], fn src ->
          module = src |> extract_module_name()
          {:ok, _p} = Newbee.DEE.Tools.HotLoader.publish(module, src, message: "import gene #{bundle["name"]}")
          module
        end)

      rules =
        Enum.map(bundle["rules"] || [], fn r ->
          Newbee.DEE.Rules.add(r["id"], r["pattern"], r["injection"], source: :gene)
          r["id"]
        end)

      prompts =
        Enum.map(bundle["prompts"] || [], fn p ->
          file = Path.join(System.user_home!(), ".newbee/prompts/#{p["id"]}.md")
          File.mkdir_p!(Path.dirname(file))
          File.write!(file, p["content"])
          p["id"]
        end)

      {:ok, %{tools: tools, rules: rules, prompts: prompts}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "基因列表（新→旧）。"
  def list do
    @dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, b} ->
              [
                %{
                  name: b["name"],
                  version: b["version"],
                  fitness: b["fitness"],
                  provenance: b["provenance"],
                  exported_at: b["exported_at"]
                }
              ]

            _ ->
              []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.exported_at, :desc)
  end

  defp tool_sources do
    Newbee.DEE.Tools.HotLoader.tool_files()
    |> Enum.map(fn f ->
      case File.read(f) do
        {:ok, body} -> body
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp rule_sources do
    if Process.whereis(Newbee.DEE.Rules) do
      Newbee.DEE.Rules.list()
    else
      []
    end
  end

  defp prompt_sources do
    dir = Path.join(System.user_home!(), ".newbee/prompts")

    if File.dir?(dir) do
      dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(fn f ->
        %{id: Path.basename(f, ".md"), content: File.read!(f)}
      end)
    else
      []
    end
  end

  defp extract_module_name(source) do
    case Regex.run(~r/defmodule\s+([A-Za-z0-9_\.]+)/, source) do
      [_, full] -> full |> String.split(".") |> List.last()
      _ -> "Tool#{:erlang.unique_integer([:positive])}"
    end
  end
end
