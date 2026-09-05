defmodule Emisar.Release.Migrations do
  @moduledoc false

  @recoveries [
    {20_260_918_000_000, __MODULE__.CascadeKeys},
    {20_260_920_000_000, __MODULE__.RecoveryPredicates},
    {20_260_921_000_000, __MODULE__.KeysetOrder},
    {20_261_001_000_000, __MODULE__.ActiveIdentifiers},
    {20_261_009_000_000, __MODULE__.QuantitySync},
    {20_261_012_000_000, __MODULE__.QueryIndexes},
    {20_261_020_000_000, __MODULE__.AccountEmailDomain}
  ]

  def run(repo, source, opts \\ []) do
    # Existing migrations are immutable. Ecto owns both the already-applied
    # check and the version write; each replacement body runs only when pending.
    for {version, module} <- @recoveries do
      Ecto.Migrator.run(repo, source, :up, Keyword.put(opts, :to_exclusive, version))
      Ecto.Migrator.up(repo, version, module, opts)
    end

    Ecto.Migrator.run(repo, source, :up, Keyword.put(opts, :all, true))
  end

  defmodule CascadeKeys do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      for {table, column} <- [
            {"api_key_device_grants", "account_id"},
            {"approval_grants", "runner_id"},
            {"oauth_authz_codes", "account_id"},
            {"oauth_authz_codes", "api_key_id"},
            {"oauth_authz_codes", "client_id"},
            {"oauth_authz_codes", "membership_id"},
            {"oauth_tokens", "account_id"},
            {"oauth_tokens", "membership_id"},
            {"sso_directory_group_members", "account_id"},
            {"sso_directory_group_role_mappings", "account_id"}
          ] do
        IndexRecovery.ensure_index(repo(), prefix(), table, [column])
      end

      for {table, columns} <- [
            {"api_keys", ~w(account_id)},
            {"approval_grants", ~w(api_key_id action_id)},
            {"catalog_pack_versions", ~w(account_id pack_id)},
            {"catalog_runner_actions", ~w(account_id pack_id pack_version)},
            {"runbook_executions", ~w(runbook_id)},
            {"runner_tokens", ~w(runner_id)},
            {"sso_identity_providers", ~w(account_id)},
            {"user_runner_scopes", ~w(membership_id)}
          ] do
        IndexRecovery.drop_index(repo(), prefix(), table, columns)
      end
    end
  end

  defmodule RecoveryPredicates do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      IndexRecovery.replace_in_flight_index(repo(), prefix())

      IndexRecovery.ensure_index(repo(), prefix(), "runbook_execution_items", ~w(id),
        name: "runbook_execution_items_running_callback_idx",
        predicate: :running
      )

      IndexRecovery.ensure_index(repo(), prefix(), "runbook_executions", ~w(inserted_at id),
        name: "runbook_executions_unscrubbed_terminal_idx",
        predicate: :unscrubbed
      )
    end
  end

  defmodule KeysetOrder do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "action_runs",
        ["account_id", {"inserted_at", :desc}, "id"],
        name: "action_runs_account_keyset_idx"
      )

      IndexRecovery.drop_index(repo(), prefix(), "action_runs", ~w(account_id inserted_at))

      IndexRecovery.ensure_index(repo(), prefix(), "audit_events", ~w(account_id occurred_at id),
        name: "audit_events_account_keyset_idx"
      )

      IndexRecovery.drop_index(repo(), prefix(), "audit_events", ~w(account_id occurred_at))
    end
  end

  defmodule ActiveIdentifiers do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "sso_user_identities",
        ~w(account_id provider_id provider_identifier),
        name: "sso_user_identities_active_provider_identifier_index",
        unique: true,
        predicate: :active_identifier
      )

      IndexRecovery.drop_index(
        repo(),
        prefix(),
        "sso_user_identities",
        ~w(account_id provider_id provider_identifier),
        name: "sso_user_identities_provider_identifier_index",
        unique: true,
        predicate: :not_deleted
      )
    end
  end

  defmodule QuantitySync do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      IndexRecovery.ensure_quantity_sync_column(repo(), prefix())

      IndexRecovery.ensure_index(repo(), prefix(), "billing_subscriptions", ~w(id),
        name: "billing_subscriptions_runner_quantity_sync_queue_index",
        predicate: :quantity_sync
      )
    end
  end

  defmodule QueryIndexes do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      for table <-
            ~w(accounts users account_memberships runners runner_enrollment_keys api_keys policies runbooks) do
        IndexRecovery.drop_index(repo(), prefix(), table, ~w(deleted_at), predicate: :deleted)
      end

      IndexRecovery.drop_index(repo(), prefix(), "action_run_events", ~w(account_id inserted_at))

      IndexRecovery.drop_index(repo(), prefix(), "accounts", ~w(id),
        name: "accounts_paddle_customer_sync_idx",
        predicate: :customer_sync
      )

      IndexRecovery.drop_index(repo(), prefix(), "runbook_executions", ~w(account_id status),
        name: "runbook_executions_active_by_account_index",
        predicate: :active
      )

      IndexRecovery.drop_index(
        repo(),
        prefix(),
        "sso_directory_group_members",
        ~w(provider_id external_group_id user_identity_id),
        name: "sso_directory_group_members_membership_index",
        unique: true,
        predicate: :not_deleted
      )

      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "audit_events",
        ~w(account_id actor_kind actor_id),
        name: "audit_events_account_actor_idx"
      )

      IndexRecovery.drop_index(repo(), prefix(), "audit_events", ~w(actor_kind actor_id))

      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "audit_events",
        ~w(account_id target_kind target_id),
        name: "audit_events_account_target_idx"
      )

      IndexRecovery.drop_index(repo(), prefix(), "audit_events", ~w(target_kind target_id),
        name: "audit_events_subject_kind_subject_id_index"
      )

      IndexRecovery.ensure_index(repo(), prefix(), "oauth_tokens", ~w(access_expires_at),
        name: "oauth_tokens_expired_idx"
      )

      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "runbook_executions",
        ~w(account_id completed_at),
        name: "runbook_executions_retention_idx",
        predicate: :completed
      )

      IndexRecovery.ensure_index(repo(), prefix(), "action_runs", ~w(account_id finished_at),
        name: "action_runs_retention_idx",
        predicate: :finished
      )

      IndexRecovery.drop_index(repo(), prefix(), "action_runs", ~w(finished_at),
        name: "action_runs_finished_at_idx",
        predicate: :finished
      )

      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "runbook_executions",
        ["status", {"last_advanced_at", :asc_nulls_first}, "inserted_at", "id"],
        name: "runbook_executions_fair_recovery_idx",
        predicate: :active
      )

      IndexRecovery.drop_index(
        repo(),
        prefix(),
        "runbook_executions",
        ~w(status last_advanced_at inserted_at),
        name: "runbook_executions_fair_recovery_index",
        predicate: :active
      )

      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "approval_requests",
        ["account_id", {"requested_at", :desc}, "id"],
        name: "approval_requests_account_keyset_idx"
      )

      IndexRecovery.drop_index(repo(), prefix(), "approval_requests", ~w(account_id requested_at))

      for {table, column} <- [
            {"action_runs", "policy_id"},
            {"approval_decisions", "decider_id"},
            {"approval_grants", "granted_by_id"},
            {"approval_grants", "revoked_by_id"},
            {"approval_requests", "decided_by_id"},
            {"approval_requests", "requested_by_id"},
            {"auth_user_tokens", "user_identity_id"},
            {"runbook_execution_items", "policy_id"},
            {"runbook_execution_items", "runner_id"},
            {"runbook_executions", "requested_by_id"},
            {"runner_tokens", "issued_via_key_id"}
          ] do
        IndexRecovery.ensure_index(repo(), prefix(), table, [column])
      end
    end
  end

  defmodule AccountEmailDomain do
    use Ecto.Migration
    alias Emisar.Release.IndexRecovery

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      IndexRecovery.ensure_index(
        repo(),
        prefix(),
        "sso_identity_providers",
        ~w(account_id allowed_email_domain),
        name: "sso_identity_providers_account_email_domain_enabled_index",
        unique: true,
        predicate: :email_domain
      )

      IndexRecovery.drop_index(
        repo(),
        prefix(),
        "sso_identity_providers",
        ~w(allowed_email_domain),
        name: "sso_identity_providers_allowed_email_domain_enabled_index",
        unique: true,
        predicate: :email_domain
      )
    end
  end
end
