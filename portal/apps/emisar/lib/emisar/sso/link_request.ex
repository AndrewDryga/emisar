defmodule Emisar.SSO.LinkRequest do
  @moduledoc """
  A pending link request: an identity that signed in / was pushed through a
  connection and is waiting for an admin to approve their access. Captures the
  real `provider_identifier` (the OIDC `sub` / SCIM `externalId`) + the claims so
  the admin recognizes the person; approving binds THAT id — never the email
  (H1). When the captured email matches an EXISTING account member, `matched_user`
  records them so approval links the identity to that user instead of creating a
  duplicate. Hard-deleted on approve/dismiss (transient by design).
  """
  use Emisar, :schema

  schema "sso_link_requests" do
    field :provider_identifier, :string
    # Which namespace `provider_identifier` belongs to. Approval stamps the OIDC
    # binding or the directory's, never one with the other's value.
    field :source, Ecto.Enum, values: [:oidc, :scim], default: :oidc
    # The issuer/client/claim this request was produced under. Approval refuses a
    # request the current connection did not make.
    field :namespace_fingerprint, :string
    field :email, :string
    field :full_name, :string
    field :claims, :map, default: %{}

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]
    belongs_to :matched_user, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
