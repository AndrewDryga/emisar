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
    |> UserIdentity.Query.scim_not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  @doc """
  Internal — compose one current-provider pending-link upsert into SSO's
  transaction. The request records the one live Member whose workspace contact
  the trusted email names, so approval links the identity to that Member — never
  an auto-merge (C1): the admin's approval is still the gate. An email that names
  two or more Members is refused as ambiguous. The display email is the raw value
  (it helps the admin recognize who is asking); approval binds the captured id.
  """
  def put_link_request(
        %Multi{} = multi,
        key,
        %IdentityProvider{} = provider,
        identifier,
        email,
        full_name,
        claims,
        source
      ) do
    case member_contact_match(provider, link_match_email(provider, email, claims, source)) do
      :ambiguous ->
        Multi.error(multi, key, :member_email_ambiguous)

      match ->
        attrs = %{
          provider_identifier: identifier,
          source: source,
          namespace_fingerprint: namespace_fingerprint(provider),
          email: email,
          full_name: full_name,
          claims: claims,
          matched_membership_id: matched_membership_id(match)
        }

        insert_link_request(multi, key, provider, attrs)
    end
  end

  defp matched_membership_id({:ok, %Accounts.Membership{id: id}}), do: id
  defp matched_membership_id(:none), do: nil

  defp insert_link_request(multi, key, provider, attrs) do
    changeset = LinkRequest.Changeset.create(provider.account_id, provider.id, attrs)

    # `source` is replaced with the rest. A re-capture of the same identifier from
    # the OTHER namespace describes a different person — it replaces the email,
    # claims and matched member — so leaving the original source behind made the
    # approval stamp the column the request no longer belongs to.
    Multi.insert(multi, key, changeset,
      on_conflict:
        {:replace,
         [
           :email,
           :full_name,
           :claims,
           :matched_membership_id,
           :source,
           :namespace_fingerprint,
           :updated_at
         ]},
      conflict_target: [:provider_id, :provider_identifier],
      returning: true
    )
  end

  # Email participates in OIDC identity only when the ID token explicitly marks
  # it verified. The raw claim remains useful display context on a pending
  # request, but never becomes an account binding or confirmed user address.
  def verified_email(%IdentityProvider{}, %{
        "email" => email,
        "email_verified" => verified
      })
      when is_binary(email) and verified in [true, "true"] do
    case String.trim(email) do
      "" -> nil
      email -> email
    end
  end

  def verified_email(%IdentityProvider{}, _claims), do: nil

  # The directory is authoritative for SCIM email. OIDC email is only display
  # context until the signed token explicitly marks it verified. Keeping the
  # choice here prevents a caller from accidentally supplying raw OIDC email as
  # an account-binding hint.
  defp link_match_email(provider, _email, claims, :oidc),
    do: verified_email(provider, claims)

  defp link_match_email(_provider, email, _claims, :scim), do: email

  # Email is never identity: an inbound address is compared only with this
  # account's own workspace contacts, never with a personal login's address, so a
  # provider can never match another account's members. One live Member is a link
  # target for the admin; two or more are ambiguous; none is a new person.
  def member_contact_match(%IdentityProvider{} = provider, email) when is_binary(email) do
    case Accounts.list_sync_memberships_by_contact_email(provider.account_id, email) do
      [] -> :none
      [%Accounts.Membership{} = member] -> {:ok, member}
      [_first, _second] -> :ambiguous
    end
  end

  def member_contact_match(_provider, _email), do: :none

  # The personal login linked to an identity's preloaded seat, locked. Callers
  # take it before the identity, in membership activation's User -> identity order.
  # A seat without a personal login has no User to lock.
  def lock_seat_user(repo, %UserIdentity{membership: %Accounts.Membership{user_id: user_id}})
      when is_binary(user_id),
      do: Users.fetch_and_lock_user_by_id(user_id, repo)

  def lock_seat_user(_repo, %UserIdentity{membership: %Accounts.Membership{user_id: nil}}),
    do: {:ok, nil}

  def lock_seat_user(_repo, %UserIdentity{}), do: {:error, :not_found}

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

  # A provider deleted concurrently (or already soft-deleted) reads as
  # :provider_disabled rather than raising a NoResultsError out of the caller's
  # Multi and crashing the LiveView — the same clean denial a disabled
  # connection gives. Composed into a caller's transaction, so it takes the
  # transaction repo.
  def lock_provider_row(%IdentityProvider{} = provider, repo \\ Repo) do
    queryable =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(provider.account_id)
      |> IdentityProvider.Query.by_id(provider.id)
      |> IdentityProvider.Query.lock_for_update()

    case repo.fetch(queryable, IdentityProvider.Query) do
      {:ok, locked} -> {:ok, locked}
      {:error, :not_found} -> {:error, :provider_disabled}
    end
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
    membership_ids = Enum.map(identities, & &1.membership_id)

    memberships =
      provider.account_id
      |> Accounts.list_sync_memberships_by_id(membership_ids)
      |> Map.new(&{&1.id, &1})

    Enum.each(memberships, fn {_id, membership} ->
      if is_integer(membership.directory_authorization_pending_version) do
        Accounts.refresh_directory_authorization_sessions(membership)
      end
    end)

    # Removed seats retain directory history, but no current authorization to
    # recompute. They must neither adopt a replacement nor log a failed write.
    identities
    |> Enum.filter(&Map.has_key?(memberships, &1.membership_id))
    |> Enum.each(fn identity ->
      group_ids = Map.get(group_ids_by_identity, identity.id, [])
      role = highest_role_for_groups(group_ids, role_mappings) || provider.default_role
      access = effective_runner_access(provider, group_ids, runner_access_mappings)
      membership = Map.get(memberships, identity.membership_id)

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
    |> Enum.group_by(& &1.user_identity_id, & &1.directory_group_id)
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
      |> Enum.filter(&(&1.directory_group_id in group_ids))

    Emisar.SSO.GroupAccess.effective(provider_runner_access(provider), group_access)
  end

  # The most-privileged mapped role over a set of group ids.
  def highest_role_for_groups(group_ids, mappings) do
    roles =
      mappings
      |> Enum.filter(&(&1.directory_group_id in group_ids))
      |> Enum.map(& &1.role)

    Enum.find(@sync_role_precedence, &(&1 in roles))
  end

  def current_group_members(%IdentityProvider{} = provider, directory_group_id) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_provider_id(provider.id)
    |> DirectoryGroupMember.Query.by_directory_group_id(directory_group_id)
    |> Repo.all()
  end

  def load_identities(%IdentityProvider{}, []), do: []

  def load_identities(%IdentityProvider{} = provider, identity_ids) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.scim_not_deleted()
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
