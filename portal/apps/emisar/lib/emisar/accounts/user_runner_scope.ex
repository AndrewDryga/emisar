defmodule Emisar.Accounts.UserRunnerScope do
  @moduledoc """
  Per-membership runner allowlist row. Membership with no scopes = all
  runners (default + v0 behavior); membership with ≥1 scope = union of
  the listed scopes only.

      scope_type = "group"  → scope_value matches runner.group
      scope_type = "runner" → scope_value matches runner.id (UUID)
  """
  use Emisar, :schema

  schema "user_runner_scopes" do
    field :scope_type, :string
    field :scope_value, :string
    belongs_to :membership, Emisar.Accounts.Membership

    timestamps(updated_at: false)
  end

  @valid_types ~w(group runner)
  def valid_types, do: @valid_types
end
