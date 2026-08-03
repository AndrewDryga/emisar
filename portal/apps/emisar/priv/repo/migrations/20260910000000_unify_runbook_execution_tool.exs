defmodule Emisar.Repo.Migrations.UnifyRunbookExecutionTool do
  use Ecto.Migration

  def up do
    drop constraint(:mcp_operations, :mcp_operations_tool_shape)

    execute("""
    UPDATE mcp_operations
    SET tool = 'execute_runbook'
    WHERE tool = 'test_runbook_draft'
    """)

    create constraint(:mcp_operations, :mcp_operations_tool_shape,
             check: """
             (tool = 'run_action' AND action_id IS NOT NULL AND pack_ref IS NOT NULL AND resource_id IS NULL AND resource_ref IS NULL)
             OR
             (tool IN ('execute_runbook', 'create_runbook_draft', 'update_runbook_draft') AND action_id IS NULL AND pack_ref IS NULL AND resource_id IS NOT NULL AND resource_ref IS NOT NULL)
             """
           )
  end

  def down do
    drop constraint(:mcp_operations, :mcp_operations_tool_shape)

    execute("""
    UPDATE mcp_operations AS operations
    SET tool = 'test_runbook_draft'
    FROM runbook_executions AS executions
    WHERE operations.id = executions.mcp_operation_record_id
      AND operations.tool = 'execute_runbook'
      AND executions.kind = 'draft_test'
    """)

    create constraint(:mcp_operations, :mcp_operations_tool_shape,
             check: """
             (tool = 'run_action' AND action_id IS NOT NULL AND pack_ref IS NOT NULL AND resource_id IS NULL AND resource_ref IS NULL)
             OR
             (tool IN ('execute_runbook', 'create_runbook_draft', 'update_runbook_draft', 'test_runbook_draft') AND action_id IS NULL AND pack_ref IS NULL AND resource_id IS NOT NULL AND resource_ref IS NOT NULL)
             """
           )
  end
end
