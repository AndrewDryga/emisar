defmodule Emisar.Accounts.Membership do
  @moduledoc """
  Joins users to accounts with a role. A user can be in many accounts;
  an account has many users.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin operator viewer)

  schema "memberships" do
    field :role, :string, default: "operator"
    field :invitation_token, :string
    field :invitation_accepted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :user, Emisar.Accounts.User
    belongs_to :invited_by, Emisar.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:account_id, :user_id, :role, :invited_by_id, :invitation_token, :invitation_accepted_at])
    |> validate_required([:account_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:account_id, :user_id])
  end

  def roles, do: @roles

  @doc "Does `role` carry the same or more privilege than `required`?"
  def at_least?(role, required) when role in @roles and required in @roles do
    rank(role) <= rank(required)
  end

  def at_least?(_, _), do: false

  defp rank("owner"), do: 0
  defp rank("admin"), do: 1
  defp rank("operator"), do: 2
  defp rank("viewer"), do: 3
end
