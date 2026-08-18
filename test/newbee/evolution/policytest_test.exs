defmodule Newbee.Evolution.PolicyTest do
  use ExUnit.Case, async: false
  alias Newbee.Evolution.Policy

  setup do
    file = Path.join(System.user_home!(), ".newbee/config.json")
    backup = if File.exists?(file), do: File.read!(file), else: nil

    on_exit(fn ->
      if backup, do: File.write!(file, backup), else: File.rm(file)
    end)

    :ok
  end

  test "默认 :background" do
    File.rm(Path.join(System.user_home!(), ".newbee/config.json"))
    assert Policy.get() == :background
  end

  test "set/get 持久化" do
    :ok = Policy.set(:auto)
    assert Policy.get() == :auto
    :ok = Policy.set(:hint)
    assert Policy.get() == :hint
  end
end