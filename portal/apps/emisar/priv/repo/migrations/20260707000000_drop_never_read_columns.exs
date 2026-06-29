defmodule Emisar.Repo.Migrations.DropNeverReadColumns do
  use Ecto.Migration

  # Corrective (not edit-original). The Jun 28–29 "drop never-read column"
  # refactors removed these seven columns by editing their ORIGINAL create
  # migrations in place. Those originals (20260520* / 20260602* / 20260616*)
  # had already been applied in production, so `migrate` saw nothing new to run
  # and prod KEPT the columns — while every fresh DB (dev/test/CI/new deploys),
  # built from the edited originals, never creates them. That divergence is the
  # drift the frozen-migration rule (IL-11 / AGENTS.md §8) exists to prevent;
  # this migration converges them by dropping the columns forward.
  #
  # Each is `remove_if_exists`, so it drops on the drifted prod DB and is a
  # no-op on a fresh DB that never had it. All seven are dead in the live schema
  # (the refactors removed the fields + their writes) — note the deliberately
  # narrow table targets: the live `runners.group`, `runner_auth_keys.revoked_at`,
  # `grants.revoked_at`, and `approval_requests.reason` are same-named columns on
  # OTHER tables and are untouched.
  #
  #   * approval_decisions.reason             — 20260616000000 (0a025314)
  #   * pack_versions.pinned_at / pinned_by_id — 20260602000000 (b6c8c378)
  #   * runner_actions.limits / output        — 20260520000003 (fe02a0ad)
  #   * runner_auth_keys.group                — 20260520000002 (7d65eb4d)
  #   * runner_tokens.revoked_at              — 20260520000002 (cb9c5310)
  def up do
    alter table(:approval_decisions) do
      remove_if_exists :reason
    end

    alter table(:pack_versions) do
      remove_if_exists :pinned_at
      remove_if_exists :pinned_by_id
    end

    alter table(:runner_actions) do
      remove_if_exists :limits
      remove_if_exists :output
    end

    alter table(:runner_auth_keys) do
      remove_if_exists :group
    end

    alter table(:runner_tokens) do
      remove_if_exists :revoked_at
    end
  end

  # No-op: these columns are dead in the live schema and never existed on a
  # fresh DB, so reversing this drop must NOT re-add them (it would re-create
  # columns no code uses, and diverge fresh DBs the other way). Same rationale
  # as 20260705000000_backfill_drifted_columns.
  def down, do: :ok
end
