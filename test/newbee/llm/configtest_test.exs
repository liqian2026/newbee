defmodule Newbee.LLM.ConfigTest do
  use ExUnit.Case, async: false

  # 这些测试验证真实配置的解析（用户环境），无配置时跳过而非失败
  setup do
    configured? =
      Enum.any?(
        [
          System.get_env("NEWBEE_MODEL_JSON"),
          "model.json",
          "model.local.json",
          Path.join([System.user_home!(), ".newbee", "model.json"])
        ],
        &(&1 && File.exists?(&1))
      )

    if configured? do
      :ok
    else
      {:skip, "未配置 model.json（NEWBEE_MODEL_JSON / ./model.json / ~/.newbee/model.json）"}
    end
  end

  test "从 ~/.newbee/model.json（或 env 覆盖）加载并解析角色" do
    # 不断言具体型号（用户会换 provider）；断言 roles→providers 的解析逻辑正确
    cfg = Newbee.LLM.Config.load()
    role = cfg["roles"]["default"]
    provider = cfg["providers"][role["provider"]]

    client = Newbee.LLM.Config.client_for("default")
    assert client.model == role["model"]
    assert client.base_url == provider["baseUrl"]
    assert client.reasoning_effort == role["reasoningEffort"]
  end

  test "默认角色带真实 api_key（直接写在配置里，非占位）" do
    assert is_binary(Newbee.LLM.Config.client_for("default").api_key)
    refute Newbee.LLM.Config.client_for("default").api_key == "<redacted>"
  end

  test "调用点存在性：provider 配置完整" do
    cfg = Newbee.LLM.Config.load()
    assert cfg["providers"]["guoyu"]["apiKey"] != "${prime:guoyu}"
    assert is_binary(cfg["providers"]["guoyu"]["apiKey"])
  end

  test "未知角色回退 default" do
    c1 = Newbee.LLM.Config.client_for("nonexistent")
    c2 = Newbee.LLM.Config.client_for("default")
    assert c1.model == c2.model
  end
end
