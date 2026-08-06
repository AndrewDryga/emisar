defmodule Emisar.SSO do
  @moduledoc """
  OIDC single sign-on: per-account identity-provider configuration, the
  relying-party login flow, and the `user_identities` bindings. The public
  authorization boundary for SSO — distinct from `Emisar.OAuth`, which is
  emisar-as-an-OAuth-*provider* for the MCP bridge.

  Config reads/writes are `%Subject{}`-gated (`manage_sso`): OIDC provider
  config needs the Team or Enterprise plan, SCIM directory sync needs
  Enterprise. The login flow (`begin_auth`/`complete_auth`) is pre-Subject — it IS
  the authentication — and resolves an identity strictly by `(provider, sub)`,
  **never by email** (the account-takeover guard). An unknown `sub`
  JIT-provisions a fresh user + identity + membership when the provider's
  `provisioner` is `:jit`.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Billing, Catalog, Crypto, Repo, Runners, Users}
  alias Emisar.Auth.Subject
  alias Emisar.SSO.{Authorizer, DirectoryGroup, DirectoryGroupMember}
  alias Emisar.SSO.GroupRoleMapping
  alias Emisar.SSO.GroupRunnerAccessMapping
  alias Emisar.SSO.{IdentityProvider, IssuerUrl, LinkRequest, OIDC, ProviderKind}
  alias Emisar.SSO.{SCIMGroupPatch, SCIMUser, SCIMUserPatch, SCIMUserUpdate, UserIdentity}
  require Logger

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)

  @impl Supervisor
  def init(_opts),
    do: Supervisor.init([job_module("AuthorizationReconcile")], strategy: :one_for_one)

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Config reads ----------------------------------------------------

  def list_providers_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.ordered_by_name()
      |> Authorizer.for_subject(subject)
      |> Repo.list(IdentityProvider.Query, opts)
    end
  end

  @doc """
  The account's connections as presentation facts, name-ordered — what a
  rendering caller needs about each one and nothing else. Requires `manage_sso`;
  account-scoped. Returns `{:ok, [facts], %Paginator.Metadata{}}`.
  """
  def list_provider_facts(%Subject{} = subject, opts \\ []) do
    with {:ok, providers, metadata} <- list_providers_for_account(subject, opts) do
      {:ok, Enum.map(providers, &provider_facts/1), metadata}
    end
  end

  @doc """
  One connection's presentation facts — its identity, whether it is enabled,
  whether it runs directory sync, and when that sync last ran. Pure: the raw
  provider carries a client secret, a SCIM token hash, and the claim/default
  configuration, none of which a rendering caller has any business reading.
  """
  def provider_facts(%IdentityProvider{} = provider) do
    %{
      id: provider.id,
      name: provider.name,
      enabled?: provider.enabled,
      directory_sync?: provider.scim_enabled,
      last_synced_at: provider.scim_last_seen_at
    }
  end

  @doc """
  The account's SSO connection posture: whether any connection is currently
  enabled, and how many. Requires the narrow `view_sso_posture` (every human
  role) — a non-admin learns the account's stance without being handed the
  connections. Returns `{:ok, %{enabled?: boolean, enabled_count: non_neg_integer}}`.
  """
  def fetch_account_connection_facts(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_sso_posture_permission()
           ) do
      count =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.enabled()
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      {:ok, %{enabled?: count > 0, enabled_count: count}}
    end
  end

  @doc """
  Directory facts for the given member `user_ids` in the subject's account: which
  connection provisioned each person, and whether that connection currently owns
  their directory profile. Bounded — the caller passes the ids on its page.

  Read from CURRENT rows, so turning directory sync off (or deleting the
  connection) changes the answer for a roster loaded a moment earlier. A person
  holding identities on several connections attributes deterministically: the
  directory-managed one wins, then provider name, then id. Requires `manage_sso`;
  account-scoped. Returns `{:ok, %{user_id => facts}}`.
  """
  def member_directory_facts(user_ids, %Subject{} = subject) when is_list(user_ids) do
    with :ok <- ensure_can_manage_sso(subject) do
      rows =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_user_ids(user_ids)
        |> UserIdentity.Query.ordered_by_directory_precedence()
        |> UserIdentity.Query.select_directory_facts()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, member_directory_facts_by_user_id(rows)}
    end
  end

  # The rows arrive in precedence order, so the first one per person is both the
  # display identity and the directory-managed answer.
  defp member_directory_facts_by_user_id(rows) do
    Enum.reduce(rows, %{}, fn {user_id, provider_id, provider_name, provisioned_via,
                               directory_managed?},
                              facts ->
      Map.put_new(facts, user_id, %{
        identity: %{
          provider_id: provider_id,
          provider_name: provider_name,
          provisioned_via: provisioned_via
        },
        directory_managed?: directory_managed?
      })
    end)
  end

  @doc """
  Internal — Accounts' admin profile edit: true when the user's profile is
  directory-owned in this account — they hold a live identity under a
  SCIM-enabled provider (the same boundary the synced-role lock uses, so
  disabling directory sync unlocks both together). Already-authorized callers
  only; scoped by the explicit account_id.
  """
  def user_profile_directory_managed?(account_id, user_id)
      when is_binary(account_id) and is_binary(user_id) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_account_id(account_id)
      |> UserIdentity.Query.by_user_id(user_id)
      |> UserIdentity.Query.scim_managed()

    Repo.exists?(queryable)
  end

  @doc """
  The users provisioned through `provider` — its `UserIdentity` rows (SCIM sync,
  SSO first-login, or approved link), each preloaded with the user, most-recent
  first. Powers the connection page's "Synced users" list. Requires `manage_sso`;
  scoped to the account. Returns `{:ok, [%UserIdentity{}]}`.
  """
  def list_synced_users(%IdentityProvider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject),
         {:ok, provider} <- fetch_provider_by_id(provider.id, subject) do
      identities =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_id(provider.id)
        |> UserIdentity.Query.with_preloaded_user()
        |> UserIdentity.Query.ordered_by_recent()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, identities}
    end
  end

  @doc """
  Per-connection sync tallies for the overview — `%{provider_id => %{users: n,
  groups: n}}` (provisioned identities + distinct groups the directory has actually
  pushed via SCIM, NOT the group→role mappings the admin configured) — so the
  connection list shows each one's scale and health at a glance (paired with the
  provider's `scim_last_seen_at`). One grouped query per table. Requires `manage_sso`;
  account-scoped. Returns `{:ok, stats}`.
  """
  def provider_sync_stats(%Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject) do
      users =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.count_by_provider()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> Map.new()

      groups =
        DirectoryGroupMember.Query.not_deleted()
        |> DirectoryGroupMember.Query.count_distinct_groups_by_provider()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> Map.new()

      provider_ids = Enum.uniq(Map.keys(users) ++ Map.keys(groups))

      stats =
        Map.new(provider_ids, fn id ->
          {id, %{users: Map.get(users, id, 0), groups: Map.get(groups, id, 0)}}
        end)

      {:ok, stats}
    end
  end

  def fetch_provider_by_id(id, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject),
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

  @doc """
  Changeset for the SSO provider config form (phx-change validation), as
  `{:ok, changeset}` for a subject holding `manage_sso` and `{:error,
  :unauthorized}` otherwise — the raw runner-scope selection is resolved
  against the subject's account, so building the form is an authorized read.

  A new connection normalizes against the SUBMITTED kind (create is where it's
  chosen); an existing one against its stored kind. The changeset is
  presentation-safe — it validates against the real row but never carries its
  stored `client_secret`, which is write-only and must not reach a rendered
  form. A secret the operator is typing stays in `changes`, so the field keeps
  what they entered.
  """
  def change_provider(provider \\ %IdentityProvider{}, attrs \\ %{}, subject)

  def change_provider(%IdentityProvider{id: nil} = provider, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject) do
      {attrs, allowlist} =
        provider_selection(new_provider_attrs(attrs), subject.account.id, provider)

      {:ok, IdentityProvider.Changeset.form(provider, attrs, allowlist)}
    end
  end

  def change_provider(%IdentityProvider{} = provider, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject),
         :ok <- Subject.ensure_in_account(subject, provider.account_id) do
      {attrs, allowlist} =
        provider_selection(edit_provider_attrs(provider, attrs), subject.account.id, provider)

      changeset =
        provider
        |> IdentityProvider.Changeset.form(attrs, allowlist)
        |> hide_stored_secret()

      {:ok, changeset}
    end
  end

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

  @doc """
  Changeset for an IdP group runner-access mapping form, as `{:ok, changeset}`
  for a subject holding `manage_sso` and `{:error, :unauthorized}` otherwise.
  From a `%IdentityProvider{}` it's the create form, from a
  `%GroupRunnerAccessMapping{}` the inline edit form; either way the raw
  runner-scope selection is resolved against the subject's account.
  """
  def change_group_runner_access_mapping(provider_or_mapping, attrs \\ %{}, subject)

  def change_group_runner_access_mapping(
        %IdentityProvider{} = provider,
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_manage_sso(subject),
         :ok <- Subject.ensure_in_account(subject, provider.account_id) do
      {attrs, allowlist} =
        mapping_selection(attrs, subject.account.id, %GroupRunnerAccessMapping{})

      {:ok,
       GroupRunnerAccessMapping.Changeset.create(
         provider.account_id,
         provider.id,
         attrs,
         allowlist
       )}
    end
  end

  def change_group_runner_access_mapping(
        %GroupRunnerAccessMapping{} = mapping,
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_manage_sso(subject),
         :ok <- Subject.ensure_in_account(subject, mapping.account_id) do
      {attrs, allowlist} = mapping_selection(attrs, subject.account.id, mapping)
      {:ok, GroupRunnerAccessMapping.Changeset.update(mapping, attrs, allowlist)}
    end
  end

  # -- Config mutations ------------------------------------------------

  @doc "Create an SSO connection. `manage_sso` + the Team or Enterprise plan. `{:ok, provider} | {:error, reason}`."
  def configure_provider(attrs, %Subject{account: account} = subject) do
    # Authorization first: nothing is parsed, normalized or built from
    # caller-supplied attrs until the subject has proven it may configure SSO.
    with :ok <- ensure_can_configure_sso(subject),
         {attrs, allowlist} =
           provider_selection(new_provider_attrs(attrs), account.id, %IdentityProvider{}),
         changeset = IdentityProvider.Changeset.create(account.id, attrs, allowlist),
         default_role = Ecto.Changeset.get_field(changeset, :default_role),
         # Creation checked runner access but never the role it hands every new
         # member. The changeset only excludes :owner, so an admin could stand up
         # a connection defaulting to a role they cannot themselves grant.
         :ok <- ensure_grantable_role(default_role, subject),
         {:ok, access} <- provider_access_from_changeset(changeset),
         :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access) do
      multi = configure_multi(changeset, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{provider: provider}} -> {:ok, provider}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Update a connection's config (locked re-read). `manage_sso` + Team or Enterprise. `{:ok, provider} | {:error, reason}`."
  def update_provider(%IdentityProvider{id: id}, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: fn loaded_provider ->
          # Judged from the PERSISTED kind, under the row lock — an edit never
          # chooses the kind, so a submitted one is not evidence of anything.
          attrs = edit_provider_attrs(loaded_provider, attrs)
          supplied_secret? = client_secret_supplied?(attrs)

          # The locked row is what the selection is resolved against: its
          # account owns the runners, so a cross-account id never gets here.
          {attrs, allowlist} =
            provider_selection(
              drop_blank_secret(attrs),
              loaded_provider.account_id,
              loaded_provider
            )

          changeset = IdentityProvider.Changeset.update(loaded_provider, attrs, allowlist)

          with {:ok, access} <- provider_access_from_changeset(changeset),
               :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access) do
            cond do
              not grantable_role?(Ecto.Changeset.get_change(changeset, :default_role), subject) ->
                :role_exceeds_your_permissions

              disabling_last_required_provider?(loaded_provider, changeset) ->
                :require_sso_last_provider

              rebinding_identity_namespace?(loaded_provider, changeset) ->
                :identity_namespace_locked

              repointing_without_secret?(changeset, supplied_secret?) ->
                :client_secret_required

              true ->
                discard_requests_captured_under_the_old_namespace(loaded_provider, changeset)
                prepare_provider_authorization_change(loaded_provider, changeset)
            end
          else
            {:error, %Ecto.Changeset{} = invalid} -> invalid
            {:error, reason} -> reason
          end
        end,
        audit: fn updated, changeset ->
          Audit.Events.identity_provider_updated(subject, changeset.data, updated)
        end,
        after_commit: &on_provider_updated/2
      )
      |> case do
        {:error, %Ecto.Changeset{} = invalid} -> {:error, hide_secrets(invalid)}
        result -> result
      end
    end
  end

  @doc "Soft-delete a connection. `manage_sso` + Team or Enterprise. `{:ok, provider} | {:error, reason}`."
  def delete_provider(%IdentityProvider{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: fn loaded_provider ->
          if removing_last_required_provider?(loaded_provider),
            do: :require_sso_last_provider,
            else:
              loaded_provider
              |> IdentityProvider.Changeset.delete()
              |> then(&prepare_provider_authorization_change(loaded_provider, &1, true))
        end,
        audit: &Audit.Events.identity_provider_deleted(subject, &1),
        after_commit: fn provider ->
          _ = return_role_control_to_operators(provider)
          _ = dismiss_pending_link_requests(provider)
          end_sessions_signed_in_through(provider)
        end
      )
    end
  end

  @doc """
  Probe an operator-supplied issuer's OIDC discovery document — the "Test
  connection" capstone, proving the issuer is reachable and serves a valid
  discovery doc *before* a connection is saved. `manage_sso` + Team or Enterprise;
  writes no row. The issuer is attacker-influenceable, so it's SSRF-validated
  (https + not a private/loopback/metadata host) before the fetch. Returns
  `{:ok, %{authorization_endpoint, token_endpoint, userinfo_endpoint, jwks_uri}}`
  or `{:error, :unauthorized | :sso_not_available | :invalid_issuer |
  :blocked_issuer | term()}` (a discovery failure carries oidcc's reason).
  """
  def test_provider(issuer, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject),
         {:ok, issuer} <- IssuerUrl.validate(issuer) do
      OIDC.discover(%IdentityProvider{issuer: issuer})
    end
  end

  # Lock-out guard — the mirror of team_live's enable-side check: when the account
  # requires SSO, the LAST enabled connection can't be disabled or deleted out from
  # under it (else everyone, owners included, is bricked). Judged inside the
  # provider's fetch_and_update :with (under the row lock); the reads join the same
  # transaction. Returning the atom (not a changeset) aborts as {:error, atom}.
  defp disabling_last_required_provider?(provider, changeset) do
    Ecto.Changeset.get_change(changeset, :enabled) == false and
      last_required_provider?(provider)
  end

  # An identity is keyed on `(provider_id, provider_identifier)`, and that
  # identifier is whatever the configured claim carries in a token from this
  # issuer + client. Change any of those three while identities exist and the
  # SAME stored row starts matching a DIFFERENT person: an admin can repoint a
  # connection at an IdP they control and mint a token whose claim equals an
  # existing owner's identifier, then sign in as that owner. Even an innocent
  # `sub` → `oid` switch can collide with an identifier captured earlier.
  #
  # So the namespace is settled by the first identity. Rotating the secret,
  # renaming, retargeting roles and runner access all stay editable — only the
  # three fields that decide WHO a stored identifier refers to are frozen. A
  # genuine move to another IdP is a new connection.
  # A connection's default role and its group mappings are BOTH ways to hand a
  # role to whoever the directory sends, so they need the same no-escalation rule
  # a team role change gets: you may only grant what you already hold. Rejecting
  # only `:owner` let an admin — who has no `manage_billing` — set
  # `default_role: :billing_manager` or map a group they control to it, and give
  # an accomplice the finance seat.
  defp ensure_grantable_role(role, %Subject{} = subject) do
    if grantable_role?(role, subject), do: :ok, else: {:error, :role_exceeds_your_permissions}
  end

  # No role named (a rename, a display-only edit) escalates nothing.
  defp grantable_role?(nil, _subject), do: true
  defp grantable_role?("", _subject), do: true

  defp grantable_role?(role, %Subject{} = subject) when is_binary(role) do
    case Auth.Role.cast(role) do
      {:ok, role} -> grantable_role?(role, subject)
      :error -> true
    end
  end

  defp grantable_role?(role, %Subject{} = subject) when is_atom(role),
    do: Auth.Permissions.covers_role?(subject, role)

  @identity_namespace_fields [:issuer, :client_id, :identifier_claim]

  # The secret field is write-only: a blank one on save means "keep the stored
  # value", so re-saving a connection does not force the operator to re-type a
  # credential they cannot read back.
  #
  # Keeping it while repointing the ISSUER or CLIENT ID is different. Discovery
  # from the new issuer names the token endpoint, and the token exchange posts
  # the client secret to it — so an admin, or anyone who took over that account,
  # could aim the connection at infrastructure they control and have us hand over
  # the customer's existing secret. That turns a field nobody can read into one
  # anybody with `manage_sso` can exfiltrate.
  #
  # Rebinding therefore requires supplying the secret. Supplying the SAME value
  # is fine — the point is that you must hold it, not that it must differ.
  defp repointing_without_secret?(changeset, supplied_secret?) do
    not supplied_secret? and
      Enum.any?([:issuer, :client_id], &Ecto.Changeset.changed?(changeset, &1))
  end

  defp client_secret_supplied?(attrs) do
    case fetch_attr(attrs, :client_secret) do
      {:ok, secret} when is_binary(secret) -> String.trim(secret) != ""
      _ -> false
    end
  end

  defp drop_blank_secret(attrs) do
    if client_secret_supplied?(attrs), do: attrs, else: drop_attr(attrs, :client_secret)
  end

  # The stored secret is write-only: it validates the write but never travels
  # back through a changeset the console renders and holds in socket state.
  defp hide_stored_secret(%Ecto.Changeset{} = changeset),
    do: %{changeset | data: %{changeset.data | client_secret: nil}}

  # A rejected write returns its changeset to the form, so the replacement secret
  # the operator submitted goes too — retyping it is the cost of not parking a
  # live credential in a browser DOM and a long-lived socket assign. A form reads
  # a field from changes, then params, then data, so all three are cleared.
  defp hide_secrets(%Ecto.Changeset{} = changeset) do
    changeset = hide_stored_secret(changeset)

    %{
      changeset
      | changes: Map.delete(changeset.changes, :client_secret),
        params: drop_attr(changeset.params || %{}, :client_secret)
    }
  end

  # Create + new-form normalization: the kind comes from the SUBMITTED attrs,
  # because a create is where it's chosen. An unrecognized kind normalizes
  # nothing — the changeset's enum rejects it.
  defp new_provider_attrs(attrs) do
    attrs = drop_blank_secret(attrs)

    case fetch_attr_kind(attrs) do
      {:ok, metadata} ->
        attrs
        |> put_kind_issuer(metadata)
        # One right answer per kind, so the claim is derived rather than offered:
        # a stale select value left over from switching provider (Entra's `oid`
        # under Okta) would otherwise be saved as the identity namespace.
        |> put_attr(:identifier_claim, metadata.identifier_claim)

      :error ->
        attrs
    end
  end

  # Update + edit-form normalization, from the PERSISTED kind — an edit never
  # chooses the kind, so a submitted one is dropped outright rather than read.
  # A kind whose issuer is one constant for every customer likewise has no
  # editable issuer: the submitted value is dropped rather than compared, so a
  # forged one can't repoint the connection AND a stored value that predates the
  # invariant stays exactly as it is instead of being silently migrated.
  defp edit_provider_attrs(%IdentityProvider{} = provider, attrs) do
    attrs = drop_attr(attrs, :kind)

    case ProviderKind.fetch(provider.kind) do
      {:ok, %{fixed_issuer: nil}} -> attrs
      {:ok, _metadata} -> drop_attr(attrs, :issuer)
      :error -> attrs
    end
  end

  # Switching to a per-customer provider clears an issuer WE prefilled — never
  # one the operator typed.
  defp put_kind_issuer(attrs, %{fixed_issuer: nil}) do
    prefilled? =
      case fetch_attr(attrs, :issuer) do
        {:ok, issuer} -> issuer in ProviderKind.fixed_issuers()
        :error -> false
      end

    if prefilled?, do: put_attr(attrs, :issuer, ""), else: attrs
  end

  defp put_kind_issuer(attrs, %{fixed_issuer: issuer}), do: put_attr(attrs, :issuer, issuer)

  defp fetch_attr_kind(attrs) do
    case fetch_attr(attrs, :kind) do
      {:ok, kind} -> ProviderKind.fetch(kind)
      :error -> :error
    end
  end

  defp fetch_attr(%{} = attrs, key) do
    case Map.fetch(attrs, Atom.to_string(key)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, key)
    end
  end

  defp fetch_attr(_attrs, _key), do: :error

  defp drop_attr(attrs, key), do: attrs |> Map.delete(Atom.to_string(key)) |> Map.delete(key)

  # Form params arrive with string keys and direct callers with atom keys, and
  # Ecto refuses a map that mixes them — so a normalized field is written back in
  # whichever style its attrs already use.
  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: Map.put(attrs, Atom.to_string(key), to_string(value)),
      else: Map.put(attrs, key, value)
  end

  # `put_attr/3` stringifies the scalar fields it normalizes; a raw selection is
  # a list of selector values and rides through as one.
  defp put_attr_values(attrs, key, values) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: Map.put(attrs, Atom.to_string(key), values),
      else: Map.put(attrs, key, values)
  end

  # Repointing is refused once an identity is bound, so it is allowed exactly
  # while none is — which is also when pending link requests exist. Those were
  # captured under the OLD issuer/client/claim, and approving one afterwards binds
  # its identifier against the NEW one: an admin who repoints the connection to an
  # IdP they control can then mint that identifier there and sign in as whoever the
  # request named. The request outlives the provenance the approval rests on, so it
  # goes with it, in the same transaction as the change.
  defp discard_requests_captured_under_the_old_namespace(provider, changeset) do
    if Enum.any?(@identity_namespace_fields, &Ecto.Changeset.changed?(changeset, &1)) do
      queryable = LinkRequest.Query.all() |> LinkRequest.Query.by_provider_id(provider.id)
      {discarded, _} = Repo.delete_all(queryable)

      if discarded > 0 do
        Logger.info("SSO discarded #{discarded} link request(s) after a namespace change")
      end
    end

    :ok
  end

  defp rebinding_identity_namespace?(provider, changeset) do
    Enum.any?(@identity_namespace_fields, &Ecto.Changeset.changed?(changeset, &1)) and
      provider_has_identities?(provider)
  end

  defp provider_has_identities?(provider) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> Repo.exists?()
  end

  defp removing_last_required_provider?(provider),
    do: provider.enabled and last_required_provider?(provider)

  # Take the ACCOUNT row lock before reading either half of the invariant
  # "require_sso on ⇒ at least one enabled connection". The two halves live in
  # different tables and are written by different transactions, so without a
  # shared serialization point two concurrent disables could each observe the
  # other's provider still enabled and both proceed — leaving require_sso on
  # with zero providers, which enforcement treats as fail-open. Accounts takes
  # the same lock when it turns require_sso on.
  defp last_required_provider?(provider) do
    _ = Accounts.fetch_and_lock_account(provider.account_id)

    account_requires_sso?(provider.account_id) and not another_enabled_provider?(provider)
  end

  defp account_requires_sso?(account_id) do
    case Accounts.fetch_account_settings(account_id) do
      {:ok, settings} -> settings.require_sso
      {:error, :not_found} -> false
    end
  end

  defp another_enabled_provider?(provider) do
    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.enabled()
    |> IdentityProvider.Query.by_account_id(provider.account_id)
    |> IdentityProvider.Query.excluding_id(provider.id)
    |> Repo.exists?()
  end

  defp configure_multi(changeset, subject) do
    Multi.new()
    |> Multi.insert(:provider, changeset)
    |> Multi.insert(:audit, fn %{provider: provider} ->
      Audit.Events.identity_provider_configured(subject, provider)
    end)
  end

  # The two surfaces that grant runner reach: the raw field their picker posts,
  # the mode it qualifies, and the persisted arrays SSO derives from it.
  @provider_scope_fields %{
    mode: :default_runner_access_mode,
    scope: :default_runner_scope,
    groups: :default_runner_scope_groups,
    runner_ids: :default_runner_scope_runner_ids,
    pack_mode: :default_pack_access_mode,
    pack_scope: :default_pack_scope,
    pack_ids: :default_pack_scope_pack_ids
  }

  @mapping_scope_fields %{
    mode: :runner_access_mode,
    scope: :scope,
    groups: :runner_scope_groups,
    runner_ids: :runner_scope_runner_ids,
    pack_mode: :pack_access_mode,
    pack_scope: :pack_scope,
    pack_ids: :pack_scope_pack_ids
  }

  defp provider_selection(attrs, account_id, %IdentityProvider{} = provider) do
    put_runner_selection(
      attrs,
      account_id,
      @provider_scope_fields,
      provider_runner_access(provider)
    )
  end

  defp mapping_selection(attrs, account_id, %GroupRunnerAccessMapping{} = mapping) do
    put_runner_selection(
      attrs,
      account_id,
      @mapping_scope_fields,
      runner_access_mapping_access(mapping)
    )
  end

  # The picker's raw `"group:<name>"` / `"runner:<id>"` and `"pack:<id>"` values
  # are the only accepted way to name reach: a submitted persisted array is
  # dropped here, and the selection is resolved against `account_id`'s live
  # runners and known packs, so a crafted submission can never widen reach past
  # what the account offers.
  defp put_runner_selection(attrs, account_id, fields, %Accounts.RunnerAccess{} = stored) do
    stored_values = Accounts.RunnerAccess.selection_values(stored.groups, stored.runner_ids)
    values = submitted_scope_values(attrs, fields.scope, fields.mode, stored_values)

    stored_pack_values = Accounts.RunnerAccess.pack_selection_values(stored.pack_ids)

    pack_values =
      submitted_scope_values(attrs, fields.pack_scope, fields.pack_mode, stored_pack_values)

    attrs =
      attrs
      |> drop_attr(fields.groups)
      |> drop_attr(fields.runner_ids)
      |> drop_attr(fields.pack_ids)
      |> put_attr_values(fields.scope, values)
      |> put_attr_values(fields.pack_scope, pack_values)

    {attrs, runner_selection_allowlist(account_id, values)}
  end

  defp submitted_scope_values(attrs, scope_field, mode_field, stored_values) do
    case fetch_attr(attrs, scope_field) do
      {:ok, values} -> List.wrap(values)
      :error -> unsubmitted_scope_values(attrs, mode_field, stored_values)
    end
  end

  # Attrs carrying the mode but no selection are "nothing is checked"; attrs
  # mentioning neither are not a reach submission at all — an unrelated
  # edit, or the untouched form — so the stored selection carries over instead
  # of reading as a cleared picker.
  defp unsubmitted_scope_values(attrs, mode_field, stored_values) do
    case fetch_attr(attrs, mode_field) do
      {:ok, _mode} -> []
      :error -> stored_values
    end
  end

  # A malformed, over-long, or unresolvable selection allowlists nothing, so
  # the changeset rejects it on the mode field instead of granting whichever
  # part of it happened to exist.
  defp runner_selection_allowlist(account_id, values) do
    # Runners answers which groups EXIST — a selected group whose runners were
    # not themselves selected resolves to a group with no runner rows, so its
    # own `groups` key is the authority, never one derived from `runners`.
    packs = Catalog.list_pack_ids_for_account(account_id)

    with {:ok, {groups, runner_ids}} <- Accounts.RunnerAccess.selection_refs(values),
         {:ok, facts} <-
           Runners.runner_selection_facts_for_account(account_id, groups, runner_ids) do
      Map.put(facts, :packs, packs)
    else
      {:error, _reason} -> %{groups: [], runners: [], packs: packs}
    end
  end

  defp provider_access_from_changeset(%Ecto.Changeset{} = changeset) do
    if changeset.valid? do
      changeset
      |> Ecto.Changeset.apply_changes()
      |> provider_runner_access()
      |> then(&{:ok, &1})
    else
      {:error, changeset}
    end
  end

  @authorization_fields ~w[default_role default_runner_access_mode
                           default_runner_scope_groups default_runner_scope_runner_ids
                           default_pack_access_mode default_pack_scope_pack_ids]a

  defp prepare_provider_authorization_change(provider, changeset, force? \\ false) do
    changes_authorization? =
      force? or Enum.any?(@authorization_fields, &Map.has_key?(changeset.changes, &1))

    if provider.scim_enabled and changes_authorization? do
      version = provider.authorization_version + 1
      user_ids = provider |> provider_identities() |> Enum.map(& &1.user_id)

      {:ok, _version} =
        Accounts.mark_directory_authorization_pending(
          Repo,
          provider.account_id,
          provider.id,
          user_ids,
          version
        )

      IdentityProvider.Changeset.bump_authorization_version(
        changeset,
        provider.authorization_version
      )
    else
      changeset
    end
  end

  # Both concerns run on every update: clause-matching on `scim_enabled` used to
  # mean a SCIM-enabled connection never reached the disable branch below.
  defp on_provider_updated(%IdentityProvider{} = provider, changeset) do
    _ = recompute_authorization_if_changed(provider, changeset)

    # Nothing to invalidate on an issuer edit: discovery is loaded per sign-in, so
    # the next one reads the new issuer and there is no cached document to strand.
    if Ecto.Changeset.get_change(changeset, :enabled) == false,
      do: end_sessions_signed_in_through(provider),
      else: :ok

    :ok
  end

  defp recompute_authorization_if_changed(
         %IdentityProvider{scim_enabled: true} = provider,
         changeset
       ) do
    changed_fields = Map.keys(changeset.changes)

    if Enum.any?(@authorization_fields, &(&1 in changed_fields)) do
      provider
      |> provider_identities()
      |> then(&recompute_role_for_affected(provider, &1))
    else
      :ok
    end
  end

  defp recompute_authorization_if_changed(%IdentityProvider{}, _changeset), do: :ok

  # Disabling or deleting a connection stopped NEW sign-ins and left every
  # session already minted through it valid — for up to their full lifetime — and
  # the API keys behind them working. An operator pulling a compromised
  # connection reasonably reads "disabled" as "nobody is coming in through this
  # any more", so the credentials it vouched for have to go with it.
  #
  # Coarse on purpose: sessions carry no provider provenance, so this ends ALL of
  # a linked member's sessions, not only the ones that came through this
  # connection. For someone whose access exists BECAUSE of this connection that
  # is the same set; for anyone else it costs a re-login, which is the right side
  # to err on when the alternative is leaving a pulled connection's sessions
  # alive. Tagging sessions with their provider would let this be exact.
  # A pending request is a person waiting on an admin. Once the connection they
  # arrived through is gone, approval is impossible — `approve_link_request` can
  # no longer fetch the provider — so leaving them queued showed admins a
  # decision they could not make and left the waiting browsers on a page that
  # would never resolve. Each one is dismissed and told.
  defp dismiss_pending_link_requests(%IdentityProvider{} = provider) do
    queryable =
      LinkRequest.Query.all()
      |> LinkRequest.Query.by_provider_id(provider.id)

    # RETURNING, not read-then-delete: a request created between the two
    # statements was deleted WITHOUT a broadcast, leaving exactly the waiting
    # browser on a never-resolving page that this function exists to prevent.
    {_count, dismissed} = queryable |> LinkRequest.Query.select_all() |> Repo.delete_all()
    Enum.each(dismissed, &broadcast_link_request_dismissed/1)
  end

  defp end_sessions_signed_in_through(%IdentityProvider{} = provider) do
    provider
    |> all_provider_identities()
    |> Enum.group_by(& &1.user_id, & &1.id)
    |> Enum.each(fn {user_id, identity_ids} ->
      end_identity_sessions(user_id, identity_ids)
    end)
  end

  @doc """
  Internal — SCIM deprovision: end the sessions this ACCOUNT authenticated for
  `user_id`, leaving any other account's untouched. Called from the membership
  suspend's after_commit, which holds the provider but cannot read SSO's tables.
  """
  def end_account_sessions_for_user(user_id, account_id)
      when is_binary(user_id) and is_binary(account_id) do
    identity_ids =
      UserIdentity.Query.all()
      |> UserIdentity.Query.by_account_id(account_id)
      |> UserIdentity.Query.by_user_id(user_id)
      |> Repo.all()
      |> Enum.map(& &1.id)

    end_identity_sessions(user_id, identity_ids)
  end

  defp end_identity_sessions(user_id, identity_ids) do
    case Users.fetch_user_by_id(user_id) do
      {:ok, user} ->
        Auth.revoke_identity_sessions(user, identity_ids)

      {:error, reason} ->
        Logger.warning("sso_session_user_missing",
          user_id: user_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp provider_identities(%IdentityProvider{} = provider) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  # Revocation reads EVERY identity the connection ever minted, retired ones
  # included. Soft-deleting an identity does not invalidate the cookie a session
  # already holds, so enumerating only live rows let a retired identity's session
  # survive the disable or delete that was supposed to end it.
  defp all_provider_identities(%IdentityProvider{} = provider) do
    UserIdentity.Query.all()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  @authorization_reconcile_batch_size 100

  @doc "Internal - retry a bounded batch of fail-closed directory authorization work."
  def reconcile_pending_authorizations(limit \\ @authorization_reconcile_batch_size) do
    limit
    |> Accounts.list_pending_directory_authorizations()
    |> Enum.each(&isolated_reconcile/1)

    :ok
  end

  # Per-row isolation, like Runbooks.Scheduler.Recovery. A raise took down the
  # whole batch, and the batch is a bounded, ordered window over the SAME
  # fail-closed set on every run — so one bad row at the head stopped every
  # other member behind it from ever reconciling, and this path is fail-closed
  # by design: they stay locked out. One bad row now costs one row.
  defp isolated_reconcile(%Accounts.Membership{} = membership) do
    reconcile_pending_authorization(membership)
  rescue
    error ->
      Logger.warning(
        "sso.authorization_reconcile_crashed membership=#{membership.id} " <>
          "error=#{inspect(error.__struct__)}"
      )

      :error
  end

  defp reconcile_pending_authorization(%Accounts.Membership{} = membership) do
    Accounts.refresh_directory_authorization_sessions(membership)

    provider =
      IdentityProvider.Query.all()
      |> IdentityProvider.Query.by_account_id(membership.account_id)
      |> IdentityProvider.Query.by_id(membership.directory_provider_id)
      |> Repo.peek()

    case provider do
      %IdentityProvider{deleted_at: nil, scim_enabled: true} = provider ->
        reconcile_pending_from_provider(provider, membership)

      _provider ->
        Accounts.clear_directory_managed_for_users(
          membership.account_id,
          membership.directory_provider_id,
          [membership.user_id]
        )

        :ok
    end
  end

  defp reconcile_pending_from_provider(provider, membership) do
    case peek_identity(provider, membership.user_id) do
      %UserIdentity{} = identity ->
        case recompute_role_for_identity(provider, identity) do
          {:ok, _membership} ->
            :ok

          other ->
            Logger.warning(
              "SSO authorization reconcile pending: membership=#{membership.id} " <>
                "provider=#{provider.id} reason=#{inspect(other)}"
            )
        end

      nil ->
        Accounts.clear_directory_managed_for_users(
          membership.account_id,
          membership.directory_provider_id,
          [membership.user_id]
        )

        :ok
    end
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
      |> IdentityProvider.Query.with_active_account()
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
  `(provider, identifier_claim)` — the `sub` for every provider except Entra, which
  uses `oid` — and never by email. An unknown `sub` JIT-provisions a fresh user
  when the provider's `provisioner` is `:jit`, or is captured as a pending link
  request and returns `{:pending, request}` when it is `:manual` (the web layer
  parks the person on the pending-approval page). Returns
  `{:ok, %{user, identity, provider}}` for the web layer to log in.
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
      %UserIdentity{} = identity -> resolve_existing_identity(provider, identity, claims)
      nil -> provision_for(provider, identifier, claims)
    end
  end

  # An identity the DIRECTORY created holds an OIDC identifier nobody ever
  # asserted over OIDC: SCIM provisioning writes its `externalId` into both
  # columns so a later login by `sub` converges on the same person. That
  # convergence is only sound while the two namespaces belong to one directory.
  # Wire SCIM to a different system than OIDC and the id spaces are unrelated —
  # then one person's `sub` can equal another's `externalId`, and this lookup
  # hands the second person the first one's account.
  #
  # So the first login against a synthesized identifier has to agree on WHO, not
  # only on the identifier. When it does not, nothing is authenticated: it becomes
  # a link request for an admin, which is what an unrecognized person gets anyway.
  defp resolve_existing_identity(%IdentityProvider{} = provider, identity, claims) do
    if synthesized_oidc_identifier?(identity) and
         not claims_name_the_same_person?(identity, claims) do
      park_link_request(provider, identity.provider_identifier, claims)
    else
      touch_and_load(provider, identity)
    end
  end

  defp synthesized_oidc_identifier?(%UserIdentity{provisioned_via: :scim} = identity),
    do: identity.provider_identifier == identity.scim_external_id

  defp synthesized_oidc_identifier?(%UserIdentity{}), do: false

  defp claims_name_the_same_person?(%UserIdentity{} = identity, claims) do
    with {:ok, user} <- Users.fetch_user_by_id(identity.user_id),
         email when is_binary(email) <- claims["email"] do
      # citext compares case-insensitively; trim only what the wire added.
      String.trim(email) == user.email
    else
      _ -> false
    end
  end

  defp touch_and_load(provider, %UserIdentity{} = identity) do
    Multi.new()
    |> put_active_account_lock(provider.account_id)
    |> put_enabled_provider_lock(provider)
    |> Multi.update(:identity, UserIdentity.Changeset.touch_last_seen(identity))
    |> Multi.run(:user, fn _repo, %{identity: identity} ->
      Users.fetch_user_by_id(identity.user_id)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: user, identity: identity}} ->
        {:ok, %{user: user, identity: identity, created?: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Directory sync on: the directory decides who exists. An identifier it never
  # provisioned belongs to someone not yet synced, or someone who should not be
  # here — and JIT-creating them minted a SECOND member for a person the
  # directory already knew under its own externalId. The two members share no
  # row, so deactivating the directory's left this one signed in. Park it for an
  # admin, exactly as a `:manual` connection does. (Ordering: this clause must
  # precede the `:jit` one, which would otherwise match first.)
  defp provision_for(%IdentityProvider{scim_enabled: true} = provider, identifier, claims),
    do: park_link_request(provider, identifier, claims)

  defp provision_for(%IdentityProvider{provisioner: :jit} = provider, identifier, claims) do
    multi = build_provision_multi(provider, identifier, claims)

    case Repo.commit_multi(multi) do
      {:ok, %{user: user, identity: identity}} ->
        {:ok, %{user: user, identity: identity, created?: true}}

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
        case capture_member_link(
               provider,
               identifier,
               claims["email"],
               claims["name"],
               claims,
               :oidc
             ) do
          {:captured, request} -> {:pending, request}
          :no_match -> {:error, :email_taken}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A `:manual`-provisioner connection never auto-creates.
  defp provision_for(%IdentityProvider{provisioner: :manual} = provider, identifier, claims),
    do: park_link_request(provider, identifier, claims)

  # The unknown identity is captured as a pending link request (the real `sub` +
  # claims, so an admin recognizes the person) and parked — re-attempts upsert,
  # never pile up. When the email matches an existing member the request records
  # them, so approving REBINDS that member's identity rather than adding a person.
  defp park_link_request(%IdentityProvider{} = provider, identifier, claims) do
    case capture_link_request(
           provider,
           identifier,
           claims["email"],
           claims["name"],
           claims,
           :oidc
         ) do
      {:ok, request} -> {:pending, request}
      # An upsert failure (rare) has no request to park them on — fall back to the
      # generic pending error so the callback still explains the wait.
      {:error, _reason} -> {:error, :identity_pending_approval}
    end
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
  defp capture_link_request(
         %IdentityProvider{deleted_at: %DateTime{}},
         _id,
         _e,
         _n,
         _claims,
         _source
       ),
       do: {:error, :provider_unavailable}

  defp capture_link_request(
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
  defp capture_member_link(
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
    runner_access = Keyword.get(opts, :runner_access, provider_runner_access(provider))
    user_attrs = %{email: verified_email(claims), full_name: claims["name"]}

    Multi.new()
    |> put_active_account_lock(provider.account_id)
    |> put_enabled_provider_lock(provider)
    |> Multi.run(:user, fn _repo, _changes -> Users.provision_sso_user(user_attrs) end)
    |> Multi.run(:identity, fn _repo, %{user: user} ->
      create_identity(provider, user, identifier, claims, created_by, provisioned_via)
    end)
    |> Multi.run(:membership, fn _repo, %{user: user} ->
      Accounts.provision_sso_membership(
        provider.account_id,
        user.id,
        provider.default_role,
        runner_access
      )
    end)
    |> Multi.insert(:audit, fn %{user: user} -> audit.(user) end)
  end

  defp put_active_account_lock(multi, account_id) do
    Multi.run(multi, :active_account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account_id, repo: repo)
    end)
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

  defp provider_runner_access(%IdentityProvider{} = provider) do
    case Accounts.RunnerAccess.from_prefixed_fields(provider, :default_runner) do
      {:ok, access} -> access
      {:error, _reason} -> Accounts.RunnerAccess.none()
    end
  end

  # R6/§9 C2: trust the email only when the IdP marks it verified (or a
  # domain-authoritative `hd` is present). Otherwise nil — the user is
  # identified solely by `(provider, sub)`.
  defp verified_email(%{"email" => email} = claims) when is_binary(email) do
    # `email_verified` arrives as a boolean from a JWT-decoded ID token but as the
    # string "true"/"false" from some IdPs / the SCIM query-param path — normalize
    # BOTH forms. A domain-authoritative Google `hd` is the other accepted signal
    # (R6/§9 C2), but an EXPLICIT unverified (`false` OR the string `"false"`)
    # overrides it (#7 — don't trust a forged `hd` paired with an unverified email;
    # comparing only against the boolean `false` let the string slip through).
    verified? = claims["email_verified"] in [true, "true"]

    if verified? or (is_binary(claims["hd"]) and not email_explicitly_unverified?(claims)),
      do: email,
      else: nil
  end

  defp verified_email(_claims), do: nil

  defp email_explicitly_unverified?(claims), do: claims["email_verified"] in [false, "false"]

  # H1: when the provider restricts a domain, the IdP-asserted `hd` (preferred)
  # or the verified email's domain must match; a login with no verified domain
  # is refused. No restriction (nil) → rely on the IdP's membership boundary.
  defp ensure_email_domain_allowed(%IdentityProvider{allowed_email_domain: nil}, _claims), do: :ok

  defp ensure_email_domain_allowed(%IdentityProvider{allowed_email_domain: domain}, claims) do
    if claimed_domain_matches?(claims, domain),
      do: :ok,
      else: {:error, :email_domain_not_allowed}
  end

  defp claimed_domain_matches?(%{"hd" => hd} = claims, domain) when is_binary(hd),
    do: not email_explicitly_unverified?(claims) and domains_equal?(hd, domain)

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
  def scim_provision_user(%IdentityProvider{} = provider, attrs),
    do: provision_or_load(provider, attrs, :may_retry)

  # `retry` is bookkeeping for the race convergence below, not something a caller
  # chooses — it stays off the public surface.
  defp provision_or_load(%IdentityProvider{} = provider, attrs, retry) do
    external_id = attrs[:external_id] || attrs["external_id"]

    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_and_scim_identity(provider.id, external_id)

    case Repo.peek(queryable) do
      %UserIdentity{} = identity -> load_provisioned(provider, identity, external_id, attrs)
      nil -> provision_scim_user(provider, external_id, attrs, retry)
    end
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
  # no `scim_external_id`. Reusing one without stamping it left the member
  # invisible to every SCIM lifecycle endpoint (they look up by
  # `scim_external_id`), so the directory could create them and never offboard
  # them.
  defp load_provisioned(
         %IdentityProvider{} = provider,
         %UserIdentity{} = identity,
         external_id,
         attrs
       ) do
    with {:ok, user} <- Users.fetch_user_by_id(identity.user_id),
         {:ok, identity} <- adopt_scim_identity(identity, external_id) do
      reconcile_provisioned(provider, user, identity, scim_active_from(attrs))
    end
  end

  defp adopt_scim_identity(%UserIdentity{scim_external_id: nil} = identity, external_id)
       when is_binary(external_id) do
    # Guarded on the column still being null AT THE WRITE, not just when we read
    # it. Two pushes that both loaded the unstamped row would otherwise each
    # claim it, and the later one would silently win.
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_id(identity.id)
      |> UserIdentity.Query.without_scim_external_id()

    {_stamped, _} = Repo.update_all(queryable, set: [scim_external_id: external_id])

    # Read back whoever won. If another push stamped it first, the write above
    # matched nothing and theirs is what stands.
    {:ok, Repo.reload!(identity)}
  end

  defp adopt_scim_identity(%UserIdentity{} = identity, _external_id), do: {:ok, identity}

  # active: true — reinstate a directory suspension (a MANUAL suspend still
  # holds, per reprovision_membership) and recompute the mapped role.
  defp reconcile_provisioned(%IdentityProvider{} = provider, user, identity, true) do
    with {:ok, _membership} <- reprovision_membership(provider, user, identity),
         {:ok, identity} <- ensure_scim_active(identity),
         {:ok, membership} <- recompute_role_for_identity(provider, identity) do
      {:ok, %{user: user, identity: identity, membership: membership}}
    end
  end

  # active: false — the same deprovision a PATCH/DELETE performs, so a create
  # that asserts "inactive" lands the member in exactly the offboarded state.
  defp reconcile_provisioned(%IdentityProvider{} = provider, user, identity, false) do
    with {:ok, membership} <- deactivate_sync_membership(provider, identity.user_id),
         {:ok, identity} <- Repo.update(UserIdentity.Changeset.set_scim_active(identity, false)) do
      {:ok, %{user: user, identity: identity, membership: membership}}
    end
  end

  # The reconcile transitions run outside any transaction, so the post-commit
  # side effects fire inline — and only when the row actually changed.
  defp deactivate_sync_membership(%IdentityProvider{} = provider, user_id) do
    case Accounts.peek_sync_membership(provider.account_id, user_id) do
      %Accounts.Membership{} = membership ->
        with {:ok, membership, changed?} <- Accounts.sync_suspend_membership(membership, provider) do
          if changed?, do: :ok = Accounts.membership_suspended_effects(membership)
          {:ok, membership}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp reinstate_sync_membership(
         %IdentityProvider{} = provider,
         %Accounts.Membership{} = membership
       ) do
    with {:ok, membership, changed?} <- Accounts.sync_reinstate_membership(membership, provider) do
      if changed?, do: :ok = Accounts.membership_reinstated_effects(membership)
      {:ok, membership}
    end
  end

  # The membership half of a SCIM re-POST — unlike an admin link-approval, it must
  # respect a break-glass MANUAL suspend.
  defp reprovision_membership(%IdentityProvider{} = provider, user, %UserIdentity{} = identity) do
    case Accounts.peek_sync_membership(provider.account_id, user.id) do
      %Accounts.Membership{disabled_at: nil} = membership ->
        {:ok, membership}

      %Accounts.Membership{} = membership ->
        # A disabled membership while the IdP still has them active (scim_active:
        # true) is a MANUAL suspend — a break-glass security action that HOLDS; a
        # routine re-POST never silently lifts it. scim_active: false means the IdP
        # is re-activating a member it DEACTIVATED, so reinstate. Same scim_active
        # boundary the manual-reinstate block uses.
        if identity.scim_active do
          {:ok, membership}
        else
          reinstate_sync_membership(provider, membership)
        end

      nil ->
        Accounts.provision_sso_membership(
          provider.account_id,
          user.id,
          provider.default_role,
          provider_runner_access(provider),
          directory_managed?: true,
          directory_provider: provider
        )
    end
  end

  # Ensure the member has an active membership, reinstating or (re)creating one —
  # the link-approval flow, where an admin explicitly grants access. Runs inside
  # the approval's Multi, so a committed reinstate is TAGGED for the commit site
  # to fire its broadcast after the transaction, never from within it.
  defp ensure_active_membership(%IdentityProvider{} = provider, user) do
    case Accounts.peek_sync_membership(provider.account_id, user.id) do
      %Accounts.Membership{disabled_at: nil} = membership ->
        {:ok, membership}

      %Accounts.Membership{} = membership ->
        with {:ok, membership, changed?} <-
               Accounts.sync_reinstate_membership(membership, provider) do
          {:ok, if(changed?, do: {:reinstated, membership}, else: membership)}
        end

      nil ->
        Accounts.provision_sso_membership(
          provider.account_id,
          user.id,
          provider.default_role,
          provider_runner_access(provider)
        )
    end
  end

  defp ensure_scim_active(%UserIdentity{scim_active: true} = identity), do: {:ok, identity}

  defp ensure_scim_active(%UserIdentity{} = identity),
    do: identity |> UserIdentity.Changeset.set_scim_active(true) |> Repo.update()

  defp provision_scim_user(%IdentityProvider{} = provider, external_id, attrs, retry) do
    multi = build_scim_provision_multi(provider, external_id, attrs)

    case Repo.commit_multi(multi) do
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
        # linked); a non-member is a genuine collision. Always 409; never merge (C1).
        email = attrs[:email] || attrs["email"]
        full_name = attrs[:full_name] || attrs["full_name"]
        _ = capture_member_link(provider, external_id, email, full_name, %{}, :scim)
        {:error, :email_taken}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only an identifier collision is the race the re-call converges on, so only it
  # earns a retry. The one-live-identity-per-person index is a different answer —
  # the re-call would peek by identifier, miss, provision, collide again, forever.
  @identifier_constraints ~w[
    sso_user_identities_provider_identifier_index
    sso_user_identities_scim_external_id_index
  ]

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
    |> put_provider_lock(provider)
    |> Multi.run(:user, fn _repo, _changes -> Users.provision_sso_user(user_attrs) end)
    |> Multi.run(:identity, fn _repo, %{user: user} ->
      create_scim_identity(provider, user, external_id, attrs)
    end)
    |> Multi.run(:membership, fn _repo, %{user: user} ->
      Accounts.provision_sso_membership(
        provider.account_id,
        user.id,
        provider.default_role,
        provider_runner_access(provider),
        active?: scim_active_from(attrs),
        directory_managed?: true,
        directory_provider: provider
      )
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
  def scim_patch_user(%IdentityProvider{} = provider, external_id, operations)
      when is_list(operations) do
    with {:ok, update} <- SCIMUserPatch.reduce(operations) do
      scim_update_user(provider, external_id, update)
    end
  end

  @doc """
  Internal — SCIM update (PATCH / PUT / DELETE): apply one directory user's
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
  def scim_update_user(%IdentityProvider{} = provider, external_id, %SCIMUserUpdate{} = update) do
    multi =
      Multi.new()
      |> Multi.run(:identity, fn repo, _changes ->
        lock_scim_identity(provider, external_id, repo)
      end)
      |> Multi.run(:rename, fn _repo, %{identity: identity} ->
        apply_scim_rename(provider, identity, update.name)
      end)
      |> Multi.run(:lifecycle, fn _repo, %{identity: identity} ->
        apply_scim_lifecycle(provider, identity, update.active)
      end)
      |> Multi.run(:updated_identity, fn repo, %{identity: identity} ->
        set_identity_scim_active(repo, identity, update.active)
      end)

    with {:ok, changes} <- Repo.commit_multi(multi, after_commit: &scim_update_effects/1) do
      {:ok, %{identity: changes.updated_identity, membership: scim_updated_membership(changes)}}
    end
  end

  defp lock_scim_identity(%IdentityProvider{} = provider, external_id, repo) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> UserIdentity.Query.lock_for_update()
    |> repo.fetch(UserIdentity.Query)
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

  defp apply_scim_lifecycle(_provider, _identity, :keep), do: {:ok, :unchanged}

  # An identity whose membership an operator removed locally is ALREADY as
  # deprovisioned as this account can make it, so a deprovision succeeds with
  # nothing to do. Answering `:not_found` told the directory the person does not
  # exist while a read still described them — so it either retried the deactivate
  # forever or concluded they were gone and re-created them, undoing the removal.
  defp apply_scim_lifecycle(%IdentityProvider{} = provider, identity, false) do
    case Accounts.peek_sync_membership(provider.account_id, identity.user_id) do
      %Accounts.Membership{} = membership ->
        with {:ok, membership, changed?} <- Accounts.sync_suspend_membership(membership, provider) do
          {:ok, if(changed?, do: {:suspended, membership}, else: membership)}
        end

      nil ->
        {:ok, :unchanged}
    end
  end

  defp apply_scim_lifecycle(%IdentityProvider{} = provider, identity, true) do
    case Accounts.peek_sync_membership(provider.account_id, identity.user_id) do
      %Accounts.Membership{} = membership ->
        with {:ok, membership, changed?} <-
               Accounts.sync_reinstate_membership(membership, provider) do
          {:ok, if(changed?, do: {:reinstated, membership}, else: membership)}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp set_identity_scim_active(_repo, %UserIdentity{} = identity, :keep), do: {:ok, identity}

  defp set_identity_scim_active(repo, %UserIdentity{} = identity, active)
       when is_boolean(active),
       do: repo.update(UserIdentity.Changeset.set_scim_active(identity, active))

  # Only a lifecycle write that actually committed earns its side effects — a
  # no-op (already suspended, break-glass hold) fires nothing.
  defp scim_update_effects(%{lifecycle: {:suspended, membership}}),
    do: Accounts.membership_suspended_effects(membership)

  defp scim_update_effects(%{lifecycle: {:reinstated, membership}}),
    do: Accounts.membership_reinstated_effects(membership)

  defp scim_update_effects(_changes), do: :ok

  # The freshest membership this transition touched, for the caller's result:
  # the lifecycle write's row wins over the rename's, and an untouched
  # membership is nil.
  defp scim_updated_membership(%{lifecycle: {_transition, %Accounts.Membership{} = membership}}),
    do: membership

  defp scim_updated_membership(%{lifecycle: %Accounts.Membership{} = membership}), do: membership
  defp scim_updated_membership(%{rename: %Accounts.Membership{} = membership}), do: membership
  defp scim_updated_membership(_changes), do: nil

  @doc """
  Internal — SCIM read: the `%SCIMUser{}` projection for `(provider,
  externalId)` (the IdP probes before create). `{:ok, %SCIMUser{}} |
  {:error, :not_found}` — an identity whose membership an operator removed is
  still found, and reports inactive.
  """
  def scim_fetch_user(%IdentityProvider{} = provider, external_id) do
    with {:ok, identity} <- fetch_scim_identity(provider, external_id) do
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
  `[%{external_group_id, display, member_external_ids}]`, ordered by group id.
  An optional `:display_name` filter answers the `displayName eq` probe Entra
  makes before every group push; without a group read it never matches an
  existing group and re-POSTs the whole directory each cycle.

  `display` is whatever the directory last pushed on the group resource. Role
  mappings and membership rows carry historical copies for their own workflows,
  but do not redefine the SCIM resource's name.
  """
  def scim_list_groups(%IdentityProvider{} = provider, opts \\ []) do
    {display_name, opts} = Keyword.pop(opts, :display_name)
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
      |> apply_scim_group_filter(display_name)

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
    external_group_ids = Enum.map(groups, & &1.external_group_id)

    members_queryable =
      DirectoryGroupMember.Query.not_deleted()
      |> DirectoryGroupMember.Query.by_account_id(provider.account_id)
      |> DirectoryGroupMember.Query.by_external_group_ids(external_group_ids)
      |> DirectoryGroupMember.Query.select_member_external_ids(provider.id)

    members = Enum.group_by(Repo.all(members_queryable), &elem(&1, 0), &elem(&1, 1))

    Enum.map(groups, fn %DirectoryGroup{external_group_id: id} = group ->
      %{
        external_group_id: id,
        display: group.display,
        member_external_ids: Map.get(members, id, [])
      }
    end)
  end

  @doc """
  Internal — SCIM read of one synced group by its externalId, so an IdP's
  `GET /Groups/{id}` round-trips instead of 404ing on a group it just pushed.
  `{:ok, summary} | {:error, :not_found}`.
  """
  def scim_fetch_group(%IdentityProvider{} = provider, external_group_id) do
    queryable =
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_external_group_id(external_group_id)

    case Repo.peek(queryable) do
      nil ->
        {:error, :not_found}

      group ->
        [summary] = scim_group_summaries([group], provider)
        {:ok, summary}
    end
  end

  defp apply_scim_group_filter(queryable, nil), do: queryable

  defp apply_scim_group_filter(queryable, display_name),
    do: DirectoryGroup.Query.by_display(queryable, display_name)

  defp apply_scim_filter(queryable, {:user_name, value}),
    do: UserIdentity.Query.by_user_name(queryable, value)

  defp apply_scim_filter(queryable, {:external_id, value}),
    do: UserIdentity.Query.by_external_id(queryable, value)

  defp apply_scim_filter(queryable, _none), do: queryable

  defp fetch_scim_identity(%IdentityProvider{} = provider, external_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> UserIdentity.Query.with_preloaded_user()
    |> peek_or_not_found()
  end

  # The shared peek-and-tag tail for the "live row or :not_found" lookups.
  defp peek_or_not_found(queryable) do
    case Repo.peek(queryable) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp scim_users(%IdentityProvider{} = provider, identities) do
    user_ids = Enum.map(identities, & &1.user_id)

    memberships =
      Map.new(Accounts.list_sync_memberships(provider.account_id, user_ids), &{&1.user_id, &1})

    Enum.map(identities, &scim_user(&1, &1.user, memberships[&1.user_id]))
  end

  # The projection's `external_id` is the IdP's externalId, not our internal
  # UUID: SCIM `id` is server-assigned and opaque to the client, and every
  # single-user operation keys strictly on externalId (decision 4 —
  # `provider_identifier == scim_external_id`), so surfacing it as the canonical
  # id lets the IdP's `GET/PATCH/DELETE /Users/{id}` round-trip without a
  # separate UUID→externalId lookup. The internal UUID is never exposed.
  defp scim_user(%UserIdentity{} = identity, user, membership) do
    external_id = identity.scim_external_id || identity.provider_identifier

    %SCIMUser{
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
  @sync_role_precedence [:admin, :billing_manager, :operator, :viewer]
  @scim_group_string_max_length 255
  @scim_group_member_max_count 5_000

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

    with :ok <- validate_scim_group_values(external_group_id, display, member_external_ids) do
      with {:ok, {current_provider, affected, member_count}} <-
             Repo.transaction(fn ->
               {locked_provider, first_push?} = lock_provider!(provider)
               desired_ids = resolve_member_identity_ids(locked_provider, member_external_ids)
               :ok = upsert_directory_group(locked_provider, external_group_id, display)
               _ = refresh_group_display(locked_provider, external_group_id, display)

               affected =
                 replace_group_members(locked_provider, external_group_id, display, desired_ids)

               affected = identities_to_recompute(locked_provider, affected, first_push?)

               current_provider =
                 prepare_scim_group_authorization_change!(locked_provider, affected)

               {current_provider, affected, length(desired_ids)}
             end),
           :ok <- recompute_role_for_affected(current_provider, affected) do
        {:ok,
         %{
           external_group_id: external_group_id,
           display: display,
           member_count: member_count
         }}
      end
    end
  end

  @doc """
  Internal — SCIM `DELETE /Groups/{id}`: retire the group and take its members'
  grants with it. `{:ok, group_summary}`; `{:error, :not_found}` for a group this
  directory never pushed, because answering 204 for one invents it.
  """
  def scim_delete_group(%IdentityProvider{} = provider, external_group_id) do
    with :ok <- validate_required_scim_string(external_group_id),
         {:ok, _group} <- scim_fetch_group(provider, external_group_id),
         {:ok, summary} <-
           scim_upsert_group(provider, %{
             external_id: external_group_id,
             member_external_ids: []
           }) do
      # Emptying it revoked what it granted; retiring the ROW is what makes the
      # resource gone. Deleting used to call the upsert alone, so a GET right
      # after a 204 still answered 200 — and deleting a group we had never seen
      # CREATED it.
      queryable =
        DirectoryGroup.Query.not_deleted()
        |> DirectoryGroup.Query.by_account_id(provider.account_id)
        |> DirectoryGroup.Query.by_provider_id(provider.id)
        |> DirectoryGroup.Query.by_external_group_id(external_group_id)

      now = DateTime.utc_now()
      Repo.update_all(queryable, set: [deleted_at: now, updated_at: now])
      {:ok, summary}
    end
  end

  @doc """
  Internal — SCIM group rename: move a synced group's human name without touching
  its id. The id is what the IdP addresses the group by and stays put; the new
  display lands on the group's membership rows and on any role mapping of it.
  `{:ok, group_summary}`.
  """
  def scim_rename_group(%IdentityProvider{} = provider, external_group_id, display) do
    with :ok <- validate_scim_group_values(external_group_id, display, []),
         # Under the same lock every other group write takes. Renaming outside it
         # raced a concurrent member push: both saw no row, the member path
         # inserted first, and the rename's conflict-free insert dropped its
         # display while still answering success. It could also recreate a group
         # a concurrent disable had just discarded.
         {:ok, _} <-
           Repo.transaction(fn ->
             {locked_provider, _first_push?} = lock_provider!(provider)
             :ok = upsert_directory_group(locked_provider, external_group_id, display)
             refresh_group_display(locked_provider, external_group_id, display)
           end) do
      {:ok, %{external_group_id: external_group_id, display: display}}
    end
  end

  @doc """
  Internal — refuse to mint a session through a connection that is no longer enabled.

  Called by `Emisar.Auth` from INSIDE the session transaction, with that
  transaction's repo, so the provider row lock is held across the credential
  write. `complete_auth/3` checks the same thing, but its lock is released when the
  identity transaction commits — leaving a window where a disable commits, its
  session sweep finds nothing, and the callback then inserts a session that
  survives. Holding the lock here means either the insert precedes the disable, or
  it is refused after it.

  `:ok` when there is no identity (a non-SSO sign-in has nothing to check).
  """
  def ensure_identity_provider_enabled(_repo, nil), do: :ok

  def ensure_identity_provider_enabled(repo, user_identity_id) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_id(user_identity_id)

    case repo.peek(queryable) do
      %UserIdentity{provider_id: provider_id, account_id: account_id} ->
        locked =
          IdentityProvider.Query.not_deleted()
          |> IdentityProvider.Query.by_account_id(account_id)
          |> IdentityProvider.Query.by_id(provider_id)
          |> IdentityProvider.Query.lock_for_update()
          |> repo.peek()

        case locked do
          %IdentityProvider{enabled: true} -> :ok
          _ -> {:error, :provider_disabled}
        end

      nil ->
        {:error, :provider_disabled}
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
        external_group_id,
        add_external_ids,
        remove_external_ids,
        display \\ nil
      ) do
    with :ok <- validate_required_scim_string(external_group_id),
         :ok <- validate_optional_scim_string(display),
         :ok <- validate_scim_patch_member_ids(add_external_ids, remove_external_ids) do
      with {:ok, {current_provider, added, removed, affected}} <-
             Repo.transaction(fn ->
               {locked_provider, first_push?} = lock_provider!(provider)
               # The batch's rename lands HERE, inside the same transaction and
               # under the same provider lock as the membership change. Applied
               # afterwards in a transaction of its own, a disable, deletion or
               # database failure between the two returned an error to the IdP with
               # the privilege change already committed.
               :ok = upsert_directory_group(locked_provider, external_group_id, display)
               _ = refresh_group_display(locked_provider, external_group_id, display)
               add_ids = resolve_member_identity_ids(locked_provider, add_external_ids)
               remove_ids = resolve_member_identity_ids(locked_provider, remove_external_ids)
               added = add_group_members(locked_provider, external_group_id, add_ids)
               removed = remove_group_members(locked_provider, external_group_id, remove_ids)
               touched = Enum.uniq(added ++ removed)
               affected = identities_to_recompute(locked_provider, touched, first_push?)

               current_provider =
                 prepare_scim_group_authorization_change!(locked_provider, affected)

               {current_provider, added, removed, affected}
             end),
           :ok <- recompute_role_for_affected(current_provider, affected) do
        {:ok,
         %{external_group_id: external_group_id, added: length(added), removed: length(removed)}}
      end
    end
  end

  @doc """
  Internal — SCIM `PATCH /Groups/{id}`: reduce the IdP's ordered RFC 7644 §3.5.2
  operation list into one transition and apply it through the same group writes a
  PUT takes, so a batch carrying both a rename and a membership change commits as
  one. The wire boundary hands the raw operations straight through — the ordering,
  the recognized attributes, and the caps are decided here.

  `{:ok, group_summary}` carrying the `member_external_ids` the response renders;
  `{:error, :invalid_scim_group | :unsupported_scim_patch}` for a batch we refuse,
  plus every group-write error for one we apply.
  """
  def scim_patch_group(%IdentityProvider{} = provider, external_group_id, operations)
      when is_list(operations) do
    with {:ok, command} <- SCIMGroupPatch.reduce(operations, external_group_id) do
      apply_scim_group_patch(provider, external_group_id, command)
    end
  end

  # The batch asked for nothing we had to write — answer with the group as it stands.
  defp apply_scim_group_patch(%IdentityProvider{} = provider, external_group_id, :unchanged),
    do: scim_fetch_group(provider, external_group_id)

  defp apply_scim_group_patch(
         %IdentityProvider{} = provider,
         external_group_id,
         {:rename, display}
       ) do
    with {:ok, _summary} <- scim_rename_group(provider, external_group_id, display) do
      {:ok, %{external_group_id: external_group_id, display: display, member_external_ids: []}}
    end
  end

  defp apply_scim_group_patch(
         %IdentityProvider{} = provider,
         external_group_id,
         {:replace, display, member_external_ids}
       ) do
    attrs = %{
      external_id: external_group_id,
      display: display,
      member_external_ids: member_external_ids
    }

    with {:ok, summary} <- scim_upsert_group(provider, attrs) do
      {:ok, Map.put(summary, :member_external_ids, member_external_ids)}
    end
  end

  defp apply_scim_group_patch(
         %IdentityProvider{} = provider,
         external_group_id,
         {:delta, display, add_ids, remove_ids}
       ) do
    with {:ok, _summary} <-
           scim_patch_group_members(provider, external_group_id, add_ids, remove_ids, display) do
      {:ok,
       %{
         external_group_id: external_group_id,
         display: display,
         member_external_ids: add_ids
       }}
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
  defp upsert_directory_group(%IdentityProvider{} = provider, external_group_id, display) do
    queryable =
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_external_group_id(external_group_id)

    case Repo.peek(queryable) do
      %DirectoryGroup{} = group ->
        {:ok, _group} = group |> DirectoryGroup.Changeset.rename(display) |> Repo.update()
        :ok

      nil ->
        changeset =
          DirectoryGroup.Changeset.create(
            provider.account_id,
            provider.id,
            external_group_id,
            display
          )

        # Lost the race to a concurrent push of the same group: it exists, which
        # is all this needed to establish.
        _ = Repo.insert(changeset, on_conflict: :nothing)
        :ok
    end
  end

  defp lock_provider_row!(%IdentityProvider{} = provider, repo \\ Repo) do
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
  defp put_provider_lock(multi, %IdentityProvider{} = provider) do
    Multi.run(multi, :locked_provider, fn repo, _changes ->
      {:ok, lock_provider_row!(provider, repo)}
    end)
  end

  # A sign-in write additionally re-reads whether the connection is still ENABLED.
  # The provider struct was resolved when the request arrived; disabling it is
  # exactly how an operator revokes a route in, and a callback already in flight
  # would otherwise land a session through a door the account had just closed —
  # `end_sessions_signed_in_through/1` runs in the disable's after_commit, so a
  # session created after that is never swept. Under the same row lock the disable
  # takes, one of the two happens first and the other refuses.
  defp put_enabled_provider_lock(multi, %IdentityProvider{} = provider) do
    Multi.run(multi, :locked_provider, fn repo, _changes ->
      locked = lock_provider_row!(provider, repo)
      if locked.enabled, do: {:ok, locked}, else: {:error, :provider_disabled}
    end)
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

  defp validate_scim_group_values(external_group_id, display, member_external_ids) do
    with :ok <- validate_required_scim_string(external_group_id),
         :ok <- validate_optional_scim_string(display) do
      validate_scim_member_ids(member_external_ids)
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

  defp validate_scim_member_ids(member_external_ids) when is_list(member_external_ids) do
    cond do
      length(member_external_ids) > @scim_group_member_max_count ->
        {:error, :invalid_scim_group}

      Enum.all?(member_external_ids, &valid_scim_required_string?/1) ->
        :ok

      true ->
        {:error, :invalid_scim_group}
    end
  end

  defp validate_scim_member_ids(_member_external_ids), do: {:error, :invalid_scim_group}

  defp validate_required_scim_string(value) do
    if valid_scim_required_string?(value), do: :ok, else: {:error, :invalid_scim_group}
  end

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

  @doc """
  Internal — recompute one identity's role from its synced group memberships:
  the HIGHEST mapped role over the groups it belongs to (`:admin > :operator >
  :viewer`; never `:owner`), applied to its membership in the provider's account
  via `Accounts.sync_set_membership_role/3`. An identity in NO mapped group
  resets to the provider's `default_role` (least-privilege on directory
  removal); a member who is currently an account `:owner` is left untouched.
  `{:ok, membership} | {:error, reason}`.
  """
  def recompute_role_for_identity(%IdentityProvider{} = provider, %UserIdentity{} = identity) do
    recompute_authorization_for_identity(
      provider,
      identity,
      provider_role_mappings(provider),
      provider_runner_access_mappings(provider)
    )
  end

  # `mappings` is hoisted once per group push by `recompute_role_for_affected/2`
  # (#12 — fetched once, not once per affected member).
  defp recompute_authorization_for_identity(
         %IdentityProvider{} = provider,
         %UserIdentity{} = identity,
         role_mappings,
         runner_access_mappings
       ) do
    # #3: an identity in NO mapped group resets to the provider `default_role`
    # (least-privilege — removing a user from their last privileged group in the
    # directory demotes them here), rather than keeping a stale elevated role.
    #
    # That reading is only valid once the directory has actually told us about
    # groups. Before the first push there is no snapshot to read, and SCIM does
    # not order Users before Groups — so recomputing then would revoke a grant
    # that is still current, or, where the default outranks a mapping, hand
    # someone a role no Group operation authorized.
    if groups_ever_synced?(provider) do
      group_ids = identity_group_ids(identity)
      role = highest_role_for_groups(group_ids, role_mappings) || provider.default_role
      access = effective_runner_access(provider, group_ids, runner_access_mappings)
      membership = Accounts.peek_sync_membership(provider.account_id, identity.user_id)
      apply_recomputed_authorization(provider, role, access, membership)
    else
      {:ok, Accounts.peek_sync_membership(provider.account_id, identity.user_id)}
    end
  end

  # A connection that never syncs groups (no group mappings configured at all)
  # has nothing to wait for — its members sit at `default_role` by design.
  defp groups_ever_synced?(%IdentityProvider{scim_groups_synced_at: %DateTime{}}), do: true

  defp groups_ever_synced?(%IdentityProvider{} = provider),
    do: not provider_maps_any_group?(provider)

  # Runner access is mapped from groups too, so a connection that maps ONLY
  # runner access still has a snapshot to wait for. Checking role mappings alone
  # let it treat the empty pre-push state as authoritative and replace mapped
  # access with the connection default.
  defp provider_maps_any_group?(%IdentityProvider{} = provider) do
    roles =
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_provider_id(provider.id)

    access =
      GroupRunnerAccessMapping.Query.not_deleted()
      |> GroupRunnerAccessMapping.Query.by_provider_id(provider.id)

    Repo.exists?(roles) or Repo.exists?(access)
  end

  # Apply the recomputed authorization in one membership transaction. Accounts
  # preserves a human owner role while still reconciling directory-owned runner
  # access, so the owner exception cannot acknowledge a stale broad grant.
  defp apply_recomputed_authorization(
         provider,
         role,
         access,
         %Accounts.Membership{} = membership
       ),
       do: Accounts.sync_set_membership_authorization(membership, role, access, provider)

  defp apply_recomputed_authorization(_provider, _role, _access, nil),
    do: {:error, :not_found}

  defp recompute_role_for_affected(%IdentityProvider{}, []), do: :ok

  defp recompute_role_for_affected(%IdentityProvider{} = provider, identities) do
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

  defp provider_runner_access_mappings(%IdentityProvider{} = provider) do
    GroupRunnerAccessMapping.Query.not_deleted()
    |> GroupRunnerAccessMapping.Query.by_provider_id(provider.id)
    |> Repo.all()
  end

  defp effective_runner_access(provider, group_ids, mappings) do
    group_access =
      mappings
      |> Enum.filter(&(&1.external_group_id in group_ids))
      |> Enum.map(&runner_access_mapping_access/1)

    Accounts.RunnerAccess.union([provider_runner_access(provider) | group_access])
  end

  defp runner_access_mapping_access(%GroupRunnerAccessMapping{} = mapping) do
    case Accounts.RunnerAccess.from_prefixed_fields(mapping, :runner) do
      {:ok, access} -> access
      {:error, _reason} -> Accounts.RunnerAccess.none()
    end
  end

  # The most-privileged mapped role over a set of group ids.
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
  defp replace_group_members(
         %IdentityProvider{} = provider,
         external_group_id,
         display,
         desired_ids
       ) do
    current = current_group_members(provider, external_group_id)
    current_ids = Enum.map(current, & &1.user_identity_id)

    to_remove = Enum.reject(current, &(&1.user_identity_id in desired_ids))
    to_add = Enum.reject(desired_ids, &(&1 in current_ids))

    soft_delete_group_members(to_remove)
    insert_group_members(provider, external_group_id, display, to_add)

    changed_ids = Enum.map(to_remove, & &1.user_identity_id) ++ to_add
    load_identities(provider, changed_ids)
  end

  defp add_group_members(%IdentityProvider{} = provider, external_group_id, add_ids) do
    current_ids =
      provider
      |> current_group_members(external_group_id)
      |> Enum.map(& &1.user_identity_id)

    # A PATCH member op carries no displayName; the group's name is whatever its
    # PUT-stamped sibling rows already say, which is what the read aggregates.
    to_add = Enum.reject(add_ids, &(&1 in current_ids))
    insert_group_members(provider, external_group_id, nil, to_add)
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
  defp insert_group_members(_provider, _external_group_id, _display, []), do: :ok

  defp insert_group_members(
         %IdentityProvider{} = provider,
         external_group_id,
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
          external_group_id: external_group_id,
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

  defp load_identities(%IdentityProvider{}, []), do: []

  defp load_identities(%IdentityProvider{} = provider, identity_ids) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_ids(Enum.uniq(identity_ids))
    |> Repo.all()
  end

  # Refresh the IdP's group label wherever it is stored: on the group's own
  # membership rows, so an unmapped group still answers SCIM reads by name, and
  # on any matching role mapping, so the config UI shows the current name. A PUT
  # that omits displayName must not erase either, so nil is a no-op.
  defp refresh_group_display(_provider, _external_group_id, nil), do: :ok

  defp refresh_group_display(%IdentityProvider{} = provider, external_group_id, display) do
    now = DateTime.utc_now()

    members_queryable =
      DirectoryGroupMember.Query.not_deleted()
      |> DirectoryGroupMember.Query.by_provider_and_group(provider.id, external_group_id)

    Repo.update_all(members_queryable, set: [external_group_display: display, updated_at: now])

    GroupRoleMapping.Query.not_deleted()
    |> GroupRoleMapping.Query.by_provider_id(provider.id)
    |> GroupRoleMapping.Query.by_external_group_id(external_group_id)
    |> Repo.update_all(set: [external_group_display: display, updated_at: now])

    :ok
  end

  # -- Directory sync (SCIM) — config (Subject-gated) ------------------

  @doc """
  Enable directory sync on a provider: mint a SCIM bearer, store its
  prefix + hash + `scim_enabled: true`, and return the raw token ONCE
  (`{:ok, provider, raw_token}` — write-only, like every emisar secret).
  `manage_sso` on the enterprise plan; a kind that can't push SCIM is
  `{:error, :scim_not_supported}` and keeps its token and flag untouched.
  """
  def enable_scim(%IdentityProvider{} = provider, %Subject{} = subject),
    do: write_scim_token(provider, subject, enabled: true)

  @doc """
  Rotate a provider's SCIM bearer (invalidates the old one). Returns the new raw
  token once. `manage_sso` + enterprise; a kind that can't push SCIM is
  `{:error, :scim_not_supported}`.
  """
  def rotate_scim_token(%IdentityProvider{} = provider, %Subject{} = subject),
    do: write_scim_token(provider, subject, enabled: true)

  defp write_scim_token(%IdentityProvider{id: id}, %Subject{} = subject, enabled: enabled) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      {raw, prefix, hash} = Crypto.scim_token()

      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        # Judged on the locked row, not on the console's copy: a kind with no
        # inbound SCIM must never end up holding a live bearer that authenticates
        # a directory it can't have. Disable stays open, so a token minted before
        # this can still be retired.
        with: fn loaded_provider ->
          if ProviderKind.supports_scim?(loaded_provider.kind),
            do: IdentityProvider.Changeset.scim_token(loaded_provider, prefix, hash, enabled),
            else: :scim_not_supported
        end,
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
    with :ok <- ensure_can_manage_sso(subject) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(IdentityProvider.Query,
        with: fn provider ->
          provider
          |> IdentityProvider.Changeset.disable_scim()
          |> then(&prepare_provider_authorization_change(provider, &1, true))
        end,
        audit: &Audit.Events.identity_provider_updated(subject, &1),
        # Sync no longer owns these members' roles — hand control back to operators.
        after_commit: &return_role_control_to_operators/1
      )
    end
  end

  defp return_role_control_to_operators(%IdentityProvider{} = provider) do
    user_ids =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> UserIdentity.Query.select_user_ids()
      |> Repo.all()

    Accounts.clear_directory_managed_for_users(provider.account_id, provider.id, user_ids)
    drop_group_snapshot(provider)
  end

  # The group memberships are a snapshot of what the directory last pushed, and
  # they are only true while it is pushing. Kept across a disable/re-enable, the
  # first user to sync recomputed their role from a stale snapshot — restoring an
  # admin role or a runner grant the directory may have revoked while sync was
  # off, before any fresh group push could correct it. Turning sync off discards
  # it; turning sync back on starts from what the directory actually says.
  defp drop_group_snapshot(%IdentityProvider{} = provider) do
    now = DateTime.utc_now()

    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_account_id(provider.account_id)
    |> DirectoryGroupMember.Query.by_provider_id(provider.id)
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    DirectoryGroup.Query.not_deleted()
    |> DirectoryGroup.Query.by_account_id(provider.account_id)
    |> DirectoryGroup.Query.by_provider_id(provider.id)
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    :ok
  end

  # -- Directory sync (SCIM) — group→role mapping config (Subject-gated) --

  @doc """
  List each external group a provider has synced via SCIM with its distinct
  member count — the synced-groups readout, and (projected to ids) the picker
  source for map-after-first-sync so an admin keys a role mapping on a real
  synced group. `manage_sso` + Enterprise; account-scoped.
  `{:ok, [%{external_group_id: String.t(), member_count: non_neg_integer()}]}`,
  ordered by external group id.
  """
  def list_synced_groups(%IdentityProvider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject),
         {:ok, provider} <- fetch_provider_by_id(provider.id, subject) do
      # Existence comes from the GROUP rows, the same source the SCIM reads use.
      # Deriving it from member rows here meant an empty group — which the
      # directory has genuinely pushed — could not be picked for a mapping,
      # because the console could not see it at all.
      counts =
        DirectoryGroupMember.Query.not_deleted()
        |> DirectoryGroupMember.Query.group_counts_for_provider(provider.id)
        |> Repo.all()
        |> Map.new(&{&1.external_group_id, &1})

      groups =
        DirectoryGroup.Query.not_deleted()
        |> DirectoryGroup.Query.by_account_id(provider.account_id)
        |> DirectoryGroup.Query.by_provider_id(provider.id)
        |> DirectoryGroup.Query.ordered_by_external_group_id()
        |> Repo.all()
        |> Enum.map(fn group ->
          counted = Map.get(counts, group.external_group_id, %{})

          %{
            external_group_id: group.external_group_id,
            member_count: Map.get(counted, :member_count, 0)
          }
        end)

      {:ok, groups}
    end
  end

  @doc "List a provider's group→role mappings. `manage_sso` + enterprise; account-scoped."
  def list_group_mappings(%IdentityProvider{id: provider_id}, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject) do
      # No pre-ordering: the query module's cursor (external_group_id, id) drives
      # the ORDER BY so it matches the keyset WHERE. `external_group_display` is
      # nullable, so it can't be a keyset field (this paginator can't compare
      # NULLs) — order on the required external_group_id instead.
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_provider_id(provider_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(GroupRoleMapping.Query, opts)
    end
  end

  @doc """
  Create a group→role mapping for a provider. `manage_sso` + enterprise; the
  provider must be in the subject's account. The changeset rejects `:owner` —
  sync can never grant owner (decision 7). Existing synced group members are
  reconciled after the mapping commits. `{:ok, mapping}`.
  """
  def create_group_mapping(%IdentityProvider{} = provider, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_configure_directory_sync(subject),
         :ok <- ensure_grantable_role(attrs["role"] || attrs[:role], subject),
         {:ok, provider} <- fetch_provider_by_id(provider.id, subject) do
      multi = create_group_mapping_multi(provider, attrs, subject)

      case Repo.commit_multi(multi,
             after_commit: fn %{mapping: mapping} -> recompute_mapping_members(mapping) end
           ) do
        {:ok, %{mapping: mapping}} -> {:ok, mapping}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_group_mapping_multi(%IdentityProvider{} = provider, attrs, %Subject{} = subject) do
    changeset = GroupRoleMapping.Changeset.create(provider.account_id, provider.id, attrs)

    Multi.new()
    |> Multi.run(:authorization_version, fn _repo, _changes ->
      prepare_mapping_authorization_change(
        provider.account_id,
        provider.id,
        Ecto.Changeset.get_field(changeset, :external_group_id)
      )
    end)
    |> Multi.insert(:mapping, changeset)
    |> Multi.insert(:audit, fn %{mapping: mapping} ->
      Audit.Events.group_role_mapping_created(subject, provider, mapping)
    end)
  end

  @doc "Update a group→role mapping (its role / display). `manage_sso` + enterprise; account-scoped. Reconciles current group members after commit and rejects `:owner`."
  def update_group_mapping(%GroupRoleMapping{id: id}, attrs, %Subject{} = subject) do
    with :ok <- ensure_can_configure_directory_sync(subject),
         :ok <- ensure_grantable_role(attrs["role"] || attrs[:role], subject) do
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(GroupRoleMapping.Query,
        with: fn mapping ->
          case prepare_mapping_authorization_change(
                 mapping.account_id,
                 mapping.provider_id,
                 mapping.external_group_id
               ) do
            {:ok, _provider} -> GroupRoleMapping.Changeset.update(mapping, attrs)
            {:error, reason} -> reason
          end
        end,
        audit: &Audit.Events.group_role_mapping_updated(subject, &1),
        after_commit: &recompute_mapping_members/1
      )
    end
  end

  @doc "Soft-delete a group→role mapping. `manage_sso` + enterprise; account-scoped. Reconciles current group members after commit."
  def delete_group_mapping(%GroupRoleMapping{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(GroupRoleMapping.Query,
        with: fn mapping ->
          case prepare_mapping_authorization_change(
                 mapping.account_id,
                 mapping.provider_id,
                 mapping.external_group_id
               ) do
            {:ok, _provider} -> GroupRoleMapping.Changeset.delete(mapping)
            {:error, reason} -> reason
          end
        end,
        audit: &Audit.Events.group_role_mapping_deleted(subject, &1),
        after_commit: &recompute_mapping_members/1
      )
    end
  end

  @doc "List a provider's explicit IdP-group runner-access mappings."
  def list_group_runner_access_mappings(
        %IdentityProvider{id: provider_id},
        %Subject{} = subject,
        opts \\ []
      ) do
    with :ok <- ensure_can_manage_sso(subject) do
      GroupRunnerAccessMapping.Query.not_deleted()
      |> GroupRunnerAccessMapping.Query.by_provider_id(provider_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(GroupRunnerAccessMapping.Query, opts)
    end
  end

  @doc "Create an explicit additive runner-access grant for one synced IdP group."
  def create_group_runner_access_mapping(
        %IdentityProvider{} = provider,
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject),
         # The subject-scoped re-read comes first: a cross-account provider is
         # not_found before any of its attrs is parsed or looked up.
         {:ok, provider} <- fetch_provider_by_id(provider.id, subject),
         {attrs, allowlist} =
           mapping_selection(attrs, provider.account_id, %GroupRunnerAccessMapping{}),
         changeset =
           GroupRunnerAccessMapping.Changeset.create(
             provider.account_id,
             provider.id,
             attrs,
             allowlist
           ),
         {:ok, access} <- runner_access_mapping_from_changeset(changeset),
         :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access) do
      Multi.new()
      |> Multi.run(:authorization_version, fn _repo, _changes ->
        prepare_mapping_authorization_change(
          provider.account_id,
          provider.id,
          Ecto.Changeset.get_field(changeset, :external_group_id)
        )
      end)
      |> Multi.insert(:mapping, changeset)
      |> Multi.insert(:audit, fn %{mapping: mapping} ->
        Audit.Events.group_runner_access_mapping_created(subject, provider, mapping)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{mapping: mapping} ->
          recompute_runner_access_mapping_members(mapping)
        end
      )
      |> case do
        {:ok, %{mapping: mapping}} -> {:ok, mapping}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Update an IdP-group runner-access grant and immediately reconcile current members."
  def update_group_runner_access_mapping(
        %GroupRunnerAccessMapping{id: id},
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      GroupRunnerAccessMapping.Query.not_deleted()
      |> GroupRunnerAccessMapping.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(GroupRunnerAccessMapping.Query,
        with: fn mapping ->
          # The locked row is what the selection is resolved against: its
          # account owns the runners, so a cross-account id never gets here.
          {attrs, allowlist} = mapping_selection(attrs, mapping.account_id, mapping)
          changeset = GroupRunnerAccessMapping.Changeset.update(mapping, attrs, allowlist)

          with {:ok, access} <- runner_access_mapping_from_changeset(changeset),
               :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access),
               {:ok, _provider} <-
                 prepare_mapping_authorization_change(
                   mapping.account_id,
                   mapping.provider_id,
                   mapping.external_group_id
                 ) do
            changeset
          else
            {:error, %Ecto.Changeset{} = invalid} -> invalid
            {:error, reason} -> reason
          end
        end,
        audit: fn updated, changeset ->
          Audit.Events.group_runner_access_mapping_updated(subject, changeset.data, updated)
        end,
        after_commit: &recompute_runner_access_mapping_members/1
      )
    end
  end

  @doc "Delete an IdP-group runner-access grant and immediately revoke its derived reach."
  def delete_group_runner_access_mapping(
        %GroupRunnerAccessMapping{id: id},
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      GroupRunnerAccessMapping.Query.not_deleted()
      |> GroupRunnerAccessMapping.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(GroupRunnerAccessMapping.Query,
        with: fn mapping ->
          case prepare_mapping_authorization_change(
                 mapping.account_id,
                 mapping.provider_id,
                 mapping.external_group_id
               ) do
            {:ok, _provider} -> GroupRunnerAccessMapping.Changeset.delete(mapping)
            {:error, reason} -> reason
          end
        end,
        audit: &Audit.Events.group_runner_access_mapping_deleted(subject, &1),
        after_commit: &recompute_runner_access_mapping_members/1
      )
    end
  end

  defp runner_access_mapping_from_changeset(%Ecto.Changeset{} = changeset) do
    if changeset.valid? do
      changeset
      |> Ecto.Changeset.apply_changes()
      |> runner_access_mapping_access()
      |> then(&{:ok, &1})
    else
      {:error, changeset}
    end
  end

  defp prepare_mapping_authorization_change(account_id, provider_id, external_group_id) do
    provider =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(account_id)
      |> IdentityProvider.Query.by_id(provider_id)
      |> IdentityProvider.Query.lock_for_update()
      |> Repo.fetch(IdentityProvider.Query)

    with {:ok, %IdentityProvider{scim_enabled: true} = provider} <- provider,
         {:ok, updated_provider} <- bump_provider_authorization_version(provider) do
      user_ids = external_group_user_ids(provider, external_group_id)

      {:ok, _version} =
        Accounts.mark_directory_authorization_pending(
          Repo,
          provider.account_id,
          provider.id,
          user_ids,
          updated_provider.authorization_version
        )

      {:ok, updated_provider}
    else
      {:ok, %IdentityProvider{} = provider} -> {:ok, provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bump_provider_authorization_version(%IdentityProvider{} = provider) do
    provider
    |> Ecto.Changeset.change()
    |> IdentityProvider.Changeset.bump_authorization_version(provider.authorization_version)
    |> Repo.update()
  end

  defp external_group_user_ids(provider, external_group_id) do
    provider
    |> current_group_members(external_group_id)
    |> Enum.map(& &1.user_identity_id)
    |> then(&load_identities(provider, &1))
    |> Enum.map(& &1.user_id)
  end

  # A group mapping is an authorization decision, not just display config. A
  # new, changed, or removed mapping must immediately reconcile members already
  # synced into that group; otherwise a deleted admin mapping can leave its
  # members elevated until the directory happens to push the group again.
  # After-commit keeps the mapping and its audit event atomic while letting the
  # membership writes own their existing transaction and audit lifecycle.
  defp recompute_mapping_members(%GroupRoleMapping{} = mapping),
    do: recompute_external_group_members(mapping)

  defp recompute_runner_access_mapping_members(%GroupRunnerAccessMapping{} = mapping),
    do: recompute_external_group_members(mapping)

  defp recompute_external_group_members(mapping) do
    provider =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(mapping.account_id)
      |> IdentityProvider.Query.by_id(mapping.provider_id)
      |> Repo.peek()

    case provider do
      %IdentityProvider{scim_enabled: true} = provider ->
        identity_ids =
          provider
          |> current_group_members(mapping.external_group_id)
          |> Enum.map(& &1.user_identity_id)

        provider
        |> load_identities(identity_ids)
        |> then(&recompute_role_for_affected(provider, &1))

      _ ->
        :ok
    end
  end

  # -- Manual link requests (Subject-gated) ----------------------------

  @doc "List a provider's pending manual-link requests. `manage_sso` + Team or Enterprise; account-scoped."
  def list_link_requests(%IdentityProvider{id: provider_id}, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject) do
      LinkRequest.Query.all()
      |> LinkRequest.Query.by_provider_id(provider_id)
      |> LinkRequest.Query.ordered_by_recent()
      |> Authorizer.for_subject(subject)
      |> Repo.list(LinkRequest.Query, opts)
    end
  end

  @doc "List pending manual-link requests across ALL the account's connections — for the SSO overview's needs-attention block. `manage_sso` + Team or Enterprise; account-scoped."
  def list_pending_link_requests_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject) do
      LinkRequest.Query.all()
      |> LinkRequest.Query.ordered_by_recent()
      |> Authorizer.for_subject(subject)
      |> Repo.list(LinkRequest.Query, opts)
    end
  end

  @doc """
  The account's pending manual-link requests as the approval form's facts: the
  request, the connection it arrived through, and the runner access that
  connection currently defaults to.

  The connection is joined in the SAME paginated read, so a request whose
  provider was deleted is simply not listed — it can never be offered with a
  silently defaulted `RunnerAccess.none()` behind it. A DISABLED connection keeps
  its defaults; only deletion removes the request. `manage_sso` + Team or
  Enterprise; account-scoped. Returns `{:ok, [facts], %Paginator.Metadata{}}`.
  """
  def list_pending_link_request_facts(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject),
         {:ok, requests, metadata} <- list_pending_link_requests_with_provider(subject, opts) do
      {:ok, Enum.map(requests, &pending_link_request_facts/1), metadata}
    end
  end

  defp list_pending_link_requests_with_provider(%Subject{} = subject, opts) do
    LinkRequest.Query.all()
    |> LinkRequest.Query.with_preloaded_provider()
    |> LinkRequest.Query.ordered_by_recent()
    |> Authorizer.for_subject(subject)
    |> Repo.list(LinkRequest.Query, opts)
  end

  # The provider rides along only so this module can derive the facts; a caller
  # reads the connection through `provider` and the defaults through
  # `default_runner_access`, never off the association.
  defp pending_link_request_facts(
         %LinkRequest{provider: %IdentityProvider{} = provider} = request
       ) do
    %{
      request: %{request | provider: nil},
      provider: provider_facts(provider),
      default_runner_access: provider_runner_access(provider)
    }
  end

  @doc """
  Internal — the SSO pending-approval page loads its OWN captured request by the
  id stashed in the browser session (authorized by possession — no `%Subject{}`,
  the person isn't a member yet), account preloaded for the org label. A missing
  row means it was already approved or dismissed. `{:ok, request} | {:error,
  :not_found}`.
  """
  def fetch_pending_link_request(id) do
    if Repo.valid_uuid?(id) do
      LinkRequest.Query.by_id(id)
      |> LinkRequest.Query.with_preloaded_account()
      |> Repo.fetch(LinkRequest.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Approve a pending manual-link request: provision the captured identity at the
  provider's `default_role` and delete the request, atomically. `manage_sso` +
  Team or Enterprise; account-scoped. Binds the captured `sub` (never email — H1).
  `{:ok, %{user: user, identity: identity}}`.
  """
  def approve_link_request(
        %LinkRequest{id: id},
        %Accounts.RunnerAccess{} = access,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_sso(subject),
         {:ok, request} <- fetch_link_request(id, subject),
         {:ok, provider} <- fetch_provider_for_request(request, subject),
         :ok <- ensure_link_target_within_authority(request, provider, subject.role, Repo),
         :ok <- ensure_approval_runner_access_allowed(request, access, subject) do
      multi = approve_link_request_multi(provider, request, access, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{user: user, identity: identity} = changes} ->
          :ok = link_approval_membership_effects(changes)
          broadcast_link_request_approved(request)
          {:ok, %{user: user, identity: identity}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # An approval that reinstated a directory-suspended membership owes the team
  # page its broadcast — fired here, after the commit, like every sync side
  # effect (the membership step tags a committed reinstate for exactly this).
  defp link_approval_membership_effects(%{membership: {:reinstated, membership}}),
    do: Accounts.membership_reinstated_effects(membership)

  defp link_approval_membership_effects(_changes), do: :ok

  # Approving a MATCH binds a new IdP credential to an EXISTING person, so
  # whoever holds that credential can afterwards sign in as them. The approver is
  # also whoever configured the IdP, so without a limit they can assert any
  # email, approve their own request, and authenticate as that member — an admin
  # reaching owner, and (because a session can switch accounts) reaching every
  # other account that person belongs to.
  #
  # Two limits, both judged on the matched member rather than on the request:
  #
  #   * the approver's permissions must COVER the target's role — the same
  #     no-escalation primitive role changes and invites use — so an admin can
  #     never bind themselves onto an owner;
  #   * the target must not hold an active membership in another account, because
  #     this account's admin has no authority there and the resulting session
  #     would reach it.
  #
  # A request with no match provisions a fresh user and escalates nothing.
  defp ensure_link_target_within_authority(
         %LinkRequest{matched_user_id: nil},
         _provider,
         _approver_role,
         _repo
       ),
       do: :ok

  defp ensure_link_target_within_authority(
         %LinkRequest{} = request,
         %IdentityProvider{} = provider,
         approver_role,
         repo
       ) do
    with {:ok, user} <- Users.fetch_user_by_id(request.matched_user_id),
         # LOCKED, because this decision has to still be true when the binding
         # commits. Re-reading inside the transaction was not enough on its own:
         # nothing stopped a concurrent promotion to owner, or a membership granted
         # in another account, from committing in the gap — leaving the approver's
         # IdP credential bound to someone they have no authority over.
         {:ok, memberships} <- Accounts.fetch_and_lock_active_memberships_for_user(user, repo) do
      {here, elsewhere} = Enum.split_with(memberships, &(&1.account_id == provider.account_id))

      cond do
        elsewhere != [] ->
          {:error, :link_target_in_other_accounts}

        # Against the role read under lock, not the session's. An owner demoted to
        # admin keeps manage_sso, so the check above still passes — but they no
        # longer cover an owner, and the cached subject said they did.
        Enum.any?(here, &(not Auth.Permissions.role_covers_role?(approver_role, &1.role))) ->
          {:error, :link_target_outranks_approver}

        true ->
          :ok
      end
    end
  end

  defp ensure_approval_runner_access_allowed(
         %LinkRequest{matched_user_id: nil},
         access,
         subject
       ),
       do: Accounts.ensure_runner_access_grant_allowed(subject, access)

  defp ensure_approval_runner_access_allowed(%LinkRequest{}, _access, %Subject{}), do: :ok

  @doc "Dismiss a pending manual-link request without provisioning. `manage_sso` + Team or Enterprise; account-scoped. `{:ok, request}`."
  def dismiss_link_request(%LinkRequest{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject),
         {:ok, request} <- fetch_link_request(id, subject) do
      multi =
        Multi.new()
        |> Multi.delete(:request, request)
        |> Multi.insert(:audit, Audit.Events.sso_link_request_dismissed(subject, request))

      case Repo.commit_multi(multi) do
        {:ok, %{request: request}} ->
          broadcast_link_request_dismissed(request)
          {:ok, request}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -- PubSub ---------------------------------------------------------
  # The pending-approval page subscribes to its own link request so it can react
  # the instant an admin approves (re-auth → signed in) or dismisses it — keyed by
  # the request id, which only that person's browser holds.

  @doc "Internal — the pending-approval page subscribes to its captured request."
  def subscribe_link_request(id) when is_binary(id),
    do: Emisar.PubSub.subscribe(link_request_topic(id))

  defp broadcast_link_request_approved(%LinkRequest{} = request) do
    Emisar.PubSub.broadcast(
      link_request_topic(request.id),
      {:sso_link_request, :approved, %{id: request.id, provider_id: request.provider_id}}
    )
  end

  defp broadcast_link_request_dismissed(%LinkRequest{} = request) do
    Emisar.PubSub.broadcast(
      link_request_topic(request.id),
      {:sso_link_request, :dismissed, %{id: request.id}}
    )
  end

  defp link_request_topic(id), do: "sso_link_request:#{id}"

  # No existing user matched → provision a fresh user (the original flow).
  defp approve_link_request_multi(
         %IdentityProvider{} = provider,
         %LinkRequest{matched_user_id: nil} = request,
         access,
         subject
       ) do
    # This branch creates a user, an identity, a membership and an audit row, and
    # it never re-checked the approver — so an admin demoted, suspended or removed
    # while the request sat open could still run all of it on a cached subject.
    # Nothing here reads the approver's row otherwise.
    Multi.new()
    |> Multi.run(:approver, fn repo, _changes ->
      ensure_approver_still_holds_authority(provider, subject, repo)
    end)
    |> Multi.append(
      build_provision_multi(provider, request.provider_identifier, request.claims,
        created_by: :admin,
        provisioned_via: :manual,
        runner_access: access,
        audit: &Audit.Events.sso_link_request_approved(subject, &1, provider)
      )
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
         _access,
         %Subject{} = subject
       ) do
    Multi.new()
    |> put_provider_lock(provider)
    |> Multi.run(:user, fn repo, _changes ->
      fetch_matched_member(provider, request, subject, repo)
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
  # Re-judge the target INSIDE the transaction, not just re-fetch them. The
  # authority check that runs before the approval reads state the approval then
  # acts on moments later: a concurrent promotion to owner, or a membership
  # granted in another account, both landed after validation and before the
  # binding — leaving an attacker-supplied credential attached to a user who had
  # since become someone this admin has no authority over.
  defp fetch_matched_member(
         %IdentityProvider{} = provider,
         %LinkRequest{} = request,
         %Subject{} = subject,
         repo
       ) do
    with :ok <- ensure_request_matches_current_namespace(provider, request),
         {:ok, approver_role} <- ensure_approver_still_holds_authority(provider, subject, repo),
         {:ok, user} <- Users.fetch_user_by_id(request.matched_user_id),
         %Accounts.Membership{} <- Accounts.peek_sync_membership(provider.account_id, user.id),
         :ok <- ensure_link_target_within_authority(request, provider, approver_role, repo) do
      {:ok, user}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :matched_user_unavailable}
    end
  end

  # The connection's identity namespace, as one comparable value. Approval checks
  # it under the provider lock, so a request made under a different issuer, client
  # or identifier claim cannot be approved against this one — including a request
  # inserted by a callback that was already in flight when the change committed,
  # which the delete alongside that change cannot reach.
  defp namespace_fingerprint(%IdentityProvider{} = provider) do
    Crypto.hash_hex("#{provider.issuer}\n#{provider.client_id}\n#{provider.identifier_claim}")
  end

  defp ensure_request_matches_current_namespace(
         %IdentityProvider{} = provider,
         %LinkRequest{} = request
       ) do
    if request.namespace_fingerprint == namespace_fingerprint(provider) do
      :ok
    else
      {:error, :identity_namespace_changed}
    end
  end

  @doc """
  Internal — retire the admin-approved SSO bindings a person holds, because they
  have just gained a membership somewhere else. No `%Subject{}`: the caller is
  Accounts, creating that membership, and this is a consequence of that write
  rather than an action anyone requested.

  Approving a link binds an IdP credential to an existing person, and is allowed
  only when that person belongs to no OTHER account — otherwise the approver
  reaches an account they have no authority over. That check is made at approval
  and cannot see the future: the moment a second membership exists, the reason the
  binding was permitted has stopped being true. So the binding goes with it, and
  the sessions behind it are revoked.

  Directory-asserted identities are untouched. Those were never an emisar-side
  decision about who a credential belongs to — the IdP said so, and it still does.

  Returns the number retired.
  """
  def retire_admin_approved_identities(%Users.User{} = user, repo) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_user_id(user.id)
      |> UserIdentity.Query.admin_approved()

    identity_ids = repo.all(UserIdentity.Query.select_ids(queryable))

    case identity_ids do
      [] ->
        {:ok, 0}

      ids ->
        now = DateTime.utc_now()

        {retired, _} =
          UserIdentity.Query.not_deleted()
          |> UserIdentity.Query.by_ids(ids)
          |> repo.update_all(set: [deleted_at: now, updated_at: now])

        :ok = Auth.revoke_identity_sessions(user, ids)
        {:ok, retired}
    end
  end

  # The approver's own standing, re-read under lock. `%Subject{}.permissions` is a
  # snapshot taken when the session was built, so an admin demoted or suspended
  # while their approval page sat open still carried the permissions they had when
  # it loaded — one last credential binding after the authority for it was taken
  # away. Nothing else in this transaction touches the approver's row, so nothing
  # else would have noticed.
  defp ensure_approver_still_holds_authority(
         %IdentityProvider{} = provider,
         %Subject{membership_id: membership_id},
         repo
       )
       when is_binary(membership_id) do
    # The same locked read OAuth takes at its consent mint, for the same reason:
    # a stale session subject must not act after access was suspended, removed or
    # demoted. It rejects a disabled or deleted membership itself, so what remains
    # to judge is the CURRENT role.
    case Accounts.fetch_and_lock_membership(provider.account_id, membership_id, repo: repo) do
      {:ok, %Accounts.Membership{role: role}} ->
        if Authorizer.manage_sso_permission() in Authorizer.list_permissions_for_role(role),
          do: {:ok, role},
          else: {:error, :unauthorized}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  defp ensure_approver_still_holds_authority(_provider, %Subject{}, _repo),
    do: {:error, :unauthorized}

  # A person holds ONE identity per connection, so a member who already has one
  # is REBOUND to the approved identifier rather than given a second. A second
  # made authorization nondeterministic — role and runner access are computed per
  # identity onto the one membership, so the last iteration won — and made the
  # reconcile job's single-row read raise.
  #
  # The request's SOURCE decides which identifier it is. Stamping both from one
  # value let the two namespaces fight over the row: with an OIDC `sub` and a
  # directory `externalId` that differ, approving a SCIM request overwrote the
  # sub, the next OIDC login then failed to find the person and parked its own
  # request, and approving THAT overwrote the externalId — back and forth, one
  # approval at a time, with whichever side was not current unable to see them.
  defp link_identity(%IdentityProvider{} = provider, user, %LinkRequest{} = request) do
    case peek_identity(provider, user.id) do
      %UserIdentity{} = identity ->
        identity
        |> rebind_changeset(request)
        |> Repo.update()

      nil ->
        # A first identity holds the identifier in both roles: the directory and
        # the login agree on it until one of them says otherwise.
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
  end

  defp rebind_changeset(%UserIdentity{} = identity, %LinkRequest{source: :scim} = request) do
    UserIdentity.Changeset.adopt_scim_external_id(identity, request.provider_identifier)
  end

  defp rebind_changeset(%UserIdentity{} = identity, %LinkRequest{} = request) do
    UserIdentity.Changeset.rebind_provider_identifier(
      identity,
      request.provider_identifier,
      request.claims
    )
  end

  defp peek_identity(%IdentityProvider{} = provider, user_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_user_id(user_id)
    |> Repo.peek()
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

  @doc "All supported identity-provider kinds, in the order the console offers them."
  def identity_provider_kinds, do: ProviderKind.all()

  @doc """
  The one issuer this kind serves every customer from — the value the console
  shows locked, and the one a create is normalized to. Nil when the issuer is
  per-customer or the kind is unknown. Takes the atom or its string form.
  """
  def provider_fixed_issuer(kind) do
    case ProviderKind.fetch(kind) do
      {:ok, metadata} -> metadata.fixed_issuer
      :error -> nil
    end
  end

  @doc """
  The claim this kind carries a stable identity in (`:sub`, or `:oid` for Entra's
  pairwise `sub`) — what a new connection is created with. Nil for an unknown
  kind. Takes the atom or its string form.
  """
  def provider_identifier_claim(kind) do
    case ProviderKind.fetch(kind) do
      {:ok, metadata} -> metadata.identifier_claim
      :error -> nil
    end
  end

  @doc "True when directory sync (SCIM) is available for this provider kind."
  def supports_scim?(kind), do: ProviderKind.supports_scim?(kind)

  @doc """
  True when this connection's directory has pushed to us within the last day —
  directory sync is enabled on a SCIM-capable connection whose
  `scim_last_seen_at` is between now and 24 hours old. Setup is done, so the console stops showing the
  "point your IdP at this connection" steps. Never synced, disabled, a kind that
  can't sync, a future stamp, or a full day of silence are all false.
  """
  def provider_sync_recent?(provider, now \\ DateTime.utc_now())

  def provider_sync_recent?(
        %IdentityProvider{scim_enabled: true, scim_last_seen_at: %DateTime{} = at} = provider,
        %DateTime{} = now
      ) do
    age = DateTime.diff(now, at, :microsecond)

    ProviderKind.supports_scim?(provider.kind) and age >= 0 and
      age < 24 * 60 * 60 * 1_000_000
  end

  def provider_sync_recent?(%IdentityProvider{}, %DateTime{}), do: false

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

  @doc "Permission HALF of the SSO gate — a permission-lock and a plan-lock are different messages."
  def subject_can_manage_sso?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_sso_permission())

  @doc "True when the subject may configure OIDC SSO — `manage_sso` on the Team or Enterprise plan."
  def subject_can_configure_sso?(%Subject{account: account} = subject) do
    Auth.Authorizer.has_permission?(subject, Authorizer.manage_sso_permission()) and
      Billing.sso_available?(account)
  end

  @doc "True when the subject may configure SCIM directory sync — `manage_sso` on the Enterprise plan."
  def subject_can_configure_directory_sync?(%Subject{account: account} = subject) do
    Auth.Authorizer.has_permission?(subject, Authorizer.manage_sso_permission()) and
      Billing.directory_sync_available?(account)
  end

  # A plan gate bounds what an account may ADD or keep running — never what it may
  # SEE or TAKE AWAY. A downgrade does not stop existing OIDC and SCIM credentials
  # working, so gating the reads and the destructive verbs on the plan left an
  # owner with live credentials they were structurally unable to retire: the
  # console could not list the connection, and delete/disable refused. Reads and
  # cleanup check the permission alone.
  #
  # "Destructive" means STOPS something, not "is spelled delete". Removing a group
  # mapping recomputes its members, and a member left in no mapped group falls
  # back to `default_role` — so with a provider defaulting to `admin` and a group
  # mapped to `viewer`, the delete PROMOTES everyone it touches. Both mapping
  # deletes are plan-gated for that reason; retiring the connection or its
  # directory token is what a downgraded account uses to contain one.
  defp ensure_can_manage_sso(%Subject{} = subject),
    do: Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_sso_permission())

  defp ensure_can_configure_sso(%Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_sso_permission()) do
      if Billing.sso_available?(account), do: :ok, else: {:error, :sso_not_available}
    end
  end

  defp ensure_can_configure_directory_sync(%Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_sso_permission()) do
      if Billing.directory_sync_available?(account),
        do: :ok,
        else: {:error, :directory_sync_not_available}
    end
  end
end
