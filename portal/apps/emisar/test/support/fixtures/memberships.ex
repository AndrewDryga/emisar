defmodule Emisar.Fixtures.Memberships do
  @moduledoc """
  Membership test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Memberships.create_membership/1`.
  """

  alias Emisar.Accounts.Membership
  alias Emisar.{Fixtures, Repo}

  @doc """
  Creates a membership. Caller supplies `:account_id` and `:user_id` (or
  the helper will create both as defaults).
  """
  def create_membership(attrs \\ %{}) do
    attrs = Map.new(attrs)

    account_id =
      attrs[:account_id] || Fixtures.Accounts.create_account().id

    user_id =
      attrs[:user_id] || Fixtures.Users.create_user().id

    params =
      %{
        account_id: account_id,
        user_id: user_id,
        role: attrs[:role] || "operator"
      }
      |> Map.merge(Map.take(attrs, [:invited_by_id, :invitation_token_digest]))

    {:ok, m} = params |> Membership.Changeset.create() |> Repo.insert()
    m
  end

  @doc """
  Test-only role override. Production code MUST go through
  `Accounts.update_membership_role/3` with a `%Subject{}`. This bypasses
  the last-owner / self-promotion / role-hierarchy guards, which exist
  to protect humans — fine to ignore in fixtures that rig a state
  directly.
  """
  def force_role(%Membership{} = membership, role) when is_binary(role) do
    {:ok, updated} =
      membership
      |> Membership.Changeset.update(%{role: role})
      |> Repo.update()

    updated
  end

  @doc """
  Test inspector: the membership joining `account_id` + `user_id`, or
  `nil`. Lets a test read post-mutation membership state without the
  production context exposing a fixture-only lookup.
  """
  def fetch_membership(account_id, user_id) do
    Membership.Query.all()
    |> Membership.Query.by_account_and_user(account_id, user_id)
    |> Repo.peek()
  end
end
