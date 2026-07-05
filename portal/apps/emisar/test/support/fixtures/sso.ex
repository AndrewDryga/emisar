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
end
