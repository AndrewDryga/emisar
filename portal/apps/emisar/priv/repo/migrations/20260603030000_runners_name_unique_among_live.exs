defmodule Emisar.Repo.Migrations.RunnersNameUniqueAmongLive do
  use Ecto.Migration

  # Identity is external_id, but `name` is what operators and LLMs address a
  # runner by — so it has to be unambiguous. Make `name` unique among LIVE
  # (non-deleted) runners. A re-registering host that can't claim a taken
  # name now gets a clean conflict (register returns
  # {:error, :runner_name_taken, name} → HTTP 409); the operator deletes or
  # renames the other runner. Deleting soft-deletes it, and the partial
  # `WHERE deleted_at IS NULL` predicate frees the name immediately.
  #
  # This refines 20260603010000 (which dropped the OLD hard unique constraint
  # because a re-register under a taken name 500'd). We get name uniqueness
  # back — but among live rows only, and with a graceful conflict path instead
  # of a crash.
  #
  # Before enforcing, collapse any pre-existing live duplicates: among rows
  # sharing (account_id, name) keep the liveliest (connected, then
  # most-recently-seen) and soft-delete the rest, so the unique index builds.

  def up do
    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY account_id, name
               ORDER BY (status = 'connected') DESC,
                        last_heartbeat_at DESC NULLS LAST,
                        inserted_at DESC
             ) AS rn
      FROM runners
      WHERE deleted_at IS NULL
    )
    UPDATE runners
    SET deleted_at = now()
    WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
    """)

    drop_if_exists index(:runners, [:account_id, :name])
    create unique_index(:runners, [:account_id, :name], where: "deleted_at IS NULL")
  end

  def down do
    drop_if_exists index(:runners, [:account_id, :name])
    create index(:runners, [:account_id, :name])
  end
end
