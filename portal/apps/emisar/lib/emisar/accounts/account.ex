defmodule Emisar.Accounts.Account do
  @moduledoc """
  An account is the multi-tenant boundary. One subscription per
  account; runners, runbooks, policies, and audit events all belong
  to exactly one account.
  """

  use Emisar, :schema

  schema "accounts" do
    field :name, :string
    field :slug, :string
    field :plan, :string, default: "free"
    field :paddle_customer_id, :string
    field :trial_ends_at, :utc_datetime
    field :status, :string, default: "active"
    field :settings, :map, default: %{}
    field :disabled_at, :utc_datetime
    field :require_mfa, :boolean, default: false
    field :deleted_at, :utc_datetime_usec

    has_many :memberships, Emisar.Accounts.Membership
    has_many :users, through: [:memberships, :user]
    has_many :runners, Emisar.Runners.Runner
    has_one :subscription, Emisar.Billing.Subscription

    timestamps()
  end

  def plans, do: Emisar.Accounts.Account.Changeset.plans()
end
