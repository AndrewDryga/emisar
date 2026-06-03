defmodule Emisar.Repo.Migrations.PartialUniqueIndexesSoftDelete do
  use Ecto.Migration

  # Soft-deletable tables carry `deleted_at`. A soft-deleted row must not
  # keep reserving a unique key — slug, email, external_id, key_prefix,
  # (account, user), one-policy-per-account, (slug, version) — against
  # live rows, or you can never re-register / re-invite / re-seed after a
  # soft delete. Re-create each such unique index as PARTIAL
  # `WHERE deleted_at IS NULL` so the constraint ranges over live rows only.
  #
  # `deleted_at` is added by a later migration (20260531000000_soft_delete
  # _columns), so the original `create unique_index/2` calls can't yet
  # reference it — they stay plain unique indexes. This migration runs once
  # the column exists and swaps each to PARTIAL, for fresh and
  # already-migrated (prod) databases alike. Index names are the
  # column-derived defaults and unchanged, so we drop + recreate in place
  # and every `unique_constraint/3` in the changesets keeps matching by name.
  @partial "deleted_at IS NULL"

  @indexes [
    {:accounts, [:slug]},
    {:users, [:email]},
    {:memberships, [:account_id, :user_id]},
    {:runners, [:account_id, :external_id]},
    {:runner_auth_keys, [:key_prefix]},
    {:api_keys, [:key_prefix]},
    {:policies, [:account_id]},
    {:runbooks, [:account_id, :slug, :version]}
  ]

  def up do
    for {table, cols} <- @indexes do
      drop_if_exists index(table, cols)
      create unique_index(table, cols, where: @partial)
    end
  end

  def down do
    for {table, cols} <- @indexes do
      drop_if_exists index(table, cols)
      create unique_index(table, cols)
    end
  end
end
