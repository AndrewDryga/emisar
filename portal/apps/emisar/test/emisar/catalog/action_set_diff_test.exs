defmodule Emisar.Catalog.ActionSetDiffTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.ActionSetDiff
  alias Emisar.Catalog.RunnerAction

  defp act(action_id, risk, kind \\ :exec),
    do: %RunnerAction{action_id: action_id, risk: risk, kind: kind}

  describe "manifest_from_actions/1" do
    test "builds string-keyed {risk, kind} entries (JSONB-shaped)" do
      assert ActionSetDiff.manifest_from_actions([
               act("a.read", :low, :exec),
               act("a.write", :critical, :script)
             ]) == %{
               "a.read" => %{"risk" => "low", "kind" => "exec"},
               "a.write" => %{"risk" => "critical", "kind" => "script"}
             }
    end

    test "is an empty map for no actions" do
      assert ActionSetDiff.manifest_from_actions([]) == %{}
    end

    test "keeps the most-severe report when runners duplicate an action" do
      assert ActionSetDiff.manifest_from_actions([
               act("a.write", :low, :exec),
               act("a.write", :critical, :script)
             ]) == %{
               "a.write" => %{"risk" => "critical", "kind" => "script"}
             }
    end
  end

  describe "changes/2" do
    test "nil or empty manifest → empty diff (UI falls back to listing actions)" do
      empty = %{added: [], removed: [], changed: []}
      assert ActionSetDiff.changes([act("a.read", :low)], nil) == empty
      assert ActionSetDiff.changes([act("a.read", :low)], %{}) == empty
    end

    test "an action only in the advertised set is added" do
      manifest = %{"a.read" => %{"risk" => "low", "kind" => "exec"}}
      advertised = [act("a.read", :low), act("a.wipe", :critical)]

      diff = ActionSetDiff.changes(advertised, manifest)
      assert diff.added == [%{action_id: "a.wipe", risk: "critical", kind: "exec"}]
      assert diff.removed == []
      assert diff.changed == []
    end

    test "an action only in the manifest is removed" do
      manifest = %{
        "a.read" => %{"risk" => "low", "kind" => "exec"},
        "a.gone" => %{"risk" => "medium", "kind" => "exec"}
      }

      diff = ActionSetDiff.changes([act("a.read", :low)], manifest)
      assert diff.removed == [%{action_id: "a.gone", risk: "medium", kind: "exec"}]
      assert diff.added == []
      assert diff.changed == []
    end

    test "a risk escalation is flagged risk_escalated?: true with old+new" do
      manifest = %{"a.read" => %{"risk" => "low", "kind" => "exec"}}
      diff = ActionSetDiff.changes([act("a.read", :critical)], manifest)

      assert diff.changed == [
               %{
                 action_id: "a.read",
                 old_risk: "low",
                 new_risk: "critical",
                 old_kind: "exec",
                 new_kind: "exec",
                 risk_escalated?: true
               }
             ]
    end

    test "a risk DE-escalation is changed but not flagged as an escalation" do
      manifest = %{"a.read" => %{"risk" => "high", "kind" => "exec"}}
      diff = ActionSetDiff.changes([act("a.read", :low)], manifest)

      assert [%{action_id: "a.read", risk_escalated?: false}] = diff.changed
    end

    test "a kind change with unchanged risk is a (non-escalation) change" do
      manifest = %{"a.read" => %{"risk" => "low", "kind" => "exec"}}
      diff = ActionSetDiff.changes([act("a.read", :low, :script)], manifest)

      assert [
               %{
                 action_id: "a.read",
                 old_kind: "exec",
                 new_kind: "script",
                 risk_escalated?: false
               }
             ] = diff.changed
    end

    test "an unchanged action produces no diff entry" do
      manifest = %{"a.read" => %{"risk" => "low", "kind" => "exec"}}

      assert ActionSetDiff.changes([act("a.read", :low, :exec)], manifest) ==
               %{added: [], removed: [], changed: []}
    end

    test "each list is sorted by action_id" do
      manifest = %{
        "z.keep" => %{"risk" => "low", "kind" => "exec"},
        "m.drop" => %{"risk" => "low", "kind" => "exec"},
        "a.drop" => %{"risk" => "low", "kind" => "exec"}
      }

      advertised = [act("z.keep", :low), act("y.add", :low), act("b.add", :low)]
      diff = ActionSetDiff.changes(advertised, manifest)

      assert Enum.map(diff.added, & &1.action_id) == ["b.add", "y.add"]
      assert Enum.map(diff.removed, & &1.action_id) == ["a.drop", "m.drop"]
    end

    test "ignores malformed persisted entries instead of crashing the review" do
      manifest = %{
        "a.read" => %{"risk" => "low", "kind" => "exec"},
        "broken" => %{"risk" => "critical"}
      }

      diff = ActionSetDiff.changes([act("a.read", :low), act("broken", :critical)], manifest)

      assert diff.added == [%{action_id: "broken", risk: "critical", kind: "exec"}]
      assert diff.removed == []
      assert diff.changed == []
    end
  end
end
