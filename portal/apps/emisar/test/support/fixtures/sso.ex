defmodule Emisar.Fixtures.SSO do
  @moduledoc """
  SSO test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.SSO.create_identity_provider/1`.
  """

  alias Emisar.Repo
  alias Emisar.SSO.IdentityProvider

  @doc """
  Creates an identity provider (enabled by default). Returns the provider.
  """
  def create_identity_provider(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Emisar.Fixtures.Accounts.create_account().id

    provider_attrs =
      Map.merge(
        %{
          kind: :okta,
          name: "Okta #{Emisar.Fixtures.Random.unique_int()}",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true,
          default_role: :viewer
        },
        Map.delete(attrs, :account_id)
      )

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account_id, provider_attrs))
    provider
  end

  @doc """
  Creates a pending manual-link (access) request against a provider. Pass a
  `:provider`, or an `:account_id` (a provider is minted on it). Returns the request.
  """
  def create_link_request(attrs \\ %{}) do
    attrs = Map.new(attrs)

    provider =
      attrs[:provider] ||
        create_identity_provider(if(id = attrs[:account_id], do: %{account_id: id}, else: %{}))

    request_attrs =
      Map.merge(
        %{
          provider_identifier: "sub-#{Emisar.Fixtures.Random.unique_int()}",
          email: "pending#{Emisar.Fixtures.Random.unique_int()}@example.com",
          full_name: "Pending Person"
        },
        Map.drop(attrs, [:account_id, :provider])
      )

    {:ok, request} =
      Repo.insert(
        Emisar.SSO.LinkRequest.Changeset.create(provider.account_id, provider.id, request_attrs)
      )

    request
  end
end
