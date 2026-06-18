defmodule Emisar.Repo.Migrations.AddAttestationToActionRuns do
  use Ecto.Migration

  # Corrective (not edit-original): the action_runs table is already on prod.
  # The client signature relayed from an MCP dispatch — stored so the run's wire
  # envelope to the runner can carry it (the runner verifies the Ed25519
  # signature), and for audit. Null for portal-originated runs (operator/
  # runbook), which carry no attestation and an enforcing runner refuses.
  def change do
    alter table(:action_runs) do
      add :attestation, :map
    end
  end
end
