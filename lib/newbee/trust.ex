defmodule Newbee.Trust do
  @moduledoc """
  信任边界（DESIGN §12）：提示注入防护采用**结构隔离 + 能力隔离**，
  不把提示词当安全边界。

  - 文件、URL、profile.md、tool stdout 等**不可信内容**统一包装为带
    `origin/hash/trust=untrusted` 的类型化 envelope，永不拼接成
    `system`/`user` 消息角色——只能出现在 tool result 里；
  - 围栏（`<<<data ...>>>`）只用于可读性，不宣称能让模型免疫指令；
  - 沉睡规则只监控 assistant 输出与待执行工具参数，不因 untrusted 数据里
    出现"指令文本"而生成二次 system reminder（避免攻击者借规则触发器升级权限）；
  - 只有结构化 parser/validator 产出的字段可降级为 trusted（`validate/2`）；
  - LLM 仍可能受内容影响——真正的安全下限由 Host capability 校验、
    路径/网络边界和不可逆操作确认提供。

  ## 副作用可逆性分级（§12）

  `reversible`（文件类，快照 /undo 可回滚）/ `compensatable`（需补偿动作，
  如 git revert）/ `irreversible`（已发送的 HTTP、远端 push、外部 DB 写入——
  执行前必须单独确认或走严格档）。审计事件带分级标签，回退报告不隐含
  "外部世界也回滚了"。
  """

  defstruct origin: nil, hash: nil, trust: :untrusted, content: nil, bytes: 0

  @type t :: %__MODULE__{}

  # ── envelope ──

  @doc "包装不可信内容为类型化 envelope。"
  def envelope(content, origin) when is_binary(content) do
    %__MODULE__{
      origin: to_string(origin),
      hash: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> String.slice(0, 16),
      trust: :untrusted,
      content: content,
      bytes: byte_size(content)
    }
  end

  @doc """
  渲染为 tool result 文本（围栏只用于可读性）。
  """
  def render(%__MODULE__{} = env) do
    """
    <<<data origin="#{env.origin}" hash="#{env.hash}" trust="#{env.trust}" bytes="#{env.bytes}">>
    #{env.content}
    <<<end #{env.hash}>>>
    """
  end

  @doc "不可信内容 → tool 消息（role 恒为 tool，永不进 system/user）。"
  def tool_message(tool_call_id, content, origin) do
    %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => render(envelope(content, origin))
    }
  end

  @doc "结构化降级：parser/validator 校验通过的字段才可信。"
  def validate(%__MODULE__{content: content}, validator) when is_function(validator, 1) do
    case validator.(content) do
      {:ok, parsed} -> {:ok, %__MODULE__{origin: "validated", hash: nil, trust: :trusted, content: parsed, bytes: 0}}
      :error -> {:error, :validation_failed}
    end
  end

  @doc "文本是否仍在不可信围栏内（taint 沿摘要/投影传播的检查点）。"
  def tainted?(text) when is_binary(text), do: String.contains?(text, ~s(trust="untrusted"))

  # ── 可逆性分级 ──

  @reversible [
    ~r/File\.(write|write!|mkdir|cp|rename|touch)/,
    ~r/Newbee\.Tools\.Fs\.(write|append)/,
    ~r/Newbee\.Tools\.Edit\.patch/,
    ~r/Newbee\.Tools\.Structural\./
  ]

  @compensatable [
    ~r/git (commit|checkout|reset|restore)/,
    ~r/Newbee\.Tools\.Git\.(commit|checkout)/,
    ~r/File\.(rm|rm_rf|mv)/,
    ~r/mix deps/
  ]

  @irreversible [
    ~r/git push/,
    ~r/Newbee\.Tools\.Http\./,
    ~r/Req\.(post|put|delete|patch)/,
    ~r/System\.cmd\(.*(curl|wget|ssh|scp)/,
    ~r/rm -rf/
  ]

  @doc "副作用可逆性分级（审计标签）。"
  def reversibility(code) when is_binary(code) do
    cond do
      Enum.any?(@irreversible, &Regex.match?(&1, code)) -> :irreversible
      Enum.any?(@compensatable, &Regex.match?(&1, code)) -> :compensatable
      Enum.any?(@reversible, &Regex.match?(&1, code)) -> :reversible
      true -> :none
    end
  end

  @doc "分级中文说明（审计/回退报告用）。"
  def reversibility_label(:reversible), do: "reversible（快照 /undo 可回滚）"
  def reversibility_label(:compensatable), do: "compensatable（需补偿动作，如 git revert）"
  def reversibility_label(:irreversible), do: "irreversible（外部世界已改变，环境回退不覆盖）"
  def reversibility_label(:none), do: "无外部副作用"
end
