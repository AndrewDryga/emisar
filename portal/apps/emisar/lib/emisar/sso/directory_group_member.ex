defmodule Emisar.SSO.DirectoryGroupMember do
  @moduledoc """
  The synced membership of an IdP group: links a provisioned `user_identity`
  to an IdP group (by its SCIM `externalId`) for a provider. A member's role
  is recomputed as the highest mapped role over the union of their groups.
  Replaced wholesale on a group sync (PUT) and patched by member-level
  `add`/`remove` ops (PATCH).

  Each row also carries the group's pushed `external_group_display`, because a
  synced group has no table of its own — it IS its member rows — and its name
  has to survive whether or not anyone has mapped it to a role.
  """
  use Emisar, :schema

  schema "sso_directory_group_members" do
    field :external_group_id, :string
    field :external_group_display, :string

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]
    belongs_to :user_identity, Emisar.SSO.UserIdentity, where: [deleted_at: nil]

    timestamps()
  end
end
