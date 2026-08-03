defmodule Emisar.Repo.Migrations.EnableRunbookDraftTests do
  use Ecto.Migration

  def up do
    drop constraint(:mcp_operations, :mcp_operations_tool_shape)

    create constraint(:mcp_operations, :mcp_operations_tool_shape,
             check: """
             (tool = 'run_action' AND action_id IS NOT NULL AND pack_ref IS NOT NULL AND resource_id IS NULL AND resource_ref IS NULL)
             OR
             (tool IN ('execute_runbook', 'create_runbook_draft', 'update_runbook_draft', 'test_runbook_draft') AND action_id IS NULL AND pack_ref IS NULL AND resource_id IS NOT NULL AND resource_ref IS NOT NULL)
             """
           )

    alter table(:runbook_executions) do
      add :kind, :string, null: false, default: "published"
      add :definition_sha256, :string
    end

    create constraint(:runbook_executions, :runbook_executions_kind_check,
             check: "kind IN ('published', 'draft_test')"
           )

    execute(
      "ALTER TABLE runbook_executions ALTER COLUMN kind DROP DEFAULT",
      "ALTER TABLE runbook_executions ALTER COLUMN kind SET DEFAULT 'published'"
    )
  end

  def down do
    execute("DELETE FROM runbook_executions WHERE kind = 'draft_test'")

    execute(
      "DELETE FROM mcp_operations WHERE tool IN ('update_runbook_draft', 'test_runbook_draft')"
    )

    drop constraint(:runbook_executions, :runbook_executions_kind_check)

    alter table(:runbook_executions) do
      remove :definition_sha256
      remove :kind
    end

    drop constraint(:mcp_operations, :mcp_operations_tool_shape)

    create constraint(:mcp_operations, :mcp_operations_tool_shape,
             check: """
             (tool = 'run_action' AND action_id IS NOT NULL AND pack_ref IS NOT NULL AND resource_id IS NULL AND resource_ref IS NULL)
             OR
             (tool IN ('execute_runbook', 'create_runbook_draft') AND action_id IS NULL AND pack_ref IS NULL AND resource_id IS NOT NULL AND resource_ref IS NOT NULL)
             """
           )
  end
end
