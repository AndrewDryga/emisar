defmodule Emisar.SSO.DirectoryGroupMember do
  @moduledoc """
  The synced membership of an IdP group: links a provisioned `user_identity`
  to a server-owned directory-group resource for a provider. A member's role
  is recomputed as the highest mapped role over the union of their groups.
  Replaced wholesale on a group sync (PUT) and patched by member-level
  `add`/`remove` ops (PATCH).

  The directory-owned external id and display remain denormalized for SCIM
  reconciliation and rendering. Authorization follows `directory_group_id`.
  A provider probe group may have neither external attribute.
  """
  use Emisar, :schema

  schema "sso_directory_group_members" do
    field :external_group_id, :string
    field :external_group_display, :string

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]
    belongs_to :directory_group, Emisar.SSO.DirectoryGroup, where: [deleted_at: nil]
    belongs_to :user_identity, Emisar.SSO.UserIdentity, where: [deleted_at: nil]

    timestamps()
  end
end
