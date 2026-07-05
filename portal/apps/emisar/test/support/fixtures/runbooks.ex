defmodule Emisar.Fixtures.Runbooks do
  @moduledoc """
  Runbook test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runbooks.create_runbook/1`.
  """

  alias Emisar.{Fixtures, Repo}
  alias Emisar.Runbooks.Runbook

  @doc """
  Persists a draft runbook. Caller supplies `:account_id` (or the helper makes
  a fresh account) and may override `:title`/`:created_by_id`.
  """
  def create_runbook(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    created_by_id = attrs[:created_by_id] || Fixtures.Users.create_user().id
    title = attrs[:title] || "Runbook #{Fixtures.Random.unique_int()}"

    {:ok, runbook} =
      account_id
      |> Runbook.Changeset.create(created_by_id, %{
        name: attrs[:name] || "runbook-#{Fixtures.Random.unique_int()}",
        slug: attrs[:slug] || "runbook-#{Fixtures.Random.unique_int()}",
        title: title,
        definition: attrs[:definition] || %{"steps" => []}
      })
      |> Repo.insert()

    runbook
  end
end
