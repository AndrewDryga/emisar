defmodule Emisar.Repo.Migrations.AddRunnerTokenExpiry do
  use Ecto.Migration

  # Step one of two. This column is written but NOT enforced: `verify_runner_token`
  # ignores it until the refresh counters show the fleet actually rotating.
  #
  # Nullable, and every existing row stays NULL. NULL means "never expires", so
  # no runner that is connected today can be locked out by this change or by the
  # one that starts enforcing it — enforcement only ever bites tokens minted
  # after rotation shipped, which are the ones that have a refresh path.
  #
  # Backfilling existing tokens is a separate, deliberate act once the evidence
  # is in, not a side effect of adding the column.

  def change do
    alter table(:runner_tokens) do
      add :expires_at, :utc_datetime_usec
    end

    # The refresh sweep reads "which of this runner's tokens are still live",
    # and the expiry check reads one row by prefix — both want the runner's
    # tokens ordered by when they lapse.
    create index(:runner_tokens, [:runner_id, :expires_at])
  end
end
