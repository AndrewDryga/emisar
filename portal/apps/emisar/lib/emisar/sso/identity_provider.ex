defmodule Emisar.SSO.IdentityProvider do
  @moduledoc """
  A per-account OIDC identity provider (relying-party connection). One live,
  enabled provider per `(account, kind)`; an `allowed_email_domain` routes
  sign-in to exactly one provider. `client_secret` is stored plaintext +
  redacted, like every emisar secret — at-rest protection is infra-level.
  """
  use Emisar, :schema
  alias Emisar.Auth

  @kinds [:google_workspace, :okta, :jumpcloud, :keycloak, :openid_connect]
  @provisioners [:jit, :manual]

  schema "identity_providers" do
    field :kind, Ecto.Enum, values: @kinds
    field :provisioner, Ecto.Enum, values: @provisioners, default: :jit
    field :name, :string
    field :issuer, :string
    field :client_id, :string
    field :client_secret, :binary, redact: true
    field :identifier_claim, :string, default: "sub"
    field :default_role, Ecto.Enum, values: Auth.Role.all(), default: :viewer
    field :satisfies_mfa, :boolean, default: true
    field :allowed_email_domain, :string
    field :enabled, :boolean, default: false

    field :scim_enabled, :boolean, default: false
    field :scim_token_prefix, :string
    field :scim_token_hash, :binary, redact: true

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end

  @doc "The supported provider kinds, for the config UI's select."
  def kinds, do: @kinds

  @doc "The new-user provisioning modes (JIT auto-provision vs manual admin approval), for the config UI's select."
  def provisioners, do: @provisioners
end
