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
    # `plan` and `status` are deliberately :string, not Ecto.Enum: Paddle owns
    # most of the value space and support also writes `complimentary`. A
    # renamed/legacy/sales-led plan name (or an unseen status) must LOAD and degrade
    # gracefully — `Billing.account_plan/1` reads `plan` as the single source
    # for gating and `Billing.plan/1` maps an unknown name to free-tier limits,
    # where an enum would raise on every fetch. Writes validate presence, not
    # inclusion (Subscription.Changeset); Paddle is the source of truth.
    field :plan, :string
    field :status, :string
    # The billing cadence ("month" | "year"), mirrored from the Paddle price's
    # billing_cycle.interval — :string for the same vendor-owned-value-space
    # reason as `plan`/`status` above (Paddle could bill day/week too, and an
    # unseen cadence must LOAD and degrade to monthly, not raise). nil = monthly
    # (pre-annual rows). Read via `Billing.billing_summary` to price the period.
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
    field :trial_end, :utc_datetime_usec
    # Paddle's per-subscription `updated_at`; monotonic, used to drop an
    # out-of-order webhook rather than clobber the row (see Changeset.upsert/2).
    field :paddle_updated_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end
end
