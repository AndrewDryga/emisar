defmodule Emisar.Repo.Migrations.RunnersNameNotUnique do
  use Ecto.Migration

  # Runner identity is (account, external_id) — the stable id the runner
  # persists and presents on every register. Names are display labels
  # (default: hostname) and may repeat: a fresh install or a different
  # machine gets a new external_id and can reuse a name. Drop the
  # (account_id, name) UNIQUE index and replace it with a plain index for
  # the by-name lookups MCP dispatch does. (The default index name is the
  # same for unique + plain, so we swap in place by name.)
  @index_name "runners_account_id_name_index"

  def up do
    drop_if_exists index(:runners, [:account_id, :name], name: @index_name)
    create index(:runners, [:account_id, :name], name: @index_name)
  end

  def down do
    drop_if_exists index(:runners, [:account_id, :name], name: @index_name)
    create unique_index(:runners, [:account_id, :name], name: @index_name)
  end
end
