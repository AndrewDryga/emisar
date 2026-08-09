defmodule Emisar.Repo.Migrations.CollapseRunbookVersions do
  @moduledoc """
  One row per runbook, one mutable draft, and an append-only release log.

  Every save used to mint an immutable `runbooks` row, so a slug family was a
  pile of rows and "which one runs" was derived from them. After this the row IS
  the runbook: `definition` is what is live, `live_version` counts publishes,
  and `draft_definition` holds the single unpublished change.

  Order is load-bearing. `runbook_executions.runbook_id` is ON DELETE CASCADE
  and `action_runs.runbook_id` is ON DELETE SET NULL, so both are backfilled and
  repointed at their group's survivor BEFORE any non-survivor row is deleted —
  collapsing first would destroy the execution history the release log exists to
  explain. The data steps therefore run through `repo()` between two flushes,
  where their order is the order they are written.
  """
  use Ecto.Migration

  # A group is one (account_id, slug, deleted_at): live rows share a NULL stamp
  # and each tombstoned family carries the single instant it was deleted, so a
  # re-created slug never merges with the one it replaced.
  @group "account_id, slug, deleted_at"

  @survivors """
  SELECT DISTINCT ON (#{@group}) id, #{@group}, status, definition
  FROM runbooks
  ORDER BY #{@group}, version DESC
  """

  # Releases renumber densely per surviving family: publishes count, saves do not.
  @published_releases """
  SELECT id, account_id, slug, title, description, definition, created_by_id, inserted_at,
         ROW_NUMBER() OVER (PARTITION BY account_id, slug ORDER BY version) AS release_version
  FROM runbooks
  WHERE deleted_at IS NULL AND status = 'published'
  """

  @non_survivors """
  SELECT r.id AS old_id, s.id AS new_id
  FROM runbooks AS r
  JOIN (#{@survivors}) AS s
    ON s.account_id = r.account_id AND s.slug = r.slug
   AND s.deleted_at IS NOT DISTINCT FROM r.deleted_at
  WHERE r.id <> s.id
  """

  def up do
    create table(:runbook_releases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # Plain reference: runbooks soft-delete, so there is no cascade to inherit
      # and a tombstoned runbook keeps the procedures it once approved.
      add :runbook_id, references(:runbooks, type: :binary_id), null: false

      add :version, :integer, null: false
      add :title, :string, null: false
      add :description, :text
      add :definition, :map, null: false
      add :definition_sha256, :string, null: false

      add :published_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runbook_releases, [:runbook_id, :version])
    create index(:runbook_releases, [:account_id])

    alter table(:runbooks) do
      add :live_version, :integer
      add :draft_definition, :map
    end

    alter table(:runbook_executions) do
      add :definition, :map
      add :runbook_version, :integer
    end

    # Null until the first publish — a new runbook is a draft with nothing live.
    execute "ALTER TABLE runbooks ALTER COLUMN definition DROP NOT NULL"

    flush()

    insert_releases()
    backfill_executions()
    repoint_history()
    collapse_survivors()

    repo().query!("DELETE FROM runbooks WHERE id NOT IN (SELECT id FROM (#{@survivors}) AS s)")

    execute "ALTER TABLE runbook_executions ALTER COLUMN definition SET NOT NULL"

    drop_if_exists index(:runbooks, [:account_id, :slug, :version])
    drop_if_exists index(:runbooks, [:account_id, :status])
    create unique_index(:runbooks, [:account_id, :slug], where: "deleted_at IS NULL")

    alter table(:runbooks) do
      remove :version
      remove :status
    end
  end

  # Structure only. The collapse itself is one-way: the per-version rows and the
  # numbering they carried are gone, so a rolled-back database has the old shape
  # with one row per runbook in it.
  def down do
    drop table(:runbook_releases)

    alter table(:runbook_executions) do
      remove :definition
      remove :runbook_version
    end

    alter table(:runbooks) do
      remove :live_version
      remove :draft_definition
      add :version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "draft"
    end

    drop_if_exists index(:runbooks, [:account_id, :slug])
    create unique_index(:runbooks, [:account_id, :slug, :version], where: "deleted_at IS NULL")
    create index(:runbooks, [:account_id, :status])
  end

  # The digest is the release's write-once audit value, computed through the one
  # module every other definition identity in this system is computed by.
  defp insert_releases do
    %{rows: rows} =
      repo().query!("""
      SELECT s.id, p.account_id, p.release_version, p.title, p.description, p.definition,
             p.created_by_id, p.inserted_at
      FROM (#{@published_releases}) AS p
      JOIN (#{@survivors}) AS s
        ON s.account_id = p.account_id AND s.slug = p.slug AND s.deleted_at IS NULL
      """)

    Enum.each(rows, &insert_release/1)
  end

  defp insert_release([
         runbook_id,
         account_id,
         version,
         title,
         description,
         definition,
         created_by_id,
         inserted_at
       ]) do
    repo().query!(
      """
      INSERT INTO runbook_releases
        (id, account_id, runbook_id, version, title, description, definition,
         definition_sha256, published_by_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10)
      """,
      [
        Ecto.UUID.bingenerate(version: 7, precision: :monotonic),
        account_id,
        runbook_id,
        version,
        title,
        description,
        definition,
        Emisar.CanonicalJSON.digest(definition),
        created_by_id,
        inserted_at
      ]
    )
  end

  # The old per-version row an execution points at IS what ran, so it is read
  # through the still-current foreign key before anything is repointed.
  defp backfill_executions do
    repo().query!("""
    UPDATE runbook_executions AS e
    SET definition = r.definition,
        runbook_version = p.release_version
    FROM runbooks AS r
    LEFT JOIN (#{@published_releases}) AS p ON p.id = r.id
    WHERE e.runbook_id = r.id
    """)
  end

  defp repoint_history do
    repo().query!("""
    UPDATE runbook_executions AS e SET runbook_id = m.new_id
    FROM (#{@non_survivors}) AS m WHERE e.runbook_id = m.old_id
    """)

    repo().query!("""
    UPDATE action_runs AS a SET runbook_id = m.new_id
    FROM (#{@non_survivors}) AS m WHERE a.runbook_id = m.old_id
    """)
  end

  # The survivor is the family head: newest title and description, and its own
  # definition becomes the draft when it was still unpublished over an older
  # live release.
  defp collapse_survivors do
    repo().query!("""
    UPDATE runbooks AS r
    SET live_version = NULLIF(g.published_count, 0),
        definition = live.definition,
        draft_definition = CASE WHEN s.status = 'draft' THEN s.definition END
    FROM (#{@survivors}) AS s
    JOIN (
      SELECT #{@group}, count(*) FILTER (WHERE status = 'published') AS published_count
      FROM runbooks GROUP BY #{@group}
    ) AS g
      ON g.account_id = s.account_id AND g.slug = s.slug
     AND g.deleted_at IS NOT DISTINCT FROM s.deleted_at
    LEFT JOIN (
      SELECT DISTINCT ON (#{@group}) #{@group}, definition
      FROM runbooks WHERE status = 'published'
      ORDER BY #{@group}, version DESC
    ) AS live
      ON live.account_id = s.account_id AND live.slug = s.slug
     AND live.deleted_at IS NOT DISTINCT FROM s.deleted_at
    WHERE r.id = s.id
    """)
  end
end
