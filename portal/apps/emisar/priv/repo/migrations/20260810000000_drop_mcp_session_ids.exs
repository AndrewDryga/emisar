defmodule Emisar.Repo.Migrations.DropMcpSessionIds do
  use Ecto.Migration

  def up do
    drop_if_exists index(:action_runs, [:mcp_session_id])
    drop_if_exists index(:audit_events, [:account_id, :mcp_session_id])

    alter table(:action_runs) do
      remove :mcp_session_id
    end

    alter table(:audit_events) do
      remove :mcp_session_id
    end
  end

  def down do
    alter table(:action_runs) do
      add :mcp_session_id, :string
    end

    alter table(:audit_events) do
      add :mcp_session_id, :string
    end

    create index(:action_runs, [:mcp_session_id], where: "mcp_session_id IS NOT NULL")

    create index(:audit_events, [:account_id, :mcp_session_id],
             where: "mcp_session_id IS NOT NULL"
           )
  end
end
