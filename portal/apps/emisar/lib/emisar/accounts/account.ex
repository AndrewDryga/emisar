defmodule Emisar.Accounts.Account do
  @moduledoc """
  An account is the multi-tenant boundary. One subscription per
  account; runners, runbooks, policies, and audit events all belong
  to exactly one account.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @plans ~w(free team enterprise)
  @statuses ~w(active suspended deleted)

  schema "accounts" do
    field :name, :string
    field :slug, :string
    field :plan, :string, default: "free"
    field :stripe_customer_id, :string
    field :trial_ends_at, :utc_datetime
    field :status, :string, default: "active"
    field :settings, :map, default: %{}
    field :disabled_at, :utc_datetime

    has_many :memberships, Emisar.Accounts.Membership
    has_many :users, through: [:memberships, :user]
    has_many :runners, Emisar.Runners.Runner
    has_one :subscription, Emisar.Billing.Subscription

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :slug, :plan, :stripe_customer_id, :trial_ends_at, :status, :settings])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9-]{1,62}[a-z0-9]$/,
      message: "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars"
    )
    |> validate_inclusion(:plan, @plans)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug)
  end

  def plans, do: @plans
end
