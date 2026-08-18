defmodule Emisar.SSO.UserIdentity.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.UserIdentity

  @fields ~w[provider_identifier claims created_by provisioned_via scim_external_id scim_active]a

  # Both columns are varchar(255) and the IdP supplies both, so bound them here
  # rather than letting an oversized externalId surface as a Postgres error.
  @identifier_max_length 255

  def create(account_id, provider_id, user_id, attrs) do
    %UserIdentity{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> put_change(:user_id, user_id)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> validate_required([
      :account_id,
      :provider_id,
      :user_id,
      :provider_identifier,
      :created_by,
      :provisioned_via
    ])
    |> validate_length(:provider_identifier, max: @identifier_max_length, count: :codepoints)
    |> validate_length(:scim_external_id, max: @identifier_max_length, count: :codepoints)
    |> unique_constraint([:account_id, :provider_id, :provider_identifier],
      name: :sso_user_identities_provider_identifier_index
    )
    |> unique_constraint([:account_id, :provider_id, :scim_external_id],
      name: :sso_user_identities_scim_external_id_index
    )
    |> unique_constraint(:user_id,
      name: :sso_user_identities_live_user_index,
      message: "already has an identity for this connection"
    )
  end

  def touch_last_seen(%UserIdentity{} = identity),
    do: change(identity, last_seen_at: DateTime.utc_now())

  @doc """
  Take directory ownership of an identity that arrived through OIDC first.

  Such an identity carries a `provider_identifier` but no `scim_external_id`. A
  SCIM `POST /Users` may reuse it by identifier. Stamping the directory's
  `externalId` preserves reconciliation, filtering, and OIDC correlation even
  if the login identifier is later rebound. Resource routes use the identity's
  server-assigned `id`.
  """
  def adopt_scim_external_id(%UserIdentity{} = identity, external_id) do
    identity
    |> change(scim_external_id: external_id)
    |> validate_length(:scim_external_id, max: @identifier_max_length, count: :codepoints)
    |> unique_constraint([:account_id, :provider_id, :scim_external_id],
      name: :sso_user_identities_scim_external_id_index
    )
  end

  @doc """
  Point a live identity at a new provider identifier.

  An approved link request means an admin confirmed that the identifier a login
  presented is this member. When they already hold an identity for the connection
  — the directory provisioned them under its own `externalId`, or the IdP rotated
  their `sub` — that one identity is rebound instead of a second being created.
  `scim_external_id` is deliberately untouched: it is the IdP-owned correlation
  value used by repeated creates and filters, and must survive an OIDC identifier
  rebind.
  """
  def rebind_provider_identifier(%UserIdentity{} = identity, identifier, claims) do
    identity
    |> change(provider_identifier: identifier, claims: claims, last_seen_at: DateTime.utc_now())
    |> validate_required([:provider_identifier])
    |> validate_length(:provider_identifier, max: @identifier_max_length, count: :codepoints)
    |> unique_constraint([:account_id, :provider_id, :provider_identifier],
      name: :sso_user_identities_provider_identifier_index
    )
  end

  @doc "Flip the SCIM lifecycle flag (provision/deprovision), independent of the membership's `disabled_at`."
  def set_scim_active(%UserIdentity{} = identity, active) when is_boolean(active),
    do: change(identity, scim_active: active)
end
