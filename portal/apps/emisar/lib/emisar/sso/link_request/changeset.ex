defmodule Emisar.SSO.LinkRequest.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.LinkRequest

  @fields ~w[provider_identifier source namespace_fingerprint email full_name claims matched_membership_id]a

  # The IdP supplies all three and each column is varchar(255), so an oversized
  # claim is refused here rather than surfacing as a Postgres error.
  @max_length 255

  @doc "Capture (or refresh) a pending link request for `(provider, sub)` — upserted on the unique index."
  def create(account_id, provider_id, attrs) do
    %LinkRequest{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :provider_identifier, :source])
    |> validate_length(:provider_identifier, max: @max_length, count: :codepoints)
    |> validate_length(:email, max: @max_length, count: :codepoints)
    |> validate_length(:full_name, max: @max_length, count: :codepoints)
    |> foreign_key_constraint(:matched_membership_id,
      name: :sso_link_requests_membership_account_fkey
    )
    |> unique_constraint([:provider_id, :provider_identifier],
      name: :sso_link_requests_provider_identifier_index
    )
  end
end
