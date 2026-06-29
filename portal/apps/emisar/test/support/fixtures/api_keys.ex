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
        scopes: attrs[:scopes] || ["actions:read", "actions:execute"],
        runner_filter: attrs[:runner_filter] || [],
        expires_at: attrs[:expires_at]
      }

    account =
      Account.Query.not_deleted()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch!(Account.Query)

    {:ok, user} = Users.fetch_user_by_id(user_id)
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, key} = ApiKeys.create_key(create_attrs, subject)
    {raw, key}
  end
end
