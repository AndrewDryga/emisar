defmodule Emisar.Fixtures.Subjects do
  @moduledoc """
  Auth-subject test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Subjects.subject_for/3`.
  """

  alias Emisar.Accounts
  alias Emisar.Accounts.Membership
  alias Emisar.Auth.Subject
  alias Emisar.{Fixtures, Repo, RequestContext}
  alias Emisar.Users.User

  @doc """
  Builds a `%Subject{}` for an account-scoped test caller. Looks up
  the user's membership in the account; defaults to `:owner` if the
  user isn't a member yet. Use this anywhere a test needs to call a
  Subject-gated context function.

      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      subject = Fixtures.Subjects.subject_for(user, account)
  """
  def subject_for(%User{} = user, account, opts \\ []) do
    role = opts[:role] || :owner
    context = opts[:context] || %RequestContext{}

    membership =
      Fixtures.Memberships.fetch_membership(account.id, user.id) ||
        %Membership{role: Atom.to_string(role), user_id: user.id, account_id: account.id}

    Subject.for_user(user, account, membership, context,
      auth_method: opts[:auth_method],
      mfa: opts[:mfa],
      user_identity_id: opts[:user_identity_id]
    )
  end

  @doc "Builds a `%Subject{}` for an existing membership — loads its user and account, carrying the membership's own role and id."
  def membership_subject(%Membership{} = membership) do
    %{user: user, account: account} = Repo.preload(membership, [:user, :account])
    Subject.for_user(user, account, membership)
  end

  @doc "Builds a bare `%Subject{}` from keyword fields — `:user` sets the `actor`, other keys map straight onto the struct."
  def build_subject(fields \\ []) do
    fields =
      case Keyword.pop(fields, :user) do
        {%User{} = user, rest} -> Keyword.put(rest, :actor, user)
        {nil, rest} -> rest
      end

    struct!(Subject, fields)
  end

  @doc """
  Subject for a fresh user + account pair as the account owner. A non-"free"
  `:plan` in `account_attrs` mints a matching subscription (plan lives on the
  subscription, not the account).
  """
  def owner_subject(account_attrs \\ %{}) do
    user = Fixtures.Users.create_user()
    {plan, account_attrs} = Fixtures.Accounts.pop_plan(account_attrs)

    base = %{
      name: Fixtures.Random.unique_account_name(),
      slug: Fixtures.Random.unique_slug()
    }

    {:ok, account} =
      Accounts.create_account_with_owner(Map.merge(base, account_attrs), user)

    Fixtures.Accounts.maybe_seed_plan(account, plan)
    subject = subject_for(user, account, role: :owner)
    {user, account, subject}
  end
end
