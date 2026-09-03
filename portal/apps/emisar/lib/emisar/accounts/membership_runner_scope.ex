defmodule Emisar.Accounts.MembershipRunnerScope do
  @moduledoc """
  Normalized restricted runner scopes for an account membership.

  The table is still named `user_runner_scopes` from before scopes moved onto
  the membership; renaming it is a migration of its own.
  """
  use Emisar, :schema

  schema "user_runner_scopes" do
    field :scope_type, Ecto.Enum, values: [:group, :runner]
    field :scope_value, :string

    belongs_to :membership, Emisar.Accounts.Membership, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end
end
