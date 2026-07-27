defmodule Emisar.Catalog.TrustedManifestTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.{RunnerAction, TrustedManifest}

  test "rejects manifests whose complete compact pack cannot fit one MCP item" do
    actions =
      for index <- 1..80 do
        %{
          "id" => "test.action_#{index}",
          "title" => String.duplicate("t", 160),
          "summary" => String.duplicate("s", 512),
          "description" => "description",
          "kind" => "exec",
          "risk" => "low",
          "side_effects" => [],
          "args" => [],
          "examples" => [],
          "search_terms" => []
        }
      end

    assert {:error, :invalid_manifest} = TrustedManifest.from_catalog_actions(actions)
  end

  test "accepts an ordinary compact manifest" do
    action = %{
      "id" => "test.status",
      "title" => "Status",
      "summary" => "Show status.",
      "description" => "Show the current status.",
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => [],
      "args" => [],
      "examples" => [],
      "search_terms" => []
    }

    assert {:ok, _manifest} = TrustedManifest.from_catalog_actions([action])
  end

  test "conflicting runner descriptors for one action id name the action in the error" do
    base_action = %RunnerAction{
      action_id: "custom.inspect",
      title: "Inspect",
      description: "Inspect state.",
      kind: :exec,
      risk: :low,
      side_effects: [],
      args_schema: %{"args" => []},
      examples: [],
      search_terms: []
    }

    assert {:error, {:descriptor_mismatch, "custom.inspect"}} =
             TrustedManifest.from_runner_actions([
               base_action,
               %{base_action | description: "Inspect state differently."}
             ])

    # Identical duplicates are agreement, not a conflict.
    assert {:ok, _manifest} = TrustedManifest.from_runner_actions([base_action, base_action])
  end

  test "the action cap counts distinct ids, not identical observations from replacement runners" do
    actions =
      for index <- 1..30 do
        %RunnerAction{
          action_id: "custom.action_#{index}",
          title: "Action #{index}",
          description: "Inspect state.",
          kind: :exec,
          risk: :low,
          side_effects: [],
          args_schema: %{"args" => []},
          examples: [],
          search_terms: []
        }
      end

    observations = actions |> List.duplicate(3) |> List.flatten()

    assert {:ok, %{"actions" => trusted_actions}} =
             TrustedManifest.from_runner_actions(observations)

    assert map_size(trusted_actions) == 30

    overflow =
      for index <- 1..81 do
        %{hd(actions) | action_id: "custom.overflow_#{index}"}
      end

    assert {:error, :invalid_manifest} = TrustedManifest.from_runner_actions(overflow)
  end

  test "conflicting duplicate catalog actions stay plain :invalid_manifest" do
    action = %{
      "id" => "test.status",
      "title" => "Status",
      "summary" => "Show status.",
      "description" => "Show the current status.",
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => [],
      "args" => [],
      "examples" => [],
      "search_terms" => []
    }

    assert {:error, :invalid_manifest} =
             TrustedManifest.from_catalog_actions([action, %{action | "title" => "Other"}])
  end

  test "carries an opt-in output contract inside the trusted descriptor" do
    action = %{
      "id" => "test.status",
      "title" => "Status",
      "summary" => "Show status.",
      "description" => "Show the current status.",
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => [],
      "args" => [],
      "examples" => [],
      "search_terms" => [],
      "output_schema" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "properties" => %{"ok" => %{"type" => "boolean"}}
      }
    }

    assert {:ok, manifest} = TrustedManifest.from_catalog_actions([action])
    assert {:ok, ^manifest} = TrustedManifest.validate(manifest)

    assert get_in(manifest, ["actions", "test.status", "output_schema", "type"]) == "object"

    # An untyped descriptor omits the key entirely and still validates.
    untyped = Map.delete(action, "output_schema")
    assert {:ok, untyped_manifest} = TrustedManifest.from_catalog_actions([untyped])
    refute manifest == untyped_manifest
    refute Map.has_key?(untyped_manifest["actions"]["test.status"], "output_schema")
  end

  test "rejects unsafe or oversized typed contracts" do
    base = %{
      "id" => "test.status",
      "title" => "Status",
      "summary" => "Show status.",
      "description" => "Show status.",
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => [],
      "args" => [],
      "examples" => [],
      "search_terms" => []
    }

    for schema <- [
          %{"type" => "array"},
          %{"type" => "object", "$ref" => "https://example.com/schema"},
          %{"type" => "object", "$ref" => "#/$defs/missing"},
          %{"type" => "object", "$id" => "urn:other"},
          %{"type" => "object", "required" => "name"},
          %{"type" => "object", "description" => String.duplicate("x", 8_192)}
        ] do
      assert {:error, :invalid_manifest} =
               TrustedManifest.from_catalog_actions([
                 Map.put(base, "output_schema", schema)
               ])
    end
  end
end
