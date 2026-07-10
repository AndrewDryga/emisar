defmodule EmisarWeb.MCP.TransportTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.Transport

  @supported ["2025-06-18", "2024-11-05"]

  describe "allowed_origin?/2" do
    test "an absent Origin (server-to-server / stdio bridge / curl) is allowed" do
      assert Transport.allowed_origin?([], "https://emisar.dev")
    end

    test "the server's own origin is allowed" do
      assert Transport.allowed_origin?(["https://emisar.dev"], "https://emisar.dev")
    end

    test "a cross-origin browser Origin is rejected" do
      refute Transport.allowed_origin?(["https://evil.example.com"], "https://emisar.dev")
    end

    test "a scheme/port mismatch is a different origin" do
      refute Transport.allowed_origin?(["http://emisar.dev"], "https://emisar.dev")
      refute Transport.allowed_origin?(["https://emisar.dev:8443"], "https://emisar.dev")
    end

    test ~s(the opaque "null" origin is rejected) do
      refute Transport.allowed_origin?(["null"], "https://emisar.dev")
    end
  end

  describe "json_content_type?/1" do
    test "an absent content type is tolerated" do
      assert Transport.json_content_type?([])
    end

    test "application/json, with or without parameters, is JSON" do
      assert Transport.json_content_type?(["application/json"])
      assert Transport.json_content_type?(["application/json; charset=utf-8"])
      assert Transport.json_content_type?(["Application/JSON"])
    end

    test "any other media type is not JSON" do
      refute Transport.json_content_type?(["text/plain"])
      refute Transport.json_content_type?(["application/json-rpc"])
      refute Transport.json_content_type?(["multipart/form-data"])
    end
  end

  describe "accepts_json?/1" do
    test "an absent Accept is treated as */*" do
      assert Transport.accepts_json?([])
    end

    test "an Accept that admits application/json passes" do
      assert Transport.accepts_json?(["application/json"])
      assert Transport.accepts_json?(["application/json, text/event-stream"])
      assert Transport.accepts_json?(["application/*"])
      assert Transport.accepts_json?(["*/*"])
      assert Transport.accepts_json?(["text/html, application/json;q=0.9"])
    end

    test "an SSE-only Accept can't be served by this JSON endpoint" do
      refute Transport.accepts_json?(["text/event-stream"])
      refute Transport.accepts_json?(["text/plain"])
    end
  end

  describe "acceptable_protocol_version?/2" do
    test "an absent header is tolerated (the spec assumes a default)" do
      assert Transport.acceptable_protocol_version?([], @supported)
    end

    test "a supported version is accepted" do
      assert Transport.acceptable_protocol_version?(["2025-06-18"], @supported)
      assert Transport.acceptable_protocol_version?(["2024-11-05"], @supported)
    end

    test "an unsupported or garbage version is rejected" do
      refute Transport.acceptable_protocol_version?(["1999-01-01"], @supported)
      refute Transport.acceptable_protocol_version?(["not-a-version"], @supported)
    end
  end
end
