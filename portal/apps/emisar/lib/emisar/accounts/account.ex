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
    field :paddle_customer_id, :string
    field :paddle_customer_synced_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    # Operator settings live in one embedded jsonb value, not a column per
    # toggle — see `Account.Settings`. `on_replace: :update` so a partial
    # `%{settings: %{require_mfa: …}}` update keeps the other settings.
    embeds_one :settings, Emisar.Accounts.Account.Settings, on_replace: :update

    # Soft-deletable associations skip tombstoned rows by default, so a
    # preload never surfaces a deleted membership/runner.
    belongs_to :paddle_billing_contact_user, Emisar.Users.User,
      foreign_key: :paddle_billing_contact_user_id,
      where: [deleted_at: nil]

    has_many :memberships, Emisar.Accounts.Membership, where: [deleted_at: nil]
    has_many :users, through: [:memberships, :user]
    has_many :runners, Emisar.Runners.Runner, where: [deleted_at: nil]
    has_one :subscription, Emisar.Billing.Subscription

    timestamps()
  end
end
