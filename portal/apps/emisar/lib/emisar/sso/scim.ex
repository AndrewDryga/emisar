defmodule Emisar.SSO.SCIM do
  @moduledoc """
  The SCIM 2.0 wire surface: how an identity provider provisions, updates and
  deprovisions users and groups against this account.

  Internal to `Emisar.SSO`, which keeps the public functions the SCIM
  controllers call and forwards to here. Implementation, not a boundary: every
  entry point is still scoped by an `%IdentityProvider{}`, and authorization is
  still the per-provider `ems-` bearer that `authenticate_scim_token/1`
  resolves, exactly as AGENTS.md §1.4 describes.
  """
  import Emisar.SSO.Provisioning
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Crypto, Repo, Users}
  alias Emisar.SSO.{DirectoryGroup, DirectoryGroupMember, GroupRoleMapping}
  alias Emisar.SSO.GroupRunnerAccessMapping
  alias Emisar.SSO.IdentityProvider
  alias Emisar.SSO.{SCIMGroupPatch, SCIMUser, SCIMUserPatch, SCIMUserUpdate, UserIdentity}
  @identifier_constraints ~w[
    sso_user_identities_active_provider_identifier_index
    sso_user_identities_scim_external_id_index
  ]

  @scim_group_member_max_count 5_000

  @scim_group_string_max_length 255

  # -- Directory sync (SCIM) — auth ------------------------------------

  @doc """
  Internal — resolve a presented SCIM bearer to its `%IdentityProvider{}`.
  The token's provider-scope IS the authorization (no `%Subject{}`): the web
  boundary calls this, then drives the `scim_*` functions with the returned
  provider. Mirrors `ApiKeys.peek_api_key_by_secret/1` — prefix lookup +
  `Crypto.secure_compare/2` — and additionally requires SCIM be enabled and
  the provider live. `{:ok, provider} | {:error, :unauthorized}`.
  """
  def authenticate_scim_token(raw) when is_binary(raw) do
    prefix_size = Crypto.scim_token_prefix_size()

    if String.length(raw) < prefix_size do
      {:error, :unauthorized}
    else
      prefix = String.slice(raw, 0, prefix_size)

      # Scope the lookup to live, SCIM-enabled providers. The partial-unique
      # prefix index only covers non-deleted rows, so querying `all()` could
      # match a soft-deleted provider that shared a prefix and make `Repo.peek`
      # (a `Repo.one`) raise; not_deleted + scim_enabled resolves the prefix to
      # at most one row. The hash compare below is still the authenticator.
      queryable =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.scim_enabled()
        |> IdentityProvider.Query.with_active_account()
        |> IdentityProvider.Query.by_scim_token_prefix(prefix)

      with %IdentityProvider{scim_token_hash: hash} = provider <- Repo.peek(queryable),
           true <- is_binary(hash),
           true <- Crypto.secure_compare(hash, Crypto.hash(raw)) do
        {:ok, touch_scim_last_seen(provider)}
      else
        _ -> {:error, :unauthorized}
      end
    end
  end

  # Record the IdP's last SCIM contact — the "is directory sync working?" signal
  # on the connection detail page. Throttled to one write per minute (the
  # `scim_last_seen_before` filter) so a reconciliation burst doesn't churn the
  # row. Returns the provider unchanged (the caller authorizes the SCIM operation
  # with it; it doesn't display the timestamp).
  defp touch_scim_last_seen(%IdentityProvider{id: id} = provider) do
    now = DateTime.utc_now()

    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.by_id(id)
    |> IdentityProvider.Query.scim_last_seen_before(DateTime.add(now, -60, :second))
    |> Repo.update_all(set: [scim_last_seen_at: now])

    provider
  end

  # Authentication resolved this row before the request entered the domain. A
  # disable or delete can commit in that gap, so every mutation takes this same
  # provider-only fence before touching a user. No account join: the lock stays
  # one row, and the locked row — never the bearer-time struct — supplies every
  # default and audit attribution used below.
  defp put_current_scim_provider(multi, provider, expected_authorization_version \\ :any) do
    Multi.run(multi, :locked_provider, fn repo, _changes ->
      with {:ok, locked} <- fetch_current_scim_provider(provider, repo, lock?: true),
           :ok <-
             ensure_authorization_version(locked, expected_authorization_version) do
        {:ok, locked}
      end
    end)
  end

  defp fetch_current_scim_provider(%IdentityProvider{} = provider, repo \\ Repo, opts \\ []) do
    queryable =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.scim_enabled()
      |> IdentityProvider.Query.by_account_id(provider.account_id)
      |> IdentityProvider.Query.by_id(provider.id)

    queryable =
      if Keyword.get(opts, :lock?, false),
        do: IdentityProvider.Query.lock_for_update(queryable),
        else: queryable

    case repo.fetch(queryable, IdentityProvider.Query) do
      {:ok, current} -> {:ok, current}
      {:error, _reason} -> {:error, :directory_sync_disabled}
    end
  end

  defp ensure_authorization_version(_provider, :any), do: :ok

  defp ensure_authorization_version(
         %IdentityProvider{authorization_version: version},
         version
       ),
       do: :ok

  defp ensure_authorization_version(%IdentityProvider{}, _expected),
    do: {:error, :stale_authorization_version}

  # -- Directory sync (SCIM) — user lifecycle (internal, provider-scoped) --

  @doc """
  Internal — SCIM provision: reconcile a directory user to a `user_identity`
  by `(provider, externalId)`. The IdP-owned value is stored as both the OIDC
  binding identifier and SCIM correlation value; the identity row's UUID is the
  SCIM resource id. An existing identity is reused (idempotent — a re-POST never
  duplicates), and a resource retired by `DELETE /Users` revives that same
  identity and person. Otherwise a fresh user + identity (`created_by: :provider`,
  `provisioned_via: :scim`) + membership at `provider.default_role` are created
  in one `Multi`. Trusts the IdP's email within the connection (collision →
  `:email_taken`, never a merge). `{:ok, %{user, identity, membership}}`.
  """
  def scim_provision_user(%IdentityProvider{} = provider, attrs),
    do: provision_or_load(provider, attrs, :may_retry)

  # `retry` is bookkeeping for the race convergence below, not something a caller
  # chooses — it stays off the public surface.
  defp provision_or_load(%IdentityProvider{} = provider, attrs, retry) do
    external_id = attrs[:external_id] || attrs["external_id"]

    case live_scim_identity(provider, external_id) do
      %UserIdentity{} = identity ->
        load_provisioned(provider, identity, external_id, attrs, retry)

      nil ->
        case retired_scim_identity(provider, external_id) do
          %UserIdentity{} = identity ->
            :ok = cleanup_retired_group_members(provider, identity)
            load_provisioned(provider, identity, external_id, attrs, retry)

          nil ->
            case unclaimed_oidc_identity(provider, external_id) do
              %UserIdentity{} = identity ->
                load_provisioned(provider, identity, external_id, attrs, retry)

              nil ->
                provision_scim_user(provider, external_id, attrs, retry)
            end
        end
    end
  end

  defp live_scim_identity(%IdentityProvider{} = provider, external_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.scim_not_deleted()
    |> UserIdentity.Query.by_account_id(provider.account_id)
    |> UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> Repo.peek()
  end

  # SCIM may adopt an OIDC-first row only when no directory resource already
  # owns the externalId. Exact live and retired SCIM keys are deliberately
  # checked first: the two namespaces may contain the same string for different
  # people, and the directory's own key is authoritative here.
  defp unclaimed_oidc_identity(%IdentityProvider{} = provider, external_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.scim_not_deleted()
    |> UserIdentity.Query.without_scim_external_id()
    |> UserIdentity.Query.by_account_id(provider.account_id)
    |> UserIdentity.Query.by_provider_and_identifier(provider.id, external_id)
    |> Repo.peek()
  end

  # The SCIM tombstone does NOT release the shared row's external-id or one-user
  # reservations. A live wire resource wins above; otherwise revive the most
  # recently retired exact SCIM resource deterministically, never the independent
  # OIDC provider-identifier namespace.
  defp retired_scim_identity(%IdentityProvider{} = provider, external_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.scim_deleted()
    |> UserIdentity.Query.by_account_id(provider.account_id)
    |> UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> UserIdentity.Query.latest_scim_deleted()
    |> Repo.peek()
  end

  # A re-POST of an existing identity RECONCILES it to the state the directory
  # just asserted (#4/#10: some IdPs re-create rather than PATCH active:true).
  #
  # It reconciles to the POSTed `active`, and does NOT force the member active.
  # Forcing it meant a duplicate or replayed create carrying `active: false`
  # reinstated a suspended member — the IdP said "inactive" and we heard
  # "active", silently undoing an offboarding.
  #
  # It also adopts an OIDC-first identity, which has a `provider_identifier` but
  # no `scim_external_id`. Stamping the directory's correlation value keeps
  # repeated POST reconciliation, externalId filters, and later OIDC convergence
  # stable even if the login identifier is rebound.
  defp load_provisioned(
         %IdentityProvider{} = provider,
         %UserIdentity{} = identity,
         external_id,
         attrs,
         retry
       ) do
    active = scim_active_from(attrs)
    state = if identity.scim_deleted_at, do: :retired, else: :live

    with {:ok, authorization} <- load_repost_authorization(provider, identity, active, state) do
      case reconcile_provisioned(provider, identity, external_id, active, authorization, state) do
        {:error, reason}
        when reason in [:stale_authorization_version, :not_found] and retry == :may_retry ->
          provision_or_load(provider, attrs, :final)

        {:error, %Ecto.Changeset{} = changeset} ->
          cond do
            identifier_race?(changeset) and retry == :may_retry ->
              provision_or_load(provider, attrs, :final)

            identifier_race?(changeset) ->
              {:error, :identifier_taken}

            true ->
              {:error, changeset}
          end

        result ->
          result
      end
    end
  end

  # Mapping/group reads can grow with the provider, so take their one-identity
  # snapshot before the row lock. Every writer that can change these facts also
  # bumps authorization_version while holding the provider row; the transaction
  # below accepts this bundle only when that version is still current, and the
  # caller retries once on a crossing write.
  defp load_repost_authorization(_provider, _identity, false, :live), do: {:ok, nil}

  defp load_repost_authorization(%IdentityProvider{} = provider, _identity, false, :retired) do
    with {:ok, current} <- fetch_current_scim_provider(provider) do
      {:ok,
       %{
         authorization_version: current.authorization_version,
         authoritative?: true,
         mapped_role: nil,
         mapped_access: Accounts.RunnerAccess.none()
       }}
    end
  end

  defp load_repost_authorization(
         %IdentityProvider{} = provider,
         %UserIdentity{} = identity,
         true,
         state
       ) do
    with {:ok, current} <- fetch_current_scim_provider(provider) do
      role_mappings = provider_role_mappings(current)
      runner_access_mappings = provider_runner_access_mappings(current)

      authoritative? =
        state == :retired or match?(%DateTime{}, current.scim_groups_synced_at) or
          (role_mappings == [] and runner_access_mappings == [])

      group_ids = repost_group_ids(identity, state)

      mapped_access =
        runner_access_mappings
        |> Enum.filter(&(&1.directory_group_id in group_ids))
        |> Enum.map(&runner_access_mapping_access/1)
        |> Accounts.RunnerAccess.union()

      {:ok,
       %{
         authorization_version: current.authorization_version,
         authoritative?: authoritative?,
         mapped_role: highest_role_for_groups(group_ids, role_mappings),
         mapped_access: mapped_access
       }}
    end
  end

  # A deleted SCIM resource starts a new directory lifecycle. Its old group links
  # were retired with it, so it returns at provider defaults until current Group
  # pushes say otherwise. This also fails closed for historical tombstones whose
  # old links predate that cleanup.
  defp repost_group_ids(_identity, :retired), do: []

  defp repost_group_ids(%UserIdentity{} = identity, :live),
    do: Map.get(group_ids_by_identity([identity]), identity.id, [])

  defp reconcile_provisioned(provider, identity, external_id, active, authorization, state) do
    expected_version =
      if authorization, do: authorization.authorization_version, else: :any

    multi =
      Multi.new()
      |> put_active_account_lock(provider.account_id)
      |> put_current_scim_provider(provider, expected_version)
      |> Multi.run(:scim_identity, fn repo, %{locked_provider: locked_provider} ->
        lock_repost_identity(locked_provider, identity.id, state, repo)
      end)
      |> Multi.run(:adopted_identity, fn repo, %{scim_identity: locked_identity} ->
        prepare_repost_identity(repo, locked_identity, external_id, state)
      end)
      |> Multi.run(:user, fn _repo, %{adopted_identity: locked_identity} ->
        Users.fetch_user_by_id(locked_identity.user_id)
      end)
      |> Multi.merge(&reconcile_provisioned_membership_multi(&1, active, authorization))
      |> Multi.run(:updated_identity, fn repo, %{adopted_identity: locked_identity} ->
        put_repost_identity_state(repo, locked_identity, active, state)
      end)
      |> maybe_put_repost_authorization(authorization)
      |> Multi.run(:result, fn _repo, changes ->
        membership = Map.get(changes, :membership, changes.membership_transition.membership)

        {:ok,
         %{
           user: changes.user,
           identity: changes.updated_identity,
           membership: membership
         }}
      end)

    case Repo.commit_multi(multi, after_commit: &repost_effects/1) do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_repost_identity(provider, id, :live, repo),
    do: lock_scim_identity(provider, id, repo)

  defp lock_repost_identity(%IdentityProvider{} = provider, id, :retired, repo) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.scim_deleted()
    |> UserIdentity.Query.by_account_id(provider.account_id)
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_id(id)
    |> UserIdentity.Query.lock_for_update()
    |> repo.fetch(UserIdentity.Query)
  end

  defp prepare_repost_identity(repo, identity, external_id, :live),
    do: adopt_scim_identity(repo, identity, external_id)

  defp prepare_repost_identity(
         _repo,
         %UserIdentity{scim_external_id: external_id} = identity,
         external_id,
         :retired
       ),
       do: {:ok, identity}

  defp prepare_repost_identity(_repo, %UserIdentity{}, _external_id, :retired),
    do: {:error, :identifier_taken}

  defp put_repost_identity_state(repo, identity, active, :live),
    do: set_identity_scim_active(repo, identity, active)

  defp put_repost_identity_state(repo, identity, active, :retired),
    do: repo.update(UserIdentity.Changeset.revive_scim_resource(identity, active))

  defp adopt_scim_identity(repo, %UserIdentity{scim_external_id: nil} = identity, external_id)
       when is_binary(external_id),
       do: repo.update(UserIdentity.Changeset.adopt_scim_external_id(identity, external_id))

  defp adopt_scim_identity(
         _repo,
         %UserIdentity{scim_external_id: external_id} = identity,
         external_id
       ),
       do: {:ok, identity}

  defp adopt_scim_identity(_repo, %UserIdentity{}, _external_id),
    do: {:error, :identifier_taken}

  # active: true — reinstate a directory suspension (a MANUAL suspend still
  # holds, per reprovision_membership) and recompute mapped authorization.
  defp reconcile_provisioned_membership_multi(
         %{locked_provider: provider, user: user, adopted_identity: identity},
         true,
         authorization
       ) do
    case Accounts.peek_sync_membership(provider.account_id, user.id) do
      %Accounts.Membership{disabled_at: nil} = membership ->
        unchanged_membership_transition(membership)

      %Accounts.Membership{} = membership ->
        if identity.scim_active do
          unchanged_membership_transition(membership)
        else
          Accounts.put_sync_membership_lifecycle(
            Multi.new(),
            membership,
            provider,
            :reinstate
          )
        end

      nil ->
        {role, access} = repost_authorization(provider, authorization)

        Accounts.put_sso_membership(
          Multi.new(),
          provider.account_id,
          user.id,
          role,
          access,
          directory_managed?: true,
          directory_provider: provider
        )
        |> Multi.run(:membership_transition, fn _repo, %{membership: membership} ->
          {:ok, %{membership: membership, effect: nil}}
        end)
    end
  end

  # active: false — the same deprovision a PATCH/DELETE performs, so a create
  # that asserts "inactive" lands the member in exactly the offboarded state.
  defp reconcile_provisioned_membership_multi(
         %{locked_provider: provider, adopted_identity: identity},
         false,
         _authorization
       ) do
    case Accounts.peek_sync_membership(provider.account_id, identity.user_id) do
      %Accounts.Membership{} = membership ->
        Accounts.put_sync_membership_lifecycle(Multi.new(), membership, provider, :suspend)

      nil ->
        Multi.error(Multi.new(), :membership_transition, :not_found)
    end
  end

  defp unchanged_membership_transition(membership) do
    Multi.run(Multi.new(), :membership_transition, fn _repo, _changes ->
      {:ok, %{membership: membership, effect: nil}}
    end)
  end

  defp maybe_put_repost_authorization(multi, %{authoritative?: true} = authorization) do
    Multi.merge(multi, fn
      %{membership: _newly_created} ->
        Multi.new()

      %{
        locked_provider: provider,
        membership_transition: %{
          membership: %Accounts.Membership{directory_provider_id: provider_id} = membership
        }
      }
      when provider_id == provider.id ->
        {role, access} = repost_authorization(provider, authorization)

        Accounts.put_sync_membership_authorization(
          Multi.new(),
          membership,
          role,
          access,
          provider
        )

      %{membership_transition: _transition} ->
        Multi.new()
    end)
  end

  defp maybe_put_repost_authorization(multi, _authorization), do: multi

  defp repost_effects(changes) do
    case changes.membership_transition.effect do
      {:suspended, membership} -> :ok = Accounts.membership_suspended_effects(membership)
      {:reinstated, membership} -> :ok = Accounts.membership_reinstated_effects(membership)
      nil -> :ok
    end

    if Map.has_key?(changes, :target) do
      Accounts.after_sync_membership_authorization_committed(changes)
    else
      :ok
    end

    Accounts.after_membership_activation_committed(changes)
  end

  defp repost_authorization(provider, %{authoritative?: true} = authorization) do
    role = authorization.mapped_role || provider.default_role

    access =
      Accounts.RunnerAccess.union([
        provider_runner_access(provider),
        authorization.mapped_access
      ])

    {role, access}
  end

  defp repost_authorization(provider, _authorization),
    do: {provider.default_role, provider_runner_access(provider)}

  defp provision_scim_user(%IdentityProvider{} = provider, external_id, attrs, retry) do
    multi = build_scim_provision_multi(provider, external_id, attrs)

    case Repo.commit_multi(multi, after_commit: &Accounts.after_membership_activation_committed/1) do
      {:ok, %{user: user, identity: identity, membership: membership}} ->
        {:ok, %{user: user, identity: identity, membership: membership}}

      {:error, %Ecto.Changeset{} = changeset} ->
        # #9: lost a concurrent first-provision race — the winner created the
        # identity. Converge on it (the fetch-or-create race-safe shape) rather
        # than surfacing the unique-violation changeset. The re-call peek-hits.
        #
        # ONCE. A race resolves on one retry because the winner's row is now
        # visible. A permanent collision does not: this identifier belongs to a
        # row the lookup deliberately cannot see — someone else's claimed
        # identity — and retrying it re-collides forever.
        cond do
          identifier_race?(changeset) and retry == :may_retry ->
            # Re-enter through the LOOKUP, not the insert: converging means
            # finding the row the winner just created.
            provision_or_load(provider, attrs, :final)

          identifier_race?(changeset) ->
            {:error, :identifier_taken}

          true ->
            {:error, changeset}
        end

      {:error, :email_taken} ->
        # The SCIM email matches an existing user. If they're a member, park a
        # link request for an admin to approve (Okta retries and self-heals once
        # linked); a non-member is a genuine collision. Never merge (C1). A
        # provider revoked before the fenced fallback gets the bearer-time 401.
        email = attrs[:email] || attrs["email"]
        full_name = attrs[:full_name] || attrs["full_name"]

        case capture_current_scim_member_link(provider, external_id, email, full_name) do
          {:error, :directory_sync_disabled} = revoked -> revoked
          _captured_or_unmatched -> {:error, :email_taken}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The create transaction rolled back before reaching this collision path. Use
  # the established account -> provider lock order before the link write: OIDC
  # collision capture takes the same account lock, so reversing these two rows
  # here would deadlock a SCIM collision against an OIDC callback. Delete either
  # sweeps the request afterwards or makes this fallback refuse — it can never
  # refill the queue after the connection is gone.
  defp capture_current_scim_member_link(provider, external_id, email, full_name) do
    Multi.new()
    |> put_active_account_lock(provider.account_id)
    |> put_current_scim_provider(provider)
    |> Multi.run(:link_request, fn _repo, %{locked_provider: locked_provider} ->
      {:ok, capture_member_link(locked_provider, external_id, email, full_name, %{}, :scim)}
    end)
    |> Repo.commit_multi()
  end

  # Only an identifier collision is the race the re-call converges on, so only it
  # earns a retry. The one-live-identity-per-person index is a different answer —
  # the re-call would peek by identifier, miss, provision, collide again, forever.

  defp identifier_race?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint_name] in @identifier_constraints
    end)
  end

  defp build_scim_provision_multi(%IdentityProvider{} = provider, external_id, attrs) do
    user_attrs = %{
      email: attrs[:email] || attrs["email"],
      full_name: attrs[:full_name] || attrs["full_name"]
    }

    Multi.new()
    |> put_active_account_lock(provider.account_id)
    |> put_current_scim_provider(provider)
    |> Multi.run(:user, fn _repo, _changes -> Users.provision_sso_user(user_attrs) end)
    |> Multi.run(:identity, fn _repo, %{locked_provider: locked_provider, user: user} ->
      create_scim_identity(locked_provider, user, external_id, attrs)
    end)
    |> Multi.merge(fn %{locked_provider: locked_provider, user: user} ->
      Accounts.put_sso_membership(
        Multi.new(),
        locked_provider.account_id,
        user.id,
        locked_provider.default_role,
        provider_runner_access(locked_provider),
        active?: scim_active_from(attrs),
        directory_managed?: true,
        directory_provider: locked_provider
      )
    end)
    |> Multi.insert(:audit, fn %{locked_provider: locked_provider, user: user} ->
      Audit.Events.user_provisioned_via_scim(user, locked_provider)
    end)
  end

  # The externalId is stored as BOTH the binding `provider_identifier` and
  # `scim_external_id` (decision 4) so an OIDC login by `sub` and SCIM by
  # `externalId` converge on the one `(provider, identifier)` identity.
  defp create_scim_identity(%IdentityProvider{} = provider, user, external_id, attrs) do
    identity_attrs = %{
      provider_identifier: external_id,
      scim_external_id: external_id,
      created_by: :provider,
      provisioned_via: :scim,
      scim_active: scim_active_from(attrs)
    }

    provider.account_id
    |> UserIdentity.Changeset.create(provider.id, user.id, identity_attrs)
    |> Repo.insert()
  end

  # The SCIM `active` flag (default true), accepting atom- or string-keyed attrs
  # — the SCIM controller decodes JSON to string keys; internal callers use atoms.
  defp scim_active_from(attrs), do: Map.get(attrs, :active, Map.get(attrs, "active", true))

  @doc """
  Internal — SCIM `PATCH /Users/{id}`: reduce the IdP's ordered RFC 7644 §3.5.2
  operation list into one desired state and apply it as `scim_update_user/3`
  does. The wire boundary hands the raw operations straight through — which
  attributes a batch may touch, how its order resolves, and how big it may get
  are decided here. `{:error, :too_many_scim_operations | :invalid_scim_active |
  :unsupported_scim_patch}` for a batch we refuse, plus every
  `scim_update_user/3` error for one we apply.
  """
  def scim_patch_user(%IdentityProvider{} = provider, id, operations)
      when is_list(operations) do
    with {:ok, update} <- SCIMUserPatch.reduce(operations) do
      scim_update_user(provider, id, update)
    end
  end

  @doc """
  Internal — SCIM update (PATCH / PUT): apply one directory user's
  desired name and lifecycle state (`%SCIMUserUpdate{}`) as ONE transaction.
  The identity is re-read and locked under the provider's scope, a partial
  name is merged against that locked state, and the rename, the membership
  transition (whose guards — provider account, last active owner, break-glass
  holds — judge the locked row), and the identity's `scim_active` flag commit
  together or not at all: the IdP is never told its operation failed after
  half of it landed. `{:error, :not_found}` when no identity matches (or a
  reactivation has no membership left); `{:error, :last_owner}` when the
  deprovision would lock out the account's last active owner. Session kill /
  key revocation / broadcasts fire only after the commit. Returns
  `{:ok, %{identity: identity, membership: membership | nil}}`.
  """
  def scim_update_user(%IdentityProvider{} = provider, id, %SCIMUserUpdate{} = update) do
    multi =
      Multi.new()
      |> put_current_scim_provider(provider)
      |> Multi.run(:identity, fn repo, %{locked_provider: locked_provider} ->
        lock_scim_identity(locked_provider, id, repo)
      end)
      |> Multi.run(:rename, fn _repo, %{locked_provider: locked_provider, identity: identity} ->
        apply_scim_rename(locked_provider, identity, update.name)
      end)
      |> Multi.merge(fn %{locked_provider: locked_provider, identity: identity} ->
        scim_lifecycle_multi(locked_provider, identity, update.active)
      end)
      |> Multi.run(:updated_identity, fn repo, %{identity: identity} ->
        set_identity_scim_active(repo, identity, update.active)
      end)

    with {:ok, changes} <- Repo.commit_multi(multi, after_commit: &scim_update_effects/1) do
      {:ok, %{identity: changes.updated_identity, membership: scim_updated_membership(changes)}}
    end
  end

  @doc """
  Internal — SCIM `DELETE /Users/{id}`: suspend the account membership and
  retire the exact directory resource in one provider-scoped transaction. The
  person and identity history remain, but the resource immediately leaves GET,
  list, PATCH, PUT and DELETE. A later `POST /Users` carrying the same
  `externalId` revives this row instead of duplicating the person. Group links
  are retired with the resource so old mapped grants cannot return on revival.
  """
  def scim_delete_user(%IdentityProvider{} = provider, id) do
    multi =
      Multi.new()
      |> put_current_scim_provider(provider)
      |> Multi.run(:identity, fn repo, %{locked_provider: locked_provider} ->
        lock_scim_identity(locked_provider, id, repo)
      end)
      |> Multi.merge(fn %{locked_provider: locked_provider, identity: identity} ->
        scim_lifecycle_multi(locked_provider, identity, false)
      end)
      |> Multi.merge(&put_deleted_scim_authorization/1)
      |> Multi.run(:identity_sessions, fn repo, %{identity: identity} ->
        Auth.delete_identity_session_tokens(identity.user_id, [identity.id], repo)
      end)
      |> Multi.run(:deleted_identity, fn repo,
                                         %{
                                           locked_provider: locked_provider,
                                           identity: identity
                                         } ->
        delete_scim_resource(repo, locked_provider, identity)
      end)

    with {:ok, changes} <- Repo.commit_multi(multi, after_commit: &scim_delete_effects/1) do
      {:ok, %{identity: changes.deleted_identity, membership: scim_updated_membership(changes)}}
    end
  end

  defp scim_delete_effects(changes) do
    :ok = Accounts.membership_lifecycle_effects(changes)
    :ok = maybe_finish_scim_authorization(changes)
    :ok = Auth.disconnect_live_socket_topics(changes.identity_sessions.socket_topics)
    cleanup_retired_group_members(changes.locked_provider, changes.deleted_identity)
  end

  defp put_deleted_scim_authorization(%{
         locked_provider: provider,
         membership_transition: %{
           membership: %Accounts.Membership{directory_provider_id: provider_id} = membership
         }
       })
       when provider_id == provider.id do
    Accounts.put_sync_membership_authorization(
      Multi.new(),
      membership,
      provider.default_role,
      provider_runner_access(provider),
      provider
    )
  end

  defp put_deleted_scim_authorization(%{membership_transition: _transition}), do: Multi.new()

  defp delete_scim_resource(
         repo,
         %IdentityProvider{} = provider,
         %UserIdentity{scim_external_id: nil} = identity
       ) do
    reserved_external_id =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_account_id(provider.account_id)
      |> UserIdentity.Query.by_provider_and_scim_external_id(
        provider.id,
        identity.provider_identifier
      )
      |> repo.peek()
      |> case do
        nil -> identity.provider_identifier
        %UserIdentity{} -> nil
      end

    repo.update(UserIdentity.Changeset.delete_scim_resource(identity, reserved_external_id))
  end

  defp delete_scim_resource(
         repo,
         %IdentityProvider{},
         %UserIdentity{scim_external_id: external_id} = identity
       ) do
    repo.update(UserIdentity.Changeset.delete_scim_resource(identity, external_id))
  end

  defp maybe_finish_scim_authorization(%{target: _target} = changes),
    do: Accounts.after_sync_membership_authorization_committed(changes)

  defp maybe_finish_scim_authorization(_changes), do: :ok

  # Group links can be numerous. Retire them only after the provider/identity/
  # membership transaction releases its locks, and repeat the same idempotent
  # cleanup before revival so a crash after the tombstone fails closed and
  # self-heals. The identity join makes the UPDATE conditional on the marker in
  # the statement snapshot. A concurrent revival can therefore expose fresh
  # group pushes only after this UPDATE's snapshot, so they are never swept.
  defp cleanup_retired_group_members(
         %IdentityProvider{} = provider,
         %UserIdentity{scim_deleted_at: %DateTime{}} = identity
       ) do
    now = DateTime.utc_now()

    queryable =
      DirectoryGroupMember.Query.not_deleted()
      |> DirectoryGroupMember.Query.by_account_id(provider.account_id)
      |> DirectoryGroupMember.Query.by_provider_id(provider.id)
      |> DirectoryGroupMember.Query.by_user_identity_id(identity.id)
      |> DirectoryGroupMember.Query.with_joined_retired_scim_identity()

    Repo.update_all(queryable, set: [deleted_at: now, updated_at: now])
    :ok
  end

  defp lock_scim_identity(%IdentityProvider{} = provider, id, repo) do
    if Repo.valid_uuid?(id) do
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.scim_not_deleted()
      |> UserIdentity.Query.by_account_id(provider.account_id)
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> UserIdentity.Query.by_id(id)
      |> UserIdentity.Query.lock_for_update()
      |> repo.fetch(UserIdentity.Query)
    else
      {:error, :not_found}
    end
  end

  defp apply_scim_rename(_provider, _identity, :keep), do: {:ok, :unchanged}

  # A component names one half, so the half this operation does not mention
  # keeps the value it already has — a `givenName`-only correction must not
  # drop the surname. Merged here, against the user the locked identity binds,
  # so a concurrent rename can't slip between the read and the write.
  defp apply_scim_rename(%IdentityProvider{} = provider, identity, {:merge, components}) do
    with {:ok, user} <- Users.fetch_user_by_id(identity.user_id) do
      apply_scim_rename(provider, identity, {:replace, merged_name(user, components)})
    end
  end

  defp apply_scim_rename(%IdentityProvider{} = provider, identity, {:replace, full_name}) do
    with {:ok, membership, sole_tenancy?} <-
           Accounts.sync_member_display_name(provider.account_id, identity.user_id, full_name,
             audit: &Audit.Events.membership_renamed_via_scim(&1, provider, full_name)
           ),
         {:ok, _user} <- rename_the_person(identity, full_name, provider, sole_tenancy?) do
      {:ok, membership}
    end
  end

  # The directory's name always lands on the MEMBERSHIP, which this account owns.
  # It reaches `users.full_name` — the person's own, cross-account attribute —
  # only when this account is their only tenancy. Writing it unconditionally let
  # one workspace's IdP put text of its choosing in front of another workspace's
  # operators, in their roster, audit trail and run attribution.
  defp rename_the_person(%UserIdentity{} = identity, full_name, provider, true) do
    Users.sync_user_full_name(identity.user_id, full_name,
      audit: &Audit.Events.user_renamed_via_scim(&1, provider)
    )
  end

  defp rename_the_person(%UserIdentity{} = identity, _full_name, _provider, false),
    do: Users.fetch_user_by_id(identity.user_id)

  # The stored name is one string, so split it to fill whichever half the
  # operation left alone: everything before the first space is the given half,
  # the rest is the family half, and a single word is a given name with no
  # family half. That is a guess about human names, and a wrong one for plenty
  # of them — it only decides what to KEEP when an operation names one
  # component, never what to store when it names both.
  defp merged_name(%Users.User{} = user, components) do
    {current_given, current_family} = split_current_name(user)

    [
      Map.get(components, :given, current_given),
      Map.get(components, :family, current_family)
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp split_current_name(user) do
    case scim_display_name(user) do
      nil ->
        {nil, nil}

      name ->
        case String.split(name, " ", parts: 2) do
          [given, family] -> {given, family}
          [only] -> {only, nil}
        end
    end
  end

  defp scim_lifecycle_multi(_provider, _identity, :keep) do
    Multi.run(Multi.new(), :membership_transition, fn _repo, _changes ->
      {:ok, %{membership: nil, effect: nil}}
    end)
  end

  # An identity whose membership an operator removed locally is ALREADY as
  # deprovisioned as this account can make it, so a deprovision succeeds with
  # nothing to do. Answering `:not_found` told the directory the person does not
  # exist while a read still described them — so it either retried the deactivate
  # forever or concluded they were gone and re-created them, undoing the removal.
  defp scim_lifecycle_multi(%IdentityProvider{} = provider, identity, false) do
    case Accounts.peek_sync_membership(provider.account_id, identity.user_id) do
      %Accounts.Membership{} = membership ->
        Accounts.put_sync_membership_lifecycle(Multi.new(), membership, provider, :suspend)

      nil ->
        Multi.run(Multi.new(), :membership_transition, fn _repo, _changes ->
          {:ok, %{membership: nil, effect: nil}}
        end)
    end
  end

  defp scim_lifecycle_multi(%IdentityProvider{} = provider, identity, true) do
    case Accounts.peek_sync_membership(provider.account_id, identity.user_id) do
      %Accounts.Membership{} = membership ->
        Accounts.put_sync_membership_lifecycle(Multi.new(), membership, provider, :reinstate)

      nil ->
        Multi.error(Multi.new(), :membership_transition, :not_found)
    end
  end

  defp set_identity_scim_active(_repo, %UserIdentity{} = identity, :keep), do: {:ok, identity}

  defp set_identity_scim_active(repo, %UserIdentity{} = identity, active)
       when is_boolean(active),
       do: repo.update(UserIdentity.Changeset.set_scim_active(identity, active))

  # Only a lifecycle write that actually committed earns its side effects — a
  # no-op (already suspended, break-glass hold) fires nothing.
  defp scim_update_effects(%{membership_transition: _transition} = changes),
    do: Accounts.membership_lifecycle_effects(changes)

  # The freshest membership this transition touched, for the caller's result:
  # the lifecycle write's row wins over the rename's, and an untouched
  # membership is nil.
  defp scim_updated_membership(%{
         membership: %Accounts.Membership{} = membership
       }),
       do: membership

  defp scim_updated_membership(%{
         membership_transition: %{membership: %Accounts.Membership{} = membership}
       }),
       do: membership

  defp scim_updated_membership(%{rename: %Accounts.Membership{} = membership}), do: membership

  defp scim_updated_membership(_changes), do: nil

  @doc """
  Internal — SCIM read: the `%SCIMUser{}` projection for a server-issued
  resource id under this provider. `{:ok, %SCIMUser{}} |
  {:error, :not_found}` — an identity whose membership an operator removed is
  still found, and reports inactive.
  """
  def scim_fetch_user(%IdentityProvider{} = provider, id) do
    with {:ok, identity} <- fetch_scim_identity(provider, id) do
      membership = Accounts.peek_sync_membership(provider.account_id, identity.user_id)
      {:ok, scim_user(identity, identity.user, membership)}
    end
  end

  @doc """
  Internal — SCIM read: the provider's directory users as `%SCIMUser{}`
  projections, paginated (the IdP's list/filter probe). An optional
  `:scim_filter` (`{:user_name, v}` | `{:external_id, v}`) is applied in the
  query so the IdP's existence probe matches a user *anywhere* in the
  directory, not just the fetched page — without it, a `userName eq` check
  past the page limit would miss the user and the IdP would re-provision a
  duplicate. `:offset` is zero-based internally and `:limit` is bounded by the
  SCIM controller. Returns `{:ok, [%SCIMUser{}], total_results}`.
  """
  def scim_list_users(%IdentityProvider{} = provider, opts \\ []) do
    {scim_filter, opts} = Keyword.pop(opts, :scim_filter)
    {offset, opts} = Keyword.pop(opts, :offset, 0)
    {limit, _opts} = Keyword.pop(opts, :limit, 100)

    # `by_provider_id` already implies the account (a provider is account-bound),
    # but this read has no `%Subject{}` — the bearer's provider-scope is the
    # authz — so scope by the explicit account too (house rule: an explicit
    # account is always filtered on, belt-and-suspenders).
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.scim_not_deleted()
      |> UserIdentity.Query.by_account_id(provider.account_id)
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> apply_scim_filter(scim_filter)

    total_results = Repo.aggregate(queryable, :count, :id)

    identities =
      if limit == 0 or offset >= total_results do
        []
      else
        queryable
        # The user carries the email `userName` renders from. Without it a listed
        # identity fell back to its opaque externalId, so the handle an IdP got
        # back from `POST /Users` differed from the next list response.
        |> UserIdentity.Query.with_preloaded_user()
        |> UserIdentity.Query.ordered_by_recent()
        |> UserIdentity.Query.offset_page(offset, limit)
        |> Repo.all()
      end

    {:ok, scim_users(provider, identities), total_results}
  end

  @doc """
  Internal — SCIM read: the provider's synced directory groups as
  `[%{id, external_group_id, display, member_ids}]`, ordered stably.
  Optional `:display_name` and `:external_id` filters answer the provider probes
  that precede a group push. Okta omits externalId on create, then probes our
  returned resource id as externalId; for Okta only, an unset externalId matches
  that exact immutable resource id without changing the stored or rendered
  attribute.

  `display` is whatever the directory last pushed on the group resource. Role
  mappings and membership rows carry historical copies for their own workflows,
  but do not redefine the SCIM resource's name.
  """
  def scim_list_groups(%IdentityProvider{} = provider, opts \\ []) do
    {display_name, opts} = Keyword.pop(opts, :display_name)
    {external_id, opts} = Keyword.pop(opts, :external_id)
    {offset, opts} = Keyword.pop(opts, :offset, 0)
    {limit, _opts} = Keyword.pop(opts, :limit, 100)

    # No `%Subject{}` here — the bearer's provider-scope IS the authz — so scope
    # by the explicit account too, as the sibling user read does.
    #
    # The GROUP rows decide what exists. Enumerating distinct membership rows
    # instead meant a group with no members was absent from this list and 404'd
    # on its own id, however recently the directory had pushed it.
    groups_queryable =
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> apply_scim_group_filter(provider, display_name, external_id)

    total_results = Repo.aggregate(groups_queryable, :count, :id)

    groups =
      if limit == 0 or offset >= total_results do
        []
      else
        groups_queryable
        |> DirectoryGroup.Query.ordered_by_external_group_id()
        |> DirectoryGroup.Query.offset_page(offset, limit)
        |> Repo.all()
      end

    {:ok, scim_group_summaries(groups, provider), total_results}
  end

  defp scim_group_summaries([], _provider), do: []

  defp scim_group_summaries(groups, %IdentityProvider{} = provider) do
    group_ids = Enum.map(groups, & &1.id)

    members_queryable =
      DirectoryGroupMember.Query.not_deleted()
      |> DirectoryGroupMember.Query.by_account_id(provider.account_id)
      |> DirectoryGroupMember.Query.by_directory_group_ids(group_ids)
      |> DirectoryGroupMember.Query.select_member_ids(provider.id)

    members = Enum.group_by(Repo.all(members_queryable), &elem(&1, 0), &elem(&1, 1))

    Enum.map(groups, fn %DirectoryGroup{} = group ->
      %{
        id: group.id,
        external_group_id: group.external_group_id,
        display: group.display,
        member_ids: Map.get(members, group.id, [])
      }
    end)
  end

  @doc """
  Internal — SCIM read of one synced group by its server-issued resource id, so an IdP's
  `GET /Groups/{id}` round-trips instead of 404ing on a group it just pushed.
  `{:ok, summary} | {:error, :not_found}`.
  """
  def scim_fetch_group(%IdentityProvider{} = provider, id) do
    if Repo.valid_uuid?(id) do
      queryable =
        DirectoryGroup.Query.not_deleted()
        |> DirectoryGroup.Query.by_account_id(provider.account_id)
        |> DirectoryGroup.Query.by_provider_id(provider.id)
        |> DirectoryGroup.Query.by_id(id)

      case Repo.peek(queryable) do
        nil ->
          {:error, :not_found}

        group ->
          [summary] = scim_group_summaries([group], provider)
          {:ok, summary}
      end
    else
      {:error, :not_found}
    end
  end

  defp apply_scim_group_filter(queryable, _provider, nil, nil), do: queryable

  defp apply_scim_group_filter(queryable, _provider, display_name, nil),
    do: DirectoryGroup.Query.by_display(queryable, display_name)

  defp apply_scim_group_filter(queryable, %IdentityProvider{kind: :okta}, nil, external_id),
    do: DirectoryGroup.Query.by_external_group_id_or_unset_resource_id(queryable, external_id)

  defp apply_scim_group_filter(queryable, _provider, nil, external_id),
    do: DirectoryGroup.Query.by_external_group_id(queryable, external_id)

  defp apply_scim_filter(queryable, {:user_name, value}),
    do: UserIdentity.Query.by_user_name(queryable, value)

  defp apply_scim_filter(queryable, {:external_id, value}),
    do: UserIdentity.Query.by_external_id(queryable, value)

  defp apply_scim_filter(queryable, _none), do: queryable

  defp fetch_scim_identity(%IdentityProvider{} = provider, id) do
    if Repo.valid_uuid?(id) do
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.scim_not_deleted()
      |> UserIdentity.Query.by_account_id(provider.account_id)
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> UserIdentity.Query.by_id(id)
      |> UserIdentity.Query.with_preloaded_user()
      |> Repo.fetch(UserIdentity.Query)
    else
      {:error, :not_found}
    end
  end

  defp scim_users(%IdentityProvider{} = provider, identities) do
    user_ids = Enum.map(identities, & &1.user_id)

    memberships =
      provider.account_id
      |> Accounts.list_sync_memberships(user_ids)
      |> Map.new(&{&1.user_id, &1})

    Enum.map(identities, &scim_user(&1, &1.user, memberships[&1.user_id]))
  end

  defp scim_user(%UserIdentity{} = identity, user, membership) do
    external_id = identity.scim_external_id || identity.provider_identifier

    %SCIMUser{
      id: identity.id,
      external_id: external_id,
      user_name: scim_user_name(identity, user),
      display_name: scim_display_name(user),
      active: scim_effective_active?(identity, membership)
    }
  end

  # What the IdP is told, and it has to be the truth. Marking the identity
  # `scim_active` is not the same as the person being usable: a directory
  # `active: true` deliberately does NOT lift a manual break-glass hold, so
  # reporting the identity's flag answered "active" for someone who cannot sign
  # in. The IdP acts on that — it stops flagging them — and nobody finds out.
  defp scim_effective_active?(%UserIdentity{} = identity, %Accounts.Membership{disabled_at: nil}),
    do: identity.scim_active

  defp scim_effective_active?(%UserIdentity{}, %Accounts.Membership{}), do: false

  # No membership at all — an operator removed them from the account while the
  # identity survived. They are not active here, and saying otherwise left the
  # directory told "active" by a read and "no such user" by a deprovision.
  defp scim_effective_active?(%UserIdentity{}, nil), do: false

  # userName prefers the user's email (the human-readable handle IdPs expect),
  # then a `preferred_username`/`nickname` claim if the IdP asserted one, and
  # only then falls back to the opaque externalId/sub (decision: SCIM email is
  # optional and the IdP may suppress it — but a readable handle is nicer).
  defp scim_user_name(%UserIdentity{} = identity, user) do
    scim_email(identity, user) || scim_username_claim(identity) || identity.scim_external_id ||
      identity.provider_identifier
  end

  defp scim_email(_identity, %{email: email}) when is_binary(email) and email != "", do: email

  defp scim_email(%UserIdentity{claims: %{"email" => email}}, _user) when is_binary(email),
    do: email

  defp scim_email(_identity, _user), do: nil

  # The common OIDC handle claims, in preference order — a friendlier userName
  # than the raw subject when no email was asserted.
  defp scim_username_claim(%UserIdentity{claims: claims}) when is_map(claims) do
    Enum.find_value(["preferred_username", "nickname"], fn key ->
      case claims do
        %{^key => value} when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp scim_username_claim(_identity), do: nil

  defp scim_display_name(%{full_name: name}) when is_binary(name) and name != "", do: name

  defp scim_display_name(_user), do: nil

  # -- Directory sync (SCIM) — groups → roles (internal, provider-scoped) --

  # `:admin > :operator > :viewer`. `:owner` is deliberately absent — sync
  # never grants owner (decision 7). `Auth.Role` has no rank by design, so the
  # precedence the recompute needs lives here, narrowed to the sync-assignable
  # roles, most-privileged first.
  # Group-sync precedence when a member is in SEVERAL mapped groups — mirrors
  # Role.all()'s order. billing_manager (the orthogonal finance seat) outranks
  # the day-to-day roles: an explicit finance-group mapping is a deliberate
  # specialist assignment, but an admin mapping still wins. Never :owner
  # (mappings can't mint owners — decision 7).

  @doc """
  Internal — SCIM group create/reconcile (`POST /Groups`). A supplied
  `externalId` reconciles the provider's existing group; without one, a fresh
  server-id resource is created. `displayName` is never identity. Membership
  values are server-issued User ids; unknown in-scope-shaped ids are ignored.
  """
  def scim_upsert_group(%IdentityProvider{} = provider, attrs) do
    external_group_id = attrs[:external_id] || attrs["external_id"]
    display = attrs[:display] || attrs["display"]
    member_ids = attrs[:member_ids] || attrs["member_ids"] || []

    with :ok <- validate_scim_group_values(external_group_id, display, member_ids),
         {:ok, {current_provider, affected, group}} <-
           Repo.transaction(fn ->
             {locked_provider, first_push?} = lock_provider!(provider)

             group =
               create_or_fetch_directory_group!(locked_provider, external_group_id, display)

             desired_ids = resolve_member_identity_ids(locked_provider, member_ids)

             affected = replace_group_members(locked_provider, group, display, desired_ids)

             affected = identities_to_recompute(locked_provider, affected, first_push?)

             current_provider =
               prepare_scim_group_authorization_change!(locked_provider, affected)

             {current_provider, affected, group}
           end),
         :ok <- recompute_role_for_affected(current_provider, affected) do
      scim_fetch_group(provider, group.id)
    end
  end

  @doc """
  Internal — SCIM `PUT /Groups/{id}`: replace the addressed group without
  allowing body identity fields to redirect the write.
  """
  def scim_replace_group(%IdentityProvider{} = provider, id, attrs) do
    external_group_id = attrs[:external_id] || attrs["external_id"]
    display = attrs[:display] || attrs["display"]
    member_ids = attrs[:member_ids] || attrs["member_ids"] || []

    with true <- Repo.valid_uuid?(id),
         :ok <- validate_optional_scim_string(external_group_id),
         :ok <- validate_optional_scim_string(display),
         :ok <- validate_scim_member_ids(member_ids),
         {:ok, {current_provider, affected, group}} <-
           Repo.transaction(fn ->
             {locked_provider, first_push?} = lock_provider!(provider)
             group = fetch_group_row!(locked_provider, id)
             :ok = ensure_group_external_id(group, external_group_id)
             group = put_group_display!(locked_provider, group, display)
             desired_ids = resolve_member_identity_ids(locked_provider, member_ids)
             affected = replace_group_members(locked_provider, group, display, desired_ids)
             affected = identities_to_recompute(locked_provider, affected, first_push?)

             current_provider =
               prepare_scim_group_authorization_change!(locked_provider, affected)

             {current_provider, affected, group}
           end),
         :ok <- recompute_role_for_affected(current_provider, affected) do
      scim_fetch_group(provider, group.id)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Internal — SCIM `DELETE /Groups/{id}`: retire the exact resource and take its
  members' grants with it. A missing resource returns `:not_found` and is never
  invented by the delete path.
  """
  def scim_delete_group(%IdentityProvider{} = provider, id) do
    with true <- Repo.valid_uuid?(id),
         {:ok, {current_provider, affected, summary}} <-
           Repo.transaction(fn ->
             {locked_provider, first_push?} = lock_provider!(provider)
             group = fetch_group_row!(locked_provider, id)
             current = current_group_members(locked_provider, group.id)
             affected = load_identities(locked_provider, Enum.map(current, & &1.user_identity_id))
             :ok = soft_delete_group_members(current)
             delete_changeset = DirectoryGroup.Changeset.delete(group)

             case Repo.update(delete_changeset) do
               {:ok, _group} -> :ok
               {:error, reason} -> Repo.rollback(reason)
             end

             affected = identities_to_recompute(locked_provider, affected, first_push?)

             current_provider =
               prepare_scim_group_authorization_change!(locked_provider, affected)

             summary = %{
               id: group.id,
               external_group_id: group.external_group_id,
               display: group.display,
               member_ids: []
             }

             {current_provider, affected, summary}
           end),
         :ok <- recompute_role_for_affected(current_provider, affected) do
      {:ok, summary}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Internal — rename one server-issued Group resource without changing identity."
  def scim_rename_group(%IdentityProvider{} = provider, id, display) do
    with true <- Repo.valid_uuid?(id),
         :ok <- validate_optional_scim_string(display),
         {:ok, group} <-
           Repo.transaction(fn ->
             {locked_provider, _first_push?} = lock_provider!(provider)
             group = fetch_group_row!(locked_provider, id)
             put_group_display!(locked_provider, group, display)
           end) do
      scim_fetch_group(provider, group.id)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Internal — is this a display name a group write would accept?

  The SCIM boundary needs to answer that BEFORE it writes anything: a batch
  carrying both a membership change and a rename used to commit the membership
  and only then reject the rename, so the IdP saw a total failure after a
  privilege change had already landed. Same rule the write itself applies, read
  from one place so the two cannot drift. `:ok | {:error, reason}`.
  """
  def validate_scim_group_display(display), do: validate_optional_scim_string(display)

  @doc """
  Internal — SCIM group patch (`PATCH /Groups` member ops): add/remove members
  of a group, then recompute the role of every affected identity. Add ids are
  resolved to the provider's identities (unknown ids ignored); remove ids
  soft-delete the matching links. `{:ok, group_summary}`.
  """
  def scim_patch_group_members(
        %IdentityProvider{} = provider,
        id,
        add_ids,
        remove_ids,
        display \\ nil
      ) do
    with true <- Repo.valid_uuid?(id),
         :ok <- validate_optional_scim_string(display),
         :ok <- validate_scim_patch_member_ids(add_ids, remove_ids),
         {:ok, {current_provider, added, removed, affected, group}} <-
           Repo.transaction(fn ->
             {locked_provider, first_push?} = lock_provider!(provider)
             group = fetch_group_row!(locked_provider, id)
             group = put_group_display!(locked_provider, group, display)
             add_ids = resolve_member_identity_ids(locked_provider, add_ids)
             remove_ids = resolve_member_identity_ids(locked_provider, remove_ids)
             added = add_group_members(locked_provider, group, add_ids)
             removed = remove_group_members(locked_provider, group, remove_ids)
             touched = Enum.uniq(added ++ removed)
             affected = identities_to_recompute(locked_provider, touched, first_push?)

             current_provider =
               prepare_scim_group_authorization_change!(locked_provider, affected)

             {current_provider, added, removed, affected, group}
           end),
         :ok <- recompute_role_for_affected(current_provider, affected),
         {:ok, summary} <- scim_fetch_group(provider, group.id) do
      {:ok, Map.merge(summary, %{added: length(added), removed: length(removed)})}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Internal — SCIM `PATCH /Groups/{id}`: reduce the IdP's ordered RFC 7644 §3.5.2
  operation list into one transition and apply it through the same group writes a
  PUT takes, so a batch carrying both a rename and a membership change commits as
  one. The wire boundary hands the raw operations straight through — the ordering,
  the recognized attributes, and the caps are decided here.

  `{:ok, group_summary}` carrying the `member_ids` the response renders;
  `{:error, :invalid_scim_group | :unsupported_scim_patch}` for a batch we refuse,
  plus every group-write error for one we apply.
  """
  def scim_patch_group(%IdentityProvider{} = provider, id, operations)
      when is_list(operations) do
    with {:ok, group} <- scim_fetch_group(provider, id),
         {:ok, command} <- SCIMGroupPatch.reduce(operations, group) do
      apply_scim_group_patch(provider, id, command)
    end
  end

  # The batch asked for nothing we had to write — answer with the group as it stands.
  defp apply_scim_group_patch(%IdentityProvider{} = provider, id, :unchanged),
    do: scim_fetch_group(provider, id)

  defp apply_scim_group_patch(
         %IdentityProvider{} = provider,
         id,
         {:rename, display}
       ) do
    scim_rename_group(provider, id, display)
  end

  defp apply_scim_group_patch(
         %IdentityProvider{} = provider,
         id,
         {:replace, display, member_ids}
       ) do
    attrs = %{
      display: display,
      member_ids: member_ids
    }

    scim_replace_group(provider, id, attrs)
  end

  defp apply_scim_group_patch(
         %IdentityProvider{} = provider,
         id,
         {:delta, display, add_ids, remove_ids}
       ) do
    with {:ok, _summary} <-
           scim_patch_group_members(provider, id, add_ids, remove_ids, display) do
      scim_fetch_group(provider, id)
    end
  end

  # Serialize every group write on the provider row, BEFORE any membership is
  # read. Locking only once a diff came out non-empty read the group twice over:
  # two concurrent PUTs both saw the same "current" set, so a PUT emptying the
  # group found nothing to remove — a no-op that took no lock and reported
  # success — while a concurrent PUT adding someone committed, leaving them
  # privileged after the directory had said they were out.
  # A group push proves the group exists, whether or not it named any members.
  # Deriving existence from membership rows meant an empty push created nothing,
  # so the `GET` right after a 201 answered 404.
  defp create_or_fetch_directory_group!(provider, external_group_id, display) do
    existing =
      if external_group_id do
        DirectoryGroup.Query.not_deleted()
        |> DirectoryGroup.Query.by_account_id(provider.account_id)
        |> DirectoryGroup.Query.by_provider_id(provider.id)
        |> DirectoryGroup.Query.by_external_group_id(external_group_id)
        |> Repo.peek()
      end

    case existing do
      %DirectoryGroup{} = group ->
        put_group_display!(provider, group, display)

      nil ->
        provider.account_id
        |> DirectoryGroup.Changeset.create(provider.id, external_group_id, display)
        |> Repo.insert()
        |> case do
          {:ok, group} -> group
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp fetch_group_row!(%IdentityProvider{} = provider, id) do
    result =
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_id(id)
      |> Repo.fetch(DirectoryGroup.Query)

    case result do
      {:ok, group} -> group
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_group_external_id(_group, nil), do: :ok

  defp ensure_group_external_id(%DirectoryGroup{external_group_id: external_id}, external_id),
    do: :ok

  defp ensure_group_external_id(_group, _external_id), do: Repo.rollback(:invalid_scim_group)

  defp put_group_display!(provider, group, display) do
    changeset = DirectoryGroup.Changeset.rename(group, display)

    case Repo.update(changeset) do
      {:ok, updated_group} ->
        :ok = refresh_group_display(provider, updated_group, display)
        updated_group

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp lock_provider!(%IdentityProvider{} = provider) do
    locked = lock_provider_row!(provider)

    # The bearer resolved this provider once, at the start of the request. Sync
    # can be turned off while the request is still in flight — and the write then
    # re-stamped the epoch, recreated the rows a disable had just discarded, and
    # reapplied roles and runner access from a directory the account had stopped
    # trusting. The locked row decides.
    unless locked.scim_enabled do
      Repo.rollback(:directory_sync_disabled)
    end

    # Reaching a group write IS the directory pushing groups. Stamped under the
    # same lock the write holds, so the recompute below can tell an empty
    # snapshot from an absent one.
    first_push? = is_nil(locked.scim_groups_synced_at)
    {:ok, stamped} = locked |> IdentityProvider.Changeset.mark_groups_synced() |> Repo.update()
    {stamped, first_push?}
  end

  # The first push after sync is enabled is the moment the snapshot becomes
  # authoritative, so EVERY identity is recomputed against it — not just the ones
  # this particular group named. Otherwise a member the push never mentions keeps
  # whatever role the discarded snapshot had given them, indefinitely.
  defp identities_to_recompute(provider, _affected, true), do: provider_identities(provider)

  defp identities_to_recompute(_provider, affected, false), do: affected

  # Takes the provider already locked by `lock_provider!/1` — same transaction,
  # so its `authorization_version` is the current one.
  defp prepare_scim_group_authorization_change!(provider, []), do: provider

  defp prepare_scim_group_authorization_change!(provider, identities) do
    case bump_provider_authorization_version(provider) do
      {:ok, updated_provider} ->
        {:ok, _version} =
          Accounts.mark_directory_authorization_pending(
            Repo,
            provider.account_id,
            provider.id,
            Enum.map(identities, & &1.user_id),
            updated_provider.authorization_version
          )

        updated_provider

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate_scim_group_values(external_group_id, display, member_ids) do
    with :ok <- validate_optional_scim_string(external_group_id),
         :ok <- validate_optional_scim_string(display),
         true <-
           valid_scim_required_string?(external_group_id) or valid_scim_required_string?(display) do
      validate_scim_member_ids(member_ids)
    else
      false -> {:error, :invalid_scim_group}
      error -> error
    end
  end

  defp validate_scim_patch_member_ids(add_external_ids, remove_external_ids)
       when is_list(add_external_ids) and is_list(remove_external_ids) do
    if length(add_external_ids) + length(remove_external_ids) > @scim_group_member_max_count do
      {:error, :invalid_scim_group}
    else
      case validate_scim_member_ids(add_external_ids) do
        :ok -> validate_scim_member_ids(remove_external_ids)
        error -> error
      end
    end
  end

  defp validate_scim_patch_member_ids(_add_external_ids, _remove_external_ids),
    do: {:error, :invalid_scim_group}

  defp validate_scim_member_ids(member_ids) when is_list(member_ids) do
    cond do
      length(member_ids) > @scim_group_member_max_count ->
        {:error, :invalid_scim_group}

      Enum.all?(member_ids, &Repo.valid_uuid?/1) ->
        :ok

      true ->
        {:error, :invalid_scim_group}
    end
  end

  defp validate_scim_member_ids(_member_ids), do: {:error, :invalid_scim_group}

  defp validate_optional_scim_string(nil), do: :ok

  defp validate_optional_scim_string(value) when is_binary(value) do
    if String.length(value) <= @scim_group_string_max_length,
      do: :ok,
      else: {:error, :invalid_scim_group}
  end

  defp validate_optional_scim_string(_value), do: {:error, :invalid_scim_group}

  defp valid_scim_required_string?(value) when is_binary(value),
    do: value != "" and String.length(value) <= @scim_group_string_max_length

  defp valid_scim_required_string?(_value), do: false

  # The provider's identities for a set of server-issued SCIM User ids. An empty
  # id list resolves to none; valid ids owned by another provider/account are
  # indistinguishable from unknown ids.
  defp resolve_member_identity_ids(%IdentityProvider{}, []), do: []

  defp resolve_member_identity_ids(%IdentityProvider{} = provider, ids) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.scim_not_deleted()
    |> UserIdentity.Query.by_account_id(provider.account_id)
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_ids(ids)
    |> Repo.all()
    |> Enum.map(& &1.id)
  end

  # Make the group's synced membership exactly `desired_ids`: revive/keep the
  # rows that should stay, insert the new ones, soft-delete the rest. Returns
  # the identities whose membership actually changed (added or removed), for the
  # role recompute.
  defp replace_group_members(
         %IdentityProvider{} = provider,
         %DirectoryGroup{} = group,
         display,
         desired_ids
       ) do
    current = current_group_members(provider, group.id)
    current_ids = Enum.map(current, & &1.user_identity_id)

    to_remove = Enum.reject(current, &(&1.user_identity_id in desired_ids))
    to_add = Enum.reject(desired_ids, &(&1 in current_ids))

    soft_delete_group_members(to_remove)
    insert_group_members(provider, group, display, to_add)

    changed_ids = Enum.map(to_remove, & &1.user_identity_id) ++ to_add
    load_identities(provider, changed_ids)
  end

  defp add_group_members(%IdentityProvider{} = provider, %DirectoryGroup{} = group, add_ids) do
    current_ids =
      provider
      |> current_group_members(group.id)
      |> Enum.map(& &1.user_identity_id)

    # A PATCH member op carries no displayName; the group's name is whatever its
    # PUT-stamped sibling rows already say, which is what the read aggregates.
    to_add = Enum.reject(add_ids, &(&1 in current_ids))
    insert_group_members(provider, group, nil, to_add)
    load_identities(provider, to_add)
  end

  defp remove_group_members(%IdentityProvider{} = provider, %DirectoryGroup{} = group, remove_ids) do
    to_remove =
      provider
      |> current_group_members(group.id)
      |> Enum.filter(&(&1.user_identity_id in remove_ids))

    soft_delete_group_members(to_remove)
    load_identities(provider, Enum.map(to_remove, & &1.user_identity_id))
  end

  # #13: one insert_all / one update_all for the join-table rows, not a write
  # per member. `to_add` are already-resolved provider identities + the group
  # is theirs, so the rows are valid by construction; on_conflict guards a
  # re-add race against the live-row partial unique.
  defp insert_group_members(_provider, _group, _display, []), do: :ok

  defp insert_group_members(
         %IdentityProvider{} = provider,
         %DirectoryGroup{} = group,
         display,
         user_identity_ids
       ) do
    now = DateTime.utc_now()

    rows =
      Enum.map(user_identity_ids, fn user_identity_id ->
        %{
          id: Repo.generate_id(),
          account_id: provider.account_id,
          provider_id: provider.id,
          directory_group_id: group.id,
          external_group_id: group.external_group_id,
          external_group_display: display,
          user_identity_id: user_identity_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(DirectoryGroupMember, rows, on_conflict: :nothing)
    :ok
  end

  defp soft_delete_group_members([]), do: :ok

  defp soft_delete_group_members(members) do
    now = DateTime.utc_now()
    ids = Enum.map(members, & &1.id)

    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_ids(ids)
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    :ok
  end

  # Refresh the IdP's group label wherever it is stored: on membership rows and
  # both authorization mapping snapshots. Identity remains the immutable group
  # UUID; a PUT that omits displayName must not erase the display snapshot.
  defp refresh_group_display(_provider, _group, nil), do: :ok

  defp refresh_group_display(%IdentityProvider{} = provider, %DirectoryGroup{} = group, display) do
    now = DateTime.utc_now()

    members_queryable =
      DirectoryGroupMember.Query.not_deleted()
      |> DirectoryGroupMember.Query.by_directory_group_id(group.id)

    Repo.update_all(members_queryable, set: [external_group_display: display, updated_at: now])

    GroupRoleMapping.Query.not_deleted()
    |> GroupRoleMapping.Query.by_provider_id(provider.id)
    |> GroupRoleMapping.Query.by_directory_group_id(group.id)
    |> Repo.update_all(set: [external_group_display: display, updated_at: now])

    GroupRunnerAccessMapping.Query.not_deleted()
    |> GroupRunnerAccessMapping.Query.by_provider_id(provider.id)
    |> GroupRunnerAccessMapping.Query.by_directory_group_id(group.id)
    |> Repo.update_all(set: [external_group_display: display, updated_at: now])

    :ok
  end
end
