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

  # Bandit hands the plug the raw request target (`request_path`) and the
  # router matches the cleaned segments (`path_info`), so a spelling the router
  # accepts must meet the same cap. Plug.Test reads `//host/path` as a URL, so
  # the doubled-slash conns are shaped by hand the way Bandit shapes them.
  test "a trailing or doubled slash meets the same cap and cache as the canonical path" do
    body = String.duplicate("x", 64 * 1024 + 1)

    assert {:more, _partial, _conn} =
             CachedBodyReader.read_body(build_conn(:post, "/webhooks/postmark/", body), [])

    doubled = %{
      build_conn(:post, "/webhooks/postmark", body)
      | request_path: "//webhooks/postmark"
    }

    assert doubled.path_info == ["webhooks", "postmark"]
    assert {:more, _partial, _conn} = CachedBodyReader.read_body(doubled, [])

    conn = build_conn(:post, "/api/mcp/rpc/", "{}")
    assert {:ok, "{}", conn} = CachedBodyReader.read_body(conn, [])
    assert conn.assigns.raw_body == "{}"

    scim = String.duplicate("x", 2 * 1024 * 1024 + 1)
    doubled = %{build_conn(:post, "/scim/v2/Users", scim) | request_path: "//scim/v2/Users"}
    assert {:more, _partial, _conn} = CachedBodyReader.read_body(doubled, [])
  end

  test "does not cache bodies for other routes" do
    conn = build_conn(:post, "/api/other", "{}")

    assert {:ok, "{}", conn} = CachedBodyReader.read_body(conn, [])
    refute Map.has_key?(conn.assigns, :raw_body)
  end
end
