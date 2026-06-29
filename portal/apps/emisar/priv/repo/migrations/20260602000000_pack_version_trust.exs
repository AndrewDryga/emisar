defmodule Emisar.Repo.Migrations.PackVersionTrust do
  @moduledoc """
  Trust-on-first-use pinning for advertised pack versions.

  Today the cloud stores every (pack_id, version, hash) the fleet
  advertises as a separate row, but nothing gates dispatch on the
  hash. This migration collapses to one row per (pack_id, version)
  per account, holding:

    * `hash` — the trusted hash (what dispatch authorizes against)
    * `pending_hash` — a different hash a runner reported later;
      surfaced in the UI for Trust/Reject
    * `trust_state` — `"trusted"` (default), `"pending"`, or `"rejected"`

  Also adds `pack_version` to `runner_actions` so dispatch can look
  up the trust state of the exact version the runner has loaded.
  """
  use Ecto.Migration

  def change do
    # 1. Add trust columns to pack_versions.
    alter table(:pack_versions) do
      add :trust_state, :string, null: false, default: "trusted"
      add :pending_hash, :string
    end

    # 2. Drop old unique index (account, pack_id, version, hash).
    drop_if_exists unique_index(:pack_versions, [:account_id, :pack_id, :version, :hash])

    # 3. Collapse duplicate rows by (acct, pack_id, version) keeping
    #    the earliest by first_seen_at. Pre-prod data only — the user
    #    has accepted that we treat the oldest row as the trusted
    #    baseline for any historical drift.
    execute(
      """
      DELETE FROM pack_versions a
      USING pack_versions b
      WHERE a.account_id = b.account_id
        AND a.pack_id = b.pack_id
        AND a.version = b.version
        AND (a.first_seen_at > b.first_seen_at
             OR (a.first_seen_at = b.first_seen_at AND a.id > b.id))
      """,
      "SELECT 1"
    )

    # 4. New unique constraint per (account, pack_id, version).
    create unique_index(:pack_versions, [:account_id, :pack_id, :version])

    # 5. Per-runner pack version so the dispatch gate can look up
    #    the trust state of the exact version this runner advertises.
    alter table(:runner_actions) do
      add :pack_version, :string
    end

    create index(:runner_actions, [:account_id, :pack_id, :pack_version])
  end
end
