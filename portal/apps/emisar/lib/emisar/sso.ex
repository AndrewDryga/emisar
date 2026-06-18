defmodule Emisar.SSO do
  @moduledoc """
  OIDC single sign-on: per-account identity-provider configuration, the
  relying-party login flow, and the `user_identities` bindings. The public
  authorization boundary for SSO — distinct from `Emisar.OAuth`, which is
  emisar-as-an-OAuth-*provider* for the MCP bridge.

  Config reads/writes are `%Subject{}`-gated (`manage_sso` + the enterprise
  plan). The login flow (`begin_auth`/`complete_auth`) is pre-Subject — it IS
  the authentication — and resolves an identity strictly by `(provider, sub)`,
  **never by email** (the account-takeover guard). An unknown `sub`
  JIT-provisions a fresh user + identity + membership when the provider's
  `provisioner` is `:jit`.
  """
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Billing, Crypto, Repo, Users}
  alias Emisar.Auth.Subject

  alias Emisar.SSO.{Authorizer, DirectoryGroupMember, GroupRoleMapping}
  alias Emisar.SSO.{IdentityProvider, LinkRequest, OIDC, UserIdentity}

  require Logger

  # -- Config reads ----------------------------------------------------

  def list_providers_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_configure_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.ordered_by_name()
      |> Authorizer.for_subject(subject)
      |> Repo.list(IdentityProvider.Query, opts)
    end
  end

  def fetch_provider_by_id(id, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject),
         true <- Repo.valid_uuid?(id) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(IdentityProvider.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Changeset for the SSO provider config form (phx-change validation)."
  def change_provider(%IdentityProvider{} = provider \\ %IdentityProvider{}, attrs \\ %{}),
    do: IdentityProvider.Changeset.form(provider, attrs)

  @doc """
  Changeset for the group→role mapping form. From a `%IdentityProvider{}` it's a
  create form (account/provider come from the provider); from a `%GroupRoleMapping{}`
  it's the inline edit form (only display + role are cast). The owner-exclusion +
  required-field validations match the server write path.
  """
  def change_group_mapping(provider_or_mapping, attrs \\ %{})

  def change_group_mapping(%IdentityProvider{} = provider, attrs),
    do: GroupRoleMapping.Changeset.create(provider.account_id, provider.id, attrs)

  def change_group_mapping(%GroupRoleMapping{} = mapping, attrs),
    do: GroupRoleMapping.Changeset.update(mapping, attrs)

  # -- Config mutations ------------------------------------------------

  @doc "Create an SSO connection. `manage_sso` + the Enterprise plan. `{:ok, provider} | {:error, reason}`."
  def configure_provider(attrs, %Subject{account: account} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      multi = configure_multi(account.id, attrs, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{provider: provider}} -> {:ok, provider}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Update a connection's config (locked re-read). `manage_sso` + Enterprise. `{:ok, provider} | {:error, reason}`."
  def update_provider(%IdentityProvider{id: id}, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: fn loaded_provider ->
          changeset = IdentityProvider.Changeset.update(loaded_provider, attrs)

          if disabling_last_required_provider?(loaded_provider, changeset),
            do: :require_sso_last_provider,
            else: changeset
        end,
        audit: &Audit.Events.identity_provider_updated(subject, &1)
      )
    end
  end

  @doc "Soft-delete a connection. `manage_sso` + Enterprise. `{:ok, provider} | {:error, reason}`."
  def delete_provider(%IdentityProvider{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: fn loaded_provider ->
          if removing_last_required_provider?(loaded_provider),
            do: :require_sso_last_provider,
            else: IdentityProvider.Changeset.delete(loaded_provider)
        end,
        audit: &Audit.Events.identity_provider_deleted(subject, &1)
      )
    end
  end

  # Lock-out guard — the mirror of team_live's enable-side check: when the account
  # requires SSO, the LAST enabled connection can't be disabled or deleted out from
  # under it (else everyone, owners included, is bricked). Judged inside the
  # provider's fetch_and_update :with (under the row lock); the reads join the same
  # transaction. Returning the atom (not a changeset) aborts as {:error, atom}.
  defp disabling_last_required_provider?(provider, changeset),
    do:
      Ecto.Changeset.get_change(changeset, :enabled) == false and
        last_required_provider?(provider)

  defp removing_last_required_provider?(provider),
    do: provider.enabled and last_required_provider?(provider)

  defp last_required_provider?(provider),
    do: account_requires_sso?(provider.account_id) and not another_enabled_provider?(provider)

  defp account_requires_sso?(account_id),
    do: match?({:ok, %{require_sso: true}}, Accounts.fetch_account_by_id(account_id))

  defp another_enabled_provider?(provider) do
    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.enabled()
    |> IdentityProvider.Query.by_account_id(provider.account_id)
    |> IdentityProvider.Query.excluding_id(provider.id)
    |> Repo.exists?()
  end

  defp configure_multi(account_id, attrs, subject) do
    changeset = IdentityProvider.Changeset.create(account_id, attrs)

    Multi.new()
    |> Multi.insert(:provider, changeset)
    |> Multi.insert(:audit, fn %{provider: provider} ->
      Audit.Events.identity_provider_configured(subject, provider)
    end)
  end

  # -- Sign-in discovery (pre-Subject) ---------------------------------

  @doc "Internal — sign-in: an account's enabled SSO providers, name-ordered, for the per-account sign-in page (pre-Subject)."
  def list_enabled_providers_for_account(account_id) when is_binary(account_id) do
    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.enabled()
    |> IdentityProvider.Query.by_account_id(account_id)
    |> IdentityProvider.Query.ordered_by_name()
    |> Repo.all()
  end

  @doc "Internal — sign-in: an enabled provider by id, for the begin-auth redirect (pre-Subject)."
  def fetch_provider_for_sign_in(id) do
    if Repo.valid_uuid?(id) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.enabled()
      |> IdentityProvider.Query.by_id(id)
      |> peek_or_not_found()
    else
      {:error, :not_found}
    end
  end

  # -- Login flow (pre-Subject — it IS the authentication) -------------

  @doc """
  Build the IdP authorization redirect for an enabled provider. The public
  boundary — the web layer never calls the internal `OIDC` wrapper directly.
  Returns `{:ok, %{authorize_url, state, nonce, pkce_verifier}}`; the web layer
  stashes the secrets (UA-bound, one-time-use) for `complete_auth/3`.
  """
  def begin_auth(%IdentityProvider{} = provider, opts),
    do: OIDC.begin_authorization(provider, opts)

  @doc """
  Validate the OIDC callback (state/nonce/PKCE + ID-token signature/iss/aud/exp
  + RFC 9207 issuer check), then resolve the identity strictly by
  `(provider, sub)` — never email. An unknown `sub` JIT-provisions a fresh user
  when the provider's `provisioner` is `:jit`, or is captured as a pending link
  request and returns `{:error, :identity_pending_approval}` when it is
  `:manual`. Returns `{:ok, %{user, identity, provider}}` for the web layer to
  log in.
  """
  def complete_auth(%IdentityProvider{} = provider, params, stashed) do
    with {:ok, %{identifier: identifier, claims: claims}} <-
           OIDC.verify_callback(provider, params, stashed),
         :ok <- ensure_email_domain_allowed(provider, claims),
         {:ok, result} <- resolve_or_provision_identity(provider, identifier, claims) do
      {:ok, Map.put(result, :provider, provider)}
    end
  end

  defp resolve_or_provision_identity(%IdentityProvider{} = provider, identifier, claims) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_and_identifier(provider.id, identifier)

    case Repo.peek(queryable) do
      %UserIdentity{} = identity -> touch_and_load(identity)
      nil -> provision_for(provider, identifier, claims)
    end
  end

  defp touch_and_load(%UserIdentity{} = identity) do
    changeset = UserIdentity.Changeset.touch_last_seen(identity)

    with {:ok, %UserIdentity{} = identity} <- Repo.update(changeset),
         {:ok, user} <- Users.fetch_user_by_id(identity.user_id) do
      {:ok, %{user: user, identity: identity}}
    end
  end

  defp provision_for(%IdentityProvider{provisioner: :jit} = provider, identifier, claims) do
    multi = build_provision_multi(provider, identifier, claims)

    case Repo.commit_multi(multi) do
      {:ok, %{user: user, identity: identity}} ->
        {:ok, %{user: user, identity: identity}}

      {:error, %Ecto.Changeset{} = changeset} ->
        # #9: a concurrent first login created this identity — converge on it
        # (re-resolve peek-hits the winner) rather than failing the login.
        if Repo.Changeset.unique_constraint_error?(changeset),
          do: resolve_or_provision_identity(provider, identifier, claims),
          else: {:error, changeset}

      {:error, :email_taken} ->
        # The email matches an existing user. If they're a member, park a link
        # request for an admin to approve (never auto-merge, C1); otherwise it's
        # a genuine collision (a non-member owns that email) — fail closed.
        case capture_member_link(provider, identifier, claims["email"], claims["name"], claims) do
          :captured -> {:error, :identity_pending_approval}
          :no_match -> {:error, :email_taken}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A `:manual`-provisioner connection never auto-creates. The unknown identity
  # is captured as a pending link request (the real `sub` + claims, so an admin
  # recognizes the person) and parked — re-attempts upsert, never pile up.
  defp provision_for(%IdentityProvider{provisioner: :manual} = provider, identifier, claims) do
    _ = capture_link_request(provider, identifier, claims["email"], claims["name"], claims)
    {:error, :identity_pending_approval}
  end

  # Capture (or refresh) a pending link request. When the email matches an
  # EXISTING account member, the request records them (`matched_user_id`) so an
  # admin can link the IdP identity to that user instead of failing/duplicating
  # — never an auto-merge (C1): the admin's approval is still the gate. The
  # display email is the raw value (helps the admin recognize who's asking); the
  # binding on approval uses the captured id, not the email.
  defp capture_link_request(%IdentityProvider{} = provider, identifier, email, full_name, claims) do
    attrs = %{
      provider_identifier: identifier,
      email: email,
      full_name: full_name,
      claims: claims,
      matched_user_id: matched_member_id(provider, email)
    }

    changeset = LinkRequest.Changeset.create(provider.account_id, provider.id, attrs)

    Repo.insert(changeset,
      on_conflict: {:replace, [:email, :full_name, :claims, :matched_user_id, :updated_at]},
      conflict_target: [:provider_id, :provider_identifier]
    )
  end

  # Collision variant (for `:jit`/SCIM): park a link request ONLY when the email
  # matches an existing member, so an admin has someone to link to. A non-member
  # collision has no link target — the caller keeps the genuine `:email_taken`
  # (C1). Returns `:captured | :no_match`.
  defp capture_member_link(%IdentityProvider{} = provider, identifier, email, full_name, claims) do
    if matched_member_id(provider, email) do
      _ = capture_link_request(provider, identifier, email, full_name, claims)
      :captured
    else
      :no_match
    end
  end

  # The existing account MEMBER an inbound email matches, if any. Restricted to
  # members (never pulls an outsider into the account); a lookup for the admin,
  # not a merge.
  defp matched_member_id(%IdentityProvider{} = provider, email) when is_binary(email) do
    with {:ok, user} <- Users.fetch_user_by_email(email),
         %Accounts.Membership{} <- Accounts.peek_sync_membership(provider.account_id, user.id) do
      user.id
    else
      _ -> nil
    end
  end

  defp matched_member_id(_provider, _email), do: nil

  defp build_provision_multi(%IdentityProvider{} = provider, identifier, claims, opts \\ []) do
    created_by = Keyword.get(opts, :created_by, :provider)
    provisioned_via = Keyword.get(opts, :provisioned_via, :oidc_jit)
    audit = Keyword.get(opts, :audit, &Audit.Events.user_provisioned_via_sso(&1, provider))
    user_attrs = %{email: verified_email(claims), full_name: claims["name"]}

    Multi.new()
    |> Multi.run(:user, fn _repo, _changes -> Users.provision_sso_user(user_attrs) end)
    |> Multi.run(:identity, fn _repo, %{user: user} ->
      create_identity(provider, user, identifier, claims, created_by, provisioned_via)
    end)
    |> Multi.run(:membership, fn _repo, %{user: user} ->
      Accounts.provision_sso_membership(provider.account_id, user.id, provider.default_role)
    end)
    |> Multi.insert(:audit, fn %{user: user} -> audit.(user) end)
  end

  defp create_identity(%IdentityProvider{} = provider, user, identifier, claims, created_by, via) do
    attrs = %{
      provider_identifier: identifier,
      claims: claims,
      created_by: created_by,
      provisioned_via: via
    }

    changeset = UserIdentity.Changeset.create(provider.account_id, provider.id, user.id, attrs)
    Repo.insert(changeset)
  end

  # R6/§9 C2: trust the email only when the IdP marks it verified (or a
  # domain-authoritative `hd` is present). Otherwise nil — the user is
  # identified solely by `(provider, sub)`.
  defp verified_email(%{"email" => email} = claims) when is_binary(email) do
    # `email_verified` arrives as a boolean from a JWT-decoded ID token but as
    # the string "true" from some IdPs / the SCIM query-param path — accept both.
    # A domain-authoritative Google `hd` is the other accepted signal (R6/§9 C2),
    # but an explicit `email_verified: false` overrides it (#7 — don't trust a
    # forged `hd` paired with an unverified email).
    if claims["email_verified"] in [true, "true"] or
         (is_binary(claims["hd"]) and claims["email_verified"] != false),
       do: email,
       else: nil
  end

  defp verified_email(_claims), do: nil

  # H1: when the provider restricts a domain, the IdP-asserted `hd` (preferred)
  # or the verified email's domain must match; a login with no verified domain
  # is refused. No restriction (nil) → rely on the IdP's membership boundary.
  defp ensure_email_domain_allowed(%IdentityProvider{allowed_email_domain: nil}, _claims), do: :ok

  defp ensure_email_domain_allowed(%IdentityProvider{allowed_email_domain: domain}, claims) do
    if claimed_domain_matches?(claims, domain),
      do: :ok,
      else: {:error, :email_domain_not_allowed}
  end

  defp claimed_domain_matches?(%{"hd" => hd}, domain) when is_binary(hd),
    do: domains_equal?(hd, domain)

  defp claimed_domain_matches?(claims, domain) do
    case verified_email(claims) do
      nil -> false
      email -> email_in_domain?(email, domain)
    end
  end

  defp email_in_domain?(email, domain) do
    case String.split(email, "@") do
      [_local, host] -> domains_equal?(host, domain)
      _ -> false
    end
  end

  defp domains_equal?(a, b), do: String.downcase(a) == String.downcase(b)

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
        |> IdentityProvider.Query.by_scim_token_prefix(prefix)

      with %IdentityProvider{scim_token_hash: hash} = provider <- Repo.peek(queryable),
           true <- is_binary(hash),
           true <- Crypto.secure_compare(hash, Crypto.hash(raw)) do
        {:ok, provider}
      else
        _ -> {:error, :unauthorized}
      end
    end
  end

  # -- Directory sync (SCIM) — user lifecycle (internal, provider-scoped) --

  @doc """
  Internal — SCIM provision: reconcile a directory user to a `user_identity`
  by `(provider, externalId)`, where the externalId IS the binding identifier
  (decision 4 — it's stored as BOTH `provider_identifier` and
  `scim_external_id`). An existing identity is reused (idempotent — a re-POST
  never duplicates); otherwise a fresh user + identity (`created_by: :provider`,
  `provisioned_via: :scim`) + membership at `provider.default_role` are created
  in one `Multi`. Trusts the IdP's email within the connection (collision →
  `:email_taken`, never a merge). `{:ok, %{user, identity, membership}}`.
  """
  def scim_provision_user(%IdentityProvider{} = provider, attrs) do
    external_id = attrs[:external_id] || attrs["external_id"]

    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_and_identifier(provider.id, external_id)

    case Repo.peek(queryable) do
      %UserIdentity{} = identity -> load_provisioned(provider, identity)
      nil -> provision_scim_user(provider, external_id, attrs)
    end
  end

  # A re-POST of an existing identity RE-PROVISIONS the user (#4/#10): some IdPs
  # re-create rather than PATCH active:true. Reinstate a suspended membership,
  # or create one if it was removed (soft-deleted) while the identity lived on,
  # and flip the identity back to scim_active. Idempotent for an active member.
  defp load_provisioned(%IdentityProvider{} = provider, %UserIdentity{} = identity) do
    with {:ok, user} <- Users.fetch_user_by_id(identity.user_id),
         {:ok, membership} <- ensure_active_membership(provider, user),
         {:ok, identity} <- ensure_scim_active(identity) do
      {:ok, %{user: user, identity: identity, membership: membership}}
    end
  end

  defp ensure_active_membership(%IdentityProvider{} = provider, user) do
    case Accounts.peek_sync_membership(provider.account_id, user.id) do
      %Accounts.Membership{disabled_at: nil} = membership ->
        {:ok, membership}

      %Accounts.Membership{} = membership ->
        Accounts.sync_reinstate_membership(membership, provider)

      nil ->
        Accounts.provision_sso_membership(provider.account_id, user.id, provider.default_role)
    end
  end

  defp ensure_scim_active(%UserIdentity{scim_active: true} = identity), do: {:ok, identity}

  defp ensure_scim_active(%UserIdentity{} = identity),
    do: identity |> UserIdentity.Changeset.set_scim_active(true) |> Repo.update()

  defp provision_scim_user(%IdentityProvider{} = provider, external_id, attrs) do
    multi = build_scim_provision_multi(provider, external_id, attrs)

    case Repo.commit_multi(multi) do
      {:ok, %{user: user, identity: identity, membership: membership}} ->
        {:ok, %{user: user, identity: identity, membership: membership}}

      {:error, %Ecto.Changeset{} = changeset} ->
        # #9: lost a concurrent first-provision race — the winner created the
        # identity. Converge on it (the fetch-or-create race-safe shape) rather
        # than surfacing the unique-violation changeset. The re-call peek-hits.
        if Repo.Changeset.unique_constraint_error?(changeset),
          do: scim_provision_user(provider, attrs),
          else: {:error, changeset}

      {:error, :email_taken} ->
        # The SCIM email matches an existing user. If they're a member, park a
        # link request for an admin to approve (Okta retries and self-heals once
        # linked); a non-member is a genuine collision. Always 409; never merge (C1).
        email = attrs[:email] || attrs["email"]
        full_name = attrs[:full_name] || attrs["full_name"]
        _ = capture_member_link(provider, external_id, email, full_name, %{})
        {:error, :email_taken}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_scim_provision_multi(%IdentityProvider{} = provider, external_id, attrs) do
    user_attrs = %{
      email: attrs[:email] || attrs["email"],
      full_name: attrs[:full_name] || attrs["full_name"]
    }

    Multi.new()
    |> Multi.run(:user, fn _repo, _changes -> Users.provision_sso_user(user_attrs) end)
    |> Multi.run(:identity, fn _repo, %{user: user} ->
      create_scim_identity(provider, user, external_id, attrs)
    end)
    |> Multi.run(:membership, fn _repo, %{user: user} ->
      Accounts.provision_sso_membership(provider.account_id, user.id, provider.default_role)
    end)
    |> Multi.insert(:audit, fn %{user: user} ->
      Audit.Events.user_provisioned_via_scim(user, provider)
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
      scim_active: Map.get(attrs, :active, Map.get(attrs, "active", true))
    }

    provider.account_id
    |> UserIdentity.Changeset.create(provider.id, user.id, identity_attrs)
    |> Repo.insert()
  end

  @doc """
  Internal — SCIM deprovision (`active:false` / DELETE): suspend the member's
  access in the provider's account, then mark the identity `scim_active: false`.
  The last-active-owner guard fires inside `Accounts.sync_suspend_membership/2`
  — a deprovision can never lock out the last owner. `{:error, :not_found}`
  when no identity matches; `{:error, :last_owner}` when refused (the identity
  flag is left untouched on a refusal).
  """
  def scim_deactivate_user(%IdentityProvider{} = provider, external_id) do
    with {:ok, identity} <- fetch_scim_identity(provider, external_id),
         {:ok, membership} <- sync_membership(provider, identity.user_id, :deactivate),
         {:ok, identity} <- Repo.update(UserIdentity.Changeset.set_scim_active(identity, false)) do
      {:ok, %{identity: identity, membership: membership}}
    end
  end

  @doc """
  Internal — SCIM re-provision (`active:true`): reinstate the suspended
  membership, then mark the identity `scim_active: true`. `{:error, :not_found}`
  when no identity matches.
  """
  def scim_reactivate_user(%IdentityProvider{} = provider, external_id) do
    with {:ok, identity} <- fetch_scim_identity(provider, external_id),
         {:ok, membership} <- sync_membership(provider, identity.user_id, :reactivate),
         {:ok, identity} <- Repo.update(UserIdentity.Changeset.set_scim_active(identity, true)) do
      {:ok, %{identity: identity, membership: membership}}
    end
  end

  # The membership write owns its own transaction + side effects (the suspend
  # kills sessions / revokes keys AFTER it commits), so it can't be wrapped in
  # an outer Multi alongside the identity flag — fetch_and_update raises on a
  # nested after_commit (CLAUDE.md §55). The identity flag is bookkeeping that
  # the next reconcile self-corrects, so sequencing it after is safe.
  defp sync_membership(%IdentityProvider{} = provider, user_id, transition) do
    case Accounts.peek_sync_membership(provider.account_id, user_id) do
      %Accounts.Membership{} = membership ->
        sync_membership_transition(membership, provider, transition)

      nil ->
        {:error, :not_found}
    end
  end

  defp sync_membership_transition(membership, provider, :deactivate),
    do: Accounts.sync_suspend_membership(membership, provider)

  defp sync_membership_transition(membership, provider, :reactivate),
    do: Accounts.sync_reinstate_membership(membership, provider)

  @doc "Internal — SCIM read: the identity for `(provider, externalId)` (the IdP probes before create)."
  def scim_fetch_user(%IdentityProvider{} = provider, external_id),
    do: fetch_scim_identity(provider, external_id)

  @doc """
  Internal — SCIM read: the provider's directory identities, paginated (the
  IdP's list/filter probe). An optional `:scim_filter` (`{:user_name, v}` |
  `{:external_id, v}`) is applied in the query so the IdP's existence probe
  matches a user *anywhere* in the directory, not just the fetched page —
  without it, a `userName eq` check past the page limit would miss the user
  and the IdP would re-provision a duplicate.
  """
  def scim_list_users(%IdentityProvider{} = provider, opts \\ []) do
    {scim_filter, opts} = Keyword.pop(opts, :scim_filter)

    # `by_provider_id` already implies the account (a provider is account-bound),
    # but this read has no `%Subject{}` — the bearer's provider-scope is the
    # authz — so scope by the explicit account too (house rule: an explicit
    # account is always filtered on, belt-and-suspenders).
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_account_id(provider.account_id)
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> apply_scim_filter(scim_filter)
    |> UserIdentity.Query.ordered_by_recent()
    |> Repo.list(UserIdentity.Query, opts)
  end

  defp apply_scim_filter(queryable, {:user_name, value}),
    do: UserIdentity.Query.by_user_name(queryable, value)

  defp apply_scim_filter(queryable, {:external_id, value}),
    do: UserIdentity.Query.by_external_id(queryable, value)

  defp apply_scim_filter(queryable, _none), do: queryable

  defp fetch_scim_identity(%IdentityProvider{} = provider, external_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> peek_or_not_found()
  end

  # The shared peek-and-tag tail for the "live row or :not_found" lookups.
  defp peek_or_not_found(queryable) do
    case Repo.peek(queryable) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  # -- Directory sync (SCIM) — groups → roles (internal, provider-scoped) --

  # `:admin > :operator > :viewer`. `:owner` is deliberately absent — sync
  # never grants owner (decision 7). `Auth.Role` has no rank by design, so the
  # precedence the recompute needs lives here, narrowed to the sync-assignable
  # roles, most-privileged first.
  @sync_role_precedence [:admin, :operator, :viewer]

  @doc """
  Internal — SCIM group upsert (`PUT /Groups`): refresh the group's display on
  any matching role mapping and replace its synced membership to be exactly the
  provider's identities whose `scim_external_id`/`provider_identifier` is in
  `member_external_ids` (unknown ids are ignored — the member may not be
  provisioned yet). Every identity whose group membership changed (added or
  removed) has its role recomputed. `{:ok, group_summary}`.
  """
  def scim_upsert_group(%IdentityProvider{} = provider, attrs) do
    external_group_id = attrs[:external_id] || attrs["external_id"]
    display = attrs[:display] || attrs["display"]
    member_external_ids = attrs[:member_external_ids] || attrs["member_external_ids"] || []

    # Best-effort by design (not one transaction): SCIM pushes are idempotent
    # and the IdP re-drives them, so a partial apply self-heals on the next
    # push. Wrapping the membership replace + per-member role recompute (each a
    # row-locked membership update + audit) in a single transaction would hold
    # locks across an unbounded member set for no gain over that self-heal.
    desired_ids = resolve_member_identity_ids(provider, member_external_ids)
    _ = refresh_group_display(provider, external_group_id, display)

    affected = replace_group_members(provider, external_group_id, desired_ids)
    :ok = recompute_role_for_affected(provider, affected)

    {:ok,
     %{external_group_id: external_group_id, display: display, member_count: length(desired_ids)}}
  end

  @doc """
  Internal — SCIM group patch (`PATCH /Groups` member ops): add/remove members
  of a group, then recompute the role of every affected identity. Add ids are
  resolved to the provider's identities (unknown ids ignored); remove ids
  soft-delete the matching links. `{:ok, group_summary}`.
  """
  def scim_patch_group_members(
        %IdentityProvider{} = provider,
        external_group_id,
        add_external_ids,
        remove_external_ids
      ) do
    add_ids = resolve_member_identity_ids(provider, add_external_ids)
    remove_ids = resolve_member_identity_ids(provider, remove_external_ids)

    added = add_group_members(provider, external_group_id, add_ids)
    removed = remove_group_members(provider, external_group_id, remove_ids)

    affected = Enum.uniq(added ++ removed)
    :ok = recompute_role_for_affected(provider, affected)

    {:ok, %{external_group_id: external_group_id, added: length(added), removed: length(removed)}}
  end

  @doc """
  Internal — recompute one identity's role from its synced group memberships:
  the HIGHEST mapped role over the groups it belongs to (`:admin > :operator >
  :viewer`; never `:owner`), applied to its membership in the provider's account
  via `Accounts.sync_set_membership_role/3`. An identity in NO mapped group
  resets to the provider's `default_role` (least-privilege on directory
  removal); a member who is currently an account `:owner` is left untouched.
  `{:ok, membership} | {:error, reason}`.
  """
  def recompute_role_for_identity(%IdentityProvider{} = provider, %UserIdentity{} = identity),
    do: recompute_role_for_identity(provider, identity, provider_role_mappings(provider))

  # `mappings` is hoisted once per group push by `recompute_role_for_affected/2`
  # (#12 — fetched once, not once per affected member).
  defp recompute_role_for_identity(
         %IdentityProvider{} = provider,
         %UserIdentity{} = identity,
         mappings
       ) do
    # #3: an identity in NO mapped group resets to the provider `default_role`
    # (least-privilege — removing a user from their last privileged group in the
    # directory demotes them here), rather than keeping a stale elevated role.
    role = highest_mapped_role(identity, mappings) || provider.default_role
    membership = Accounts.peek_sync_membership(provider.account_id, identity.user_id)
    apply_recomputed_role(provider, role, membership)
  end

  # Apply a recomputed role to a (possibly nil) membership — the only per-row DB
  # write on the bulk path. Sync never re-roles a human owner (#3, defense against
  # clobbering a deliberate owner grant); a missing membership is :not_found.
  defp apply_recomputed_role(_provider, _role, %Accounts.Membership{role: :owner} = membership),
    do: {:ok, membership}

  defp apply_recomputed_role(provider, role, %Accounts.Membership{} = membership),
    do: Accounts.sync_set_membership_role(membership, role, provider)

  defp apply_recomputed_role(_provider, _role, nil), do: {:error, :not_found}

  defp recompute_role_for_affected(%IdentityProvider{}, []), do: :ok

  defp recompute_role_for_affected(%IdentityProvider{} = provider, identities) do
    mappings = provider_role_mappings(provider)
    group_ids_by_identity = group_ids_by_identity(identities)
    user_ids = Enum.map(identities, & &1.user_id)

    membership_by_user =
      Map.new(Accounts.list_sync_memberships(provider.account_id, user_ids), &{&1.user_id, &1})

    Enum.each(identities, fn identity ->
      group_ids = Map.get(group_ids_by_identity, identity.id, [])
      role = highest_role_for_groups(group_ids, mappings) || provider.default_role
      membership = Map.get(membership_by_user, identity.user_id)

      case apply_recomputed_role(provider, role, membership) do
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
  defp group_ids_by_identity(identities) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_user_identity_ids(Enum.map(identities, & &1.id))
    |> Repo.all()
    |> Enum.group_by(& &1.user_identity_id, & &1.external_group_id)
  end

  defp provider_role_mappings(%IdentityProvider{} = provider) do
    GroupRoleMapping.Query.not_deleted()
    |> GroupRoleMapping.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  # The most-privileged mapped role over the identity's groups (`@sync_role_precedence`);
  # nil when the identity is in no mapped group.
  defp highest_mapped_role(%UserIdentity{} = identity, mappings),
    do: highest_role_for_groups(identity_group_ids(identity), mappings)

  # The most-privileged mapped role over a set of group ids — shared by the
  # single-identity path (which queries the ids) and the batched bulk path
  # (which pre-fetches them in one query).
  defp highest_role_for_groups(group_ids, mappings) do
    roles =
      mappings
      |> Enum.filter(&(&1.external_group_id in group_ids))
      |> Enum.map(& &1.role)

    Enum.find(@sync_role_precedence, &(&1 in roles))
  end

  # #14: a DirectoryGroupMember always belongs to its user_identity's provider,
  # so no in-app provider filter is needed.
  defp identity_group_ids(%UserIdentity{} = identity) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_user_identity_id(identity.id)
    |> Repo.all()
    |> Enum.map(& &1.external_group_id)
  end

  # The provider's identities for a set of SCIM member ids (decision-4 union of
  # scim_external_id / provider_identifier). An empty id list resolves to none.
  defp resolve_member_identity_ids(%IdentityProvider{}, []), do: []

  defp resolve_member_identity_ids(%IdentityProvider{} = provider, external_ids) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_external_ids(provider.id, external_ids)
    |> Repo.all()
    |> Enum.map(& &1.id)
  end

  # Make the group's synced membership exactly `desired_ids`: revive/keep the
  # rows that should stay, insert the new ones, soft-delete the rest. Returns
  # the identities whose membership actually changed (added or removed), for the
  # role recompute.
  defp replace_group_members(%IdentityProvider{} = provider, external_group_id, desired_ids) do
    current = current_group_members(provider, external_group_id)
    current_ids = Enum.map(current, & &1.user_identity_id)

    to_remove = Enum.reject(current, &(&1.user_identity_id in desired_ids))
    to_add = Enum.reject(desired_ids, &(&1 in current_ids))

    soft_delete_group_members(to_remove)
    insert_group_members(provider, external_group_id, to_add)

    changed_ids = Enum.map(to_remove, & &1.user_identity_id) ++ to_add
    load_identities(provider, changed_ids)
  end

  defp add_group_members(%IdentityProvider{} = provider, external_group_id, add_ids) do
    current_ids =
      provider
      |> current_group_members(external_group_id)
      |> Enum.map(& &1.user_identity_id)

    to_add = Enum.reject(add_ids, &(&1 in current_ids))
    insert_group_members(provider, external_group_id, to_add)
    load_identities(provider, to_add)
  end

  defp remove_group_members(%IdentityProvider{} = provider, external_group_id, remove_ids) do
    to_remove =
      provider
      |> current_group_members(external_group_id)
      |> Enum.filter(&(&1.user_identity_id in remove_ids))

    soft_delete_group_members(to_remove)
    load_identities(provider, Enum.map(to_remove, & &1.user_identity_id))
  end

  defp current_group_members(%IdentityProvider{} = provider, external_group_id) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_provider_and_group(provider.id, external_group_id)
    |> Repo.all()
  end

  # #13: one insert_all / one update_all for the join-table rows, not a write
  # per member. `to_add` are already-resolved provider identities + the group
  # is theirs, so the rows are valid by construction; on_conflict guards a
  # re-add race against the live-row partial unique.
  defp insert_group_members(_provider, _external_group_id, []), do: :ok

  defp insert_group_members(%IdentityProvider{} = provider, external_group_id, user_identity_ids) do
    now = DateTime.utc_now()

    rows =
      Enum.map(user_identity_ids, fn user_identity_id ->
        %{
          id: Repo.generate_id(),
          account_id: provider.account_id,
          provider_id: provider.id,
          external_group_id: external_group_id,
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

  defp load_identities(%IdentityProvider{}, []), do: []

  defp load_identities(%IdentityProvider{} = provider, identity_ids) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_ids(Enum.uniq(identity_ids))
    |> Repo.all()
  end

  # Refresh the IdP's group label on any matching role mapping so the config UI
  # shows the current group name. No mapping (group not mapped to a role) → a
  # no-op; the membership is still tracked for when a mapping is added.
  defp refresh_group_display(_provider, _external_group_id, nil), do: :ok

  defp refresh_group_display(%IdentityProvider{} = provider, external_group_id, display) do
    GroupRoleMapping.Query.not_deleted()
    |> GroupRoleMapping.Query.by_provider_id(provider.id)
    |> GroupRoleMapping.Query.by_external_group_id(external_group_id)
    |> Repo.update_all(set: [external_group_display: display, updated_at: DateTime.utc_now()])

    :ok
  end

  # -- Directory sync (SCIM) — config (Subject-gated) ------------------

  @doc """
  Enable directory sync on a provider: mint a SCIM bearer, store its
  prefix + hash + `scim_enabled: true`, and return the raw token ONCE
  (`{:ok, provider, raw_token}` — write-only, like every emisar secret).
  `manage_sso` on the enterprise plan.
  """
  def enable_scim(%IdentityProvider{} = provider, %Subject{} = subject),
    do: write_scim_token(provider, subject, enabled: true)

  @doc "Rotate a provider's SCIM bearer (invalidates the old one). Returns the new raw token once. `manage_sso` + enterprise."
  def rotate_scim_token(%IdentityProvider{} = provider, %Subject{} = subject),
    do: write_scim_token(provider, subject, enabled: true)

  defp write_scim_token(%IdentityProvider{id: id}, %Subject{} = subject, enabled: enabled) do
    with :ok <- ensure_can_configure_sso(subject) do
      {raw, prefix, hash} = Crypto.scim_token()

      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: &IdentityProvider.Changeset.scim_token(&1, prefix, hash, enabled),
        audit: &Audit.Events.identity_provider_updated(subject, &1)
      )
      |> case do
        {:ok, provider} -> {:ok, provider, raw}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Disable directory sync: clear the SCIM token + `scim_enabled: false`. `manage_sso` + enterprise."
  def disable_scim(%IdentityProvider{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: &IdentityProvider.Changeset.disable_scim/1,
        audit: &Audit.Events.identity_provider_updated(subject, &1)
      )
    end
  end

  # -- Directory sync (SCIM) — group→role mapping config (Subject-gated) --

  @doc "List a provider's group→role mappings. `manage_sso` + enterprise; account-scoped."
  def list_group_mappings(%IdentityProvider{id: provider_id}, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_configure_sso(subject) do
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_provider_id(provider_id)
      |> GroupRoleMapping.Query.ordered_by_group()
      |> Authorizer.for_subject(subject)
      |> Repo.list(GroupRoleMapping.Query, opts)
    end
  end

  @doc """
  Create a group→role mapping for a provider. `manage_sso` + enterprise; the
  provider must be in the subject's account. The changeset rejects `:owner` —
  sync can never grant owner (decision 7). `{:ok, mapping}`.
  """
  def create_group_mapping(%IdentityProvider{} = provider, attrs, %Subject{} = subject) do
    with {:ok, provider} <- fetch_provider_by_id(provider.id, subject) do
      multi = create_group_mapping_multi(provider, attrs, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{mapping: mapping}} -> {:ok, mapping}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_group_mapping_multi(%IdentityProvider{} = provider, attrs, %Subject{} = subject) do
    changeset = GroupRoleMapping.Changeset.create(provider.account_id, provider.id, attrs)

    Multi.new()
    |> Multi.insert(:mapping, changeset)
    |> Multi.insert(:audit, fn %{mapping: mapping} ->
      Audit.Events.group_role_mapping_created(subject, provider, mapping)
    end)
  end

  @doc "Update a group→role mapping (its role / display). `manage_sso` + enterprise; account-scoped. Rejects `:owner`."
  def update_group_mapping(%GroupRoleMapping{id: id}, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(GroupRoleMapping.Query,
        with: &GroupRoleMapping.Changeset.update(&1, attrs),
        audit: &Audit.Events.group_role_mapping_updated(subject, &1)
      )
    end
  end

  @doc "Soft-delete a group→role mapping. `manage_sso` + enterprise; account-scoped."
  def delete_group_mapping(%GroupRoleMapping{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(GroupRoleMapping.Query,
        with: &GroupRoleMapping.Changeset.delete/1,
        audit: &Audit.Events.group_role_mapping_deleted(subject, &1)
      )
    end
  end

  # -- Manual link requests (Subject-gated) ----------------------------

  @doc "List a provider's pending manual-link requests. `manage_sso` + enterprise; account-scoped."
  def list_link_requests(%IdentityProvider{id: provider_id}, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_configure_sso(subject) do
      LinkRequest.Query.all()
      |> LinkRequest.Query.by_provider_id(provider_id)
      |> LinkRequest.Query.ordered_by_recent()
      |> Authorizer.for_subject(subject)
      |> Repo.list(LinkRequest.Query, opts)
    end
  end

  @doc """
  Approve a pending manual-link request: provision the captured identity at the
  provider's `default_role` and delete the request, atomically. `manage_sso` +
  enterprise; account-scoped. Binds the captured `sub` (never email — H1).
  `{:ok, %{user: user, identity: identity}}`.
  """
  def approve_link_request(%LinkRequest{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject),
         {:ok, request} <- fetch_link_request(id, subject),
         {:ok, provider} <- fetch_provider_for_request(request, subject) do
      multi = approve_link_request_multi(provider, request, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{user: user, identity: identity}} -> {:ok, %{user: user, identity: identity}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Dismiss a pending manual-link request without provisioning. `manage_sso` + enterprise; account-scoped. `{:ok, request}`."
  def dismiss_link_request(%LinkRequest{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject),
         {:ok, request} <- fetch_link_request(id, subject) do
      multi =
        Multi.new()
        |> Multi.delete(:request, request)
        |> Multi.insert(:audit, Audit.Events.sso_link_request_dismissed(subject, request))

      case Repo.commit_multi(multi) do
        {:ok, %{request: request}} -> {:ok, request}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # No existing user matched → provision a fresh user (the original flow).
  defp approve_link_request_multi(
         %IdentityProvider{} = provider,
         %LinkRequest{matched_user_id: nil} = request,
         subject
       ) do
    provider
    |> build_provision_multi(request.provider_identifier, request.claims,
      created_by: :admin,
      provisioned_via: :manual,
      audit: &Audit.Events.sso_link_request_approved(subject, &1, provider)
    )
    |> Multi.delete(:link_request, request)
  end

  # An existing account member matched → bind this IdP identity to THAT user (no
  # new user, no email merge — the admin's approval is the gate). The identity
  # stores the captured id as BOTH provider_identifier + scim_external_id
  # (decision 4) so OIDC login and SCIM converge on it afterward; the user's
  # existing membership is left as-is (never downgraded, never granted owner).
  defp approve_link_request_multi(
         %IdentityProvider{} = provider,
         %LinkRequest{} = request,
         subject
       ) do
    Multi.new()
    |> Multi.run(:user, fn _repo, _changes ->
      fetch_matched_member(provider, request)
    end)
    |> Multi.run(:identity, fn _repo, %{user: user} ->
      link_identity(provider, user, request)
    end)
    |> Multi.run(:membership, fn _repo, %{user: user} ->
      ensure_active_membership(provider, user)
    end)
    |> Multi.insert(:audit, fn %{user: user} ->
      Audit.Events.sso_existing_user_linked(subject, user, provider)
    end)
    |> Multi.delete(:link_request, request)
  end

  # Re-verify at approval time (the match was recorded at capture): the matched
  # user must still exist AND still be a member of this account.
  defp fetch_matched_member(%IdentityProvider{} = provider, %LinkRequest{} = request) do
    with {:ok, user} <- Users.fetch_user_by_id(request.matched_user_id),
         %Accounts.Membership{} <- Accounts.peek_sync_membership(provider.account_id, user.id) do
      {:ok, user}
    else
      _ -> {:error, :matched_user_unavailable}
    end
  end

  defp link_identity(%IdentityProvider{} = provider, user, %LinkRequest{} = request) do
    attrs = %{
      provider_identifier: request.provider_identifier,
      scim_external_id: request.provider_identifier,
      claims: request.claims,
      created_by: :admin,
      provisioned_via: :manual
    }

    provider.account_id
    |> UserIdentity.Changeset.create(provider.id, user.id, attrs)
    |> Repo.insert()
  end

  # Account-scoped fetches for the already-permission-gated approve/dismiss paths.
  defp fetch_link_request(id, %Subject{} = subject) do
    LinkRequest.Query.all()
    |> LinkRequest.Query.by_id(id)
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(LinkRequest.Query)
  end

  defp fetch_provider_for_request(%LinkRequest{provider_id: provider_id}, %Subject{} = subject) do
    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.by_id(provider_id)
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(IdentityProvider.Query)
  end

  # -- Capabilities ----------------------------------------------------

  @doc "True when sessions via this provider satisfy MFA (decision 4 / N2) — drives the TOTP skip + `require_mfa` exemption."
  def provider_satisfies_mfa?(%IdentityProvider{satisfies_mfa: satisfies}), do: satisfies

  @doc """
  Internal — SSO sign-in flow: true when an SSO session (identified by its
  `user_identity_id`) satisfies the account's MFA requirement — its provider's
  `satisfies_mfa` is set. Evaluated on the freshly-resolved identity before the
  session subject exists. The `require_mfa` exemption gates on THIS, not merely
  on the session being SSO, so a provider marked `satisfies_mfa: false` still
  forces emisar TOTP. Returns false for a nil/unknown identity (fail closed).
  """
  def identity_satisfies_mfa?(user_identity_id) when is_binary(user_identity_id) do
    queryable =
      UserIdentity.Query.not_deleted() |> UserIdentity.Query.by_id(user_identity_id)

    case Repo.peek(queryable) do
      %UserIdentity{provider_id: provider_id} -> provider_satisfies_mfa_by_id?(provider_id)
      nil -> false
    end
  end

  def identity_satisfies_mfa?(_), do: false

  @doc """
  Internal — require_sso enforcement: is this session's SSO identity one of the
  account's own? (Pre-Subject.) Matches by the identity's `account_id` ALONE — it
  deliberately does NOT re-check that the provider is still enabled/not-deleted, so
  an already-signed-in SSO session survives a provider being disabled (until the
  token expires) rather than ripping live sessions out on a config change (mirrors
  `identity_satisfies_mfa?/1`). The last-enabled-provider removal guard
  (`update_provider`/`delete_provider`) is what keeps the account from being stranded.
  """
  def identity_belongs_to_account?(user_identity_id, account_id)
      when is_binary(user_identity_id) and is_binary(account_id) do
    queryable = UserIdentity.Query.not_deleted() |> UserIdentity.Query.by_id(user_identity_id)

    case Repo.peek(queryable) do
      %UserIdentity{account_id: ^account_id} -> true
      _ -> false
    end
  end

  def identity_belongs_to_account?(_user_identity_id, _account_id), do: false

  defp provider_satisfies_mfa_by_id?(provider_id) do
    queryable =
      IdentityProvider.Query.not_deleted() |> IdentityProvider.Query.by_id(provider_id)

    case Repo.peek(queryable) do
      %IdentityProvider{} = provider -> provider_satisfies_mfa?(provider)
      nil -> false
    end
  end

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may configure SSO — `manage_sso` on the enterprise plan."
  def subject_can_configure_sso?(%Subject{account: account} = subject) do
    Auth.Authorizer.has_permission?(subject, Authorizer.manage_sso_permission()) and
      Billing.sso_available?(account)
  end

  defp ensure_can_configure_sso(%Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_sso_permission()) do
      if Billing.sso_available?(account), do: :ok, else: {:error, :sso_not_available}
    end
  end
end
