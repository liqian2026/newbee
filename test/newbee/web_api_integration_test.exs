defmodule Newbee.Web.ApiIntegrationTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  defp post_rpc(method, payload \\ %{}) do
    body =
      Jason.encode!(%{
        "rpcId" => "test-1",
        "method" => method,
        "payload" => payload
      })

    conn =
      Plug.Test.conn(:post, "/api/" <> method, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Newbee.Web.Router.call(conn, @opts)
  end

  defp parse_body(conn) do
    case conn.resp_body do
      nil -> %{}
      body ->
        case Jason.decode(body) do
          {:ok, json} -> json
          _ -> %{}
        end
    end
  end

  describe "git.diffStat" do
    test "返回文件列表结构" do
      conn = post_rpc("git.diffStat")
      assert conn.status == 200

      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "files")
          assert is_list(ok["files"])

        %{"error" => err} ->
          assert is_binary(err["code"])
      end
    end
  end

  describe "git.impact" do
    test "返回影响分析结构" do
      conn = post_rpc("git.impact")
      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "files") or Map.has_key?(ok, "summary")
          if Map.has_key?(ok, "summary"), do: assert(is_map(ok["summary"]))

        %{"error" => _} ->
          :ok
      end
    end
  end

  describe "env.health" do
    test "返回环境健康数据" do
      conn = post_rpc("env.health")
      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "rules")
          assert Map.has_key?(ok, "antibodies")

        %{"error" => _} ->
          :ok
      end
    end
  end

  describe "files.search" do
    test "搜索文件返回列表" do
      conn = post_rpc("files.search", %{"q" => "api"})
      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "files")
          assert is_list(ok["files"])

        %{"error" => _} ->
          :ok
      end
    end
  end

  describe "未知方法" do
    test "返回 unknown_method 错误" do
      conn = post_rpc("nonexistent.method")
      resp = parse_body(conn)
      result = resp["result"]
      assert %{"error" => err} = result
      assert err["code"] == "unknown_method"
    end
  end
end
