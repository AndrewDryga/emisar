defmodule Emisar.Repo.Migrations.AddPackScopeToRunnerAccess do
  use Ecto.Migration

  def up do
    alter table(:account_memberships) do
      add :pack_access_mode, :string, null: false, default: "all"
      add :pack_scope_pack_ids, {:array, :string}, null: false, default: []
    end

    alter table(:sso_identity_providers) do
      add :default_pack_access_mode, :string, null: false, default: "all"
      add :default_pack_scope_pack_ids, {:array, :string}, null: false, default: []
    end

    alter table(:sso_directory_group_runner_access_mappings) do
      add :pack_access_mode, :string, null: false, default: "all"
      add :pack_scope_pack_ids, {:array, :string}, null: false, default: []
    end

    create constraint(:account_memberships, :account_memberships_pack_access_check,
             check: pack_access_check("runner", "pack")
           )

    create constraint(
             :sso_identity_providers,
             :sso_identity_providers_default_pack_access_check,
             check: pack_access_check("default_runner", "default_pack")
           )

    create constraint(
             :sso_directory_group_runner_access_mappings,
             :sso_directory_group_runner_access_mappings_pack_access_check,
             check: pack_access_check("runner", "pack")
           )
  end

  def down do
    drop constraint(
           :sso_directory_group_runner_access_mappings,
           :sso_directory_group_runner_access_mappings_pack_access_check
         )

    drop constraint(
           :sso_identity_providers,
           :sso_identity_providers_default_pack_access_check
         )

    drop constraint(:account_memberships, :account_memberships_pack_access_check)

    alter table(:sso_directory_group_runner_access_mappings) do
      remove :pack_scope_pack_ids
      remove :pack_access_mode
    end

    alter table(:sso_identity_providers) do
      remove :default_pack_scope_pack_ids
      remove :default_pack_access_mode
    end

    alter table(:account_memberships) do
      remove :pack_scope_pack_ids
      remove :pack_access_mode
    end
  end

  # The pack dimension narrows an existing runner grant, so it is only ever
  # `all` (no list) or `restricted` (a non-empty list) — and a grant reaching no
  # runner at all carries no pack restriction, which would be unreachable.
  defp pack_access_check(runner_prefix, pack_prefix) do
    runner_mode = "#{runner_prefix}_access_mode"
    mode = "#{pack_prefix}_access_mode"
    packs = "#{pack_prefix}_scope_pack_ids"

    """
    #{mode} IN ('all', 'restricted') AND (
      (#{mode} = 'all' AND cardinality(#{packs}) = 0)
      OR
      (#{mode} = 'restricted' AND cardinality(#{packs}) > 0)
    ) AND (#{runner_mode} <> 'none' OR #{mode} = 'all')
    """
  end
end
