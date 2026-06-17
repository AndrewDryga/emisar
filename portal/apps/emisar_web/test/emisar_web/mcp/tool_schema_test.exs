defmodule EmisarWeb.MCP.ToolSchemaTest do
  use ExUnit.Case, async: true

  alias EmisarWeb.MCP.ToolSchema

  defp action(opts \\ []) do
    %{args_schema: %{"args" => Keyword.get(opts, :args, [])}}
  end

  describe "build/2 — control fields" do
    test "always includes reason as a required string" do
      schema = ToolSchema.build(action(), ["only-runner"])

      assert schema.properties["reason"].type == "string"
      assert "reason" in schema.required
    end

    test "always includes idempotency_key as optional" do
      schema = ToolSchema.build(action(), ["only-runner"])

      assert schema.properties["idempotency_key"].type == "string"
      refute "idempotency_key" in schema.required
    end

    test "exactly one runner → runners optional with a default + enum locked to that name" do
      schema = ToolSchema.build(action(), ["solo"])

      runners = schema.properties["runners"]
      assert runners.items.enum == ["solo"]
      assert runners.default == ["solo"]
      refute "runners" in schema.required
    end

    test "multiple runners → runners required, enum lists every option" do
      schema = ToolSchema.build(action(), ["a", "b", "c"])

      runners = schema.properties["runners"]
      assert runners.items.enum == ["a", "b", "c"]
      assert runners.minItems == 1
      assert runners.maxItems == 3
      assert "runners" in schema.required
    end

    test "no runners advertise this action → runners property is omitted" do
      schema = ToolSchema.build(action(), [])
      refute Map.has_key?(schema.properties, "runners")
      refute "runners" in schema.required
    end

    test "fan-out is capped at 16 even with more runners" do
      runners = Enum.map(1..32, &"r-#{&1}")
      schema = ToolSchema.build(action(), runners)
      assert schema.properties["runners"].maxItems == 16
    end
  end

  describe "build/2 — per-action args" do
    test "string arg becomes a JSON Schema string property" do
      schema = ToolSchema.build(action(args: [%{"name" => "host", "type" => "string"}]), ["r"])
      assert schema.properties["host"].type == "string"
    end

    test "emisar `duration` type widens to string with a regex pattern" do
      schema = ToolSchema.build(action(args: [%{"name" => "wait", "type" => "duration"}]), ["r"])
      prop = schema.properties["wait"]
      assert prop.type == "string"
      assert prop.pattern =~ "ns|us|ms|s|m|h"
    end

    test "string_array widens to array of strings" do
      schema =
        ToolSchema.build(
          action(args: [%{"name" => "tags", "type" => "string_array"}]),
          ["r"]
        )

      prop = schema.properties["tags"]
      assert prop.type == "array"
      assert prop.items.type == "string"
    end

    test "unknown type falls back to string so the document stays valid" do
      schema =
        ToolSchema.build(action(args: [%{"name" => "x", "type" => "futuristic"}]), ["r"])

      assert schema.properties["x"].type == "string"
    end

    test "required args land in the `required` list" do
      schema =
        ToolSchema.build(
          action(
            args: [
              %{"name" => "host", "type" => "string", "required" => true},
              %{"name" => "label", "type" => "string"}
            ]
          ),
          ["r"]
        )

      assert "host" in schema.required
      refute "label" in schema.required
    end

    test "required args containing 'reason' or 'runners' do not result in duplicate required fields" do
      schema =
        ToolSchema.build(
          action(
            args: [
              %{"name" => "reason", "type" => "string", "required" => true},
              %{"name" => "runners", "type" => "string_array", "required" => true}
            ]
          ),
          ["r1", "r2"]
        )

      assert "reason" in schema.required
      assert "runners" in schema.required
      assert Enum.count(schema.required, &(&1 == "reason")) == 1
      assert Enum.count(schema.required, &(&1 == "runners")) == 1
    end

    test "validation map carries enum/pattern/min/max/min_items/max_items" do
      schema =
        ToolSchema.build(
          action(
            args: [
              %{
                "name" => "tier",
                "type" => "string",
                "validation" => %{
                  "enum" => ["bronze", "silver", "gold"],
                  "pattern" => "^[a-z]+$"
                }
              },
              %{
                "name" => "n",
                "type" => "integer",
                "validation" => %{"min" => 1, "max" => 100}
              },
              %{
                "name" => "tags",
                "type" => "string_array",
                "validation" => %{"min_items" => 1, "max_items" => 4}
              }
            ]
          ),
          ["r"]
        )

      assert schema.properties["tier"].enum == ["bronze", "silver", "gold"]
      assert schema.properties["tier"].pattern == "^[a-z]+$"
      assert schema.properties["n"].minimum == 1
      assert schema.properties["n"].maximum == 100
      assert schema.properties["tags"].minItems == 1
      assert schema.properties["tags"].maxItems == 4
    end

    test "blank description / empty enum / empty validation are dropped" do
      schema =
        ToolSchema.build(
          action(
            args: [
              %{
                "name" => "x",
                "type" => "string",
                "description" => "",
                "validation" => %{"enum" => []}
              }
            ]
          ),
          ["r"]
        )

      prop = schema.properties["x"]
      refute Map.has_key?(prop, :description)
      refute Map.has_key?(prop, :enum)
    end

    test "default value flows through verbatim" do
      schema =
        ToolSchema.build(
          action(args: [%{"name" => "limit", "type" => "integer", "default" => 25}]),
          ["r"]
        )

      assert schema.properties["limit"].default == 25
    end
  end

  describe "build/2 — schema envelope" do
    test "is a valid JSON Schema 2020-12 object" do
      schema = ToolSchema.build(action(), ["r"])
      assert schema.type == "object"
      assert schema.additionalProperties == false
      assert schema[:"$schema"] == "https://json-schema.org/draft/2020-12/schema"
    end
  end
end
