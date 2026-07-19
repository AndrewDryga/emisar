defmodule Emisar.SSO.GroupRunnerAccessMapping do
  @moduledoc """
  Explicit additive runner access granted by one synced IdP group.

  Role mappings remain separate because an IdP group may grant either concern,
  both, or neither, and runner access can contain several group/runner scopes.
  """
  use Emisar, :schema

  @runner_access_modes [:all, :restricted]

  schema "sso_directory_group_runner_access_mappings" do
    field :external_group_id, :string
    field :external_group_display, :string
    field :runner_access_mode, Ecto.Enum, values: @runner_access_modes
    field :runner_scope_groups, {:array, :string}, default: []
    field :runner_scope_runner_ids, {:array, Ecto.UUID}, default: []
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]

    timestamps()
  end
end
