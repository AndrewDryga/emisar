defmodule Emisar.Auth.SessionGrants do
  @moduledoc false

  alias Ecto.Multi
  alias Emisar.{Accounts, Auth, Repo, SSO, Users}
  alias Emisar.Auth.{MemberGrant, MemberGrantRoute, Subject, UserToken}

  def put_personal_authority(multi, user, target_account) do
    multi
    |> Multi.run(:grant_member_candidates, fn _repo, _changes ->
      {:ok, Accounts.list_active_memberships_for_user(user)}
    end)
    |> Multi.run(:grant_accounts, fn repo, %{grant_member_candidates: members} ->
      account_ids = Enum.map(members, & &1.account_id)
      account_ids = if target_account, do: [target_account.id | account_ids], else: account_ids
      Accounts.fetch_and_lock_session_accounts(account_ids, repo)
    end)
    |> Multi.run(:sign_in_account, fn _repo, %{grant_accounts: accounts} ->
      if is_nil(target_account) or Map.has_key?(accounts, target_account.id),
        do: {:ok, target_account},
        else: {:error, :account_disabled}
    end)
  end

  def insert_personal(repo, token, changes) do
    candidates =
      Enum.filter(
        changes.grant_member_candidates,
        &Map.has_key?(changes.grant_accounts, &1.account_id)
      )

    members =
      case Map.get(changes, :membership) do
        %Accounts.Membership{} = created -> [created | candidates]
        nil -> candidates
      end

    members
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, []}, fn hint, {:ok, grants} ->
      case Accounts.fetch_and_lock_active_membership(repo, hint.account_id, hint.id) do
        {:ok, member} when member.user_id == token.user_id ->
          with {:ok, grant} <- repo.insert(MemberGrant.Changeset.create(token, member)),
               {:ok, _route} <-
                 repo.insert(
                   MemberGrantRoute.Changeset.personal(
                     grant,
                     token.personal_proved_at,
                     token.personal_expires_at
                   )
                 ) do
            {:cont, {:ok, [grant | grants]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:cont, {:ok, grants}}
      end
    end)
  end

  def insert_sso(repo, token, destinations) do
    proved_at = token.inserted_at
    expires_at = UserToken.Query.session_expires_at(proved_at)

    destinations
    |> Enum.group_by(& &1.membership.id)
    |> Enum.sort_by(fn {member_id, _destinations} -> member_id end)
    |> Enum.reduce_while({:ok, []}, fn {_member_id, [first | _] = routes}, {:ok, grants} ->
      with {:ok, grant} <- repo.insert(MemberGrant.Changeset.create(token, first.membership)),
           :ok <- insert_sso_routes(repo, grant, routes, proved_at, expires_at) do
        {:cont, {:ok, [grant | grants]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_sso_routes(repo, grant, routes, proved_at, expires_at) do
    Enum.reduce_while(routes, :ok, fn route, :ok ->
      changeset =
        MemberGrantRoute.Changeset.sso(
          grant,
          route.identity,
          route.direct?,
          route.mfa?,
          proved_at,
          expires_at
        )

      case repo.insert(changeset) do
        {:ok, _proof} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def account_ids(token_id) do
    MemberGrant.Query.by_token_id(token_id)
    |> MemberGrant.Query.select_account_ids()
    |> Repo.all()
  end

  # Moves every donor grant to the replacement and returns only the destinations
  # this SSO proof refreshed; the other moved grants keep their original proof.
  def transfer_for_sso_step_up(repo, donor, replacement, destinations) do
    eligible_members = MapSet.new(membership_ids(donor))
    proved_at = replacement.inserted_at
    expires_at = UserToken.Query.session_expires_at(proved_at)

    MemberGrant.Query.by_token_id(donor.id)
    |> MemberGrant.Query.ordered_by_id()
    |> MemberGrant.Query.lock_for_update()
    |> repo.all()
    |> Enum.reduce_while({:ok, []}, fn grant, {:ok, refreshed} ->
      fresh_routes =
        Enum.filter(destinations, fn destination ->
          MapSet.member?(eligible_members, grant.membership_id) and
            destination.membership.id == grant.membership_id and
            destination.membership.account_id == grant.account_id
        end)

      # Never restamp or filter old routes by current workspace policy. A
      # disabled account can recover, while expired/retired proof stays inert.
      with {:ok, transferred} <-
             repo.update(MemberGrant.Changeset.transfer_session(grant, replacement)),
           :ok <- insert_sso_routes(repo, transferred, fresh_routes, proved_at, expires_at) do
        {:cont, {:ok, fresh_routes ++ refreshed}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def membership_ids(session) do
    case session_id(session) do
      nil ->
        []

      token_id ->
        token_id
        |> current_routes()
        |> MemberGrantRoute.Query.select_membership_ids()
        |> Repo.all()
    end
  end

  def subject_options(%Accounts.Membership{} = member, session) do
    case fetch_route(member.account_id, member.id, session) do
      {:ok, route, idp_mfa?} -> options(route, idp_mfa?)
      {:error, :unauthorized} -> []
    end
  end

  # The grant alone resolves authority; the held actor must still be the
  # granted Member's person, so a Subject cannot be re-pointed at another
  # person or borrow a Member it does not hold.
  def fetch_subject(
        %Subject{
          actor: actor,
          account: %Accounts.Account{id: account_id},
          membership_id: member_id,
          member_grant_id: grant_id
        } = subject
      ) do
    with true <- Enum.all?([grant_actor_id(actor), grant_id], &Repo.valid_uuid?/1),
         {:ok, route, idp_mfa?} <- fetch_route(account_id, member_id, subject),
         %Accounts.Membership{} = member <- route.membership,
         true <- holds_member?(actor, member) do
      fresh =
        Subject.for_member(member, member.account, subject.context, options(route, idp_mfa?))

      {:ok, %{fresh | permissions: MapSet.intersection(subject.permissions, fresh.permissions)}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def fetch_subject(%Subject{}), do: {:error, :unauthorized}

  # Only a person holds a session grant: a linked Member's personal login, or a
  # Member without one acting as itself.
  defp grant_actor_id(%Users.User{id: id}), do: id
  defp grant_actor_id(%Accounts.Membership{id: id, user_id: nil}), do: id
  defp grant_actor_id(_actor), do: nil

  # A linked Member acts as its live personal login; a Member without one is
  # its own actor. Two absent logins never read as the same person.
  defp holds_member?(%Users.User{id: id}, %Accounts.Membership{user: %Users.User{id: id}}),
    do: true

  defp holds_member?(
         %Accounts.Membership{id: id, user_id: nil},
         %Accounts.Membership{id: id, user_id: nil}
       ),
       do: true

  defp holds_member?(_actor, _member), do: false

  def ensure_personal_session(%Subject{actor: %Users.User{id: user_id}} = subject) do
    with {:ok, token} <- fetch_token(user_id, subject),
         %DateTime{} <- token.personal_proved_at,
         true <- future?(token.personal_expires_at) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def ensure_personal_session(%Subject{} = subject), do: Subject.personal_denial(subject)

  def fetch_token(user_id, session) do
    with token_id when is_binary(token_id) <- session_id(session),
         true <- Repo.valid_uuid?(user_id) do
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_user_id(user_id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.not_expired("session")
      |> UserToken.Query.with_preloaded_user()
      |> Repo.one()
      |> case do
        %UserToken{user: %Users.User{}} = token -> {:ok, token}
        _ -> {:error, :unauthorized}
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_route(account_id, member_id, session) do
    with token_id when is_binary(token_id) <- session_id(session),
         true <- Enum.all?([account_id, member_id], &Repo.valid_uuid?/1) do
      token_id
      |> current_routes()
      |> MemberGrantRoute.Query.by_account_id(account_id)
      |> MemberGrantRoute.Query.by_membership_id(member_id)
      |> scope_grant(session)
      |> MemberGrantRoute.Query.with_preloaded_authority()
      |> MemberGrantRoute.Query.ordered_by_proof()
      |> Repo.all()
      |> choose_route()
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp scope_grant(query, %Subject{member_grant_id: id}),
    do: MemberGrantRoute.Query.by_grant_id(query, id)

  defp scope_grant(query, %UserToken{}), do: query

  defp choose_route([]), do: {:error, :unauthorized}

  defp choose_route(routes) do
    {route, idp_mfa?} =
      routes
      |> Enum.map(&{&1, idp_mfa_current?(&1)})
      |> Enum.max_by(fn {route, mfa?} -> {route.auth_method == :sso, mfa?} end)

    {:ok, route, idp_mfa?}
  end

  defp idp_mfa_current?(%MemberGrantRoute{idp_mfa_verified_at: nil}), do: false

  defp idp_mfa_current?(%MemberGrantRoute{direct: true, user_identity: identity}),
    do: identity.provider.satisfies_mfa

  defp idp_mfa_current?(%MemberGrantRoute{account_id: account_id, issuer: issuer}),
    do: SSO.issuer_satisfies_mfa_for_account?(issuer, account_id)

  defp options(route, idp_mfa?) do
    token = route.member_grant.user_token
    local_epoch = Auth.session_mfa_enrollment_verified_at(route.membership.user, token)

    [
      session_token_id: token.id,
      member_grant_id: route.member_grant_id,
      auth_method: route.auth_method,
      user_identity_id: route.user_identity_id,
      mfa: not is_nil(local_epoch) or idp_mfa?,
      mfa_enrollment_verified_at: local_epoch
    ]
  end

  defp current_routes(token_id) do
    MemberGrantRoute.Query.by_token_id(token_id)
    |> MemberGrantRoute.Query.current()
  end

  defp session_id(%UserToken{id: id}), do: valid_session_id(id)
  defp session_id(%{session_token_id: id}), do: valid_session_id(id)
  defp session_id(_session), do: nil

  defp valid_session_id(id), do: if(Repo.valid_uuid?(id), do: id)

  defp future?(%DateTime{} = deadline), do: DateTime.after?(deadline, DateTime.utc_now())
  defp future?(_deadline), do: false

  # Do not require current route validity: a role/policy transition must also
  # refresh sockets holding authority that has just become unusable.
  def member_token_digests(member) do
    MemberGrant.Query.by_membership(member.account_id, member.id)
    |> MemberGrant.Query.select_token_digests()
    |> Repo.all()
  end

  def delete_member_grants(repo, member) do
    queryable =
      MemberGrant.Query.by_membership(member.account_id, member.id)
      |> MemberGrant.Query.select_token_digests()

    {count, digests} = repo.delete_all(queryable)
    {:ok, %{count: count, token_digests: Enum.uniq(digests)}}
  end

  def delete_identity_routes(repo, identity_ids) do
    queryable =
      MemberGrantRoute.Query.by_identity_ids(identity_ids)
      |> MemberGrantRoute.Query.select_token_digests()

    {count, digests} = repo.delete_all(queryable)
    {:ok, %{count: count, token_digests: Enum.uniq(digests)}}
  end
end
