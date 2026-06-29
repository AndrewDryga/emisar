defmodule Emisar.Repo.Migrations.BackfillDriftedColumns do
  use Ecto.Migration

  # Corrective (not edit-original). These three columns were added to their
  # ORIGINAL migrations after production had already applied those versions, so
  # `migrate` saw nothing new to run and prod never got them — every request
  # then 500'd on `Auth.fetch_user_and_token_by_session_token/1` selecting the
  # missing `user_tokens.remaining_attempts`. A fresh DB (dev/test/CI/new
  # deploys) already has all three from the edited originals, so each add is
  # guarded with `add_if_not_exists` and is a no-op there; only the drifted
  # prod DB is changed.
  #
  #   * user_tokens.remaining_attempts  — 20260520000001 (split-code magic link)
  #   * oauth_clients.last_authorized_at — 20260603000000 (OAuth/MCP)
  #   * subscriptions.paddle_updated_at  — 20260520000007 (Paddle mirror)
  def up do
    alter table(:user_tokens) do
      add_if_not_exists :remaining_attempts, :integer
    end

    alter table(:oauth_clients) do
      add_if_not_exists :last_authorized_at, :utc_datetime_usec
    end

    alter table(:subscriptions) do
      add_if_not_exists :paddle_updated_at, :utc_datetime_usec
    end
  end

  # No-op: these columns are owned by the original migrations above and are
  # required by the live schema, so reversing this backfill must NOT drop them
  # (they exist on every fresh DB from those originals).
  def down, do: :ok
end
