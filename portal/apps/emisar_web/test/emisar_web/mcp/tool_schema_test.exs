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
      assert schema.properties["timeout"].format == "duration"

      assert schema.properties["tags"] == %{
               type: "array",
               items: %{"x-emisar-maxUtf8Bytes" => 32_768, type: "string"}
             }

      assert schema.properties["ports"] == %{type: "array", items: %{type: "integer"}}
      assert schema.properties["future"] == %{}
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
               "x-emisar-maxUtf8Bytes" => 32_768,
               type: "string",
               default: "bronze",
               description: "Service tier",
               enum: ["bronze", "gold"],
               pattern: "^[a-z]+$"
             }

      assert schema.properties["count"].minimum == 1
      assert schema.properties["count"].maximum == 10
      refute Map.has_key?(schema.properties["tags"], :minItems)
      assert schema.properties["tags"].maxItems == 4
    end

    test "places element constraints correctly and exposes non-standard runner limits" do
      schema =
        ToolSchema.action_args_schema(
          action([
            %{
              "name" => "ports",
              "type" => "integer_array",
              "validation" => %{"min" => 1, "max" => 65_535, "allowed" => [80, 443]}
            },
            %{
              "name" => "logs",
              "type" => "string_array",
              "validation" => %{
                "max_length" => 256,
                "allowed_prefixes" => ["/var/log"],
                "denied_paths" => ["/var/log/secure"]
              }
            },
            %{
              "name" => "timeout",
              "type" => "duration",
              "validation" => %{"min_duration" => "1s", "max_duration" => "1h0m0s"}
            }
          ])
        )

      assert schema["x-emisar-maxEncodedBytes"] == 32_768

      assert schema.properties["ports"].items == %{
               type: "integer",
               minimum: 1,
               maximum: 65_535,
               enum: [80, 443]
             }

      assert schema.properties["logs"].items["x-emisar-maxUtf8Bytes"] == 256

      assert schema.properties["logs"]["x-emisar-pathConstraints"] == %{
               "allowed_prefixes" => ["/var/log"],
               "denied_paths" => ["/var/log/secure"]
             }

      assert schema.properties["timeout"]["x-emisar-minDuration"] == "1s"
      assert schema.properties["timeout"]["x-emisar-maxDuration"] == "1h0m0s"
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
                 "x-emisar-maxEncodedBytes" => 32_768,
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
