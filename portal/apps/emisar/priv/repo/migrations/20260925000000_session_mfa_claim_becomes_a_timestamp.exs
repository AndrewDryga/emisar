defmodule Emisar.Repo.Migrations.SessionMfaClaimBecomesATimestamp do
  @moduledoc """
  `auth_user_tokens.mfa` recorded THAT a session proved a second factor but not
  WHEN, and the column is fixed at mint — so the claim outlived the enrollment
  behind it. Disable TOTP, re-enroll, and the old cookie still asserted a factor
  it had never proved against the new one.

  A timestamp lets the claim be bound at read time: a magic-link session counts
  only when its proof is not older than the user's current `mfa_enabled_at`, so
  re-enrolling invalidates every session that proved the previous factor without
  signing anyone out. SSO sessions are exempt from that comparison — the IdP
  proved the factor and our TOTP lifecycle does not govern it.

  The boolean was fixed at mint, so proof-time IS mint-time for every existing
  row: `inserted_at` is the exact backfill value, not an approximation. The table
  holds one row per live credential and expires on the session window, so the
  single UPDATE has nothing to grow against.
  """
  use Ecto.Migration

  def up do
    alter table(:auth_user_tokens) do
      add :mfa_verified_at, :utc_datetime_usec
    end

    execute "UPDATE auth_user_tokens SET mfa_verified_at = inserted_at WHERE mfa = true"

    alter table(:auth_user_tokens) do
      remove :mfa
    end
  end

  def down do
    alter table(:auth_user_tokens) do
      add :mfa, :boolean, null: false, default: false
    end

    execute "UPDATE auth_user_tokens SET mfa = true WHERE mfa_verified_at IS NOT NULL"

    alter table(:auth_user_tokens) do
      remove :mfa_verified_at
    end
  end
end
