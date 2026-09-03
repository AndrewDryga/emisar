defmodule EmisarWeb.RequestContextTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias Emisar.RequestContext
  alias EmisarWeb.RequestContext, as: Builder

  defp conn, do: Plug.Test.conn(:get, "/")

  describe "from_conn/1" do
    test "pulls user-agent and request-id response metadata" do
      context =
        conn()
        |> put_req_header("user-agent", "curl/8.5.0")
        |> put_resp_header("x-request-id", "req_1")
        |> Builder.from_conn()

      assert %RequestContext{} = context
      assert context.user_agent == "curl/8.5.0"
      assert context.request_id == "req_1"
    end

    test "uses GCP's right-anchored client IP and ignores a forged prefix" do
      context =
        conn()
        |> put_req_header("x-forwarded-for", "forged, 203.0.113.9, 8.233.97.247")
        |> Builder.from_conn()

      assert context.ip_address == "203.0.113.9"
    end

    test "falls back to the socket peer when there is no forwarded header" do
      context = Builder.from_conn(%{conn() | remote_ip: {198, 51, 100, 4}})
      assert context.ip_address == "198.51.100.4"
    end

    test "does not trust a forwarded header without GCP's two-value tail" do
      context =
        conn()
        |> Map.put(:remote_ip, {198, 51, 100, 4})
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> Builder.from_conn()

      assert context.ip_address == "198.51.100.4"
    end

    test "joins repeated forwarded header lines, so a caller's line cannot win" do
      # `put_req_header/3` replaces, so the duplicate line is set directly.
      req_headers = [
        {"x-forwarded-for", "forged, 198.51.100.7, 192.0.2.1"},
        {"x-forwarded-for", "203.0.113.9, 8.233.97.247"}
      ]

      context = Builder.from_conn(%{conn() | req_headers: req_headers})

      assert context.ip_address == "203.0.113.9"
    end

    test "strips the ::ffff: IPv4-mapped wrapper an IPv6 listener surfaces" do
      context =
        conn()
        |> put_req_header("x-forwarded-for", "::ffff:192.0.2.5, 8.233.97.247")
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

  describe "from_socket/1" do
    test "joins repeated forwarded header lines like the HTTP path" do
      req_headers = [
        {"x-forwarded-for", "forged, 198.51.100.7, 192.0.2.1"},
        {"x-forwarded-for", "203.0.113.9, 8.233.97.247"}
      ]

      context = Builder.from_socket(socket_with_headers(req_headers))

      assert context.ip_address == "203.0.113.9"
    end

    test "falls back to the socket peer when no forwarded header is present" do
      context = Builder.from_socket(socket_with_headers([]))

      assert context.ip_address == "127.0.0.1"
    end
  end

  # LiveView's mount-time `connect_info` may be the request `%Plug.Conn{}`
  # itself, and it derives `:x_headers` from that conn's headers in order —
  # duplicates included.
  defp socket_with_headers(req_headers) do
    %Phoenix.LiveView.Socket{private: %{connect_info: %{conn() | req_headers: req_headers}}}
  end
end
