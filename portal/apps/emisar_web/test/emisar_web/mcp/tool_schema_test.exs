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
      assert schema.properties["idempotency_key"].maxLength == 200
      refute "idempotency_key" in schema.required
    end

    test "always describes the optional bounded wait argument" do
      schema = ToolSchema.build(action(), ["only-runner"])

      assert schema.properties["wait"].type == "string"
      assert schema.properties["wait"].pattern == "^[0-9]{1,8}(ms|s|m)?$"
      assert schema.properties["wait"].description =~ "Omit to wait up to 60s"
      refute "wait" in schema.required
    end

    test "exactly one runner → runners still REQUIRED (no auto-pick), enum locked to that id" do
      schema = ToolSchema.build(action(), ["solo"])

      runners = schema.properties["runners"]
      assert runners.items.enum == ["solo"]
      assert runners.minItems == 1
      assert runners.maxItems == 1
      assert runners.uniqueItems == true
      # No `default` and not optional — emisar never auto-targets, so the caller
      # must name the host explicitly even when there's only one choice.
      refute Map.has_key?(runners, :default)
      assert "runners" in schema.required
    end

    test "multiple runners → runners required, enum lists every option" do
      schema = ToolSchema.build(action(), ["a", "b", "c"])

      runners = schema.properties["runners"]
      assert runners.items.enum == ["a", "b", "c"]
      assert runners.minItems == 1
      assert runners.maxItems == 3
      assert "runners" in schema.required
    end

    test "runner choices expose stable ids with human names only as labels" do
      schema =
        ToolSchema.build(action(), [
          %{id: "runner-id-b", name: "db-prod-02"},
          %{id: "runner-id-a", name: "db-prod-01"}
        ])

      runners = schema.properties["runners"]
      assert runners.items.enum == ["runner-id-b", "runner-id-a"]
      assert runners.description =~ "`runner-id-a` — db-prod-01"
      refute "db-prod-01" in runners.items.enum
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
      schema =
        ToolSchema.build(action(args: [%{"name" => "timeout", "type" => "duration"}]), ["r"])

      prop = schema.properties["timeout"]
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

    test "ignores malformed catalog arguments instead of failing tool discovery" do
      schema =
        ToolSchema.build(
          %{
            args_schema: %{
              "args" => ["bad", %{"name" => 1}, %{"name" => "host", "validation" => []}]
            }
          },
          ["r"]
        )

      assert schema.properties["host"].type == "string"
      refute Map.has_key?(schema.properties["host"], :enum)
    end

    test "ignores a non-list catalog args schema and reserved control names" do
      schema =
        ToolSchema.build(
          %{args_schema: %{"args" => %{"name" => "bad"}}},
          ["r"]
        )

      assert schema.properties["reason"].type == "string"
      refute Map.has_key?(schema.properties, "bad")

      schema =
        ToolSchema.build(
          action(
            args: [
              %{"name" => "reason", "required" => true},
              %{"name" => "runner", "required" => true},
              %{"name" => "wait", "required" => true},
              %{"name" => "attestation", "required" => true}
            ]
          ),
          ["r"]
        )

      assert Enum.count(schema.required, &(&1 == "reason")) == 1
      refute "runner" in schema.required
      refute "wait" in schema.required
      refute "attestation" in schema.required
    end
  end

  describe "build_ambiguous/1 — divergent runner arg schemas" do
    test "exposes only the control fields and allows additional properties" do
      schema = ToolSchema.build_ambiguous(["a", "b"])

      assert Map.keys(schema.properties) |> Enum.sort() == [
               "idempotency_key",
               "reason",
               "runners",
               "wait"
             ]

      assert schema.additionalProperties == true
      assert schema.type == "object"
      assert schema[:"$schema"] == "https://json-schema.org/draft/2020-12/schema"
    end

    test "reason and runners stay required; the runner re-validates the real args" do
      schema = ToolSchema.build_ambiguous(["a", "b"])

      assert "reason" in schema.required
      assert "runners" in schema.required
      assert schema.properties["runners"].items.enum == ["a", "b"]
    end

    test "no runners advertise the action → runners is omitted and not required" do
      schema = ToolSchema.build_ambiguous([])

      refute Map.has_key?(schema.properties, "runners")
      refute "runners" in schema.required
      assert "reason" in schema.required
    end
  end

  describe "build/2 — schema envelope" do
    test "is a valid JSON Schema 2020-12 object" do
      schema = ToolSchema.build(action(), ["r"])
      assert schema.type == "object"
      assert schema.additionalProperties == false
      assert schema[:"$schema"] == "https://json-schema.org/draft/2020-12/schema"
    end

    test "the schema is a client-facing HINT, carried verbatim — not the dispatch gate" do
      # The moduledoc's contract: emisar's own arg types are widened to a JSON
      # primitive + a carried constraint, and "the runner re-validates with the
      # original spec on dispatch — the schema is a hint to the LLM, not the
      # security gate." Assert the generated shape matches that contract: the
      # constraint travels on the property (so a well-behaved client self-checks)
      # but the descriptor is pure data with no enforcement attached.
      schema =
        ToolSchema.build(
          action(
            args: [
              %{
                "name" => "tier",
                "type" => "string",
                "validation" => %{"enum" => ["bronze", "gold"]}
              }
            ]
          ),
          ["r"]
        )

      # The constraint is present as a hint the LLM can read…
      assert schema.properties["tier"].enum == ["bronze", "gold"]
      # …on a plain map (a descriptor), not a validator. A value OUTSIDE the
      # enum is not rejected here — build/2 never inspects argument values, it
      # only describes them; the runner makes the real allow/deny call.
      assert is_map(schema.properties["tier"])
      assert {:module, _} = Code.ensure_loaded(ToolSchema)
      refute function_exported?(ToolSchema, :validate, 2)
    end
  end
end
