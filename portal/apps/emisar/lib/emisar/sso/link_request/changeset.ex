defmodule Emisar.SSO.LinkRequest.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.LinkRequest

  @fields ~w[provider_identifier email full_name claims]a

  @doc "Capture (or refresh) a pending link request for `(provider, sub)` — upserted on the unique index."
  def create(account_id, provider_id, attrs) do
    %LinkRequest{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :provider_identifier])
    |> unique_constraint([:provider_id, :provider_identifier],
      name: :sso_link_requests_provider_identifier_index
    )
  end
end
