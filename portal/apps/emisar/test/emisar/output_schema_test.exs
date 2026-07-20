defmodule Emisar.OutputSchemaTest do
  use ExUnit.Case, async: true
  alias Emisar.OutputSchema

  @valid_schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "object",
    "required" => ["status"],
    "properties" => %{
      "status" => %{"type" => "string", "enum" => ["ok", "degraded"]},
      "count" => %{"type" => "integer", "minimum" => 0},
      "detail" => %{"$ref" => "#/$defs/detail"}
    },
    "additionalProperties" => false,
    "$defs" => %{
      "detail" => %{
        "type" => "object",
        "properties" => %{"message" => %{"type" => "string"}},
        "additionalProperties" => false
      }
    }
  }

  describe "valid?/1" do
    test "accepts a bounded local object schema with $defs refs" do
      assert OutputSchema.valid?(@valid_schema)
    end

    test "rejects non-object roots and non-map values" do
      refute OutputSchema.valid?(%{"type" => "array"})
      refute OutputSchema.valid?(%{"type" => "string"})
      refute OutputSchema.valid?(nil)
      refute OutputSchema.valid?("{}")
    end

    test "rejects identity, dynamic-scope, and content keywords anywhere" do
      for {key, value} <- [
            {"$id", "urn:other"},
            {"$anchor", "a"},
            {"$dynamicAnchor", "a"},
            {"$dynamicRef", "#a"},
            {"$vocabulary", %{}},
            {"definitions", %{}},
            {"contentEncoding", "base64"},
            {"contentMediaType", "application/json"},
            {"contentSchema", %{}}
          ] do
        refute OutputSchema.valid?(%{"type" => "object", key => value})

        refute OutputSchema.valid?(%{
                 "type" => "object",
                 "properties" => %{"nested" => %{key => value}}
               })
      end
    end

    test "rejects external, pointer, and unresolved refs" do
      refute OutputSchema.valid?(%{"type" => "object", "$ref" => "https://example.com/s"})
      refute OutputSchema.valid?(%{"type" => "object", "$ref" => "#/properties/x"})
      refute OutputSchema.valid?(%{"type" => "object", "$ref" => "#/$defs/missing"})
    end

    test "rejects cyclic $defs references before compiling" do
      cyclic = %{
        "type" => "object",
        "properties" => %{"node" => %{"$ref" => "#/$defs/a"}},
        "$defs" => %{
          "a" => %{"$ref" => "#/$defs/b"},
          "b" => %{"$ref" => "#/$defs/a"}
        }
      }

      refute OutputSchema.valid?(cyclic)
    end

    test "rejects fractional or nonpositive multipleOf" do
      refute OutputSchema.valid?(%{
               "type" => "object",
               "properties" => %{"ratio" => %{"type" => "number", "multipleOf" => 0.1}}
             })

      refute OutputSchema.valid?(%{
               "type" => "object",
               "properties" => %{"count" => %{"type" => "integer", "multipleOf" => 0}}
             })

      assert OutputSchema.valid?(%{
               "type" => "object",
               "properties" => %{"count" => %{"type" => "integer", "multipleOf" => 5}}
             })
    end

    test "rejects meta-schema-invalid shapes" do
      refute OutputSchema.valid?(%{"type" => "object", "required" => "status"})
      refute OutputSchema.valid?(%{"type" => "object", "properties" => []})
    end

    test "rejects schemas past the depth and node ceilings" do
      deep =
        Enum.reduce(1..17, %{"type" => "object"}, fn _index, child ->
          %{"type" => "object", "properties" => %{"next" => child}}
        end)

      refute OutputSchema.valid?(deep)

      wide_properties = Map.new(1..512, &{"field_#{&1}", %{"type" => "string"}})
      refute OutputSchema.valid?(%{"type" => "object", "properties" => wide_properties})
    end
  end

  describe "validate_instance/2" do
    test "accepts a conforming result object" do
      assert OutputSchema.validate_instance(@valid_schema, %{
               "status" => "ok",
               "count" => 3,
               "detail" => %{"message" => "fine"}
             }) == :ok
    end

    test "rejects schema violations" do
      assert OutputSchema.validate_instance(@valid_schema, %{"status" => "unknown"}) ==
               {:error, :schema_mismatch}

      assert OutputSchema.validate_instance(@valid_schema, %{"status" => "ok", "extra" => 1}) ==
               {:error, :schema_mismatch}

      assert OutputSchema.validate_instance(@valid_schema, %{}) == {:error, :schema_mismatch}
    end

    test "rejects non-object instances and invalid schemas" do
      assert OutputSchema.validate_instance(@valid_schema, "not a map") ==
               {:error, :schema_mismatch}

      assert OutputSchema.validate_instance(%{"type" => "array"}, %{"status" => "ok"}) ==
               {:error, :schema_mismatch}
    end

    test "rejects instances past the depth and node ceilings" do
      permissive = %{"type" => "object"}

      deep_value =
        Enum.reduce(1..16, %{"leaf" => true}, fn _index, child -> %{"next" => child} end)

      assert OutputSchema.validate_instance(permissive, deep_value) ==
               {:error, :schema_mismatch}

      wide_value = %{"values" => Enum.to_list(1..1_024)}
      assert OutputSchema.validate_instance(permissive, wide_value) == {:error, :schema_mismatch}
    end
  end
end
