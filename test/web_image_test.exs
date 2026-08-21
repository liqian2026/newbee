defmodule Newbee.WebImageTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.Image

  @tiny_png "data:image/png;base64," <> Base.encode64("fake-png-bytes")

  test "validate_data_url 接受合法 data URL" do
    assert {:ok, {"image/png", "fake-png-bytes"}} = Image.validate_data_url(@tiny_png)
  end

  test "validate_data_url 拒绝非图片 data URL" do
    assert {:error, {:invalid_data_url, _}} = Image.validate_data_url("data:text/plain;base64," <> Base.encode64("hi"))
  end

  test "message_with_images 构造多模态 user 消息" do
    assert {:ok, msg} = Image.message_with_images([@tiny_png], "看看这个")
    assert msg["role"] == "user"
    assert [%{"type" => "text", "text" => "看看这个"}, %{"type" => "image_url"} | _] = msg["content"]
  end

  test "message_with_images 空图列表报错" do
    assert {:error, :invalid_images} = Image.message_with_images([], "x")
  end
end
