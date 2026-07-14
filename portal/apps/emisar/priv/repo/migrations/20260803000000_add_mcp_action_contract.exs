defmodule Emisar.Repo.Migrations.AddMcpActionContract do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :credential_lineage_id, :uuid
    end

    execute("""
    UPDATE api_keys
    SET credential_lineage_id = id
    WHERE credential_lineage_id IS NULL
    """)

    execute("""
    WITH RECURSIVE lineages AS (
      SELECT id, id AS root_id, ARRAY[id] AS path
      FROM api_keys
      WHERE replaces_id IS NULL

      UNION ALL

      SELECT child.id, parent.root_id, parent.path || child.id
      FROM api_keys child
      JOIN lineages parent ON child.replaces_id = parent.id
      WHERE NOT child.id = ANY(parent.path)
    )
    UPDATE api_keys key
    SET credential_lineage_id = lineages.root_id
    FROM lineages
    WHERE key.id = lineages.id
    """)

    alter table(:api_keys) do
      modify :credential_lineage_id, :uuid, null: false
    end

    create index(:api_keys, [:account_id, :credential_lineage_id])

    create table(:mcp_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credential_lineage_id, :uuid, null: false
      add :operation_id, :string, null: false
      add :tool, :string, null: false
      add :fingerprint, :string, null: false
      add :action_id, :string
      add :pack_ref, :string
      add :resource_id, :uuid
      add :resource_ref, :string

      timestamps()
    end

    create unique_index(
             :mcp_operations,
             [:account_id, :credential_lineage_id, :operation_id],
             name: :mcp_operations_lineage_operation_index
           )

    create constraint(:mcp_operations, :mcp_operations_tool_shape,
             check: """
             (tool = 'run_action' AND action_id IS NOT NULL AND pack_ref IS NOT NULL AND resource_id IS NULL AND resource_ref IS NULL)
             OR
             (tool IN ('execute_runbook', 'create_runbook_draft') AND action_id IS NULL AND pack_ref IS NULL AND resource_id IS NOT NULL AND resource_ref IS NOT NULL)
             """
           )

    create constraint(:mcp_operations, :mcp_operations_identity_bounds,
             check: """
             operation_id ~ '^op_[0-7][0-9A-HJKMNP-TV-Z]{25}$'
             AND octet_length(fingerprint) = 64
             AND octet_length(resource_ref) <= 255
             """
           )

    alter table(:action_runs) do
      add :operation_id, :string
      add :pack_ref, :string
      add :runner_ref, :string
      add :args_raw, :binary

      add :mcp_operation_record_id,
          references(:mcp_operations, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:action_runs, [:account_id, :operation_id], where: "operation_id IS NOT NULL")
    create index(:action_runs, [:mcp_operation_record_id])

    create unique_index(:action_runs, [:mcp_operation_record_id, :runner_id],
             where: "mcp_operation_record_id IS NOT NULL",
             name: :action_runs_mcp_operation_runner_index
           )

    alter table(:runbook_executions) do
      add :operation_id, :string

      add :mcp_operation_record_id,
          references(:mcp_operations, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:runbook_executions, [:mcp_operation_record_id])

    create unique_index(:runbook_executions, [:mcp_operation_record_id],
             where: "mcp_operation_record_id IS NOT NULL",
             name: :runbook_executions_mcp_operation_index
           )
  end
end
