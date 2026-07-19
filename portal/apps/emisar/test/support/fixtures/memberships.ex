defmodule Emisar.Fixtures.Memberships do
  @moduledoc """
  Membership test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Memberships.create_membership/1`.
  """

  alias Emisar.Accounts.{Membership, MembershipRunnerScope, RunnerAccess}
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
        role: attrs[:role] || "operator",
        runner_access_mode: attrs[:runner_access_mode] || "all"
      }
      |> Map.merge(
        Map.take(attrs, [
          :invited_by_id,
          :invitation_token_digest,
          :directory_managed,
          :runner_access_directory_managed,
          :directory_provider_id,
          :directory_authorization_version,
          :directory_authorization_pending_version
        ])
      )

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
  Test-only runner-access override. Production code MUST go through
  `Accounts.update_membership_runner_access/3`; this helper rigs an existing
  caller's state without exercising nondelegation or emitting an audit event.
  """
  def force_runner_access(%Membership{} = membership, %RunnerAccess{} = access) do
    membership = Repo.reload!(membership)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        Repo,
        "SELECT set_config('emisar.runner_access_write', 'enabled', true)",
        []
      )

    {:ok, updated} =
      membership
      |> Membership.Changeset.update_runner_access(access.mode)
      |> Repo.update()

    MembershipRunnerScope.Query.by_membership_id(membership.id)
    |> Repo.delete_all()

    now = DateTime.utc_now()

    rows =
      Enum.map(RunnerAccess.scope_tuples(access), fn {scope_type, scope_value} ->
        %{
          id: Repo.generate_id(),
          membership_id: membership.id,
          scope_type: scope_type,
          scope_value: scope_value,
          inserted_at: now
        }
      end)

    Repo.insert_all(MembershipRunnerScope, rows)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        Repo,
        "SELECT set_config('emisar.runner_access_write', 'disabled', true)",
        []
      )

    updated
  end

  @doc "Suspends a membership (sets `disabled_at`) directly, returning the updated struct."
  def suspend_membership(%Membership{} = membership) do
    {:ok, suspended} =
      membership
      |> Membership.Changeset.suspend()
      |> Repo.update()

    suspended
  end

  @doc "Soft-deletes a membership, returning the tombstoned row."
  def mark_membership_as_deleted(%Membership{} = membership) do
    {:ok, deleted} =
      membership
      |> Membership.Changeset.delete()
      |> Repo.update()

    deleted
  end

  @doc "Marks a membership directory-managed (the SCIM synced-role lock), as a sync would."
  def mark_directory_managed(%Membership{} = membership) do
    {:ok, managed} =
      membership
      |> Membership.Changeset.sync_role(membership.role)
      |> Repo.update()

    managed
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
