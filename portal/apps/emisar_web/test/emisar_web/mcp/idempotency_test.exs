defmodule EmisarWeb.MCP.IdempotencyTest do
  use ExUnit.Case, async: true

  alias EmisarWeb.MCP.Idempotency

  defp conn_with_header(value) do
    %Plug.Conn{req_headers: [{"idempotency-key", value}]}
  end

  defp conn_without_header, do: %Plug.Conn{req_headers: []}

  describe "resolve/2" do
    test "Layer 2 (body arg) wins over Layer 1 (header)" do
      conn = conn_with_header("from-header")
      assert Idempotency.resolve(conn, %{"idempotency_key" => "from-body"}) == "from-body"
    end

    test "falls back to header when body arg is missing" do
      conn = conn_with_header("from-header")
      assert Idempotency.resolve(conn, %{}) == "from-header"
    end

    test "returns nil when neither source is set" do
      assert Idempotency.resolve(conn_without_header(), %{}) == nil
    end

    test "blank body arg → falls through to header (sanitisation rejects it)" do
      conn = conn_with_header("from-header")
      assert Idempotency.resolve(conn, %{"idempotency_key" => "   "}) == "from-header"
    end

    test "blank header is also rejected → nil" do
      conn = conn_with_header("   ")
      assert Idempotency.resolve(conn, %{}) == nil
    end

    test "over-long key is rejected (would otherwise fill the unique index with junk)" do
      conn = conn_without_header()
      too_long = String.duplicate("x", 201)
      assert Idempotency.resolve(conn, %{"idempotency_key" => too_long}) == nil
    end

    test "a key of exactly 200 bytes is accepted (the cap is inclusive)" do
      # closes MCP-014-T06
      conn = conn_without_header()
      exactly_max = String.duplicate("x", 200)
      assert Idempotency.resolve(conn, %{"idempotency_key" => exactly_max}) == exactly_max
    end

    test "201 bytes is rejected — the boundary is exactly 200" do
      # closes MCP-014-T06
      conn = conn_without_header()
      one_over = String.duplicate("x", 201)
      assert Idempotency.resolve(conn, %{"idempotency_key" => one_over}) == nil
    end

    test "non-string body input is rejected" do
      conn = conn_without_header()
      assert Idempotency.resolve(conn, %{"idempotency_key" => 12_345}) == nil
    end

    test "trims whitespace before deciding" do
      assert Idempotency.resolve(conn_without_header(), %{"idempotency_key" => "  abc  "}) ==
               "abc"
    end
  end

  describe "per_runner/2" do
    test "nil key stays nil (no replay semantics ⇒ no suffix)" do
      assert Idempotency.per_runner(nil, "runner-1") == nil
    end

    test "suffixes the runner id so each fan-out row claims a distinct unique-index slot" do
      assert Idempotency.per_runner("idem-abc", "runner-1") == "idem-abc:runner-1"
      assert Idempotency.per_runner("idem-abc", "runner-2") == "idem-abc:runner-2"
    end

    test "deterministic: same (key, runner_id) → same result (so retries replay cleanly)" do
      assert Idempotency.per_runner("k", "r") == Idempotency.per_runner("k", "r")
    end
  end
end
