defmodule Emisar.Auth.MemberGrantRoute.Query do
  use Emisar, :query
  alias Emisar.{Accounts, Auth, SSO, Users}
  alias Emisar.Auth.MemberGrantRoute

  def all, do: from(routes in MemberGrantRoute, as: :grant_routes)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [grant_routes: r], r.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [grant_routes: r], r.account_id == ^account_id)

  def by_membership_id(queryable \\ all(), membership_id),
    do: where(queryable, [grant_routes: r], r.membership_id == ^membership_id)

  def by_grant_id(queryable, grant_id),
    do: where(queryable, [grant_routes: r], r.member_grant_id == ^grant_id)

  def by_identity_ids(queryable \\ all(), identity_ids),
    do: where(queryable, [grant_routes: r], r.user_identity_id in ^identity_ids)

  def with_joined_grant(queryable) do
    with_named_binding(queryable, :member_grants, fn queryable, binding ->
      join(queryable, :inner, [grant_routes: r], grant in assoc(r, :member_grant), as: ^binding)
    end)
  end

  def with_joined_token(queryable) do
    queryable
    |> with_joined_grant()
    |> Auth.MemberGrant.Query.with_joined_token()
  end

  def by_token_id(queryable \\ all(), token_id) do
    queryable
    |> with_joined_grant()
    |> where([member_grants: g], g.user_token_id == ^token_id)
  end

  def by_token_user_id(queryable, user_id) do
    queryable
    |> with_joined_token()
    |> where([grant_token: t], t.user_id == ^user_id)
  end

  # Every predicate judges the presented token and its frozen destination in
  # one snapshot. No origin identity or current membership discovery can widen
  # this set, and an expired/deleted bearer cannot keep a held Subject alive.
  def current(queryable \\ all()) do
    live_tokens =
      Auth.UserToken.Query.by_context("session")
      |> Auth.UserToken.Query.not_expired("session")

    queryable
    |> with_joined_token()
    |> where([grant_token: t], t.id in subquery(select(live_tokens, [tokens: t], t.id)))
    |> join(:inner, [member_grants: g], member in ^Accounts.Membership.Query.authorized(),
      as: :route_member,
      on: member.account_id == g.account_id and member.id == g.membership_id
    )
    |> join(:inner, [route_member: m], account in ^Accounts.Account.Query.active(),
      as: :route_account,
      on: account.id == m.account_id
    )
    |> join(:inner, [grant_token: t], user in ^Users.User.Query.not_deleted(),
      as: :route_user,
      on: user.id == t.user_id
    )
    |> join(:left, [grant_routes: r], identity in ^SSO.UserIdentity.Query.not_deleted(),
      as: :route_identity,
      on: identity.id == r.user_identity_id
    )
    |> join(:left, [route_identity: i], provider in ^SSO.IdentityProvider.Query.not_deleted(),
      as: :route_provider,
      on: provider.id == i.provider_id and provider.account_id == i.account_id
    )
    |> where(
      [grant_routes: r, grant_token: t, route_member: m, route_identity: i, route_provider: p],
      r.expires_at > from_now(0, "second") and m.user_id == t.user_id and
        ((r.auth_method == :magic_link and t.personal_expires_at > from_now(0, "second")) or
           (r.auth_method == :sso and i.account_id == r.account_id and
              i.membership_id == r.membership_id and i.user_id == t.user_id and
              is_nil(i.provider_identifier_retired_at) and
              i.provider_identifier == r.provider_identifier and p.enabled and
              p.issuer == r.issuer))
    )
  end

  def with_preloaded_authority(queryable) do
    preload(
      queryable,
      [
        member_grants: g,
        grant_token: t,
        route_member: m,
        route_account: a,
        route_user: u,
        route_identity: i,
        route_provider: p
      ],
      member_grant: {g, user_token: t},
      membership: {m, account: a, user: u},
      user_identity: {i, provider: p}
    )
  end

  def select_membership_ids(queryable),
    do: queryable |> select([grant_routes: r], r.membership_id) |> distinct(true)

  def select_account_ids(queryable),
    do: queryable |> select([grant_routes: r], r.account_id) |> distinct(true)

  def select_token_digests(queryable) do
    queryable
    |> with_joined_token()
    |> select([grant_token: t], t.token)
  end

  def ordered_by_proof(queryable),
    do: order_by(queryable, [grant_routes: r], desc: r.proved_at, asc: r.id)
end
