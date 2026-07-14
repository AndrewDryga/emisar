defmodule EmisarWeb.MCP.RawJSONTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.RawJSON

  describe "parse/1" do
    test "retains exact nested value bytes" do
      raw = ~s({"outer": { "n": 1.000e+3, "text": "ok" }})

      assert {:ok, root} = RawJSON.parse(raw)
      assert {:ok, nested} = RawJSON.fetch(root, ["outer"])
      assert RawJSON.slice(raw, nested) == ~s({ "n": 1.000e+3, "text": "ok" })
    end

    test "rejects decoded duplicate keys at every depth" do
      assert {:error, {:duplicate_key, ["outer", "same"]}} =
               RawJSON.parse(~s({"outer":{"same":1,"same":2}}))

      assert {:error, {:duplicate_key, ["same"]}} =
               RawJSON.parse(~s({"same":1,"\\u0073ame":2}))
    end

    test "rejects invalid UTF-8, surrogate escapes, trailing values, and excess depth" do
      assert {:error, :invalid_utf8} = RawJSON.parse(<<123, 34, 120, 34, 58, 255, 125>>)
      assert {:error, :invalid_json} = RawJSON.parse(~s({"x":"\\uD800"}))
      assert {:error, :invalid_json} = RawJSON.parse(~s({"x":"\\uDC00"}))
      assert {:ok, _} = RawJSON.parse(~s({"x":"\\uD83D\\uDE80"}))
      assert {:error, :invalid_json} = RawJSON.parse("{} {}")

      nested = String.duplicate("[", 66) <> "0" <> String.duplicate("]", 66)
      assert {:error, :nesting_too_deep} = RawJSON.parse(nested)
    end

    test "rejects non-JSON number spellings" do
      for invalid <- ["01", "+1", "1.", ".1", "1e", "NaN", "Infinity"] do
        assert {:error, :invalid_json} = RawJSON.parse(invalid), invalid
      end
    end
  end

  describe "tool_call/1" do
    test "extracts run_action args without normalizing numeric spelling or whitespace" do
      raw =
        ~s({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"db.pause","pack_ref":"db@1/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","runner_refs":["db~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"args": { "job_id": 9007199254740993, "ratio": -0.0 },"reason":"maintenance"}}})

      assert {:ok, call} = RawJSON.tool_call(raw)
      assert call.name == "run_action"
      assert call.action_args == ~s({ "job_id": 9007199254740993, "ratio": -0.0 })
    end

    test "does not add raw sidecars to non-action mutations" do
      raw =
        ~s({"jsonrpc":"2.0","id":"draft","method":"tools/call","params":{"name":"create_runbook_draft","arguments":{"title":"T","steps":[{"step_id":"one","action_id":"db.one","pack_ref":"db@1/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","args":{"n":1e3},"runner_selector":{"groups":["db"]},"depends_on":[]},{"step_id":"two","action_id":"db.two","pack_ref":"db@1/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","args": {"n":1000},"runner_selector":{"groups":["db"]},"depends_on":["one"]}]}}})

      assert {:ok, call} = RawJSON.tool_call(raw)
      assert call.name == "create_runbook_draft"
      assert call.action_args == nil
    end

    test "enforces the raw 32 KiB action argument limit" do
      value = String.duplicate("x", 32_768)

      raw =
        ~s({"method":"tools/call","params":{"name":"run_action","arguments":{"args":{"v":"#{value}"}}}})

      assert {:error, :action_args_too_large} = RawJSON.tool_call(raw)
    end
  end
end
