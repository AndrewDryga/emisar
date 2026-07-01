defmodule Emisar.Repo.Migrations.AddRetainUntilToAuditEvents do
  use Ecto.Migration

  # Per-row audit retention. Stamp each row's delete horizon at WRITE time
  # (occurred_at + the then-current plan window) so a plan DOWNGRADE can't
  # retroactively wipe history: the nightly sweep prunes `retain_until < now`
  # instead of recomputing the cutoff from the (now smaller) current window,
  # which let an insider downgrade-to-wipe up to ~83 days of trail.
  def change do
    alter table(:audit_events) do
      add :retain_until, :utc_datetime_usec
    end

    # Backfill existing rows from each account's CURRENT plan window. The
    # plan→days map (Free 7 / Team 90 / Enterprise 365) is snapshotted here; the
    # app owns it going forward via `Billing.account_audit_retention_days/1`.
    execute(
      """
      UPDATE audit_events ae
      SET retain_until = ae.occurred_at + (
        CASE COALESCE(
          (SELECT s.plan FROM subscriptions s WHERE s.account_id = ae.account_id LIMIT 1),
          'free'
        )
          WHEN 'enterprise' THEN interval '365 days'
          WHEN 'team' THEN interval '90 days'
          ELSE interval '7 days'
        END
      )
      WHERE ae.retain_until IS NULL
      """,
      "UPDATE audit_events SET retain_until = NULL"
    )

    # The sweep pages `by_account_id |> retain_until < now` — keep it keyset-friendly.
    create index(:audit_events, [:account_id, :retain_until])
  end
end
