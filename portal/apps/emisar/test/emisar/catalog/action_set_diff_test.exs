defmodule Emisar.Catalog.ActionSetDiffTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.{ActionSetDiff, RunnerAction, TrustedManifest}

  defp act(action_id, risk, kind \\ :exec, opts \\ []) do
    %RunnerAction{
      action_id: action_id,
      title: Keyword.get(opts, :title, "Title for #{action_id}"),
      description: Keyword.get(opts, :description, "Description for #{action_id}."),
      risk: risk,
      kind: kind,
      side_effects: Keyword.get(opts, :side_effects, ["Reads state."]),
      args_schema:
        Keyword.get(opts, :args_schema, %{
          "args" => [%{"name" => "limit", "type" => "integer"}]
        }),
      examples: Keyword.get(opts, :examples, [%{"title" => "Example", "args" => %{}}]),
      search_terms: Keyword.get(opts, :search_terms, [])
    }
  end

  defp manifest(actions), do: ActionSetDiff.manifest_from_actions(actions)

  describe "manifest_from_actions/1" do
    test "builds a versioned complete descriptor manifest" do
      result = manifest([act("a.read", :low), act("a.write", :critical, :script)])

      assert result["schema_version"] == 1
      assert result["actions"] |> Map.keys() |> Enum.sort() == ["a.read", "a.write"]

      assert result["actions"]["a.write"] == %{
               "title" => "Title for a.write",
               "summary" => "Description for a.write.",
               "description" => "Description for a.write.",
               "kind" => "script",
               "risk" => "critical",
               "side_effects" => ["Reads state."],
               "args_schema" => %{
                 "args" => [%{"name" => "limit", "type" => "integer"}]
               },
               "examples" => [%{"title" => "Example", "args" => %{}}],
               "search_terms" => []
             }
    end

    test "is a complete empty manifest for no actions" do
      assert manifest([]) == %{"schema_version" => 1, "actions" => %{}}
    end

    test "conflicting duplicate action descriptors fail closed" do
      assert manifest([
               act("a.write", :low, :exec),
               act("a.write", :critical, :script)
             ]) == %{"schema_version" => 1, "actions" => %{}}
    end
  end

  describe "changes/2" do
    test "nil, sparse, or malformed historical manifests yield the UI fallback" do
      empty = %{added: [], removed: [], changed: []}
      advertised = [act("a.read", :low)]

      assert ActionSetDiff.changes(advertised, nil) == empty
      assert ActionSetDiff.changes(advertised, %{}) == empty

      assert ActionSetDiff.changes(advertised, %{
               "a.read" => %{"risk" => "low", "kind" => "exec"}
             }) == empty
    end

    test "an action only in the advertised set is added" do
      trusted = manifest([act("a.read", :low)])
      advertised = [act("a.read", :low), act("a.wipe", :critical)]

      diff = ActionSetDiff.changes(advertised, trusted)
      assert diff.added == [%{action_id: "a.wipe", risk: "critical", kind: "exec"}]
      assert diff.removed == []
      assert diff.changed == []
    end

    test "an action only in the trusted manifest is removed" do
      trusted = manifest([act("a.read", :low), act("a.gone", :medium)])
      diff = ActionSetDiff.changes([act("a.read", :low)], trusted)

      assert diff.removed == [%{action_id: "a.gone", risk: "medium", kind: "exec"}]
      assert diff.added == []
      assert diff.changed == []
    end

    test "a risk escalation is explicit and reports the deterministic changed field" do
      trusted = manifest([act("a.read", :low)])
      diff = ActionSetDiff.changes([act("a.read", :critical)], trusted)

      assert diff.changed == [
               %{
                 action_id: "a.read",
                 old_risk: "low",
                 new_risk: "critical",
                 old_kind: "exec",
                 new_kind: "exec",
                 changed_fields: ["risk"],
                 risk_escalated?: true
               }
             ]
    end

    test "every execution/model-facing descriptor field participates in drift" do
      trusted = manifest([act("a.read", :low)])

      advertised = [
        act("a.read", :critical, :script,
          title: "Changed title",
          description: "Changed description.",
          side_effects: ["Writes state."],
          args_schema: %{"args" => [%{"name" => "force", "type" => "boolean"}]},
          examples: [%{"title" => "Changed", "args" => %{"force" => true}}],
          search_terms: ["changed"]
        )
      ]

      assert [%{changed_fields: fields, risk_escalated?: true}] =
               ActionSetDiff.changes(advertised, trusted).changed

      assert fields == TrustedManifest.descriptor_fields()
    end

    test "a risk de-escalation is changed but not flagged as an escalation" do
      trusted = manifest([act("a.read", :high)])

      assert [%{action_id: "a.read", risk_escalated?: false}] =
               ActionSetDiff.changes([act("a.read", :low)], trusted).changed
    end

    test "each list is sorted by action_id" do
      trusted = manifest([act("z.keep", :low), act("m.drop", :low), act("a.drop", :low)])
      advertised = [act("z.keep", :low), act("y.add", :low), act("b.add", :low)]
      diff = ActionSetDiff.changes(advertised, trusted)

      assert Enum.map(diff.added, & &1.action_id) == ["b.add", "y.add"]
      assert Enum.map(diff.removed, & &1.action_id) == ["a.drop", "m.drop"]
    end

    test "conflicting current descriptors fail closed instead of fabricating a diff" do
      trusted = manifest([act("a.read", :low)])

      advertised = [
        act("a.read", :low, :exec),
        act("a.read", :critical, :script)
      ]

      assert ActionSetDiff.changes(advertised, trusted) == %{
               added: [],
               removed: [],
               changed: []
             }
    end
  end
end
