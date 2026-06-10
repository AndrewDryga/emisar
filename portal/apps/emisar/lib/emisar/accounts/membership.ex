defmodule Emisar.Accounts.Membership do
  @moduledoc """
  Joins users to accounts with a role. A user can be in many accounts;
  an account has many users.
  """
  use Emisar, :schema
  alias Emisar.Auth.Role

  @roles Role.all()

  schema "memberships" do
    field :role, Ecto.Enum, values: @roles, default: :operator
    field :invitation_token, :string
    field :invitation_accepted_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :user, Emisar.Accounts.User, where: [deleted_at: nil]
    belongs_to :invited_by, Emisar.Accounts.User, where: [deleted_at: nil]

    timestamps()
  end

  @doc "True when a member's access to this tenant has been suspended (`disabled_at` set)."
  def disabled?(%__MODULE__{disabled_at: %DateTime{}}), do: true
  def disabled?(%__MODULE__{}), do: false
end
