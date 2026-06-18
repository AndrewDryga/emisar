defmodule Emisar.Repo.Migrations.AddEnforceSignaturesToRunners do
  use Ecto.Migration

  # Corrective (not edit-original): the runners table is already on prod.
  # Runner-advertised: when true, the runner verifies a client signature on
  # every dispatch and refuses unsigned ones — so the portal disables its own
  # (operator/runbook) dispatch to that runner; only signed MCP calls get
  # through. A runner can only make itself stricter, so this is trusted from
  # the runner_state advertisement (the host is the trust anchor, like `group`).
  def change do
    alter table(:runners) do
      add :enforce_signatures, :boolean, null: false, default: false
    end
  end
end
