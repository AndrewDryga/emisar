defmodule Emisar.Repo.Migrations.ApiKeysAndBilling do
  use Ecto.Migration

  def change do
    # API keys grant programmatic access. The MCP endpoint authenticates
    # LLM tool callers (Claude, Cursor, etc.) with these.
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :description, :string

      add :key_prefix, :string, null: false
      add :key_hash, :binary, null: false

      # Which runners this key may target. Empty = all runners in
      # account; non-empty = strict allowlist of runner ids.
      add :runner_filter, {:array, :string}, null: false, default: []

      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoked_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_prefix])
    create index(:api_keys, [:account_id])

    # Approval grants are durable "next-time-just-run-it" decisions an
    # operator attaches when approving a high-risk action. Scoped to
    # the calling API key, optionally narrowed to a specific runner +
    # args fingerprint, optionally time-boxed and use-capped.
    #
    # Lives here (not in 20260520000006_approvals_and_audit) because
    # it FKs api_keys, which this migration creates.
    #
    # Match rules:
    #   args_sha256 = NULL → matches any args for the action
    #   args_sha256 = <hex> → matches only exact-args calls
    #   runner_id   = NULL → matches any runner advertising the action
    #   runner_id   = <uuid> → matches that runner only
    #   max_uses    = NULL → unlimited (within duration)
    #   max_uses    = N → consumed by use_grant after N matches
    #   expires_at  = NULL → indefinite (must be manually revoked)
    create table(:approval_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :action_id, :string, null: false
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all)
      add :args_sha256, :string

      add :granted_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :granted_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoked_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :max_uses, :integer
      add :uses_count, :integer, null: false, default: 0
      add :last_used_at, :utc_datetime_usec

      # Pointer back to the approval row that originated this grant —
      # dashboard "what grant came from this approval?" lookup.
      add :approval_request_id,
          references(:approval_requests, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:approval_grants, [:api_key_id, :action_id])
    create index(:approval_grants, [:account_id, :action_id])
    create index(:approval_grants, [:approval_request_id])

    # Billing — a thin layer over Stripe customer + subscription. We
    # rely on Paddle as the source of truth; this table mirrors the
    # subset we need to enforce plan limits without round-tripping to
    # Paddle on every request.
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :paddle_subscription_id, :string
      add :paddle_price_id, :string
      add :plan, :string, null: false
      add :status, :string, null: false

      add :quantity, :integer, null: false, default: 1
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :trial_end, :utc_datetime_usec
      # The subscription's Paddle `updated_at` — a monotonic per-subscription
      # timestamp used to drop an out-of-order webhook (a late `canceled` whose
      # state predates a fresh `active`) instead of clobbering the row.
      add :paddle_updated_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:account_id])
    create index(:subscriptions, [:paddle_subscription_id])

    # Cursor sidecar — mirrors the runner's local outbox cursor so we
    # know which JSONL event_ids we've acked. Used by the audit-upload
    # sink (cloud receives JSONL replays, dedups by event_id).
    create table(:runner_event_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, :string, null: false
      add :acked_at, :utc_datetime_usec, null: false
    end

    create unique_index(:runner_event_cursors, [:runner_id, :event_id])
  end
end
