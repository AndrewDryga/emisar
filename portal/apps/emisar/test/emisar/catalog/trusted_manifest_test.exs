defmodule Emisar.Catalog.TrustedManifestTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.{RunnerAction, TrustedManifest}
  alias Emisar.Crypto

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

    assert TrustedManifest.from_catalog_actions(actions) == {:error, :invalid_manifest}
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

    assert TrustedManifest.from_runner_actions([
             base_action,
             %{base_action | description: "Inspect state differently."}
           ]) == {:error, {:descriptor_mismatch, "custom.inspect"}}

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
      for index <- 1..(TrustedManifest.max_actions() + 1) do
        %{hd(actions) | action_id: "custom.overflow_#{index}"}
      end

    assert TrustedManifest.from_runner_actions(overflow) == {:error, :invalid_manifest}
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

    assert TrustedManifest.from_catalog_actions([action, %{action | "title" => "Other"}]) ==
             {:error, :invalid_manifest}
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
      assert TrustedManifest.from_catalog_actions([
               Map.put(base, "output_schema", schema)
             ]) == {:error, :invalid_manifest}
    end
  end

  test "a runner advertising an unusable output contract builds no manifest" do
    assert {:ok, _manifest} =
             TrustedManifest.from_runner_actions([
               runner_action(output_schema: %{"type" => "object", "properties" => %{}})
             ])

    for schema <- [%{"type" => "array"}, %{"type" => "object", "$id" => "urn:other"}, "object"] do
      assert TrustedManifest.from_runner_actions([runner_action(output_schema: schema)]) ==
               {:error, :invalid_manifest},
             "expected #{inspect(schema)} to be refused"
    end
  end

  test "the digest is sha256 over a recursively key-sorted encoding" do
    descriptor = %{"b" => [%{"y" => 2, "x" => 1}], "a" => "one"}
    canonical = ~s([["a","one"],["b",[[["x",1],["y",2]]]]])

    assert TrustedManifest.descriptor_digest(descriptor) == Crypto.hash_hex(canonical)
  end

  test "a runner row digests to its own trusted manifest descriptor" do
    action = runner_action()

    assert {:ok, manifest} = TrustedManifest.from_runner_actions([action])
    assert {:ok, %{"custom.inspect" => descriptor}} = TrustedManifest.actions(manifest)

    assert TrustedManifest.runner_action_digest(action) ==
             TrustedManifest.descriptor_digest(descriptor)
  end

  test "every descriptor field moves the digest" do
    action = runner_action()
    digest = TrustedManifest.runner_action_digest(action)

    drifts = [
      [title: "Inspect harder"],
      [summary: "Inspects state, quietly."],
      [description: "Inspect state differently."],
      [kind: :script],
      [risk: :high],
      [side_effects: ["writes /tmp"]],
      [args_schema: %{"args" => [%{"name" => "path"}]}],
      [examples: [%{"args" => %{}}]],
      [search_terms: ["inspect"]],
      [output_schema: %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}]
    ]

    for drift <- drifts do
      drifted = struct!(action, drift)

      refute TrustedManifest.runner_action_digest(drifted) == digest,
             "expected #{inspect(drift)} to change the descriptor digest"
    end
  end

  test "kind and risk digest the same whether they arrive as atoms or as stored strings" do
    typed = runner_action()
    as_stored = struct!(typed, kind: "exec", risk: "low")

    assert TrustedManifest.runner_action_digest(as_stored) ==
             TrustedManifest.runner_action_digest(typed)
  end

  test "an absent summary digests as the one the manifest derives from the description" do
    action = runner_action(summary: nil)
    derived = runner_action(summary: "Inspect state.")

    assert TrustedManifest.runner_action_digest(action) ==
             TrustedManifest.runner_action_digest(derived)
  end

  defp runner_action(overrides \\ []) do
    struct!(
      %RunnerAction{
        action_id: "custom.inspect",
        title: "Inspect",
        summary: "Inspect state.",
        description: "Inspect state.",
        kind: :exec,
        risk: :low,
        side_effects: [],
        args_schema: %{"args" => []},
        examples: [],
        search_terms: []
      },
      overrides
    )
  end

  describe "persisted/1" do
    test "returns a current-schema manifest and rejects any other shape" do
      {:ok, manifest} =
        TrustedManifest.from_runner_actions([
          %RunnerAction{
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
        ])

      assert TrustedManifest.persisted(manifest) == {:ok, manifest}
      assert TrustedManifest.persisted(nil) == {:error, :incomplete_manifest}

      assert TrustedManifest.persisted(%{"custom.inspect" => %{"risk" => "low"}}) ==
               {:error, :incomplete_manifest}
    end
  end
end
