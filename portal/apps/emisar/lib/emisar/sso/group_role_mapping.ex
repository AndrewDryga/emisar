defmodule Emisar.SSO.GroupRoleMapping do
  @moduledoc """
  Maps an IdP group (by its SCIM `externalId`) to an emisar role for a
  provider. Directory sync recomputes a member's role as the HIGHEST mapped
  role over the groups they belong to. `role` is validated non-`:owner` in
  the changeset — sync can never grant owner (decision 7).
  """
  use Emisar, :schema
  alias Emisar.Auth

  schema "sso_directory_group_role_mappings" do
    field :external_group_id, :string
    field :external_group_display, :string
    field :role, Ecto.Enum, values: Auth.Role.all()

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]

    timestamps()
  end
end
