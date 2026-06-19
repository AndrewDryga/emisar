defmodule Emisar.Repo.Migrations.AddExpectedPackHashToActionRuns do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      # The trusted pack hash SNAPSHOTTED at authorization (run creation), so the
      # dispatch ships the exact bytes the policy/operator authorized for THIS
      # run — never a hash re-read at send time, which a pack that drifted then
      # re-trusted to different bytes could otherwise swap underneath it. Null
      # for a pack-less action (nothing to pin).
      add :expected_pack_hash, :string
    end
  end
end
