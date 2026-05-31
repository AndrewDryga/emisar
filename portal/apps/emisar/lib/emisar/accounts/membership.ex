defmodule Emisar.Accounts.Membership do
  @moduledoc """
  Joins users to accounts with a role. A user can be in many accounts;
  an account has many users.
  """

  use Emisar, :schema

  @roles ~w(owner admin operator viewer)

  schema "memberships" do
    field :role, :string, default: "operator"
    field :invitation_token, :string
    field :invitation_accepted_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :user, Emisar.Accounts.User
    belongs_to :invited_by, Emisar.Accounts.User

    timestamps()
  end

  @doc "True when a member's access to this tenant has been suspended (`disabled_at` set)."
  def disabled?(%__MODULE__{disabled_at: %DateTime{}}), do: true
  def disabled?(%__MODULE__{}), do: false

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
