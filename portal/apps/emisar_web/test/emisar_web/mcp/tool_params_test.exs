defmodule EmisarWeb.MCP.ToolParamsTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ToolParams

  describe "limit/3" do
    test "nil takes the default" do
      assert ToolParams.limit(nil, 15, 50) == {:ok, 15}
    end

    test "an in-range integer passes through" do
      assert ToolParams.limit(50, 15, 50) == {:ok, 50}
      assert ToolParams.limit(1, 15, 50) == {:ok, 1}
    end

    test "a canonical integer string coerces" do
      assert ToolParams.limit("50", 15, 50) == {:ok, 50}
      assert ToolParams.limit("1", 15, 50) == {:ok, 1}
    end

    test "an out-of-range value states the range" do
      assert ToolParams.limit(0, 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50."}

      assert ToolParams.limit(51, 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50."}

      # A coerced string hits the same range check.
      assert ToolParams.limit("51", 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50."}
    end

    test "a genuine type mismatch names the received JSON type" do
      assert ToolParams.limit("many", 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50; it was sent as a string."}

      assert ToolParams.limit("12.5", 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50; it was sent as a string."}

      assert ToolParams.limit(true, 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50; it was sent as a boolean."}

      assert ToolParams.limit(12.5, 15, 50) ==
               {:error,
                "limit must be a JSON integer from 1 to 50; it was sent as a non-integer number."}

      assert ToolParams.limit([15], 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50; it was sent as an array."}

      assert ToolParams.limit(%{"n" => 15}, 15, 50) ==
               {:error, "limit must be a JSON integer from 1 to 50; it was sent as an object."}
    end
  end

  describe "boolean/3" do
    test "nil takes the default" do
      assert ToolParams.boolean(nil, false, "issues_only") == {:ok, false}
    end

    test "booleans pass through and literal strings coerce" do
      assert ToolParams.boolean(true, false, "issues_only") == {:ok, true}
      assert ToolParams.boolean("true", false, "issues_only") == {:ok, true}
      assert ToolParams.boolean("false", true, "issues_only") == {:ok, false}
    end

    test "a mismatch names the field and the received JSON type" do
      assert ToolParams.boolean("yes", false, "issues_only") ==
               {:error, "issues_only must be a JSON boolean; it was sent as a string."}

      assert ToolParams.boolean(1, false, "issues_only") ==
               {:error, "issues_only must be a JSON boolean; it was sent as a number."}
    end
  end
end
