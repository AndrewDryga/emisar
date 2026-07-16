defmodule Emisar.Repo.Migrations.RenameTablesToOwningContext do
  use Ecto.Migration

  # Tables are named after the context that owns them (accounts, sso, catalog,
  # auth, billing). Postgres does not rename a table's constraints or indexes
  # on table rename, but Ecto infers constraint names from the table name, so
  # every one is renamed to the new prefix here — otherwise a unique violation
  # would raise instead of returning an error changeset. Ships in a
  # maintenance window: old code queries old names, so no rolling deploy.

  def up do
    rename table(:memberships), to: table(:account_memberships)

    execute "ALTER TABLE account_memberships RENAME CONSTRAINT memberships_account_id_fkey TO account_memberships_account_id_fkey"

    execute "ALTER TABLE account_memberships RENAME CONSTRAINT memberships_invited_by_id_fkey TO account_memberships_invited_by_id_fkey"

    execute "ALTER TABLE account_memberships RENAME CONSTRAINT memberships_user_id_fkey TO account_memberships_user_id_fkey"

    execute "ALTER TABLE account_memberships RENAME CONSTRAINT memberships_pkey TO account_memberships_pkey"

    execute "ALTER INDEX memberships_account_id_user_id_index RENAME TO account_memberships_account_id_user_id_index"

    execute "ALTER INDEX memberships_active_owner_contact_idx RENAME TO account_memberships_active_owner_contact_idx"

    execute "ALTER INDEX memberships_deleted_at_index RENAME TO account_memberships_deleted_at_index"

    execute "ALTER INDEX memberships_disabled_at_index RENAME TO account_memberships_disabled_at_index"

    execute "ALTER INDEX memberships_invitation_token_index RENAME TO account_memberships_invitation_token_index"

    execute "ALTER INDEX memberships_user_id_index RENAME TO account_memberships_user_id_index"

    rename table(:identity_providers), to: table(:sso_identity_providers)

    execute "ALTER TABLE sso_identity_providers RENAME CONSTRAINT identity_providers_account_id_fkey TO sso_identity_providers_account_id_fkey"

    execute "ALTER TABLE sso_identity_providers RENAME CONSTRAINT identity_providers_pkey TO sso_identity_providers_pkey"

    execute "ALTER INDEX identity_providers_account_id_index RENAME TO sso_identity_providers_account_id_index"

    execute "ALTER INDEX identity_providers_account_kind_enabled_index RENAME TO sso_identity_providers_account_kind_enabled_index"

    execute "ALTER INDEX identity_providers_allowed_email_domain_enabled_index RENAME TO sso_identity_providers_allowed_email_domain_enabled_index"

    execute "ALTER INDEX identity_providers_scim_token_prefix_index RENAME TO sso_identity_providers_scim_token_prefix_index"

    rename table(:user_identities), to: table(:sso_user_identities)

    execute "ALTER TABLE sso_user_identities RENAME CONSTRAINT user_identities_account_id_fkey TO sso_user_identities_account_id_fkey"

    execute "ALTER TABLE sso_user_identities RENAME CONSTRAINT user_identities_provider_id_fkey TO sso_user_identities_provider_id_fkey"

    execute "ALTER TABLE sso_user_identities RENAME CONSTRAINT user_identities_user_id_fkey TO sso_user_identities_user_id_fkey"

    execute "ALTER TABLE sso_user_identities RENAME CONSTRAINT user_identities_pkey TO sso_user_identities_pkey"

    execute "ALTER INDEX user_identities_provider_id_index RENAME TO sso_user_identities_provider_id_index"

    execute "ALTER INDEX user_identities_provider_identifier_index RENAME TO sso_user_identities_provider_identifier_index"

    execute "ALTER INDEX user_identities_scim_external_id_index RENAME TO sso_user_identities_scim_external_id_index"

    execute "ALTER INDEX user_identities_user_id_index RENAME TO sso_user_identities_user_id_index"

    rename table(:directory_group_members), to: table(:sso_directory_group_members)

    execute "ALTER TABLE sso_directory_group_members RENAME CONSTRAINT directory_group_members_account_id_fkey TO sso_directory_group_members_account_id_fkey"

    execute "ALTER TABLE sso_directory_group_members RENAME CONSTRAINT directory_group_members_provider_id_fkey TO sso_directory_group_members_provider_id_fkey"

    execute "ALTER TABLE sso_directory_group_members RENAME CONSTRAINT directory_group_members_user_identity_id_fkey TO sso_directory_group_members_user_identity_id_fkey"

    execute "ALTER TABLE sso_directory_group_members RENAME CONSTRAINT directory_group_members_pkey TO sso_directory_group_members_pkey"

    execute "ALTER INDEX directory_group_members_membership_index RENAME TO sso_directory_group_members_membership_index"

    execute "ALTER INDEX directory_group_members_provider_id_external_group_id_index RENAME TO sso_directory_group_members_provider_id_external_group_id_index"

    execute "ALTER INDEX directory_group_members_user_identity_id_index RENAME TO sso_directory_group_members_user_identity_id_index"

    rename table(:directory_group_role_mappings), to: table(:sso_directory_group_role_mappings)

    execute "ALTER TABLE sso_directory_group_role_mappings RENAME CONSTRAINT directory_group_role_mappings_account_id_fkey TO sso_directory_group_role_mappings_account_id_fkey"

    execute "ALTER TABLE sso_directory_group_role_mappings RENAME CONSTRAINT directory_group_role_mappings_provider_id_fkey TO sso_directory_group_role_mappings_provider_id_fkey"

    execute "ALTER TABLE sso_directory_group_role_mappings RENAME CONSTRAINT directory_group_role_mappings_pkey TO sso_directory_group_role_mappings_pkey"

    execute "ALTER INDEX directory_group_role_mappings_provider_group_index RENAME TO sso_directory_group_role_mappings_provider_group_index"

    rename table(:runner_actions), to: table(:catalog_runner_actions)

    execute "ALTER TABLE catalog_runner_actions RENAME CONSTRAINT runner_actions_account_id_fkey TO catalog_runner_actions_account_id_fkey"

    execute "ALTER TABLE catalog_runner_actions RENAME CONSTRAINT runner_actions_runner_id_fkey TO catalog_runner_actions_runner_id_fkey"

    execute "ALTER TABLE catalog_runner_actions RENAME CONSTRAINT runner_actions_pkey TO catalog_runner_actions_pkey"

    execute "ALTER INDEX runner_actions_account_id_action_id_index RENAME TO catalog_runner_actions_account_id_action_id_index"

    execute "ALTER INDEX runner_actions_account_id_pack_id_pack_version_index RENAME TO catalog_runner_actions_account_id_pack_id_pack_version_index"

    execute "ALTER INDEX runner_actions_account_id_pack_id_pack_version_pack_hash_index RENAME TO catalog_runner_actions_account_id_pack_id_pack_version_pack_hash_index"

    execute "ALTER INDEX runner_actions_account_id_risk_index RENAME TO catalog_runner_actions_account_id_risk_index"

    execute "ALTER INDEX runner_actions_runner_id_action_id_index RENAME TO catalog_runner_actions_runner_id_action_id_index"

    rename table(:pack_versions), to: table(:catalog_pack_versions)

    execute "ALTER TABLE catalog_pack_versions RENAME CONSTRAINT pack_versions_account_id_fkey TO catalog_pack_versions_account_id_fkey"

    execute "ALTER TABLE catalog_pack_versions RENAME CONSTRAINT pack_versions_retirement_overridden_by_id_fkey TO catalog_pack_versions_retirement_overridden_by_id_fkey"

    execute "ALTER TABLE catalog_pack_versions RENAME CONSTRAINT pack_versions_pkey TO catalog_pack_versions_pkey"

    execute "ALTER INDEX pack_versions_account_id_pack_id_index RENAME TO catalog_pack_versions_account_id_pack_id_index"

    execute "ALTER INDEX pack_versions_account_id_pack_id_version_index RENAME TO catalog_pack_versions_account_id_pack_id_version_index"

    rename table(:user_tokens), to: table(:auth_user_tokens)

    execute "ALTER TABLE auth_user_tokens RENAME CONSTRAINT user_tokens_user_id_fkey TO auth_user_tokens_user_id_fkey"

    execute "ALTER TABLE auth_user_tokens RENAME CONSTRAINT user_tokens_user_identity_id_fkey TO auth_user_tokens_user_identity_id_fkey"

    execute "ALTER TABLE auth_user_tokens RENAME CONSTRAINT user_tokens_pkey TO auth_user_tokens_pkey"

    execute "ALTER INDEX user_tokens_context_token_index RENAME TO auth_user_tokens_context_token_index"

    execute "ALTER INDEX user_tokens_user_id_context_index RENAME TO auth_user_tokens_user_id_context_index"

    rename table(:subscriptions), to: table(:billing_subscriptions)

    execute "ALTER TABLE billing_subscriptions RENAME CONSTRAINT subscriptions_account_id_fkey TO billing_subscriptions_account_id_fkey"

    execute "ALTER TABLE billing_subscriptions RENAME CONSTRAINT subscriptions_pkey TO billing_subscriptions_pkey"

    execute "ALTER INDEX subscriptions_account_id_index RENAME TO billing_subscriptions_account_id_index"

    execute "ALTER INDEX subscriptions_paddle_subscription_id_idx RENAME TO billing_subscriptions_paddle_subscription_id_idx"
  end

  def down do
    rename table(:account_memberships), to: table(:memberships)

    execute "ALTER TABLE memberships RENAME CONSTRAINT account_memberships_account_id_fkey TO memberships_account_id_fkey"

    execute "ALTER TABLE memberships RENAME CONSTRAINT account_memberships_invited_by_id_fkey TO memberships_invited_by_id_fkey"

    execute "ALTER TABLE memberships RENAME CONSTRAINT account_memberships_user_id_fkey TO memberships_user_id_fkey"

    execute "ALTER TABLE memberships RENAME CONSTRAINT account_memberships_pkey TO memberships_pkey"

    execute "ALTER INDEX account_memberships_account_id_user_id_index RENAME TO memberships_account_id_user_id_index"

    execute "ALTER INDEX account_memberships_active_owner_contact_idx RENAME TO memberships_active_owner_contact_idx"

    execute "ALTER INDEX account_memberships_deleted_at_index RENAME TO memberships_deleted_at_index"

    execute "ALTER INDEX account_memberships_disabled_at_index RENAME TO memberships_disabled_at_index"

    execute "ALTER INDEX account_memberships_invitation_token_index RENAME TO memberships_invitation_token_index"

    execute "ALTER INDEX account_memberships_user_id_index RENAME TO memberships_user_id_index"

    rename table(:sso_identity_providers), to: table(:identity_providers)

    execute "ALTER TABLE identity_providers RENAME CONSTRAINT sso_identity_providers_account_id_fkey TO identity_providers_account_id_fkey"

    execute "ALTER TABLE identity_providers RENAME CONSTRAINT sso_identity_providers_pkey TO identity_providers_pkey"

    execute "ALTER INDEX sso_identity_providers_account_id_index RENAME TO identity_providers_account_id_index"

    execute "ALTER INDEX sso_identity_providers_account_kind_enabled_index RENAME TO identity_providers_account_kind_enabled_index"

    execute "ALTER INDEX sso_identity_providers_allowed_email_domain_enabled_index RENAME TO identity_providers_allowed_email_domain_enabled_index"

    execute "ALTER INDEX sso_identity_providers_scim_token_prefix_index RENAME TO identity_providers_scim_token_prefix_index"

    rename table(:sso_user_identities), to: table(:user_identities)

    execute "ALTER TABLE user_identities RENAME CONSTRAINT sso_user_identities_account_id_fkey TO user_identities_account_id_fkey"

    execute "ALTER TABLE user_identities RENAME CONSTRAINT sso_user_identities_provider_id_fkey TO user_identities_provider_id_fkey"

    execute "ALTER TABLE user_identities RENAME CONSTRAINT sso_user_identities_user_id_fkey TO user_identities_user_id_fkey"

    execute "ALTER TABLE user_identities RENAME CONSTRAINT sso_user_identities_pkey TO user_identities_pkey"

    execute "ALTER INDEX sso_user_identities_provider_id_index RENAME TO user_identities_provider_id_index"

    execute "ALTER INDEX sso_user_identities_provider_identifier_index RENAME TO user_identities_provider_identifier_index"

    execute "ALTER INDEX sso_user_identities_scim_external_id_index RENAME TO user_identities_scim_external_id_index"

    execute "ALTER INDEX sso_user_identities_user_id_index RENAME TO user_identities_user_id_index"

    rename table(:sso_directory_group_members), to: table(:directory_group_members)

    execute "ALTER TABLE directory_group_members RENAME CONSTRAINT sso_directory_group_members_account_id_fkey TO directory_group_members_account_id_fkey"

    execute "ALTER TABLE directory_group_members RENAME CONSTRAINT sso_directory_group_members_provider_id_fkey TO directory_group_members_provider_id_fkey"

    execute "ALTER TABLE directory_group_members RENAME CONSTRAINT sso_directory_group_members_user_identity_id_fkey TO directory_group_members_user_identity_id_fkey"

    execute "ALTER TABLE directory_group_members RENAME CONSTRAINT sso_directory_group_members_pkey TO directory_group_members_pkey"

    execute "ALTER INDEX sso_directory_group_members_membership_index RENAME TO directory_group_members_membership_index"

    execute "ALTER INDEX sso_directory_group_members_provider_id_external_group_id_index RENAME TO directory_group_members_provider_id_external_group_id_index"

    execute "ALTER INDEX sso_directory_group_members_user_identity_id_index RENAME TO directory_group_members_user_identity_id_index"

    rename table(:sso_directory_group_role_mappings), to: table(:directory_group_role_mappings)

    execute "ALTER TABLE directory_group_role_mappings RENAME CONSTRAINT sso_directory_group_role_mappings_account_id_fkey TO directory_group_role_mappings_account_id_fkey"

    execute "ALTER TABLE directory_group_role_mappings RENAME CONSTRAINT sso_directory_group_role_mappings_provider_id_fkey TO directory_group_role_mappings_provider_id_fkey"

    execute "ALTER TABLE directory_group_role_mappings RENAME CONSTRAINT sso_directory_group_role_mappings_pkey TO directory_group_role_mappings_pkey"

    execute "ALTER INDEX sso_directory_group_role_mappings_provider_group_index RENAME TO directory_group_role_mappings_provider_group_index"

    rename table(:catalog_runner_actions), to: table(:runner_actions)

    execute "ALTER TABLE runner_actions RENAME CONSTRAINT catalog_runner_actions_account_id_fkey TO runner_actions_account_id_fkey"

    execute "ALTER TABLE runner_actions RENAME CONSTRAINT catalog_runner_actions_runner_id_fkey TO runner_actions_runner_id_fkey"

    execute "ALTER TABLE runner_actions RENAME CONSTRAINT catalog_runner_actions_pkey TO runner_actions_pkey"

    execute "ALTER INDEX catalog_runner_actions_account_id_action_id_index RENAME TO runner_actions_account_id_action_id_index"

    execute "ALTER INDEX catalog_runner_actions_account_id_pack_id_pack_version_index RENAME TO runner_actions_account_id_pack_id_pack_version_index"

    execute "ALTER INDEX catalog_runner_actions_account_id_pack_id_pack_version_pack_hash_index RENAME TO runner_actions_account_id_pack_id_pack_version_pack_hash_index"

    execute "ALTER INDEX catalog_runner_actions_account_id_risk_index RENAME TO runner_actions_account_id_risk_index"

    execute "ALTER INDEX catalog_runner_actions_runner_id_action_id_index RENAME TO runner_actions_runner_id_action_id_index"

    rename table(:catalog_pack_versions), to: table(:pack_versions)

    execute "ALTER TABLE pack_versions RENAME CONSTRAINT catalog_pack_versions_account_id_fkey TO pack_versions_account_id_fkey"

    execute "ALTER TABLE pack_versions RENAME CONSTRAINT catalog_pack_versions_retirement_overridden_by_id_fkey TO pack_versions_retirement_overridden_by_id_fkey"

    execute "ALTER TABLE pack_versions RENAME CONSTRAINT catalog_pack_versions_pkey TO pack_versions_pkey"

    execute "ALTER INDEX catalog_pack_versions_account_id_pack_id_index RENAME TO pack_versions_account_id_pack_id_index"

    execute "ALTER INDEX catalog_pack_versions_account_id_pack_id_version_index RENAME TO pack_versions_account_id_pack_id_version_index"

    rename table(:auth_user_tokens), to: table(:user_tokens)

    execute "ALTER TABLE user_tokens RENAME CONSTRAINT auth_user_tokens_user_id_fkey TO user_tokens_user_id_fkey"

    execute "ALTER TABLE user_tokens RENAME CONSTRAINT auth_user_tokens_user_identity_id_fkey TO user_tokens_user_identity_id_fkey"

    execute "ALTER TABLE user_tokens RENAME CONSTRAINT auth_user_tokens_pkey TO user_tokens_pkey"

    execute "ALTER INDEX auth_user_tokens_context_token_index RENAME TO user_tokens_context_token_index"

    execute "ALTER INDEX auth_user_tokens_user_id_context_index RENAME TO user_tokens_user_id_context_index"

    rename table(:billing_subscriptions), to: table(:subscriptions)

    execute "ALTER TABLE subscriptions RENAME CONSTRAINT billing_subscriptions_account_id_fkey TO subscriptions_account_id_fkey"

    execute "ALTER TABLE subscriptions RENAME CONSTRAINT billing_subscriptions_pkey TO subscriptions_pkey"

    execute "ALTER INDEX billing_subscriptions_account_id_index RENAME TO subscriptions_account_id_index"

    execute "ALTER INDEX billing_subscriptions_paddle_subscription_id_idx RENAME TO subscriptions_paddle_subscription_id_idx"
  end
end
