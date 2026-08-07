defmodule Emisar.SSO.Provisioning do
  @moduledoc """
  How a directory-synced member's role and runner access are resolved from the
  groups their identity provider reports.

  Internal to `Emisar.SSO` — not a context, and never reached from the web.
  Both halves of SSO need exactly this: the SCIM wire handlers recompute it
  when a group's membership changes, and the OIDC and admin paths recompute it
  when a mapping changes. These are the private helpers the two halves SHARED,
  which is why Emisar.SSO could not simply be cut into two contexts —
  `.agent/kb/rules/elixir-rejected-context-splits.md` carries the measurement.
  """
  alias Ecto.Multi
  alias Emisar.{Accounts, Crypto, Repo, Users}
  alias Emisar.SSO.{DirectoryGroupMember, GroupRoleMapping}
  alias Emisar.SSO.{GroupRunnerAccessMapping, IdentityProvider, LinkRequest, UserIdentity}
  require Logger
  @sync_role_precedence [:admin, :billing_manager, :operator, :viewer]

  def provider_identities(%IdentityProvider{} = provider) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  # Capture (or refresh) a pending link request. When the email matches an
  # EXISTING account member, the request records them (`matched_user_id`) so an
  # admin can link the IdP identity to that user instead of failing/duplicating
  # — never an auto-merge (C1): the admin's approval is still the gate. The
  # display email is the raw value (helps the admin recognize who's asking); the
  # binding on approval uses the captured id, not the email.
  # A callback already in flight when the connection is deleted would otherwise
  # park a request against a provider that no longer exists — unapprovable the
  # moment it is written, and a browser waiting on a page that never resolves.
  # The delete sweeps the queue; this stops a straggler refilling it.
  def capture_link_request(
        %IdentityProvider{deleted_at: %DateTime{}},
        _id,
        _e,
        _n,
        _claims,
        _source
      ),
      do: {:error, :provider_unavailable}

  def capture_link_request(
        %IdentityProvider{} = provider,
        identifier,
        email,
        full_name,
        claims,
        source
      ) do
    attrs = %{
      provider_identifier: identifier,
      source: source,
      namespace_fingerprint: namespace_fingerprint(provider),
      email: email,
      full_name: full_name,
      claims: claims,
      matched_user_id: matched_member_id(provider, email)
    }

    changeset = LinkRequest.Changeset.create(provider.account_id, provider.id, attrs)

    Multi.new()
    |> put_active_account_lock(provider.account_id)
    # `source` is replaced with the rest. A re-capture of the same identifier from
    # the OTHER namespace describes a different person — it replaces the email,
    # claims and matched user — so leaving the original source behind made the
    # approval stamp the column the request no longer belongs to.
    |> Multi.insert(:request, changeset,
      on_conflict:
        {:replace,
         [
           :email,
           :full_name,
           :claims,
           :matched_user_id,
           :source,
           :namespace_fingerprint,
           :updated_at
         ]},
      conflict_target: [:provider_id, :provider_identifier]
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{request: request}} -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  # Collision variant (for `:jit`/SCIM): park a link request ONLY when the email
  # matches an existing member, so an admin has someone to link to. A non-member
  # collision has no link target — the caller keeps the genuine `:email_taken`
  # (C1). Returns `:captured | :no_match`.
  def capture_member_link(
        %IdentityProvider{} = provider,
        identifier,
        email,
        full_name,
        claims,
        source
      ) do
    if matched_member_id(provider, email) do
      case capture_link_request(provider, identifier, email, full_name, claims, source) do
        {:ok, request} -> {:captured, request}
        {:error, _} -> :no_match
      end
    else
      :no_match
    end
  end

  # The existing account MEMBER an inbound email matches, if any. Restricted to
  # members (never pulls an outsider into the account); a lookup for the admin,
  # not a merge.
  def matched_member_id(%IdentityProvider{} = provider, email) when is_binary(email) do
    with {:ok, user} <- Users.fetch_user_by_email(email),
         %Accounts.Membership{} <- Accounts.peek_sync_membership(provider.account_id, user.id) do
      user.id
    else
      _ -> nil
    end
  end

  def matched_member_id(_provider, _email), do: nil

  def put_active_account_lock(multi, account_id) do
    Multi.run(multi, :active_account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account_id, repo: repo)
    end)
  end

  def provider_runner_access(%IdentityProvider{} = provider) do
    case Accounts.RunnerAccess.from_prefixed_fields(provider, :default_runner) do
      {:ok, access} -> access
      {:error, _reason} -> Accounts.RunnerAccess.none()
    end
  end

  def lock_provider_row!(%IdentityProvider{} = provider, repo \\ Repo) do
    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.by_account_id(provider.account_id)
    |> IdentityProvider.Query.by_id(provider.id)
    |> IdentityProvider.Query.lock_for_update()
    |> repo.fetch!(IdentityProvider.Query)
  end

  # Minting an identity takes the same provider lock a config edit does, so the
  # namespace check and the write that would violate it cannot interleave. The
  # check found no live identity while a callback was mid-flight, the edit
  # committed, and the callback then wrote an identifier from the OLD namespace
  # under the new configuration.
  def put_provider_lock(multi, %IdentityProvider{} = provider) do
    Multi.run(multi, :locked_provider, fn repo, _changes ->
      {:ok, lock_provider_row!(provider, repo)}
    end)
  end

  # Apply the recomputed authorization in one membership transaction. Accounts
  # preserves a human owner role while still reconciling directory-owned runner
  # access, so the owner exception cannot acknowledge a stale broad grant.
  def apply_recomputed_authorization(
        provider,
        role,
        access,
        %Accounts.Membership{} = membership
      ),
      do: Accounts.sync_set_membership_authorization(membership, role, access, provider)

  def apply_recomputed_authorization(_provider, _role, _access, nil),
    do: {:error, :not_found}

  def recompute_role_for_affected(%IdentityProvider{}, []), do: :ok

  def recompute_role_for_affected(%IdentityProvider{} = provider, identities) do
    role_mappings = provider_role_mappings(provider)
    runner_access_mappings = provider_runner_access_mappings(provider)
    group_ids_by_identity = group_ids_by_identity(identities)
    user_ids = Enum.map(identities, & &1.user_id)

    membership_by_user =
      Map.new(Accounts.list_sync_memberships(provider.account_id, user_ids), &{&1.user_id, &1})

    Enum.each(membership_by_user, fn {_user_id, membership} ->
      if is_integer(membership.directory_authorization_pending_version) do
        Accounts.refresh_directory_authorization_sessions(membership)
      end
    end)

    Enum.each(identities, fn identity ->
      group_ids = Map.get(group_ids_by_identity, identity.id, [])
      role = highest_role_for_groups(group_ids, role_mappings) || provider.default_role
      access = effective_runner_access(provider, group_ids, runner_access_mappings)
      membership = Map.get(membership_by_user, identity.user_id)

      case apply_recomputed_authorization(provider, role, access, membership) do
        {:ok, _membership} ->
          :ok

        # #5: a refused/failed role change (e.g. :last_owner) must not vanish.
        # The group push still succeeds (correct SCIM posture — the guard held
        # the role), but the skipped change is logged for the operator.
        other ->
          Logger.warning(
            "SSO group role recompute skipped: identity=#{identity.id} provider=#{provider.id} reason=#{inspect(other)}"
          )
      end
    end)
  end

  # All the affected identities' synced group ids in ONE query, grouped by
  # identity — replaces the per-identity `identity_group_ids/1` (the N+1 on a
  # SCIM Groups reconcile, where the affected set can be hundreds).
  def group_ids_by_identity(identities) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_user_identity_ids(Enum.map(identities, & &1.id))
    |> Repo.all()
    |> Enum.group_by(& &1.user_identity_id, & &1.external_group_id)
  end

  def provider_role_mappings(%IdentityProvider{} = provider) do
    GroupRoleMapping.Query.not_deleted()
    |> GroupRoleMapping.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  def provider_runner_access_mappings(%IdentityProvider{} = provider) do
    GroupRunnerAccessMapping.Query.not_deleted()
    |> GroupRunnerAccessMapping.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  def effective_runner_access(provider, group_ids, mappings) do
    group_access =
      mappings
      |> Enum.filter(&(&1.external_group_id in group_ids))
      |> Enum.map(&runner_access_mapping_access/1)

    Accounts.RunnerAccess.union([provider_runner_access(provider) | group_access])
  end

  def runner_access_mapping_access(%GroupRunnerAccessMapping{} = mapping) do
    case Accounts.RunnerAccess.from_prefixed_fields(mapping, :runner) do
      {:ok, access} -> access
      {:error, _reason} -> Accounts.RunnerAccess.none()
    end
  end

  # The most-privileged mapped role over a set of group ids.
  def highest_role_for_groups(group_ids, mappings) do
    roles =
      mappings
      |> Enum.filter(&(&1.external_group_id in group_ids))
      |> Enum.map(& &1.role)

    Enum.find(@sync_role_precedence, &(&1 in roles))
  end

  def current_group_members(%IdentityProvider{} = provider, external_group_id) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_provider_and_group(provider.id, external_group_id)
    |> Repo.all()
  end

  def load_identities(%IdentityProvider{}, []), do: []

  def load_identities(%IdentityProvider{} = provider, identity_ids) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_ids(Enum.uniq(identity_ids))
    |> Repo.all()
  end

  def bump_provider_authorization_version(%IdentityProvider{} = provider) do
    provider
    |> Ecto.Changeset.change()
    |> IdentityProvider.Changeset.bump_authorization_version(provider.authorization_version)
    |> Repo.update()
  end

  # The connection's identity namespace, as one comparable value. Approval checks
  # it under the provider lock, so a request made under a different issuer, client
  # or identifier claim cannot be approved against this one — including a request
  # inserted by a callback that was already in flight when the change committed,
  # which the delete alongside that change cannot reach.
  def namespace_fingerprint(%IdentityProvider{} = provider) do
    Crypto.hash_hex("#{provider.issuer}\n#{provider.client_id}\n#{provider.identifier_claim}")
  end
end
