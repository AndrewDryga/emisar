defmodule Emisar.Repo.Migrations.MakeRunnerAccessExplicit do
  use Ecto.Migration

  @none_runner_id "00000000-0000-0000-0000-000000000000"

  def up do
    alter table(:account_memberships) do
      add :runner_access_mode, :string
      add :runner_access_directory_managed, :boolean, null: false, default: false

      add :directory_provider_id,
          references(:sso_identity_providers, type: :binary_id, on_delete: :nilify_all)

      add :directory_authorization_version, :bigint, null: false, default: 0
      add :directory_authorization_pending_version, :bigint
    end

    alter table(:sso_identity_providers) do
      add :authorization_version, :bigint, null: false, default: 0
    end

    execute """
    UPDATE account_memberships AS memberships
    SET runner_access_mode = CASE
      WHEN EXISTS (
        SELECT 1 FROM user_runner_scopes AS scopes
        WHERE scopes.membership_id = memberships.id
      ) THEN 'restricted'
      ELSE 'all'
    END
    """

    alter table(:account_memberships) do
      modify :runner_access_mode, :string, null: false
    end

    execute """
    UPDATE account_memberships AS memberships
    SET directory_provider_id = (
      SELECT identities.provider_id
      FROM sso_user_identities AS identities
      JOIN sso_identity_providers AS providers ON providers.id = identities.provider_id
      WHERE identities.account_id = memberships.account_id
        AND identities.user_id = memberships.user_id
        AND identities.deleted_at IS NULL
        AND providers.scim_enabled = TRUE
      ORDER BY identities.inserted_at DESC, identities.id
      LIMIT 1
    )
    WHERE memberships.directory_managed = TRUE
       OR memberships.runner_access_directory_managed = TRUE
    """

    execute """
    UPDATE account_memberships
    SET runner_access_directory_managed = TRUE
    WHERE directory_provider_id IS NOT NULL
    """

    create index(:account_memberships, [:directory_provider_id])

    create index(:account_memberships, [:directory_authorization_pending_version],
             where: "directory_authorization_pending_version IS NOT NULL",
             name: :account_memberships_pending_directory_authorization_index
           )

    create constraint(:account_memberships, :account_memberships_runner_access_mode_check,
             check: "runner_access_mode IN ('none', 'all', 'restricted')"
           )

    alter table(:sso_identity_providers) do
      add :default_runner_access_mode, :string, null: false, default: "none"
      add :default_runner_scope_groups, {:array, :string}, null: false, default: []
      add :default_runner_scope_runner_ids, {:array, :uuid}, null: false, default: []
    end

    execute "UPDATE sso_identity_providers SET default_runner_access_mode = 'all'"

    create constraint(
             :sso_identity_providers,
             :sso_identity_providers_default_runner_access_check,
             check: access_check("default_runner")
           )

    create unique_index(:sso_identity_providers, [:account_id, :id],
             name: :sso_identity_providers_account_id_id_index
           )

    create table(:sso_directory_group_runner_access_mappings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_id,
          references(:sso_identity_providers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :external_group_id, :string, null: false
      add :external_group_display, :string
      add :runner_access_mode, :string, null: false
      add :runner_scope_groups, {:array, :string}, null: false, default: []
      add :runner_scope_runner_ids, {:array, :uuid}, null: false, default: []
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :sso_directory_group_runner_access_mappings,
             [:provider_id, :external_group_id],
             where: "deleted_at IS NULL",
             name: :sso_directory_group_runner_access_mappings_provider_group_index
           )

    create index(:sso_directory_group_runner_access_mappings, [:account_id])

    execute """
    ALTER TABLE sso_directory_group_runner_access_mappings
    ADD CONSTRAINT sso_group_runner_access_provider_account_fkey
    FOREIGN KEY (account_id, provider_id)
    REFERENCES sso_identity_providers (account_id, id)
    ON DELETE CASCADE
    """

    create constraint(
             :sso_directory_group_runner_access_mappings,
             :sso_directory_group_runner_access_mappings_access_check,
             check: access_check("runner") <> " AND runner_access_mode <> 'none'"
           )

    create constraint(
             :sso_directory_group_runner_access_mappings,
             :sso_directory_group_runner_access_mappings_external_group_id_check,
             check: "char_length(external_group_id) BETWEEN 1 AND 255"
           )

    create constraint(
             :sso_directory_group_runner_access_mappings,
             :sso_directory_group_runner_access_mappings_external_group_display_check,
             check: "external_group_display IS NULL OR char_length(external_group_display) <= 255"
           )

    create constraint(:runners, :runners_id_not_runner_access_none_sentinel,
             check: "id <> '#{@none_runner_id}'::uuid"
           )

    alter table(:action_runs) do
      add :initiating_membership_id,
          references(:account_memberships, type: :binary_id, on_delete: :nilify_all)
    end

    execute """
    UPDATE action_runs AS runs
    SET initiating_membership_id = keys.created_by_membership_id
    FROM api_keys AS keys
    WHERE keys.id = runs.api_key_id
    """

    execute """
    UPDATE action_runs AS runs
    SET initiating_membership_id = memberships.id
    FROM account_memberships AS memberships
    WHERE runs.api_key_id IS NULL
      AND memberships.account_id = runs.account_id
      AND memberships.user_id = runs.requested_by_id
      AND memberships.deleted_at IS NULL
    """

    create index(:action_runs, [:initiating_membership_id])

    install_compatibility_triggers()
  end

  def down do
    execute "DROP TRIGGER IF EXISTS account_memberships_seed_runner_access ON account_memberships"
    execute "DROP FUNCTION IF EXISTS account_memberships_seed_runner_access()"

    execute "DROP TRIGGER IF EXISTS account_memberships_default_runner_access ON account_memberships"

    execute "DROP FUNCTION IF EXISTS account_memberships_default_runner_access()"

    execute "DROP TRIGGER IF EXISTS user_runner_scopes_require_explicit_writer ON user_runner_scopes"

    execute "DROP FUNCTION IF EXISTS user_runner_scopes_require_explicit_writer()"

    drop constraint(:runners, :runners_id_not_runner_access_none_sentinel)
    drop_if_exists index(:action_runs, [:initiating_membership_id])

    alter table(:action_runs) do
      remove_if_exists :initiating_membership_id
    end

    drop table(:sso_directory_group_runner_access_mappings)

    drop_if_exists index(:sso_identity_providers, [:account_id, :id],
                     name: :sso_identity_providers_account_id_id_index
                   )

    alter table(:sso_identity_providers) do
      remove :default_runner_scope_runner_ids
      remove :default_runner_scope_groups
      remove :default_runner_access_mode
      remove_if_exists :authorization_version
    end

    drop_if_exists index(:account_memberships, [:directory_authorization_pending_version],
                     name: :account_memberships_pending_directory_authorization_index
                   )

    drop_if_exists index(:account_memberships, [:directory_provider_id])

    alter table(:account_memberships) do
      remove_if_exists :directory_authorization_pending_version
      remove_if_exists :directory_authorization_version
      remove_if_exists :directory_provider_id
      remove :runner_access_directory_managed
      remove :runner_access_mode
    end
  end

  defp access_check(prefix) do
    mode = "#{prefix}_access_mode"
    groups = "#{prefix}_scope_groups"
    runners = "#{prefix}_scope_runner_ids"

    """
    #{mode} IN ('none', 'all', 'restricted') AND (
      (#{mode} IN ('none', 'all') AND cardinality(#{groups}) = 0 AND cardinality(#{runners}) = 0)
      OR
      (#{mode} = 'restricted' AND cardinality(#{groups}) + cardinality(#{runners}) > 0)
    )
    """
  end

  defp install_compatibility_triggers do
    execute """
    CREATE FUNCTION account_memberships_default_runner_access()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.runner_access_mode IS NULL THEN
        NEW.runner_access_mode := CASE WHEN NEW.role = 'owner' THEN 'all' ELSE 'none' END;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER account_memberships_default_runner_access
    BEFORE INSERT ON account_memberships
    FOR EACH ROW EXECUTE FUNCTION account_memberships_default_runner_access()
    """

    execute """
    CREATE FUNCTION account_memberships_seed_runner_access()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.runner_access_mode = 'none' THEN
        INSERT INTO user_runner_scopes
          (id, membership_id, scope_type, scope_value, inserted_at)
        VALUES
          (gen_random_uuid(), NEW.id, 'runner', '#{@none_runner_id}', NOW())
        ON CONFLICT DO NOTHING;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER account_memberships_seed_runner_access
    AFTER INSERT ON account_memberships
    FOR EACH ROW EXECUTE FUNCTION account_memberships_seed_runner_access()
    """

    execute """
    CREATE FUNCTION user_runner_scopes_require_explicit_writer()
    RETURNS trigger AS $$
    BEGIN
      IF pg_trigger_depth() = 1 AND
         COALESCE(current_setting('emisar.runner_access_write', true), '') <> 'enabled' THEN
        RAISE EXCEPTION 'runner access must be written through the explicit aggregate'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP <> 'DELETE' AND NEW.scope_type = 'runner' AND
         NEW.scope_value <> '#{@none_runner_id}' AND NOT EXISTS (
           SELECT 1
           FROM account_memberships AS memberships
           JOIN runners ON runners.account_id = memberships.account_id
           WHERE memberships.id = NEW.membership_id
             AND runners.id = NEW.scope_value::uuid
             AND runners.deleted_at IS NULL
         ) THEN
        RAISE EXCEPTION 'runner scope must reference a live runner in the membership account'
          USING ERRCODE = 'foreign_key_violation',
                CONSTRAINT = 'user_runner_scopes_runner_account_fkey';
      END IF;

      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END;
    $$ LANGUAGE plpgsql
    """

    # During the brief mixed-revision drain, old instances may still read this
    # table but their direct scope edits are intentionally rejected. Availability
    # narrows rather than allowing an old writer to erase explicit none access.

    execute """
    CREATE TRIGGER user_runner_scopes_require_explicit_writer
    BEFORE INSERT OR UPDATE OR DELETE ON user_runner_scopes
    FOR EACH ROW EXECUTE FUNCTION user_runner_scopes_require_explicit_writer()
    """
  end
end
