defmodule Emisar.Accounts.MembershipRunnerScope do
  @moduledoc """
  Normalized restricted runner scopes for an account membership.

  The table name stays unchanged during the mixed-version rollout so old portal
  revisions can still enforce restricted access. Accounts owns all new writes.
  """
  use Emisar, :schema

  schema "user_runner_scopes" do
    field :scope_type, Ecto.Enum, values: [:group, :runner]
    field :scope_value, :string

    belongs_to :membership, Emisar.Accounts.Membership

    timestamps(updated_at: false)
  end
end
