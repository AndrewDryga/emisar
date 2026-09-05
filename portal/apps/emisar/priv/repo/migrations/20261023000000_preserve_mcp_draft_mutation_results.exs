defmodule Emisar.Repo.Migrations.PreserveMCPDraftMutationResults do
  use Ecto.Migration

  def change do
    alter table(:mcp_operations) do
      add :draft_definition_sha256, :string
      add :draft_live_version, :integer
    end

    create constraint(:mcp_operations, :mcp_operations_draft_result_shape,
             check: """
             (draft_definition_sha256 IS NULL AND draft_live_version IS NULL)
             OR
             (tool IN ('create_runbook_draft', 'update_runbook_draft')
              AND draft_definition_sha256 IS NOT NULL
              AND draft_definition_sha256 ~ '^[0-9a-f]{64}$'
              AND (draft_live_version IS NULL OR draft_live_version > 0))
             """
           )
  end
end
