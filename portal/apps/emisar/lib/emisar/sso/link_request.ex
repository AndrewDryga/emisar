defmodule Emisar.SSO.LinkRequest do
  @moduledoc """
  A pending manual-link request: an unknown identity that signed in through a
  `:manual`-provisioner connection and is waiting for an admin to approve their
  access. Captures the real OIDC `provider_identifier` (the `sub`) + the claims
  so the admin recognizes the person; approving binds THAT sub — never the email
  (H1). Hard-deleted on approve/dismiss (transient by design).
  """
  use Emisar, :schema

  schema "sso_link_requests" do
    field :provider_identifier, :string
    field :email, :string
    field :full_name, :string
    field :claims, :map, default: %{}

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]

    timestamps()
  end
end
