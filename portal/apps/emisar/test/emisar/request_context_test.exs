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
  end
end
