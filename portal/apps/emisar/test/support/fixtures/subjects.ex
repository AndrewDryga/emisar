defmodule Emisar.Fixtures.Subjects do
  @moduledoc """
  Auth-subject test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Subjects.subject_for/2`.
  """

  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Auth.{Subject, UserToken}
  alias Emisar.{Crypto, Fixtures, Repo, RequestContext, SSO}

  @doc """
  Builds the `%Subject{}` a live session gives `membership`: its Member acting
  in its workspace, through one real session row. The row is inserted (see
  `Fixtures.Auth.create_session_token!/5`) unless `:session` passes an existing
  one, as a raw token or a `%UserToken{}`. The Subject is built from the row
  and the Member as stored, without requiring the per-request predicate to
  pass, so a denial test arranges a removed, suspended or otherwise dead
  Member and still fails at use, where the context re-reads the session.

  Options: `:auth_method` (`:magic_link` by default, or `:sso` with
  `:user_identity_id`), `:mfa` (stamp the session's second factor now; a local
  proof counts only for an enrolled Member, an IdP one only while the provider
  satisfies MFA), `:session` and `:context`.

      member = Fixtures.Memberships.create_membership(account_id: account.id, role: :admin)
      subject = Fixtures.Subjects.subject_for(member)
  """
  def subject_for(%Membership{} = membership, opts \\ []) do
    context = opts[:context] || %RequestContext{}
    session = session_for(membership, opts)

    membership = Repo.reload!(membership)
    account = Repo.get!(Account, membership.account_id)

    identity =
      if session.user_identity_id do
        identity = Repo.get!(SSO.UserIdentity, session.user_identity_id)
        %{identity | provider: Repo.get!(SSO.IdentityProvider, identity.provider_id)}
      end

    Subject.for_session(
      %{session | membership: %{membership | account: account}, user_identity: identity},
      context
    )
  end

  defp session_for(membership, opts) do
    case opts[:session] do
      %UserToken{id: id} ->
        Repo.get!(UserToken, id)

      raw when is_binary(raw) ->
        UserToken.Query.by_token_digest(Crypto.hash(raw)) |> Repo.one!()

      nil ->
        method = Keyword.get(opts, :auth_method, :magic_link)
        mfa_at = if opts[:mfa], do: DateTime.utc_now()
        raw = Fixtures.Auth.create_session_token!(membership, method, mfa_at, %{}, opts)
        UserToken.Query.by_token_digest(Crypto.hash(raw)) |> Repo.one!()
    end
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

  @doc "Builds a bare `%Subject{}` from keyword fields — `:member` sets the `actor`, other keys map straight onto the struct."
  def build_subject(fields \\ []) do
    fields =
      case Keyword.pop(fields, :member) do
        {%Membership{} = member, rest} -> Keyword.put(rest, :actor, member)
        {nil, rest} -> rest
      end

    struct!(Subject, fields)
  end

  @doc """
  An account with its owner: returns `{owner_member, account, subject}`. The
  owner is a verified Member with every runner, the account gets the default
  policy, and a non-"free" `:plan` in `account_attrs` mints a matching
  subscription (plan lives on the subscription, not the account).
  """
  def owner_subject(account_attrs \\ %{}) do
    account = Fixtures.Accounts.create_account(account_attrs)

    owner =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        role: "owner",
        runner_access_mode: "all"
      )

    {:ok, _policy} = Emisar.Policies.seed_policy(account.id, owner.id)
    {owner, account, subject_for(owner)}
  end
end
