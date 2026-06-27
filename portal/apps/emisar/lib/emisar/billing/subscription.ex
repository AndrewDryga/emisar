defmodule Emisar.Billing.Subscription do
  @moduledoc """
  Mirror of the Paddle subscription record for the account's current
  plan. Paddle remains the source of truth; we mirror what we need for
  in-app plan enforcement without round-tripping to Paddle per request.
  """
  use Emisar, :schema

  schema "subscriptions" do
    field :paddle_subscription_id, :string
    field :paddle_price_id, :string
    # `plan` and `status` are deliberately :string, not Ecto.Enum: this row is
    # a Paddle mirror, so the value space is vendor-owned. A renamed/legacy/
    # sales-led plan name (or an unseen status) must still LOAD and degrade
    # gracefully — `Billing.account_plan/1` reads `plan` as the single source
    # for gating and `Billing.plan/1` maps an unknown name to free-tier limits,
    # where an enum would raise on every fetch. Writes validate presence, not
    # inclusion (Subscription.Changeset); Paddle is the source of truth.
    field :plan, :string
    field :status, :string
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

  def active?(%__MODULE__{status: status}) when status in ["trialing", "active"], do: true
  def active?(_), do: false
end
