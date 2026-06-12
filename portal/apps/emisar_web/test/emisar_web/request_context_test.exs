defmodule EmisarWeb.RequestContextTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Emisar.RequestContext
  alias EmisarWeb.RequestContext, as: Builder

  defp conn, do: Plug.Test.conn(:get, "/")

  describe "from_conn/1" do
    test "pulls user-agent, request-id (resp header), and mcp-session-id from the request" do
      context =
        conn()
        |> put_req_header("user-agent", "curl/8.5.0")
        |> put_req_header("mcp-session-id", "sess_1")
        |> put_resp_header("x-request-id", "req_1")
        |> Builder.from_conn()

      assert %RequestContext{} = context
      assert context.user_agent == "curl/8.5.0"
      assert context.request_id == "req_1"
      assert context.mcp_session_id == "sess_1"
    end

    test "trusts the first x-forwarded-for hop, trimmed" do
      context =
        conn()
        |> put_req_header("x-forwarded-for", "203.0.113.9, 10.0.0.1")
        |> Builder.from_conn()

      assert context.ip_address == "203.0.113.9"
    end

    test "falls back to the socket peer when there is no forwarded header" do
      context = Builder.from_conn(%{conn() | remote_ip: {198, 51, 100, 4}})
      assert context.ip_address == "198.51.100.4"
    end

    test "strips the ::ffff: IPv4-mapped wrapper an IPv6 listener surfaces" do
      context =
        conn()
        |> put_req_header("x-forwarded-for", "::ffff:192.0.2.5")
        |> Builder.from_conn()

      assert context.ip_address == "192.0.2.5"
    end

    test "is an all-nil struct when no client metadata is present" do
      # No headers, and a non-tuple remote_ip exercises the peer fallback's
      # nil path — the system/engine-origin shape.
      context = Builder.from_conn(%{conn() | remote_ip: nil})
      assert context == %RequestContext{}
    end
  end
end
