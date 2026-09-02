defmodule Emisar.RequestContextTest do
  use ExUnit.Case, async: true
  alias Emisar.RequestContext

  describe "new/1" do
    test "keeps only the fixed request-metadata fields" do
      context =
        RequestContext.new(%{
          ip_address: "203.0.113.7",
          user_agent: "emisar-mcp/1.0",
          request_id: "req-123",
          ignored: "not persisted"
        })

      assert context == %RequestContext{
               ip_address: "203.0.113.7",
               user_agent: "emisar-mcp/1.0",
               request_id: "req-123"
             }
    end

    test "accepts keyword fields and defaults omitted metadata to nil" do
      assert RequestContext.new(request_id: "req-123") == %RequestContext{request_id: "req-123"}
    end

    test "strips terminal controls and bidi formatting from captured request metadata" do
      context =
        RequestContext.new(
          ip_address: "203.0." <> <<27>> <> "113.7",
          user_agent: "agent\u202Etxt",
          request_id: "req\u200D123"
        )

      assert context.ip_address == "203.0.113.7"
      assert context.user_agent == "agenttxt"
      assert context.request_id == "req123"
    end
  end
end
