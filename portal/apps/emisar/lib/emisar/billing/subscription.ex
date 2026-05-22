defmodule Emisar.Billing.Subscription do
  @moduledoc """
  Mirror of the Stripe subscription record for the account's current
  plan. Stripe remains the source of truth; we mirror what we need for
  in-app plan enforcement without round-tripping to Stripe per request.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(trialing active past_due canceled unpaid incomplete incomplete_expired paused)

  schema "subscriptions" do
    field :stripe_subscription_id, :string
    field :stripe_price_id, :string
    field :plan, :string
    field :status, :string
    field :quantity, :integer, default: 1
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancel_at_period_end, :boolean, default: false
    field :trial_end, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [
      :account_id, :stripe_subscription_id, :stripe_price_id, :plan, :status,
      :quantity, :current_period_start, :current_period_end, :cancel_at_period_end, :trial_end
    ])
    |> validate_required([:account_id, :plan, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:account_id)
  end

  def statuses, do: @statuses

  def active?(%__MODULE__{status: status}) when status in ["trialing", "active"], do: true
  def active?(_), do: false
end
