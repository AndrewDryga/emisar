defmodule Emisar.Repo.Migrations.DropLegacyJobQueue do
  use Ecto.Migration

  def up do
    drop_if_exists table(:oban_jobs)

    create index(:approval_requests, [:expires_at],
             where: "status = 'pending' AND expires_at IS NOT NULL",
             name: :approval_requests_pending_expires_at_idx
           )

    create index(:oauth_authz_codes, [:expires_at],
             where: "expires_at IS NOT NULL",
             name: :oauth_authz_codes_expired_idx
           )

    create index(:oauth_clients, [:inserted_at],
             where: "last_authorized_at IS NULL",
             name: :oauth_clients_never_authorized_inserted_at_idx
           )

    create index(:action_runs, [:finished_at],
             where: "finished_at IS NOT NULL",
             name: :action_runs_finished_at_idx
           )

    create index(:action_run_events, [:account_id, :run_id],
             name: :action_run_events_account_id_run_id_idx
           )

    drop_if_exists index(:audit_events, [:account_id, :retain_until])

    create index(:audit_events, [:account_id, :retain_until],
             where: "retain_until IS NOT NULL",
             name: :audit_events_retention_idx
           )

    drop_if_exists index(:subscriptions, [:paddle_subscription_id])

    create index(:subscriptions, [:paddle_subscription_id],
             where: "paddle_subscription_id IS NOT NULL",
             name: :subscriptions_paddle_subscription_id_idx
           )

    create index(:accounts, [:id],
             where: """
             deleted_at IS NULL AND (
               paddle_customer_id IS NULL OR
               paddle_billing_contact_user_id IS NULL OR
               paddle_customer_synced_at IS NULL OR
               updated_at > paddle_customer_synced_at
             )
             """,
             name: :accounts_paddle_customer_sync_idx
           )

    create index(:memberships, [:account_id, :user_id, :updated_at],
             where: "deleted_at IS NULL AND disabled_at IS NULL AND role = 'owner'",
             name: :memberships_active_owner_contact_idx
           )
  end

  def down do
    drop_if_exists index(:memberships, name: :memberships_active_owner_contact_idx)
    drop_if_exists index(:accounts, name: :accounts_paddle_customer_sync_idx)

    drop_if_exists index(:subscriptions, name: :subscriptions_paddle_subscription_id_idx)
    create index(:subscriptions, [:paddle_subscription_id])

    drop_if_exists index(:audit_events, name: :audit_events_retention_idx)
    create index(:audit_events, [:account_id, :retain_until])

    drop_if_exists index(:action_run_events, name: :action_run_events_account_id_run_id_idx)
    drop_if_exists index(:action_runs, name: :action_runs_finished_at_idx)
    drop_if_exists index(:oauth_clients, name: :oauth_clients_never_authorized_inserted_at_idx)
    drop_if_exists index(:oauth_authz_codes, name: :oauth_authz_codes_expired_idx)
    drop_if_exists index(:approval_requests, name: :approval_requests_pending_expires_at_idx)
  end
end
