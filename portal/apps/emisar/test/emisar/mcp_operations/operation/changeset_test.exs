defmodule Emisar.MCPOperations.Operation.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.MCPOperations.Operation

  describe "complete_draft/2" do
    test "accepts only a canonical digest and a positive optional release number" do
      operation = %Operation{tool: :create_runbook_draft}
      digest = String.duplicate("a", 64)

      for version <- [nil, 1, 12] do
        attrs = %{draft_definition_sha256: digest, draft_live_version: version}
        changeset = Operation.Changeset.complete_draft(operation, attrs)
        assert changeset.valid?
      end

      for digest <- [nil, "", String.duplicate("a", 63), String.duplicate("A", 64)] do
        changeset =
          Operation.Changeset.complete_draft(operation, %{draft_definition_sha256: digest})

        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), :draft_definition_sha256)
      end

      for version <- [0, -1] do
        attrs = %{draft_definition_sha256: digest, draft_live_version: version}
        changeset = Operation.Changeset.complete_draft(operation, attrs)
        assert "must be greater than 0" in errors_on(changeset).draft_live_version
      end
    end

    test "does not change an existing snapshot or attach one to an action" do
      digest = String.duplicate("a", 64)
      attrs = %{draft_definition_sha256: String.duplicate("b", 64)}

      for operation <- [
            %Operation{tool: :run_action},
            %Operation{tool: :update_runbook_draft, draft_definition_sha256: digest}
          ] do
        changeset = Operation.Changeset.complete_draft(operation, attrs)

        assert errors_on(changeset).draft_definition_sha256 == [
                 "requires an unfinished draft operation"
               ]

        assert changeset.changes == %{}
      end
    end
  end
end
