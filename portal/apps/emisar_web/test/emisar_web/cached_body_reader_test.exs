defmodule EmisarWeb.CachedBodyReaderTest do
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.CachedBodyReader

  test "caches the complete Paddle webhook body" do
    conn = build_conn(:post, "/webhooks/paddle", "{}")

    assert {:ok, "{}", conn} = CachedBodyReader.read_body(conn, [])
    assert conn.assigns.raw_body == "{}"
  end

  test "passes an incomplete webhook body through without caching it" do
    conn = build_conn(:post, "/webhooks/paddle", "{}")

    assert {:more, _body, conn} = CachedBodyReader.read_body(conn, length: 1, read_length: 1)
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "caches a bounded MCP body" do
    conn = build_conn(:post, "/api/mcp/rpc", "{}")

    assert {:ok, "{}", conn} = CachedBodyReader.read_body(conn, [])
    assert conn.assigns.raw_body == "{}"
  end

  test "refuses to retain an MCP body above 128 KiB" do
    body = String.duplicate("x", 128 * 1024 + 1)
    conn = build_conn(:post, "/api/mcp/rpc", body)

    assert {:more, _partial, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "reads a Postmark body at exactly 64 KiB without caching it" do
    body = String.duplicate("x", 64 * 1024)
    conn = build_conn(:post, "/webhooks/postmark", body)

    assert {:ok, ^body, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "refuses a Postmark body above 64 KiB" do
    body = String.duplicate("x", 64 * 1024 + 1)
    conn = build_conn(:post, "/webhooks/postmark", body)

    assert {:more, _partial, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "refuses a device-grant body above 8 KiB" do
    body = String.duplicate("x", 8 * 1024 + 1)
    conn = build_conn(:post, "/api/mcp/device_token", body)

    assert {:more, _partial, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "refuses an OAuth body above 64 KiB" do
    body = String.duplicate("x", 64 * 1024 + 1)
    conn = build_conn(:post, "/oauth/token", body)

    assert {:more, _partial, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "refuses a runner enrollment body above 128 KiB" do
    body = String.duplicate("x", 128 * 1024 + 1)
    conn = build_conn(:post, "/runner/register", body)

    assert {:more, _partial, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "reads a runner enrollment carrying the domain's largest legal labels map" do
    # The runner changeset admits 64 KiB of `labels`, so the transport bound has
    # to clear it — a body the domain would accept must not die at the parser.
    body = String.duplicate("x", 64 * 1024)
    conn = build_conn(:post, "/runner/register", body)

    assert {:ok, ^body, conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "does not cache bodies for other routes" do
    conn = build_conn(:post, "/api/other", "{}")

    assert {:ok, "{}", conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end
end
