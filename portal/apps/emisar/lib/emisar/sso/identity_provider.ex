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
  alias Emisar.SSO.ProviderKind

  @runner_access_modes Emisar.Accounts.RunnerAccess.modes()

  schema "sso_identity_providers" do
    field :kind, Ecto.Enum, values: ProviderKind.all()
    field :provisioner, Ecto.Enum, values: [:jit, :manual], default: :jit
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
    # The raw `"group:<name>"` / `"runner:<id>"` picker selection — the only
    # accepted way to set the two arrays above, so a rejected submission still
    # renders what the operator chose.
    field :default_runner_scope, {:array, :string}, virtual: true
    field :authorization_version, :integer, default: 0
    field :satisfies_mfa, :boolean, default: false
    field :allowed_email_domain, :string
    field :enabled, :boolean, default: false

    field :scim_enabled, :boolean, default: false
    field :scim_token_prefix, :string
    field :scim_token_hash, :binary, redact: true
    # Last time the IdP's SCIM connector authenticated against us — the "is
    # directory sync actually working?" signal on the connection detail page.
    # Stamped (throttled) on every authenticated SCIM request; nil = never synced.
    field :scim_last_seen_at, :utc_datetime_usec
    # When this connection's directory first pushed groups since sync was turned
    # on. Nil means no snapshot has arrived, which is NOT the same as "everyone
    # is in no groups" — the role recompute must not act on the difference.
    field :scim_groups_synced_at, :utc_datetime_usec

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end
end
