defmodule Emisar.Repo.Migrations.ApiKeysAndBilling do
  use Ecto.Migration

  def change do
    # API keys grant programmatic access. The MCP endpoint authenticates
    # LLM tool callers (Claude, Cursor, etc.) with these.
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :description, :string

      add :key_prefix, :string, null: false
      add :key_hash, :binary, null: false

      # Which agents this key may target. NULL = all agents in account.
      add :agent_filter, {:array, :string}, null: false, default: []

      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoked_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_prefix])
    create index(:api_keys, [:account_id])

    # Billing — a thin layer over Stripe customer + subscription. We
    # rely on Stripe as the source of truth; this table mirrors the
    # subset we need to enforce plan limits without round-tripping to
    # Stripe on every request.
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false

      add :stripe_subscription_id, :string
      add :stripe_price_id, :string
      add :plan, :string, null: false
      add :status, :string, null: false

      add :quantity, :integer, null: false, default: 1
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :trial_end, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:account_id])
    create index(:subscriptions, [:stripe_subscription_id])

    # Cursor sidecar — mirrors the agent's local outbox cursor so we
    # know which JSONL event_ids we've acked. Used by the audit-upload
    # sink (cloud receives JSONL replays, dedups by event_id).
    create table(:agent_event_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, :string, null: false
      add :acked_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agent_event_cursors, [:agent_id, :event_id])
  end
end
