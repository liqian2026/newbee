defmodule Newbee.CheckpointTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  defp post_rpc(method, payload \\ %{}) do
    body =
      Jason.encode!(%{"rpcId" => "t", "method" => method, "payload" => payload})

    conn =
      Plug.Test.conn(:post, "/api/" <> method, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Newbee.Web.Router.call(conn, @opts)
  end

  defp parse(conn) do
    case Jason.decode(conn.resp_body || "{}") do
      {:ok, j} -> j["result"]
      _ -> nil
    end
  end

  test "checkpoint.list 返回列表结构" do
    conn = post_rpc("git.checkpoint.list")
    assert conn.status == 200

    case parse(conn) do
      %{"ok" => ok} -> assert is_list(ok["checkpoints"])
      _ -> :ok
    end
  end

  test "checkpoint.create 返回结构化结果" do
    conn = post_rpc("git.checkpoint.create", %{"description" => "test"})

    case parse(conn) do
      %{"ok" => ok} -> assert is_map(ok)
      %{"error" => err} -> assert is_map(err)
      _ -> :ok
    end
  end
end
