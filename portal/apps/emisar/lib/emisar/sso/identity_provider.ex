defmodule Emisar.SSO.IdentityProvider do
  @moduledoc """
  A per-account OIDC identity provider (relying-party connection). One live,
  enabled provider per `(account, kind)`; an `allowed_email_domain`, if set,
  refuses any sign-in whose IdP-verified domain doesn't match (unique per
  enabled provider). `client_secret` is stored plaintext +
  redacted, like every emisar secret — at-rest protection is infra-level.
  """
  use Emisar, :schema
  alias Emisar.Auth

  @kinds [:google_workspace, :okta, :jumpcloud, :keycloak, :openid_connect]
  @provisioners [:jit, :manual]
  @runner_access_modes Emisar.Accounts.RunnerAccess.modes()

  schema "sso_identity_providers" do
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

    field :default_runner_access_mode, Ecto.Enum,
      values: @runner_access_modes,
      default: :none

    field :default_runner_scope_groups, {:array, :string}, default: []
    field :default_runner_scope_runner_ids, {:array, Ecto.UUID}, default: []
    field :authorization_version, :integer, default: 0
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
  SCIM 2.0 endpoint. Two kinds can't, and their detail pages hide the directory-
  sync sections rather than offer a feature that cannot connect: Google Workspace
  has no inbound SCIM for a custom app, and Keycloak ships no outbound SCIM client
  (its own SCIM Realm API provisions INTO Keycloak). Both provision members on
  first sign-in instead. A Keycloak fronted by a third-party SCIM extension is
  configured as `:openid_connect`, which keeps the sync surface.
  """
  def supports_scim?(kind) when kind in [:google_workspace, :keycloak], do: false
  def supports_scim?(kind) when kind in @kinds, do: true

  @doc "The new-user provisioning modes (JIT auto-provision vs manual admin approval), for the config UI's select."
  def provisioners, do: @provisioners
end
