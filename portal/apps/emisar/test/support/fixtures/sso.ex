defmodule Emisar.Fixtures.SSO do
  @moduledoc """
  SSO test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.SSO.create_identity_provider/1`.
  """

  alias Emisar.Repo
  alias Emisar.SSO.{IdentityProvider, UserIdentity}

  @runner_scope_fields [
    :default_runner_access_mode,
    :default_runner_scope_groups,
    :default_runner_scope_runner_ids
  ]

  @doc """
  Creates an identity provider (enabled by default). Returns the provider.

  The default runner-access mode and scope arrays are written directly: `SSO`
  derives them from a raw picker selection allowlisted against the account's
  live runners, which is the write path under test, not a way to rig the state
  it starts from.
  """
  def create_identity_provider(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Emisar.Fixtures.Accounts.create_account().id
    {scope, attrs} = Map.split(attrs, @runner_scope_fields)

    provider_attrs =
      Map.merge(
        %{
          kind: :okta,
          name: "Okta #{Emisar.Fixtures.Random.unique_int()}",
          # Unique per call so a test can mint several providers on one account
          # without tripping the per-account issuer/client_id uniqueness.
          issuer: "https://idp-#{Emisar.Fixtures.Random.unique_int()}.test",
          client_id: "cid-#{Emisar.Fixtures.Random.unique_int()}",
          client_secret: "secret",
          enabled: true,
          default_role: :viewer
        },
        Map.delete(attrs, :account_id)
      )

    {:ok, provider} =
      account_id
      |> IdentityProvider.Changeset.create(provider_attrs)
      |> Ecto.Changeset.change(scope)
      |> Repo.insert()

    provider
  end

  @doc "Enables SCIM state directly for tests that exercise later directory transitions."
  def enable_scim(%IdentityProvider{} = provider) do
    prefix = "emsp_#{Emisar.Fixtures.Random.unique_int()}"

    provider
    |> IdentityProvider.Changeset.scim_token(prefix, "digest", true)
    |> Repo.update!()
  end

  @doc """
  Binds a user to a provider. Defaults to an OIDC-created identity (a
  `provider_identifier`, no `scim_external_id`); pass `:scim_external_id` for a
  directory-provisioned one. Returns the identity.
  """
  def create_user_identity(attrs) do
    attrs = Map.new(attrs)

    identity_attrs =
      Map.merge(
        %{
          provider_identifier: "sub-#{Emisar.Fixtures.Random.unique_int()}",
          created_by: :provider,
          provisioned_via: :oidc_jit
        },
        Map.drop(attrs, [:account_id, :provider_id, :user_id])
      )

    {:ok, identity} =
      attrs.account_id
      |> UserIdentity.Changeset.create(attrs.provider_id, attrs.user_id, identity_attrs)
      |> Repo.insert()

    identity
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
