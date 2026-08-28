defmodule Emisar.Repo.Migrations.GiveTheFourTablesMicrosecondTimestamps do
  use Ecto.Migration

  # Four tables kept `timestamp(0)` from a bare `timestamps()` while their
  # schemas declare :utc_datetime_usec (Emisar.__schema__/0 sets
  # @timestamps_opts). Postgres ROUNDS on the way in, so a row can carry an
  # inserted_at up to half a second in its own future — and inside
  # runbook_executions that sits beside completed_at, started_at and
  # last_advanced_at, which are microsecond-grained, so an execution can appear
  # to complete before it was inserted.
  #
  # Widening a timestamp precision is a catalog relabel, not a rewrite:
  # verified on Postgres 18.4 (the version production and the dev stack run) by
  # comparing pg_relation_filenode across the ALTER — both the table's and an
  # index's filenode were unchanged. The lock is ACCESS EXCLUSIVE but momentary.
  #
  # schema_migrations is Ecto's own table and is left alone.

  @tables ~w[marketing_signups mcp_operations runbook_executions user_runner_scopes]a

  def up do
    for table <- @tables do
      alter table(table) do
        modify :inserted_at, :utc_datetime_usec
      end
    end

    # user_runner_scopes has no updated_at.
    for table <- @tables -- [:user_runner_scopes] do
      alter table(table) do
        modify :updated_at, :utc_datetime_usec
      end
    end
  end

  def down do
    for table <- @tables do
      alter table(table) do
        modify :inserted_at, :naive_datetime
      end
    end

    for table <- @tables -- [:user_runner_scopes] do
      alter table(table) do
        modify :updated_at, :naive_datetime
      end
    end
  end
end
