defmodule Newbee.SessionTest do
  use ExUnit.Case, async: false
  alias Newbee.Session

  test "transcript 追加与读取" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")
    Session.append(s, %{"role" => "user", "content" => "hi"})
    Session.append(s, %{"role" => "assistant", "content" => "yo"})

    msgs = Session.messages(s)
    assert length(msgs) == 2
    assert Enum.at(msgs, 0)["content"] == "hi"
  end

  test "绑定快照：可序列化保留，PID/函数 tombstone" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")

    Session.save_bindings(s, [
      good: "hello",
      num: 42,
      bad_pid: self(),
      bad_fun: fn -> 1 end
    ])

    restored = Session.load_bindings(s)
    assert restored[:good] == "hello"
    assert restored[:num] == 42
    refute Keyword.has_key?(restored, :bad_pid)
    refute Keyword.has_key?(restored, :bad_fun)
  end

  test "transcript 坏行（崩溃写了一半）跳过而非崩" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")
    Session.append(s, %{"role" => "user", "content" => "hi"})
    File.write!(s.transcript, ~s({"role": "assistant", "content": "断了一半\n), [:append])
    Session.append(s, %{"role" => "user", "content" => "after"})

    msgs = Session.messages(s)
    assert Enum.map(msgs, & &1["content"]) == ["hi", "after"]
  end
end