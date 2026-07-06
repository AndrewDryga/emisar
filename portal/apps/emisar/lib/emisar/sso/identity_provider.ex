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
    # The stable, IdP-issued subject identifier the (provider, sub) account-takeover
    # guard binds on (see the Emisar.SSO moduledoc). An Ecto.Enum, NOT free text, so
    # a manage_sso admin can't point it at a mutable/forgeable claim (email,
    # preferred_username) and re-open the takeover. `sub` is OIDC-standard; `oid` is
    # Microsoft Entra's immutable object id.
    field :identifier_claim, Ecto.Enum, values: [:sub, :oid], default: :sub
    field :default_role, Ecto.Enum, values: Auth.Role.all(), default: :viewer
    field :satisfies_mfa, :boolean, default: true
    field :allowed_email_domain, :string
    field :enabled, :boolean, default: false

    field :scim_enabled, :boolean, default: false
    field :scim_token_prefix, :string
    field :scim_token_hash, :binary, redact: true
    # Last time the IdP's SCIM connector authenticated against us — the "is
    # directory sync actually working?" signal on the connection detail page.
    # Stamped (throttled) on every authenticated SCIM request; nil = never synced.
    field :scim_last_seen_at, :utc_datetime_usec

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end

  @doc "The supported provider kinds, for the config UI's select."
  def kinds, do: @kinds

  @doc """
  True when this provider kind can push SCIM directory sync to emisar's inbound
  SCIM 2.0 endpoint. Google Workspace has no inbound SCIM for a custom app —
  members provision on first sign-in — so its detail page hides the directory-
  sync sections rather than offer a feature that can't connect.
  """
  def supports_scim?(:google_workspace), do: false
  def supports_scim?(kind) when kind in @kinds, do: true

  @doc "The new-user provisioning modes (JIT auto-provision vs manual admin approval), for the config UI's select."
  def provisioners, do: @provisioners
end
