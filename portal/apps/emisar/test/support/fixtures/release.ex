defmodule Emisar.Fixtures.Release do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.Repo

  @tables [
    {"api_key_device_grants", ~w(account_id)},
    {"approval_grants", ~w(runner_id api_key_id action_id granted_by_id revoked_by_id)},
    {"oauth_authz_codes", ~w(account_id api_key_id client_id membership_id)},
    {"oauth_tokens", ~w(account_id membership_id access_expires_at)},
    {"sso_directory_group_members",
     ~w(account_id provider_id external_group_id user_identity_id deleted_at)},
    {"sso_directory_group_role_mappings", ~w(account_id)},
    {"api_keys", ~w(account_id deleted_at)},
    {"catalog_pack_versions", ~w(account_id pack_id)},
    {"catalog_runner_actions", ~w(account_id pack_id pack_version)},
    {"runbook_executions",
     ~w(id runbook_id account_id status inserted_at inputs_raw completed_at last_advanced_at requested_by_id)},
    {"runner_tokens", ~w(runner_id issued_via_key_id)},
    {"sso_identity_providers", ~w(account_id allowed_email_domain enabled deleted_at)},
    {"user_runner_scopes", ~w(membership_id)},
    {"action_runs", ~w(id account_id status queued_at inserted_at finished_at policy_id)},
    {"runbook_execution_items", ~w(id status policy_id runner_id)},
    {"audit_events", ~w(account_id occurred_at id actor_kind actor_id target_kind target_id)},
    {"sso_user_identities",
     ~w(account_id provider_id provider_identifier deleted_at provider_identifier_retired_at)},
    {"billing_subscriptions", ~w(id)},
    {"accounts",
     ~w(id deleted_at paddle_customer_id paddle_billing_contact_user_id paddle_customer_synced_at updated_at)},
    {"users", ~w(deleted_at)},
    {"account_memberships", ~w(deleted_at)},
    {"runners", ~w(deleted_at)},
    {"runner_enrollment_keys", ~w(deleted_at)},
    {"policies", ~w(deleted_at)},
    {"runbooks", ~w(deleted_at)},
    {"action_run_events", ~w(account_id inserted_at)},
    {"approval_requests", ~w(account_id requested_at id decided_by_id requested_by_id)},
    {"approval_decisions", ~w(decider_id)},
    {"auth_user_tokens", ~w(user_identity_id)}
  ]

  def with_schema(fun) do
    Sandbox.unboxed_run(Repo, fn -> isolated_schema(fun) end)
  end

  def isolated_schema(fun) do
    schema = "index_recovery_#{System.unique_integer([:positive])}"
    sql("CREATE SCHEMA #{quote_name(schema)}")

    try do
      fun.(schema)
    after
      sql("DROP SCHEMA #{quote_name(schema)} CASCADE")
    end
  end

  def with_migration_repo(fun, pool_size \\ 3) do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, pool_size)

    {:ok, pid} = __MODULE__.MigrationRepo.start_link(config)
    schema = "index_recovery_#{System.unique_integer([:positive])}"
    sql("CREATE SCHEMA #{quote_name(schema)}", [], __MODULE__.MigrationRepo)

    try do
      fun.(schema, __MODULE__.MigrationRepo)
    after
      sql("DROP SCHEMA #{quote_name(schema)} CASCADE", [], __MODULE__.MigrationRepo)
      Supervisor.stop(pid)
    end
  end

  def create_tables(schema, repo \\ Repo) do
    for {table, columns} <- @tables do
      columns = Enum.map_join(columns, ", ", &(quote_name(&1) <> " " <> type(&1)))
      sql("CREATE TABLE #{qualified(schema, table)} (#{columns})", [], repo)
    end
  end

  def prepare(schema, version, prefix_length \\ 0) do
    create_tables(schema)

    for {:drop, index} <- steps(version), do: create_index(schema, index)
    for operation <- Enum.take(steps(version), prefix_length), do: apply_step(schema, operation)
  end

  def baseline(schema, repo) do
    create_tables(schema, repo)

    for version <- versions(), {:drop, index} <- steps(version) do
      sql(create_sql(schema, index), [], repo)
    end
  end

  def versions do
    [
      20_260_918_000_000,
      20_260_920_000_000,
      20_260_921_000_000,
      20_261_001_000_000,
      20_261_009_000_000,
      20_261_012_000_000,
      20_261_020_000_000
    ]
  end

  def migration(20_260_918_000_000), do: Emisar.Release.Migrations.CascadeKeys
  def migration(20_260_920_000_000), do: Emisar.Release.Migrations.RecoveryPredicates
  def migration(20_260_921_000_000), do: Emisar.Release.Migrations.KeysetOrder
  def migration(20_261_001_000_000), do: Emisar.Release.Migrations.ActiveIdentifiers
  def migration(20_261_009_000_000), do: Emisar.Release.Migrations.QuantitySync
  def migration(20_261_012_000_000), do: Emisar.Release.Migrations.QueryIndexes
  def migration(20_261_020_000_000), do: Emisar.Release.Migrations.AccountEmailDomain

  def migrate(schema, version) do
    Ecto.Migrator.up(Repo, version, migration(version), prefix: schema)
  end

  def steps(20_260_918_000_000) do
    creates =
      for {table, columns} <- [
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
          ],
          do: {:create, definition(table, columns)}

    drops =
      for {table, columns} <- [
            {"api_keys", "account_id"},
            {"approval_grants", "api_key_id, action_id"},
            {"catalog_pack_versions", "account_id, pack_id"},
            {"catalog_runner_actions", "account_id, pack_id, pack_version"},
            {"runbook_executions", "runbook_id"},
            {"runner_tokens", "runner_id"},
            {"sso_identity_providers", "account_id"},
            {"user_runner_scopes", "membership_id"}
          ],
          do: {:drop, definition(table, columns)}

    creates ++ drops
  end

  def steps(20_260_920_000_000) do
    [
      {:drop,
       definition(
         "action_runs",
         "status, queued_at",
         "action_runs_in_flight_idx",
         "status IN ('pending', 'sent', 'running')"
       )},
      {:create,
       definition(
         "action_runs",
         "status, queued_at",
         "action_runs_in_flight_idx",
         "status IN ('pending', 'sent', 'running', 'cancelling')"
       )},
      {:create,
       definition(
         "runbook_execution_items",
         "id",
         "runbook_execution_items_running_callback_idx",
         "status = 'running'"
       )},
      {:create,
       definition(
         "runbook_executions",
         "inserted_at, id",
         "runbook_executions_unscrubbed_terminal_idx",
         "status IN ('succeeded', 'halted', 'cancelled') AND inputs_raw IS NOT NULL"
       )}
    ]
  end

  def steps(20_260_921_000_000) do
    [
      {:create,
       definition(
         "action_runs",
         "account_id, inserted_at DESC, id ASC",
         "action_runs_account_keyset_idx"
       )},
      {:drop, definition("action_runs", "account_id, inserted_at")},
      {:create,
       definition(
         "audit_events",
         "account_id, occurred_at, id",
         "audit_events_account_keyset_idx"
       )},
      {:drop, definition("audit_events", "account_id, occurred_at")}
    ]
  end

  def steps(20_261_001_000_000) do
    [
      {:create,
       definition(
         "sso_user_identities",
         "account_id, provider_id, provider_identifier",
         "sso_user_identities_active_provider_identifier_index",
         "deleted_at IS NULL AND provider_identifier_retired_at IS NULL",
         true
       )},
      {:drop,
       definition(
         "sso_user_identities",
         "account_id, provider_id, provider_identifier",
         "sso_user_identities_provider_identifier_index",
         "deleted_at IS NULL",
         true
       )}
    ]
  end

  def steps(20_261_009_000_000) do
    [
      :quantity_column,
      {:create,
       definition(
         "billing_subscriptions",
         "id",
         "billing_subscriptions_runner_quantity_sync_queue_index",
         "runner_quantity_sync_requested_at IS NOT NULL"
       )}
    ]
  end

  def steps(20_261_012_000_000) do
    drops =
      for table <-
            ~w(accounts users account_memberships runners runner_enrollment_keys api_keys policies runbooks),
          do: {:drop, definition(table, "deleted_at", nil, "deleted_at IS NOT NULL")}

    middle = [
      {:drop, definition("action_run_events", "account_id, inserted_at")},
      {:drop,
       definition(
         "accounts",
         "id",
         "accounts_paddle_customer_sync_idx",
         "deleted_at IS NULL AND (paddle_customer_id IS NULL OR paddle_billing_contact_user_id IS NULL OR paddle_customer_synced_at IS NULL OR updated_at > paddle_customer_synced_at)"
       )},
      {:drop,
       definition(
         "runbook_executions",
         "account_id, status",
         "runbook_executions_active_by_account_index",
         "status = 'active'"
       )},
      {:drop,
       definition(
         "sso_directory_group_members",
         "provider_id, external_group_id, user_identity_id",
         "sso_directory_group_members_membership_index",
         "deleted_at IS NULL",
         true
       )},
      {:create,
       definition(
         "audit_events",
         "account_id, actor_kind, actor_id",
         "audit_events_account_actor_idx"
       )},
      {:drop, definition("audit_events", "actor_kind, actor_id")},
      {:create,
       definition(
         "audit_events",
         "account_id, target_kind, target_id",
         "audit_events_account_target_idx"
       )},
      {:drop,
       definition(
         "audit_events",
         "target_kind, target_id",
         "audit_events_subject_kind_subject_id_index"
       )},
      {:create, definition("oauth_tokens", "access_expires_at", "oauth_tokens_expired_idx")},
      {:create,
       definition(
         "runbook_executions",
         "account_id, completed_at",
         "runbook_executions_retention_idx",
         "completed_at IS NOT NULL"
       )},
      {:create,
       definition(
         "action_runs",
         "account_id, finished_at",
         "action_runs_retention_idx",
         "finished_at IS NOT NULL"
       )},
      {:drop,
       definition(
         "action_runs",
         "finished_at",
         "action_runs_finished_at_idx",
         "finished_at IS NOT NULL"
       )},
      {:create,
       definition(
         "runbook_executions",
         "status, last_advanced_at ASC NULLS FIRST, inserted_at, id",
         "runbook_executions_fair_recovery_idx",
         "status = 'active'"
       )},
      {:drop,
       definition(
         "runbook_executions",
         "status, last_advanced_at, inserted_at",
         "runbook_executions_fair_recovery_index",
         "status = 'active'"
       )},
      {:create,
       definition(
         "approval_requests",
         "account_id, requested_at DESC, id ASC",
         "approval_requests_account_keyset_idx"
       )},
      {:drop, definition("approval_requests", "account_id, requested_at")}
    ]

    creates =
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
          ],
          do: {:create, definition(table, column)}

    drops ++ middle ++ creates
  end

  def steps(20_261_020_000_000) do
    [
      {:create,
       definition(
         "sso_identity_providers",
         "account_id, allowed_email_domain",
         "sso_identity_providers_account_email_domain_enabled_index",
         "enabled AND deleted_at IS NULL AND allowed_email_domain IS NOT NULL",
         true
       )},
      {:drop,
       definition(
         "sso_identity_providers",
         "allowed_email_domain",
         "sso_identity_providers_allowed_email_domain_enabled_index",
         "enabled AND deleted_at IS NULL AND allowed_email_domain IS NOT NULL",
         true
       )}
    ]
  end

  def definition(table, columns, name \\ nil, predicate \\ nil, unique \\ false) do
    name = name || table <> "_" <> String.replace(columns, ", ", "_") <> "_index"
    %{table: table, columns: columns, name: name, predicate: predicate, unique: unique}
  end

  def apply_step(schema, {:create, index}), do: create_index(schema, index)
  def apply_step(schema, {:drop, index}), do: sql("DROP INDEX #{qualified(schema, index.name)}")

  def apply_step(schema, :quantity_column) do
    sql(
      "ALTER TABLE #{qualified(schema, "billing_subscriptions")} ADD COLUMN runner_quantity_sync_requested_at timestamp"
    )
  end

  def create_index(schema, index), do: sql(create_sql(schema, index))

  def create_sql(schema, index, concurrent \\ false) do
    unique = if index.unique, do: "UNIQUE ", else: ""
    concurrently = if concurrent, do: "CONCURRENTLY ", else: ""
    predicate = if index.predicate, do: " WHERE " <> index.predicate, else: ""

    "CREATE #{unique}INDEX #{concurrently}#{quote_name(index.name)} ON #{qualified(schema, index.table)} (#{index.columns})#{predicate}"
  end

  def index(schema, name, repo \\ Repo) do
    query = """
    SELECT c.oid::bigint, i.indisvalid, i.indisready, i.indislive,
      pg_catalog.pg_get_expr(i.indpred, i.indrelid, false)
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
    WHERE n.nspname = $1 AND c.relname = $2
    """

    case sql(query, [schema, name], repo).rows do
      [[oid, valid, ready, live, predicate]] ->
        %{oid: oid, valid: valid, ready: ready, live: live, predicate: predicate}

      [] ->
        nil
    end
  end

  def migrated_versions(schema), do: Ecto.Migrator.migrated_versions(Repo, prefix: schema)

  def duplicate_identifiers(schema) do
    table = qualified(schema, "sso_user_identities")

    sql(
      "INSERT INTO #{table} (account_id, provider_id, provider_identifier) SELECT '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'subject' FROM generate_series(1, 2)"
    )
  end

  def remove_duplicate_identifier(schema) do
    table = qualified(schema, "sso_user_identities")
    sql("DELETE FROM #{table} WHERE ctid = (SELECT ctid FROM #{table} LIMIT 1)")
  end

  def duplicate_domains(schema) do
    table = qualified(schema, "sso_identity_providers")

    sql(
      "INSERT INTO #{table} (account_id, allowed_email_domain, enabled) SELECT '00000000-0000-0000-0000-000000000001', 'example.com', true FROM generate_series(1, 2)"
    )
  end

  def remove_duplicate_domain(schema) do
    table = qualified(schema, "sso_identity_providers")
    sql("DELETE FROM #{table} WHERE ctid = (SELECT ctid FROM #{table} LIMIT 1)")
  end

  def interrupt_index_build(schema, definition, repo, stage \\ :build) do
    parent = self()

    holder =
      Task.async(fn ->
        repo.transaction(fn ->
          if stage == :build do
            sql(
              "LOCK TABLE #{qualified(schema, definition.table)} IN ROW EXCLUSIVE MODE",
              [],
              repo
            )
          else
            sql("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [], repo)
            sql("SELECT * FROM #{qualified(schema, definition.table)} LIMIT 1", [], repo)
          end

          send(parent, :writer_locked)

          receive do
            :release_writer -> :ok
          after
            10_000 -> raise "writer fixture was not released"
          end
        end)
      end)

    receive do
      :writer_locked -> :ok
    after
      5_000 -> raise "writer fixture did not acquire its lock"
    end

    builder =
      Task.async(fn ->
        repo.checkout(fn ->
          [[pid]] = sql("SELECT pg_backend_pid()", [], repo).rows
          send(parent, {:builder_backend, pid})

          try do
            sql(create_sql(schema, definition, true), [], repo)
          rescue
            error in Postgrex.Error -> {:error, error}
          end
        end)
      end)

    try do
      receive do
        {:builder_backend, pid} ->
          await_catalog_index(
            schema,
            definition.name,
            repo,
            stage,
            System.monotonic_time(:millisecond) + 5_000
          )

          sql("SELECT pg_cancel_backend($1)", [pid], repo)
      after
        5_000 -> raise "builder fixture did not start"
      end

      Task.await(builder, 5_000)
    after
      send(holder.pid, :release_writer)
      Task.await(holder, 5_000)
    end
  end

  defp await_catalog_index(schema, name, repo, stage, deadline) do
    case index(schema, name, repo) do
      %{valid: false, ready: ready} when stage == :build or ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: raise("concurrent index did not enter the catalog")

        await_catalog_index(schema, name, repo, stage, deadline)
    end
  end

  def interrupt_index_drop(schema, definition, repo) do
    {first, first_backend} = start_reader(schema, definition.table, repo)
    parent = self()

    dropper =
      Task.async(fn ->
        repo.checkout(fn ->
          [[pid]] = sql("SELECT pg_backend_pid()", [], repo).rows
          send(parent, {:dropper_backend, pid})

          try do
            sql("DROP INDEX CONCURRENTLY #{qualified(schema, definition.name)}", [], repo)
          rescue
            error in Postgrex.Error -> {:error, error}
          end
        end)
      end)

    backend =
      receive do
        {:dropper_backend, pid} -> pid
      after
        5_000 -> raise "dropper did not start"
      end

    try do
      await(fn ->
        sql("SELECT $1 = ANY(pg_blocking_pids($2))", [first_backend, backend], repo).rows == [
          [true]
        ]
      end)

      {second, _backend} = start_reader(schema, definition.table, repo)

      try do
        send(first.pid, :release_reader)

        await(fn ->
          match?(%{valid: false, ready: false, live: false}, index(schema, definition.name, repo))
        end)

        sql("SELECT pg_cancel_backend($1)", [backend], repo)
        Task.await(dropper, 5_000)
      after
        send(second.pid, :release_reader)
        Task.await(second, 5_000)
      end
    after
      send(first.pid, :release_reader)
      Task.await(first, 5_000)
    end
  end

  defp start_reader(schema, table, repo) do
    parent = self()

    task =
      Task.async(fn ->
        repo.transaction(fn ->
          sql("LOCK TABLE #{qualified(schema, table)} IN ACCESS SHARE MODE", [], repo)
          [[backend]] = sql("SELECT pg_backend_pid()", [], repo).rows
          send(parent, {:reader_locked, self(), backend})

          receive do
            :release_reader -> :ok
          after
            10_000 -> raise "reader was not released"
          end
        end)
      end)

    task_pid = task.pid

    receive do
      {:reader_locked, ^task_pid, backend} -> {task, backend}
    after
      5_000 -> raise "reader did not acquire its lock"
    end
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 5_000)

  defp await(fun, deadline) do
    unless fun.() do
      if System.monotonic_time(:millisecond) > deadline,
        do: raise("catalog checkpoint not reached")

      await(fun, deadline)
    end
  end

  def sql(statement, params \\ [], repo \\ Repo),
    do: SQL.query!(repo, statement, params, timeout: :infinity)

  def quote_name(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
  def qualified(schema, name), do: quote_name(schema) <> "." <> quote_name(name)

  defp type(name)
       when name in ~w(status actor_kind target_kind action_id pack_id pack_version provider_identifier external_group_id paddle_customer_id),
       do: "varchar(255)"

  defp type("allowed_email_domain"), do: "public.citext"
  defp type("inputs_raw"), do: "bytea"
  defp type("enabled"), do: "boolean"
  defp type(name), do: if(String.ends_with?(name, "_at"), do: "timestamp", else: "uuid")

  defmodule Baseline do
    use Ecto.Migration

    def up, do: Emisar.Fixtures.Release.baseline(prefix(), repo())
  end

  defmodule AfterCascadeKeys do
    use Ecto.Migration

    def up do
      # Its dependency proves the segmented runner does not skip intermediate
      # ordinary migrations or run a recovery body before its predecessors.
      Emisar.Fixtures.Release.sql(
        "DROP INDEX #{Emisar.Fixtures.Release.qualified(prefix(), "api_key_device_grants_account_id_index")}",
        [],
        repo()
      )

      create table(:release_order_marker, prefix: prefix())
    end
  end

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :emisar, adapter: Ecto.Adapters.Postgres
  end

  defmodule StaffWindowIndex do
    use Ecto.Migration
    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      create_if_not_exists index(:action_runs, [:inserted_at],
                             name: :action_runs_inserted_at_idx,
                             concurrently: true
                           )
    end
  end

  defmodule ConsoleKeysetIndex do
    use Ecto.Migration
    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      create_if_not_exists index(:audit_events, [:account_id, "occurred_at DESC", "id ASC"],
                             name: :audit_events_account_console_keyset_idx,
                             concurrently: true
                           )
    end
  end
end
