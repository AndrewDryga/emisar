defmodule Emisar.Repo.Migrations.AddMcpClientMetadataToActionRuns do
  use Ecto.Migration

  # Self-reported MCP client metadata — the operator-configured key/value map an
  # MCP caller sends (Emisar-Client-Metadata header) so its Emisar activity can be
  # correlated with the customer's own MDM/EDR/device inventory in the audit log +
  # SIEM export. Snapshotted onto each run at dispatch time (so a historical run
  # keeps the metadata present when it ran, even as a key is reused). UNTRUSTED,
  # self-reported enrichment, validated at the MCP boundary; never an authz input.
  # Empty for non-MCP runs (jsonb, null:false default %{}, mirroring client_info).
  def change do
    alter table(:action_runs) do
      add :mcp_client_metadata, :map, null: false, default: %{}
    end
  end
end
