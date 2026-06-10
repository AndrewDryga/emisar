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
    field :plan, :string
    field :status, :string
    field :quantity, :integer, default: 1
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancel_at_period_end, :boolean, default: false
    field :trial_end, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end

  def statuses, do: Emisar.Billing.Subscription.Changeset.statuses()

  def active?(%__MODULE__{status: status}) when status in ["trialing", "active"], do: true
  def active?(_), do: false
end
