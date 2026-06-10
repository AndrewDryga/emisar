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
    # Deliberately NOT Ecto.Enum: writes are constrained to the current
    # plan list (changeset inclusion), but a stored legacy/renamed plan
    # name must still LOAD — `Billing.plan/1` degrades it to free-tier
    # limits, whereas an enum would raise on every fetch of the account.
    field :plan, :string, default: "free"
    field :paddle_customer_id, :string
    field :require_mfa, :boolean, default: false
    field :deleted_at, :utc_datetime_usec

    # Soft-deletable associations skip tombstoned rows by default, so a
    # preload never surfaces a deleted membership/runner.
    has_many :memberships, Emisar.Accounts.Membership, where: [deleted_at: nil]
    has_many :users, through: [:memberships, :user]
    has_many :runners, Emisar.Runners.Runner, where: [deleted_at: nil]
    has_one :subscription, Emisar.Billing.Subscription

    timestamps()
  end

  def plans, do: Emisar.Accounts.Account.Changeset.plans()
end
