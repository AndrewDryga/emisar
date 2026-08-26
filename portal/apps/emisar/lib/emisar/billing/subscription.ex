defmodule Emisar.Billing.Subscription do
  @moduledoc """
  The account's current paid or complimentary plan. Rows with a Paddle
  subscription id mirror Paddle; `status: "complimentary"` with no Paddle id
  represents a support-granted plan using the same enforcement path.
  """
  use Emisar, :schema

  schema "billing_subscriptions" do
    field :paddle_subscription_id, :string
    field :paddle_price_id, :string
    # These lifecycle/catalog strings deliberately stay open rather than using
    # Ecto.Enum: Paddle owns their value spaces. Unknown values must load so
    # Billing can degrade them safely instead of crashing a webhook or read.
    # Support also writes the local `complimentary` status.
    field :plan, :string
    field :status, :string
    # Paddle owns both values. `collection_mode` distinguishes automatic
    # dunning (Paddle drives it to a terminal state) from a manually collected
    # invoice that needs an explicit contract policy. Unknown values load and
    # fail closed through Billing's owned lifecycle projection.
    field :collection_mode, :string
    # The billing cadence ("month" | "year" today), mirrored from the Paddle
    # price. An unseen cadence must load and degrade safely. nil = monthly for
    # pre-annual rows. Read via `Billing.billing_summary` to price the period.
    field :billing_interval, :string
    # The exact recurring price Paddle charges, in the currency's minor unit.
    # These remain nullable because legacy rows are backfilled by the hourly
    # reconciliation job, and Paddle remains the source of truth.
    field :unit_price_amount, :integer
    field :currency_code, :string
    # Paddle's billing_cycle.frequency (for example every 2 months). Combined
    # with billing_interval so analytics can normalize recurring revenue.
    field :billing_frequency, :integer
    # Paddle-mirrored plan entitlements (the product's custom_data), validated
    # into canonical form by `Billing.Entitlements` at extraction — limits are
    # non-negative ints or the string "unlimited", feature flags booleans. A
    # plain :map, not an embed: the int-or-"unlimited" union has no embed field
    # type, and the write-side validator already guarantees the shape.
    field :entitlements, :map, default: %{}
    field :quantity, :integer, default: 1
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancel_at_period_end, :boolean, default: false
    # Keep Paddle's open scheduled-action value beside the legacy cancellation
    # flag. Known cancel/pause actions end access at their exact deadline;
    # unknown actions load but make the lifecycle unresolved.
    field :scheduled_change_action, :string
    field :scheduled_change_effective_at, :utc_datetime_usec
    field :trial_end, :utc_datetime_usec
    # Paddle's per-subscription `updated_at`; monotonic, used to drop an
    # out-of-order webhook rather than clobber the row (see Changeset.upsert/2).
    field :paddle_updated_at, :utc_datetime_usec
    # Top-level webhook occurred_at is Paddle's event ordering authority. It is
    # separate from the subscription object's own updated_at, which the hourly
    # retrieve sweep uses to avoid rewinding newer provider state.
    field :paddle_event_occurred_at, :utc_datetime_usec
    # Durable outbox marker for reconciling the absolute billable-runner count
    # to Paddle. Runner rows remain authoritative; no desired count is cached.
    field :runner_quantity_sync_requested_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end
end
