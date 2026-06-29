defmodule Emisar.Repo.Migrations.ConsolidateAccountSettings do
  use Ecto.Migration

  # Corrective (not edit-original): the accounts table is already on prod.
  # Fold the three operator settings (require_mfa / require_sso /
  # max_grant_lifetime_seconds) into one `settings` jsonb column backed by the
  # Account.Settings embedded schema, so the schema stops growing a column per
  # toggle. Add the column, backfill from the existing columns, drop them.
  def up do
    alter table(:accounts) do
      add :settings, :map, null: false, default: %{}
    end

    execute("""
    UPDATE accounts
    SET settings = jsonb_build_object(
      'require_mfa', require_mfa,
      'require_sso', require_sso,
      'max_grant_lifetime_seconds', max_grant_lifetime_seconds
    )
    """)

    alter table(:accounts) do
      remove :require_mfa
      remove :require_sso
      remove :max_grant_lifetime_seconds
    end
  end

  def down do
    alter table(:accounts) do
      add :require_mfa, :boolean, null: false, default: false
      add :require_sso, :boolean, null: false, default: false
      add :max_grant_lifetime_seconds, :integer
    end

    execute("""
    UPDATE accounts
    SET require_mfa = COALESCE((settings ->> 'require_mfa')::boolean, false),
        require_sso = COALESCE((settings ->> 'require_sso')::boolean, false),
        max_grant_lifetime_seconds = (settings ->> 'max_grant_lifetime_seconds')::integer
    """)

    alter table(:accounts) do
      remove :settings
    end
  end
end
