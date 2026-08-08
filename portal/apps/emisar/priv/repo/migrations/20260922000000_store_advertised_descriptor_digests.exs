defmodule Emisar.Repo.Migrations.StoreAdvertisedDescriptorDigests do
  @moduledoc """
  Store a content digest of each advertised action descriptor, so a catalog
  listing can judge trusted-manifest match without loading `args_schema`,
  `output_schema`, `examples`, `description`, and `search_terms` for every
  action of every pack on every runner.

  The backfill is the point of doing it here rather than waiting for each
  runner's next advertisement: a connected runner whose rows carried no digest
  would read as drifted, and `descriptor_mismatch` is a tamper-flavored alarm.
  """
  use Ecto.Migration

  # `catalog_runner_actions` already holds production rows and this runs before
  # an instance serves. Adding a nullable column with no default is metadata
  # only, but the backfill is real work: batched by primary key, each batch its
  # own transaction, so nothing holds write locks across the whole table.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 500

  # Keyset lower bound for the first batch — every UUID sorts above it.
  @before_first_id <<0::128>>

  def up do
    alter table(:catalog_runner_actions) do
      add :descriptor_digest, :string
    end

    flush()

    backfill(@before_first_id)
  end

  # Derived data: every write recomputes it from the descriptor columns.
  def down do
    alter table(:catalog_runner_actions) do
      remove :descriptor_digest
    end
  end

  defp backfill(after_id) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, title, summary, description, kind, risk, side_effects,
               args_schema, output_schema, examples, search_terms
        FROM catalog_runner_actions
        WHERE id > $1
        ORDER BY id
        LIMIT $2
        """,
        [after_id, @batch_size]
      )

    write_digests(rows)
  end

  defp write_digests([]), do: :ok

  defp write_digests(rows) do
    ids = Enum.map(rows, &hd/1)
    digests = Enum.map(rows, fn [_id | descriptor] -> digest(descriptor) end)

    repo().query!(
      """
      UPDATE catalog_runner_actions AS a
      SET descriptor_digest = b.descriptor_digest
      FROM unnest($1::uuid[], $2::text[]) AS b(id, descriptor_digest)
      WHERE a.id = b.id
      """,
      [ids, digests]
    )

    ids |> List.last() |> backfill()
  end

  # Through the same function the ingest uses, reached at runtime rather than
  # through a compiled struct literal: a fresh database has no rows to backfill,
  # so a later rename of the schema must not stop this migration from replaying.
  defp digest([
         title,
         summary,
         description,
         kind,
         risk,
         side_effects,
         args_schema,
         output_schema,
         examples,
         search_terms
       ]) do
    Emisar.Catalog.RunnerAction
    |> struct!(
      title: title,
      summary: summary,
      description: description,
      kind: kind,
      risk: risk,
      side_effects: side_effects,
      args_schema: args_schema,
      output_schema: output_schema,
      examples: examples,
      search_terms: search_terms
    )
    |> Emisar.Catalog.TrustedManifest.runner_action_digest()
  end
end
