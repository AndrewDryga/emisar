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
      name: :user_identities_provider_identifier_index
    )
    |> unique_constraint([:account_id, :provider_id, :scim_external_id],
      name: :user_identities_scim_external_id_index
    )
  end

  def touch_last_seen(%UserIdentity{} = identity),
    do: change(identity, last_seen_at: DateTime.utc_now())

  @doc "Flip the SCIM lifecycle flag (provision/deprovision), independent of the membership's `disabled_at`."
  def set_scim_active(%UserIdentity{} = identity, active) when is_boolean(active),
    do: change(identity, scim_active: active)
end
