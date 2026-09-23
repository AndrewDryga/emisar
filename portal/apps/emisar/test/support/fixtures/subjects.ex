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
  Builds a `%Subject{}` for an account-scoped test caller with a real frozen
  session grant. Creates an owner membership if the user isn't a member yet.
  Pass an existing `:session` to exercise an older bearer's exact authority;
  use `build_subject/1` for intentionally unbound or malformed callers.

      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      subject = Fixtures.Subjects.subject_for(user, account)
  """
  def subject_for(%User{} = user, account, opts \\ []) do
    role = opts[:role] || :owner
    context = opts[:context] || %RequestContext{}

    membership =
      opts[:membership] ||
        Fixtures.Memberships.fetch_membership(account.id, user.id) ||
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: role
        )

    session = opts[:session] || session_for(user, opts)
    auth_opts = Emisar.Auth.session_subject_options(membership, session)
    Subject.for_user(user, account, membership, context, auth_opts)
  end

  defp session_for(user, opts) do
    method = Keyword.get(opts, :auth_method, :magic_link)
    mfa_at = if opts[:mfa], do: DateTime.utc_now()
    raw = Fixtures.Auth.create_session_token!(user, method, mfa_at, %{}, opts)
    {:ok, _user, token} = Emisar.Auth.fetch_user_and_token_by_session_token(raw)
    token
  end

  @doc "Builds a `%Subject{}` for an existing membership — loads its user and account, carrying the membership's own role and id."
  def membership_subject(%Membership{} = membership) do
    %{user: user, account: account} = Repo.preload(membership, [:user, :account])
    session = session_for(user, [])
    auth_opts = Emisar.Auth.session_subject_options(membership, session)
    Subject.for_user(user, account, membership, %RequestContext{}, auth_opts)
  end

  @doc """
  Subject carrying no permissions at all — the denial-test caller for
  surfaces where every real membership role holds the permission being
  checked. No production constructor builds such a subject; the struct is
  assembled directly so the refusal branch stays exercised.
  """
  def permissionless_subject(account) do
    build_subject(account: account, role: :viewer, permissions: MapSet.new())
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
