defmodule Emisar.Repo.Migrations.IndexCascadeKeysAndDropPrefixes do
  use Ecto.Migration

  # Built CONCURRENTLY: bin/migrate runs before an instance serves, so an
  # ordinary CREATE INDEX on a populated table holds a write lock for as long as
  # the build takes. Concurrent builds cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Two halves, both about indexes that should already have matched the queries.
  #
  # ADD: ten ON DELETE CASCADE foreign keys had no index leading with the key
  # column. Accounts.delete_by_id/1 is a real hard delete that relies on those
  # cascades, so erasing one account sequential-scanned each of these tables.
  # The asymmetry was visible: oauth_tokens indexes api_key_id and client_id but
  # not account_id or membership_id, and its sibling oauth_authz_codes indexes
  # none of its four.
  #
  # DROP: eight indexes are a strict prefix of a wider sibling added later, on
  # the same columns in the same order, none unique and none backing a
  # constraint. A B-tree already serves leading-column lookups, so each was pure
  # write amplification on every insert and update. 20260620000000 already made
  # exactly this trade for action_runs.runbook_id.
  def up do
    for {table, column} <- cascade_keys() do
      create index(table, [column], concurrently: true)
    end

    for name <- redundant_prefixes() do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end
  end

  def down do
    for name <- redundant_prefixes() do
      execute(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} ON #{prefix_table(name)} (#{prefix_columns(name)})"
      )
    end

    for {table, column} <- cascade_keys() do
      drop_if_exists index(table, [column], concurrently: true)
    end
  end

  defp cascade_keys do
    [
      {:api_key_device_grants, :account_id},
      {:approval_grants, :runner_id},
      {:oauth_authz_codes, :account_id},
      {:oauth_authz_codes, :api_key_id},
      {:oauth_authz_codes, :client_id},
      {:oauth_authz_codes, :membership_id},
      {:oauth_tokens, :account_id},
      {:oauth_tokens, :membership_id},
      {:sso_directory_group_members, :account_id},
      {:sso_directory_group_role_mappings, :account_id}
    ]
  end

  defp redundant_prefixes do
    [
      "api_keys_account_id_index",
      "approval_grants_api_key_id_action_id_index",
      "catalog_pack_versions_account_id_pack_id_index",
      "catalog_runner_actions_account_id_pack_id_pack_version_index",
      "runbook_executions_runbook_id_index",
      "runner_tokens_runner_id_index",
      "sso_identity_providers_account_id_index",
      "user_runner_scopes_membership_id_index"
    ]
  end

  defp prefix_table("api_keys_" <> _), do: "api_keys"
  defp prefix_table("approval_grants_" <> _), do: "approval_grants"
  defp prefix_table("catalog_pack_versions_" <> _), do: "catalog_pack_versions"
  defp prefix_table("catalog_runner_actions_" <> _), do: "catalog_runner_actions"
  defp prefix_table("runbook_executions_" <> _), do: "runbook_executions"
  defp prefix_table("runner_tokens_" <> _), do: "runner_tokens"
  defp prefix_table("sso_identity_providers_" <> _), do: "sso_identity_providers"
  defp prefix_table("user_runner_scopes_" <> _), do: "user_runner_scopes"

  defp prefix_columns("api_keys_account_id_index"), do: "account_id"
  defp prefix_columns("approval_grants_api_key_id_action_id_index"), do: "api_key_id, action_id"
  defp prefix_columns("catalog_pack_versions_account_id_pack_id_index"), do: "account_id, pack_id"

  defp prefix_columns("catalog_runner_actions_account_id_pack_id_pack_version_index"),
    do: "account_id, pack_id, pack_version"

  defp prefix_columns("runbook_executions_runbook_id_index"), do: "runbook_id"
  defp prefix_columns("runner_tokens_runner_id_index"), do: "runner_id"
  defp prefix_columns("sso_identity_providers_account_id_index"), do: "account_id"
  defp prefix_columns("user_runner_scopes_membership_id_index"), do: "membership_id"
end
