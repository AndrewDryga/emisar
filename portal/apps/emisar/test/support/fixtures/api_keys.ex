defmodule Emisar.Fixtures.ApiKeys do
  @moduledoc """
  API key test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.ApiKeys.create_api_key/1`.
  """

  alias Emisar.Accounts.Account
  alias Emisar.{ApiKeys, Fixtures, Repo, Users}

  @doc """
  Creates an API key. Returns `{raw, key}`.
  """
  def create_api_key(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    user_id = attrs[:created_by_id] || Fixtures.Users.create_user().id

    create_attrs =
      %{
        name: attrs[:name] || "key-#{Fixtures.Random.unique_int()}",
        description: attrs[:description],
        kind: attrs[:kind] || :mcp,
        expires_at: attrs[:expires_at]
      }

    account =
      Account.Query.not_deleted()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch!(Account.Query)

    {:ok, user} = Users.fetch_user_by_id(user_id)

    membership =
      Fixtures.Memberships.fetch_membership(account.id, user.id) ||
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

    subject = Fixtures.Subjects.membership_subject(membership)
    {:ok, raw, key} = ApiKeys.create_key(create_attrs, subject)
    {raw, key}
  end

  @doc """
  Forges a rotation back-link directly on the row — the production paths can
  only mint same-account links, so tests use this to prove the retirement
  sweep's own scoping holds even against a corrupted link.
  """
  def force_replaces(%ApiKeys.ApiKey{} = key, replaced_id) do
    key |> Ecto.Changeset.change(replaces_id: replaced_id) |> Repo.update!()
  end

  @doc "Forges an unbound row so auth tests cover fail-closed legacy data."
  def force_membership_unbound(%ApiKeys.ApiKey{} = key) do
    key |> Ecto.Changeset.change(created_by_membership_id: nil) |> Repo.update!()
  end
end
