defmodule Emisar.Repo.Migrations.SoftDeleteColumns do
  use Ecto.Migration

  @soft_deleted_tables ~w[
    accounts
    users
    memberships
    runners
    runner_auth_keys
    api_keys
    policies
    runbooks
  ]a

  def change do
    for table_name <- @soft_deleted_tables do
      alter table(table_name) do
        add :deleted_at, :utc_datetime_usec, null: true
      end

      # Partial index — only soft-deleted rows are indexed, keeping
      # `WHERE deleted_at IS NULL` reads (the default scope) fast on
      # the bulk of the table.
      create index(table_name, [:deleted_at], where: "deleted_at IS NOT NULL")
    end
  end
end
