defmodule Emisar.Repo.Migrations.AddMaxAttestationAgeToRunners do
  use Ecto.Migration

  # Corrective (runners is already on prod, like the enforce_signatures add).
  # Runner-advertised alongside enforce_signatures: the freshness window (in
  # seconds) a signed dispatch's issued_at must fall within. The portal stores
  # it so it can refuse an approval up front when the parked signature would
  # already be stale by the time the runner re-receives it (a slow approval) —
  # fail-fast; the runner stays the authority on the actual refusal.
  def change do
    alter table(:runners) do
      add :max_attestation_age_seconds, :integer
    end
  end
end
