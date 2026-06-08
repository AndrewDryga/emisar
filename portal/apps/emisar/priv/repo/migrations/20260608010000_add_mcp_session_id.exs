defmodule Emisar.Repo.Migrations.AddMcpSessionId do
  use Ecto.Migration

  # The MCP Streamable-HTTP session id (Mcp-Session-Id header) a client
  # echoes after `initialize`. Recorded on each run and on audit events so
  # the actions from one MCP session can be correlated. Partial indexes —
  # only MCP rows carry a session id, the rest are null.
  def change do
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
