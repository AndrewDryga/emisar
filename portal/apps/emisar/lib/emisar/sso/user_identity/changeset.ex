defmodule Emisar.SSO.UserIdentity.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.UserIdentity

  @fields ~w[provider_identifier claims created_by provisioned_via scim_external_id scim_active]a

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
    |> unique_constraint([:account_id, :provider_id, :provider_identifier],
      name: :sso_user_identities_provider_identifier_index
    )
    |> unique_constraint([:account_id, :provider_id, :scim_external_id],
      name: :sso_user_identities_scim_external_id_index
    )
  end

  def touch_last_seen(%UserIdentity{} = identity),
    do: change(identity, last_seen_at: DateTime.utc_now())

  @doc """
  Take directory ownership of an identity that arrived through OIDC first.

  Such an identity carries a `provider_identifier` but no `scim_external_id`. A
  SCIM `POST /Users` reuses it by identifier, but every later `GET`/`PATCH`/
  `DELETE /Users/{id}` looks up by `scim_external_id` — so without this stamp the
  directory could create the member and then never offboard them.
  """
  def adopt_scim_external_id(%UserIdentity{} = identity, external_id) do
    identity
    |> change(scim_external_id: external_id)
    |> unique_constraint([:account_id, :provider_id, :scim_external_id],
      name: :sso_user_identities_scim_external_id_index
    )
  end

  @doc "Flip the SCIM lifecycle flag (provision/deprovision), independent of the membership's `disabled_at`."
  def set_scim_active(%UserIdentity{} = identity, active) when is_boolean(active),
    do: change(identity, scim_active: active)
end
