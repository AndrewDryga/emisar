defmodule Emisar.Repo.Migrations.TrackPolicyVersionOnRuns do
  use Ecto.Migration

  @moduledoc """
  Adds version tracking so an audit row + run row can both point at
  the exact policy revision that decided the dispatch.

  * `policies.vsn` — integer, starts at 1, bumped on every
    `update_policy_rules`. Lets the audit trail correlate "runs 123,
    456, 789 were all decided under policy v3" even after the rules
    map is later edited.
  * `action_runs.policy_version` — the vsn snapshot taken when the
    decision was made. Nilable for runs that pre-date this migration.
  """

  def change do
    alter table(:policies) do
      add :vsn, :integer, null: false, default: 1
    end

    alter table(:action_runs) do
      add :policy_version, :integer
    end
  end
end
