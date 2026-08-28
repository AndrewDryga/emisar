defmodule Emisar.Repo.Migrations.AlignIndexesWithTheQueriesThatUseThem do
  use Ecto.Migration

  # Built CONCURRENTLY for the same reason 20260921000000 was: bin/migrate runs
  # before an instance serves, and an ordinary CREATE INDEX on a populated table
  # holds a write lock for the whole build. Concurrent builds cannot run inside
  # a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Every claim below was checked against a database with all prior migrations
  # applied — pg_indexes for the real definitions, pg_constraint for the
  # unindexed foreign keys, and EXPLAIN for the two plan-level claims.

  @soft_delete_tables ~w[
    accounts users account_memberships runners
    runner_enrollment_keys api_keys policies runbooks
  ]a

  # A foreign key with no index on the child column makes the parent's delete
  # scan the child table once per referencing constraint. These are the eleven
  # on tables that grow without bound; 20260918000000 covered CASCADE, and
  # SET NULL and NO ACTION need the same index for the same reason. Account and
  # user erasure are real hard deletes (Accounts.delete_by_id/1 and
  # erase_user_and_owned_accounts/1), so these fire in production.
  @unindexed_child_keys [
    {:action_runs, :policy_id},
    {:approval_decisions, :decider_id},
    {:approval_grants, :granted_by_id},
    {:approval_grants, :revoked_by_id},
    {:approval_requests, :decided_by_id},
    {:approval_requests, :requested_by_id},
    {:auth_user_tokens, :user_identity_id},
    {:runbook_execution_items, :policy_id},
    {:runbook_execution_items, :runner_id},
    {:runbook_executions, :requested_by_id},
    {:runner_tokens, :issued_via_key_id}
  ]

  def up do
    # -- Indexes nothing can use -------------------------------------------

    # 20260531000000 built these to keep `deleted_at IS NULL` reads fast. A
    # partial index on `deleted_at IS NOT NULL` holds only the deleted rows, so
    # it can never answer the negation — and no query anywhere asks for the
    # positive. Eight indexes of pure write amplification.
    for table <- @soft_delete_tables do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{table}_deleted_at_index")
    end

    # The highest-write table in the product, keyed on a column no query
    # touches: RunEvent.Query has no inserted_at helper, and retention is keyed
    # on the parent run's finished_at.
    execute("DROP INDEX CONCURRENTLY IF EXISTS action_run_events_account_id_inserted_at_index")

    # The customer-sync sweep's WHERE grew to reference two joined tables, so
    # six of its ten disjuncts are on account_memberships/users. The index
    # predicate is only the four on accounts, which means an account the query
    # matches can be absent from the index — the planner must not use it.
    execute("DROP INDEX CONCURRENTLY IF EXISTS accounts_paddle_customer_sync_idx")

    # No query pairs account_id with status here: both active/1 call sites are
    # fleet-wide recovery scans, and every by_account_id/2 site pairs with a
    # primary-key lookup.
    execute("DROP INDEX CONCURRENTLY IF EXISTS runbook_executions_active_by_account_index")

    # paddle_processed_events_received_at_index is deliberately KEPT. received_at
    # had no reader when this sweep was planned, but the retention job added in
    # the same change reads exactly it, and that job is why the table stops
    # growing forever. Dropping it would have made its own fix a seq scan.

    # Superseded by sso_directory_group_members_resource_membership_index.
    # 20260927000000 made external_group_id nullable, and Postgres treats NULLs
    # as distinct, so this unique index enforces nothing for exactly the
    # externalId-less membership that migration exists to support.
    execute("DROP INDEX CONCURRENTLY IF EXISTS sso_directory_group_members_membership_index")

    # -- Indexes a real predicate needs ------------------------------------

    # Both audit lookups are account-scoped by Authorizer.for_subject/2, but
    # neither index leads with account_id: the actor picker reads every tenant's
    # events of that kind before the account filter applies, on the one table
    # that is append-only and unbounded per tenant.
    #
    # The dropped subject_* index NAME is left over from the subject→target
    # column rename, which is why this drops by literal name: a
    # `drop index(:audit_events, [:target_kind, :target_id])` would generate
    # `audit_events_target_kind_target_id_index` and silently match nothing.
    create index(:audit_events, [:account_id, :actor_kind, :actor_id],
             name: :audit_events_account_actor_idx,
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS audit_events_actor_kind_actor_id_index")

    create index(:audit_events, [:account_id, :target_kind, :target_id],
             name: :audit_events_account_target_idx,
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS audit_events_subject_kind_subject_id_index")

    # The hourly expiry sweep had no index for its predicate at all, while the
    # sibling oauth_authz_codes got exactly this in 20260722000000. The
    # predicate leads with access_expires_at; refresh_expires_at is a filter.
    create index(:oauth_tokens, [:access_expires_at],
             name: :oauth_tokens_expired_idx,
             concurrently: true
           )

    # Execution retention filters completed_at, which had no index. Same shape
    # as audit_events_retention_idx, already reviewed for the sibling sweep.
    create index(:runbook_executions, [:account_id, :completed_at],
             name: :runbook_executions_retention_idx,
             where: "completed_at IS NOT NULL",
             concurrently: true
           )

    # The run/event retention subquery is account-scoped as of this change, so
    # the fleet-wide finished_at index is replaced by the one the scoped
    # predicate can walk.
    create index(:action_runs, [:account_id, :finished_at],
             name: :action_runs_retention_idx,
             where: "finished_at IS NOT NULL",
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS action_runs_finished_at_idx")

    # ordered_by_least_recently_advanced/1 asks for NULLS FIRST — a NULL
    # last_advanced_at means "never advanced", so it IS the fairness guarantee.
    # A plain ASC b-tree stores NULLS LAST, so the old index could not serve
    # that order: EXPLAIN on 60k active rows showed a full Seq Scan plus a Sort
    # to return the LIMIT 50. With the direction declared, and the cursor's `id`
    # tie-break included, the same query is an Index Only Scan touching 50 rows.
    create index(
             :runbook_executions,
             [:status, "last_advanced_at ASC NULLS FIRST", :inserted_at, :id],
             name: :runbook_executions_fair_recovery_idx,
             where: "status = 'active'",
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS runbook_executions_fair_recovery_index")

    # The keyset defect 20260921000000 fixed for action_runs and audit_events —
    # approval_requests was not in that pass. Its cursor is
    # {requested_at DESC, id ASC} and the index carried no id, so the row
    # comparison stayed a post-scan filter. The replacement is a strict superset
    # of what it drops, so every prefix and range lookup still resolves.
    create index(:approval_requests, [:account_id, "requested_at DESC", "id ASC"],
             name: :approval_requests_account_keyset_idx,
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS approval_requests_account_id_requested_at_index")

    # -- Child keys the parent's delete has to scan ------------------------

    for {table, column} <- @unindexed_child_keys do
      create index(table, [column], concurrently: true)
    end
  end

  def down do
    for {table, column} <- @unindexed_child_keys do
      drop_if_exists index(table, [column])
    end

    create index(:approval_requests, [:account_id, :requested_at],
             name: :approval_requests_account_id_requested_at_index,
             concurrently: true
           )

    drop_if_exists index(:approval_requests, [:account_id, "requested_at DESC", "id ASC"],
                     name: :approval_requests_account_keyset_idx
                   )

    create index(:runbook_executions, [:status, :last_advanced_at, :inserted_at],
             name: :runbook_executions_fair_recovery_index,
             where: "status = 'active'",
             concurrently: true
           )

    drop_if_exists index(
                     :runbook_executions,
                     [:status, "last_advanced_at ASC NULLS FIRST", :inserted_at, :id],
                     name: :runbook_executions_fair_recovery_idx
                   )

    create index(:action_runs, [:finished_at],
             name: :action_runs_finished_at_idx,
             where: "finished_at IS NOT NULL",
             concurrently: true
           )

    drop_if_exists index(:action_runs, [:account_id, :finished_at],
                     name: :action_runs_retention_idx
                   )

    drop_if_exists index(:runbook_executions, [:account_id, :completed_at],
                     name: :runbook_executions_retention_idx
                   )

    drop_if_exists index(:oauth_tokens, [:access_expires_at], name: :oauth_tokens_expired_idx)

    create index(:audit_events, [:target_kind, :target_id],
             name: :audit_events_subject_kind_subject_id_index,
             concurrently: true
           )

    drop_if_exists index(:audit_events, [:account_id, :target_kind, :target_id],
                     name: :audit_events_account_target_idx
                   )

    create index(:audit_events, [:actor_kind, :actor_id],
             name: :audit_events_actor_kind_actor_id_index,
             concurrently: true
           )

    drop_if_exists index(:audit_events, [:account_id, :actor_kind, :actor_id],
                     name: :audit_events_account_actor_idx
                   )

    create unique_index(
             :sso_directory_group_members,
             [:provider_id, :external_group_id, :user_identity_id],
             where: "deleted_at IS NULL",
             name: :sso_directory_group_members_membership_index,
             concurrently: true
           )

    create index(:runbook_executions, [:account_id, :status],
             name: :runbook_executions_active_by_account_index,
             where: "status = 'active'",
             concurrently: true
           )

    create index(:accounts, [:id],
             name: :accounts_paddle_customer_sync_idx,
             where:
               "deleted_at IS NULL AND (paddle_customer_id IS NULL OR " <>
                 "paddle_billing_contact_user_id IS NULL OR " <>
                 "paddle_customer_synced_at IS NULL OR updated_at > paddle_customer_synced_at)",
             concurrently: true
           )

    create index(:action_run_events, [:account_id, :inserted_at], concurrently: true)

    for table <- @soft_delete_tables do
      create index(table, [:deleted_at], where: "deleted_at IS NOT NULL", concurrently: true)
    end
  end
end
