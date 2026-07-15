defmodule EmisarWeb.MCP.ToolSchemaTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ToolSchema

  defp action(args), do: %{args_schema: %{"args" => args}}

  describe "action_args_schema/1" do
    test "projects primitive and Emisar argument types" do
      schema =
        ToolSchema.action_args_schema(
          action([
            %{"name" => "host", "type" => "string"},
            %{"name" => "count", "type" => "integer"},
            %{"name" => "ratio", "type" => "number"},
            %{"name" => "force", "type" => "boolean"},
            %{"name" => "timeout", "type" => "duration"},
            %{"name" => "tags", "type" => "string_array"},
            %{"name" => "ports", "type" => "integer_array"},
            %{"name" => "future", "type" => "unknown"}
          ])
        )

      assert schema.properties["host"].type == "string"
      assert schema.properties["count"].type == "integer"
      assert schema.properties["ratio"].type == "number"
      assert schema.properties["force"].type == "boolean"
      assert schema.properties["timeout"].pattern == "^[0-9]+(ns|us|ms|s|m|h)$"
      assert schema.properties["tags"] == %{type: "array", items: %{type: "string"}}
      assert schema.properties["ports"] == %{type: "array", items: %{type: "integer"}}
      assert schema.properties["future"].type == "string"
    end

    test "preserves declared requirements, defaults, descriptions, and validation" do
      schema =
        ToolSchema.action_args_schema(
          action([
            %{
              "name" => "tier",
              "type" => "string",
              "required" => true,
              "default" => "bronze",
              "description" => "Service tier",
              "validation" => %{
                "enum" => ["bronze", "gold"],
                "pattern" => "^[a-z]+$"
              }
            },
            %{
              "name" => "count",
              "type" => "integer",
              "validation" => %{"min" => 1, "max" => 10}
            },
            %{
              "name" => "tags",
              "type" => "string_array",
              "validation" => %{"min_items" => 1, "max_items" => 4}
            }
          ])
        )

      assert schema.required == ["tier"]

      assert schema.properties["tier"] == %{
               type: "string",
               default: "bronze",
               description: "Service tier",
               enum: ["bronze", "gold"],
               pattern: "^[a-z]+$"
             }

      assert schema.properties["count"].minimum == 1
      assert schema.properties["count"].maximum == 10
      assert schema.properties["tags"].minItems == 1
      assert schema.properties["tags"].maxItems == 4
    end

    test "drops malformed arguments and empty constraints without reserving nested names" do
      schema =
        ToolSchema.action_args_schema(
          action([
            "bad",
            %{"name" => 1},
            %{"name" => "good", "description" => "", "validation" => %{"enum" => []}},
            %{"name" => "reason", "required" => true},
            %{"name" => "runner", "required" => true},
            %{"name" => "runners", "required" => true},
            %{"name" => "wait", "required" => true},
            %{"name" => "idempotency_key", "required" => true},
            %{"name" => "attestation", "required" => true}
          ])
        )

      assert MapSet.new(Map.keys(schema.properties)) ==
               MapSet.new(~w(attestation good idempotency_key reason runner runners wait))

      refute Map.has_key?(schema.properties["good"], :description)
      refute Map.has_key?(schema.properties["good"], :enum)

      assert schema.required == [
               "reason",
               "runner",
               "runners",
               "wait",
               "idempotency_key",
               "attestation"
             ]
    end

    test "returns a closed JSON Schema object for absent or malformed args" do
      for action <- [%{}, %{args_schema: %{"args" => %{}}}] do
        assert ToolSchema.action_args_schema(action) == %{
                 "$schema": "https://json-schema.org/draft/2020-12/schema",
                 type: "object",
                 properties: %{},
                 required: [],
                 additionalProperties: false
               }
      end
    end
  end
end
