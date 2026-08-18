defmodule Emisar.SSO.DirectoryGroup do
  @moduledoc """
  A group the directory has pushed. Its UUID is the SCIM resource `id`;
  `external_group_id` is the directory-owned `externalId` when one was supplied.
  Existence and display live here; who is IN it lives on
  `DirectoryGroupMember`.

  Deriving a group from its membership rows meant an empty group did not exist —
  `POST /Groups` with no members answered 201 and the next `GET` answered 404,
  and a group pushed ahead of its users disappeared until someone landed in it.
  """
  use Emisar, :schema

  schema "sso_directory_groups" do
    field :external_group_id, :string
    field :display, :string
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]

    timestamps()
  end
end
