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
  JIT-provisions a workspace Member + identity when the provider's
  `provisioner` is `:jit`. SSO and SCIM create Members whose address stays
  unverified, so they sign in through SSO only.
  """
  use Supervisor
  import Emisar.SSO.Provisioning
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Billing, Catalog, Crypto, Repo, Runners}
  alias Emisar.Auth.Subject
  alias Emisar.RequestContext
  alias Emisar.SSO.{Authorizer, DirectoryGroup, DirectoryGroupMember}
  alias Emisar.SSO.GroupAccess
  alias Emisar.SSO.GroupRoleMapping
  alias Emisar.SSO.GroupRunnerAccessMapping
  alias Emisar.SSO.{IdentityProvider, IssuerUrl, LinkRequest, OIDC, ProviderKind}
  alias Emisar.SSO.SCIM
  alias Emisar.SSO.UserIdentity
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
  whether it runs directory sync, when that sync last ran, and the identifier
  claim its sign-ins match on (the unmatched-request help names the exact claim
  to fix). Pure: the raw provider carries a client secret, a SCIM token hash,
  and the default configuration, none of which a rendering caller has any
  business reading.
  """
  def provider_facts(%IdentityProvider{} = provider) do
    %{
      id: provider.id,
      name: provider.name,
      enabled?: provider.enabled,
      directory_sync?: provider.scim_enabled,
      last_synced_at: provider.scim_last_seen_at,
      identifier_claim: provider.identifier_claim
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
  Directory facts for the given `membership_ids` in the subject's account: which
  connection provisioned each member, and whether that connection currently owns
  their directory profile. Bounded — the caller passes the ids on its page.

  Read from CURRENT rows, so turning directory sync off (or deleting the
  connection) changes the answer for a roster loaded a moment earlier. A member
  holding identities on several connections attributes deterministically: the
  directory-managed one wins, then provider name, then id. Requires `manage_sso`;
  account-scoped. Returns `{:ok, %{membership_id => facts}}`.
  """
  def member_directory_facts(membership_ids, %Subject{} = subject)
      when is_list(membership_ids) do
    with :ok <- ensure_can_manage_sso(subject) do
      rows =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_membership_ids(membership_ids)
        |> UserIdentity.Query.with_live_membership()
        |> UserIdentity.Query.ordered_by_directory_precedence()
        |> UserIdentity.Query.select_directory_facts()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, member_directory_facts_by_membership_id(rows)}
    end
  end

  # The rows arrive in precedence order, so the first one per member is both the
  # display identity and the directory-managed answer.
  defp member_directory_facts_by_membership_id(rows) do
    Enum.reduce(rows, %{}, fn {membership_id, provider_id, provider_name, provisioned_via,
                               directory_managed?},
                              facts ->
      Map.put_new(facts, membership_id, %{
        identity: %{
          provider_id: provider_id,
          provider_name: provider_name,
          provisioned_via: provisioned_via
        },
        directory_managed?: directory_managed?
      })
    end)
  end

  @doc "At most three distinct directory groups per visible member, with the full count. Requires manage_sso."
  def member_group_summaries(membership_ids, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject),
         true <-
           is_list(membership_ids) and length(membership_ids) <= 100 and
             Enum.all?(membership_ids, &Repo.valid_uuid?/1),
         :ok <- validate_group_provider_option(opts) do
      rows =
        directory_roster_query(subject, opts)
        |> DirectoryGroupMember.Query.by_roster_membership_ids(membership_ids)
        |> DirectoryGroupMember.Query.first_groups_per_member(3)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      summaries = Map.new(membership_ids, &{&1, %{groups: [], count: 0}})

      {:ok,
       Enum.reduce(rows, summaries, fn row, acc ->
         Map.update!(acc, row.membership_id, fn summary ->
           %{
             groups: summary.groups ++ [Map.drop(row, [:membership_id, :total])],
             count: row.total
           }
         end)
       end)}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @doc "One searchable page of a member's groups, across providers unless provider_id is supplied."
  def list_member_groups(membership_id, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject),
         true <- Repo.valid_uuid?(membership_id),
         :ok <- validate_group_provider_option(opts) do
      {provider_id, opts} = Keyword.pop(opts, :provider_id)

      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(subject.account.id)
      |> DirectoryGroup.Query.for_roster_member(membership_id, subject.account.id)
      |> maybe_group_provider(provider_id)
      |> DirectoryGroup.Query.with_live_provider()
      |> DirectoryGroup.Query.select_directory_labels()
      |> Authorizer.for_subject(subject)
      |> Repo.list(DirectoryGroup.Query, opts)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Narrow current group identity for a roster filter; no provider configuration is returned."
  def fetch_directory_group_facts(id, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject),
         true <- Repo.valid_uuid?(id),
         :ok <- validate_group_provider_option(opts) do
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_id(id)
      |> maybe_group_provider(Keyword.get(opts, :provider_id))
      |> DirectoryGroup.Query.with_live_provider()
      |> DirectoryGroup.Query.select_directory_labels()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(DirectoryGroup.Query)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Searchable, paginated directory group choices, optionally scoped to one connection. Requires manage_sso."
  def list_directory_groups(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_manage_sso(subject),
         :ok <- validate_group_provider_option(opts),
         :ok <- validate_directory_group_search(opts) do
      {provider_id, opts} = Keyword.pop(opts, :provider_id)

      DirectoryGroup.Query.not_deleted()
      |> maybe_group_provider(provider_id)
      |> DirectoryGroup.Query.with_live_provider()
      |> DirectoryGroup.Query.select_directory_labels()
      |> Authorizer.for_subject(subject)
      |> Repo.list(DirectoryGroup.Query, opts)
    end
  end

  defp validate_directory_group_search(opts) do
    search = opts |> Keyword.get(:filter, []) |> Keyword.get(:search, "")

    if is_binary(search) and byte_size(search) <= 512 and String.valid?(search) and
         not String.contains?(search, <<0>>), do: :ok, else: {:error, :invalid_request}
  end

  def directory_group_filters, do: DirectoryGroup.Query.filters()
  def directory_member_filters, do: UserIdentity.Query.filters()

  defp directory_roster_query(subject, opts) do
    queryable =
      DirectoryGroupMember.Query.not_deleted()
      |> DirectoryGroupMember.Query.by_account_id(subject.account.id)
      |> DirectoryGroupMember.Query.with_directory_roster()

    case Keyword.get(opts, :provider_id) do
      nil -> queryable
      id -> DirectoryGroupMember.Query.by_provider_id(queryable, id)
    end
  end

  defp maybe_group_provider(queryable, nil), do: queryable
  defp maybe_group_provider(queryable, id), do: DirectoryGroup.Query.by_provider_id(queryable, id)

  defp validate_group_provider_option(opts) do
    case Keyword.get(opts, :provider_id) do
      nil -> :ok
      id -> if Repo.valid_uuid?(id), do: :ok, else: {:error, :not_found}
    end
  end

  @doc """
  Internal — Accounts' admin profile edit: true when the user's profile is
  directory-owned in this account — they hold a live identity under a
  SCIM-enabled provider (the same boundary the synced-role lock uses, so
  disabling directory sync unlocks both together). Already-authorized callers
  only; scoped by the explicit account_id.
  """
  def member_profile_directory_managed?(account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_account_id(account_id)
      |> UserIdentity.Query.by_membership_id(membership_id)
      |> UserIdentity.Query.scim_managed()
      |> UserIdentity.Query.with_live_membership()

    Repo.exists?(queryable)
  end

  @doc """
  The members provisioned through `provider` — its `UserIdentity` rows (SCIM sync,
  SSO first-login, or approved link), each preloaded with its member profile,
  most-recent first. Powers the connection page's "Synced members" list. Paginated,
  because a directory is exactly what makes this set large. Requires `manage_sso`;
  scoped to the account. Returns `{:ok, [%UserIdentity{}], %Paginator.Metadata{}}`.
  """
  def list_synced_users(%IdentityProvider{} = provider, %Subject{} = subject, opts \\ []) do
    {group_id, opts} = Keyword.pop(opts, :directory_group_id)

    with {:ok, provider} <- fetch_provider_by_id(provider.id, subject),
         {:ok, queryable} <- synced_user_query(provider, group_id, subject) do
      # No `ordered_by_recent/1`: the query module's `cursor_fields/0` is that
      # same order, and `Repo.list/3` applies it.
      queryable
      |> UserIdentity.Query.with_preloaded_membership()
      |> Authorizer.for_subject(subject)
      |> Repo.list(UserIdentity.Query, opts)
    end
  end

  defp synced_user_query(provider, nil, _subject) do
    {:ok, UserIdentity.Query.not_deleted() |> UserIdentity.Query.by_provider_id(provider.id)}
  end

  defp synced_user_query(provider, group_id, subject) do
    with {:ok, group} <- fetch_directory_group_facts(group_id, subject, provider_id: provider.id) do
      {:ok,
       UserIdentity.Query.not_deleted()
       |> UserIdentity.Query.by_provider_id(provider.id)
       |> UserIdentity.Query.by_directory_group(group.id, provider.account_id, provider.id)}
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
        DirectoryGroup.Query.not_deleted()
        |> DirectoryGroup.Query.count_by_provider()
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

  @doc "Whether identities have fixed this connection's issuer, client ID, and identifier claim."
  def provider_identity_namespace_locked?(%IdentityProvider{id: id}, %Subject{} = subject) do
    with {:ok, provider} <- fetch_provider_by_id(id, subject) do
      locked? =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_id(provider.id)
        |> Authorizer.for_subject(subject)
        |> Repo.exists?()

      {:ok, locked?}
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
  it's the inline edit form (only role is cast). The owner-exclusion +
  required-field validations match the server write path.
  """
  def change_group_mapping(provider_or_mapping, attrs \\ %{})

  def change_group_mapping(%IdentityProvider{} = provider, attrs),
    do: GroupRoleMapping.Changeset.form(provider.account_id, provider.id, attrs)

  def change_group_mapping(%GroupRoleMapping{} = mapping, attrs),
    do: GroupRoleMapping.Changeset.update(mapping, attrs)

  @doc "Pure runner and pack defaults from an already loaded connection."
  def group_access_defaults(%IdentityProvider{} = provider), do: GroupAccess.defaults(provider)

  @doc "Pure combined selection values for connection defaults and explicit group additions."
  def group_access_selection(default, additions), do: GroupAccess.selection(default, additions)

  @doc "Pure explicit additions from combined selections; inherited access is never persisted as a group grant."
  def group_access_additions(default, params, presentation, runners),
    do: GroupAccess.additions(default, params, presentation, runners)

  @doc "Whether explicit group additions grant neither runners nor packs."
  def empty_group_access?(additions), do: GroupAccess.empty?(additions)

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
       GroupRunnerAccessMapping.Changeset.form(
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

  # -- SSO connection verification -------------------------------------

  # Every authenticated SSO ceremony (connection verification, MFA enrollment
  # and reset reauthentication, an invitation's SSO step) asks the IdP for a
  # fresh sign-in, and its callback separately requires a recent integer
  # `auth_time`, because oidcc does not enforce that claim. An IdP session left
  # open in the browser therefore never answers one.
  @fresh_sign_in_url_extension [{"prompt", "login"}, {"max_age", "0"}]
  @reauthentication_max_age_seconds 120
  @reauthentication_clock_skew_seconds 30

  @doc "A provider's durable real-sign-in receipt and the acting admin's link state."
  def provider_sign_in_verification_facts(
        %IdentityProvider{id: provider_id},
        %Subject{actor: %Accounts.Membership{}} = subject
      ) do
    with {:ok, provider} <- fetch_provider_by_id(provider_id, subject) do
      identity =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.provider_identifier_active()
        |> UserIdentity.Query.by_provider_id(provider.id)
        |> UserIdentity.Query.by_membership_id(subject.membership_id)
        |> Repo.peek()

      status = provider_sign_in_verification_status(provider)

      {:ok,
       %{
         status: status,
         verified_at: provider.sign_in_verified_at,
         verified_by_current_member?:
           provider.sign_in_verified_by_membership_id == subject.membership_id,
         linked?: not is_nil(identity),
         identity_id: identity && identity.id
       }}
    end
  end

  def provider_sign_in_verification_facts(%IdentityProvider{}, %Subject{}),
    do: {:error, :unauthorized}

  @doc """
  Begin verifying an SSO connection by signing in through it, after the acting
  administrator's fresh local proof (`Auth.confirm_oidc_identity_step_up/3`).
  Fixed `prompt=login` and `max_age=0` ask the IdP for a fresh sign-in, and the
  callback separately requires a recent `auth_time`. Returns `{:ok, begun}`: the
  authorization URL plus the state the boundary keeps in its encrypted session
  for `complete_identity_link/4`, bound to the workspace, the acting Member and
  its session, the provider and its namespace, the local proof, the OIDC state,
  nonce and PKCE verifier, and the start time.
  """
  def begin_identity_link(
        provider_id,
        redirect_uri,
        proof,
        actor_session_token_digest,
        %Subject{actor: %Accounts.Membership{}} = subject
      )
      when is_binary(provider_id) and is_binary(redirect_uri) and is_binary(proof) and
             is_binary(actor_session_token_digest) do
    with {:ok, provider} <- fetch_identity_link_provider(provider_id, subject),
         %Accounts.Membership{} = member <-
           Accounts.peek_active_membership(subject.account.id, subject.membership_id),
         :ok <- Auth.verify_oidc_identity_step_up_proof(proof, provider.id, member),
         {:ok, begun} <-
           OIDC.begin_authorization(provider,
             redirect_uri: redirect_uri,
             url_extension: @fresh_sign_in_url_extension
           ) do
      {:ok,
       Map.merge(begun, %{
         actor_membership_id: member.id,
         actor_session_token_digest: actor_session_token_digest,
         account_id: provider.account_id,
         provider_id: provider.id,
         namespace: callback_namespace(provider),
         local_proof: proof,
         started_at: System.system_time(:second)
       })}
    else
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def begin_identity_link(_provider_id, _redirect_uri, _proof, _digest, %Subject{}),
    do: {:error, :unauthorized}

  @doc """
  Complete an SSO connection verification. The callback must answer the exact
  workspace, acting Member, session and provider the ceremony began with, with a
  fresh IdP sign-in; it binds the identity it proves to that Member, records the
  connection's verified sign-in, and audits both. It creates no Member and no
  session. Returns `{:ok, %{identity: identity, provider: provider}}` or
  `{:error, reason}`.
  """
  def complete_identity_link(
        params,
        stashed,
        actor_session_token_digest,
        %Subject{actor: %Accounts.Membership{}} = subject
      )
      when is_map(params) and is_map(stashed) and is_binary(actor_session_token_digest) do
    with :ok <- ensure_identity_link_stash(stashed, actor_session_token_digest, subject),
         :ok <- ensure_can_configure_sso(subject),
         {:ok, provider} <- fetch_identity_link_provider_from_stash(stashed),
         {:ok, %{identifier: identifier, claims: claims}} <-
           OIDC.verify_callback(provider, params, stashed),
         {:ok, _auth_time} <- fresh_reauthentication_auth_time(claims, stashed),
         {:ok, result} <-
           commit_identity_link(
             provider,
             identifier,
             claims,
             stashed,
             actor_session_token_digest,
             subject
           ) do
      {:ok, result}
    else
      {:error, :reauthentication_invalid} -> {:error, :identity_link_invalid}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :identity_link_invalid}
    end
  end

  def complete_identity_link(_params, _stashed, _digest, %Subject{}),
    do: {:error, :identity_link_invalid}

  defp active_identity?(%UserIdentity{provider_identifier_retired_at: nil}), do: true
  defp active_identity?(_identity), do: false

  defp provider_sign_in_verification_status(
         %IdentityProvider{
           sign_in_verified_at: %DateTime{},
           sign_in_verified_configuration_digest: stored
         } = provider
       )
       when is_binary(stored) do
    if Crypto.secure_compare(stored, provider_sign_in_configuration_digest(provider)),
      do: :verified,
      else: :stale
  end

  defp provider_sign_in_verification_status(%IdentityProvider{}), do: :unverified

  defp provider_sign_in_configuration_digest(%IdentityProvider{} = provider) do
    [
      provider.kind,
      provider.issuer,
      provider.client_id,
      provider.client_secret,
      provider.identifier_claim,
      provider.allowed_email_domain
    ]
    |> :erlang.term_to_binary()
    |> Crypto.hash()
  end

  defp fetch_identity_link_provider(provider_id, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject) do
      fetch_provider_by_id(provider_id, subject)
    end
  end

  defp fetch_identity_link_provider_from_stash(%{
         provider_id: provider_id,
         account_id: account_id
       }) do
    if Repo.valid_uuid?(provider_id) and Repo.valid_uuid?(account_id) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(account_id)
      |> IdentityProvider.Query.by_id(provider_id)
      |> Repo.fetch(IdentityProvider.Query)
    else
      {:error, :not_found}
    end
  end

  defp fetch_identity_link_provider_from_stash(_stash), do: {:error, :not_found}

  defp ensure_identity_link_stash(stashed, actor_session_token_digest, subject) do
    valid? =
      Map.get(stashed, :actor_membership_id) == subject.membership_id and
        Map.get(stashed, :account_id) == subject.account.id and
        Map.get(stashed, :actor_session_token_digest) == actor_session_token_digest and
        is_binary(Map.get(stashed, :provider_id)) and
        is_binary(Map.get(stashed, :local_proof)) and
        is_tuple(Map.get(stashed, :namespace)) and
        is_integer(Map.get(stashed, :started_at))

    if valid?, do: :ok, else: {:error, :identity_link_invalid}
  end

  defp commit_identity_link(provider, identifier, claims, stashed, digest, subject) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(provider.account_id, repo: repo)
    end)
    |> put_sso_entitlement(provider.account_id)
    |> Multi.run(:provider, fn repo, _changes ->
      lock_identity_link_provider(repo, provider, stashed)
    end)
    |> Multi.run(:actor, fn repo, %{account: account, provider: locked_provider} ->
      lock_identity_link_actor(repo, account, locked_provider, stashed, digest, subject)
    end)
    |> Multi.run(:identity, fn repo, %{actor: %{membership: member}, provider: locked_provider} ->
      link_identity_to_actor(repo, locked_provider, member, identifier, claims)
    end)
    |> Multi.insert(:identity_audit, fn %{
                                          actor: %{subject: current_subject, membership: member},
                                          provider: locked_provider
                                        } ->
      Audit.Events.sso_identity_linked(current_subject, member, locked_provider)
    end)
    |> Multi.update(:verified_provider, fn %{
                                             actor: %{subject: current_subject},
                                             provider: locked_provider
                                           } ->
      IdentityProvider.Changeset.verify_sign_in(
        locked_provider,
        current_subject.membership_id,
        provider_sign_in_configuration_digest(locked_provider)
      )
    end)
    |> Multi.insert(:provider_audit, fn %{
                                          actor: %{subject: current_subject},
                                          verified_provider: verified_provider
                                        } ->
      Audit.Events.identity_provider_sign_in_verified(current_subject, verified_provider)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{identity: identity, verified_provider: verified_provider}} ->
        {:ok, %{identity: identity, provider: verified_provider}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Verification may test a connection that is not enabled yet, so only the
  # namespace the ceremony began with must still hold.
  defp lock_identity_link_provider(repo, started_provider, stashed) do
    current =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(started_provider.account_id)
      |> IdentityProvider.Query.by_id(started_provider.id)
      |> IdentityProvider.Query.lock_for_update()
      |> repo.peek()

    case current do
      %IdentityProvider{} = provider ->
        if callback_namespace(provider) == stashed.namespace,
          do: {:ok, provider},
          else: {:error, :identity_namespace_changed}

      nil ->
        {:error, :provider_disabled}
    end
  end

  # The acting Member, locked after the provider, must still configure SSO and
  # still hold the exact session and fresh local proof the ceremony began with.
  defp lock_identity_link_actor(repo, account, provider, stashed, digest, subject) do
    with {:ok, membership} <-
           Accounts.fetch_and_lock_active_membership(
             repo,
             account.id,
             stashed.actor_membership_id
           ),
         current_subject = Subject.rebuild(subject, membership, account),
         :ok <- ensure_can_configure_sso(current_subject),
         :ok <-
           Auth.ensure_oidc_identity_step_up_current(
             repo,
             stashed.local_proof,
             digest,
             provider.id,
             membership
           ) do
      {:ok, %{membership: membership, subject: current_subject}}
    end
  end

  defp link_identity_to_actor(repo, provider, member, identifier, claims) do
    identifier_identity =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_and_identifier(provider.id, identifier)
      |> UserIdentity.Query.lock_for_update()
      |> repo.peek()

    # A Member holds at most one live identity per connection.
    member_identity =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> UserIdentity.Query.by_membership_id(member.id)
      |> UserIdentity.Query.lock_for_update()
      |> repo.peek()

    with :ok <- ensure_identity_link_target(identifier_identity, member_identity),
         :ok <- ensure_email_domain_allowed(provider, claims) do
      persist_self_verified_identity(repo, provider, member, member_identity, identifier, claims)
    end
  end

  defp ensure_identity_link_target(%UserIdentity{id: id}, %UserIdentity{id: id}), do: :ok

  defp ensure_identity_link_target(%UserIdentity{}, _current),
    do: {:error, :identity_already_linked}

  defp ensure_identity_link_target(nil, %UserIdentity{} = current) do
    if active_identity?(current), do: {:error, :different_identity_already_linked}, else: :ok
  end

  defp ensure_identity_link_target(nil, nil), do: :ok

  defp persist_self_verified_identity(repo, provider, member, nil, identifier, claims) do
    UserIdentity.Changeset.create(provider.account_id, provider.id, member, %{
      provider_identifier: identifier,
      claims: claims,
      created_by: :user,
      provisioned_via: :oidc_link
    })
    |> repo.insert()
  end

  defp persist_self_verified_identity(repo, _provider, member, identity, identifier, claims) do
    identity
    |> UserIdentity.Changeset.verify_by_user(identifier, claims)
    |> UserIdentity.Changeset.bind_membership(member)
    |> repo.update()
  end

  # Members of this connection left with no usable identity once it is disabled
  # or deleted. This runs after the provider write in the same transaction, so
  # the connection itself no longer counts as usable.
  defp revoke_stranded_member_credentials(repo, %IdentityProvider{} = provider, subject) do
    bound =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_account_id(provider.account_id)
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> UserIdentity.Query.select_membership_ids()
      |> repo.all()

    usable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.provider_identifier_active()
      |> UserIdentity.Query.by_account_id(provider.account_id)
      |> UserIdentity.Query.by_membership_ids(bound)
      |> UserIdentity.Query.with_enabled_provider()
      |> UserIdentity.Query.select_membership_ids()
      |> repo.all()

    Accounts.revoke_stranded_member_credentials(
      repo,
      provider,
      Enum.uniq(bound) -- usable,
      subject
    )
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
         # member. Checked here, before the insert, so the escalation answer wins
         # over the changeset's own narrower :owner exclusion.
         :ok <- ensure_grantable_role(default_role, subject),
         {:ok, access} <- provider_access_from_changeset(changeset),
         :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access) do
      multi = configure_multi(changeset, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{provider: provider}} -> {:ok, provider}
        {:error, reason} -> {:error, reason}
      end
    end
    # Scrub the typed client secret out of any rejected changeset — from the
    # commit here OR the earlier `provider_access_from_changeset` short-circuit —
    # matching update_provider: the LiveView re-renders it into the form and a
    # password input echoes `value=`, so the raw IdP secret would otherwise land
    # in the DOM and the socket assigns.
    |> hide_result_secret()
  end

  defp hide_result_secret({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, hide_secrets(changeset)}

  defp hide_result_secret(result), do: result

  @doc "Update a connection's config (locked re-read). `manage_sso` + Team or Enterprise. `{:ok, provider} | {:error, reason}`."
  def update_provider(%IdentityProvider{id: id}, attrs, %Subject{} = subject) do
    cleanup_only? = provider_disable_only?(attrs)

    with :ok <- ensure_can_update_provider(subject, cleanup_only?),
         {:ok, scoped_provider} <- fetch_provider_by_id(id, subject) do
      Multi.new()
      # Disabling a connection consults the account's require_sso invariant.
      # Take the shared account fence before the provider row, matching every
      # OIDC/SCIM path that may need both locks.
      |> put_active_account_lock(scoped_provider.account_id)
      |> maybe_put_sso_entitlement(scoped_provider.account_id, cleanup_only?)
      |> Multi.run(:update_target, fn repo, _changes ->
        queryable =
          IdentityProvider.Query.not_deleted()
          |> IdentityProvider.Query.by_id(id)
          |> IdentityProvider.Query.lock_for_update()
          |> Authorizer.for_subject(subject)

        with {:ok, loaded_provider} <- repo.fetch(queryable, IdentityProvider.Query),
             %Ecto.Changeset{} = changeset <-
               provider_update_changeset(loaded_provider, attrs, subject) do
          {:ok, %{provider: loaded_provider, changeset: changeset}}
        else
          {:error, reason} -> {:error, reason}
          reason -> {:error, reason}
        end
      end)
      |> Multi.update(:provider, fn %{update_target: %{changeset: changeset}} -> changeset end)
      |> Multi.run(:session_effect, fn repo,
                                       %{
                                         provider: provider,
                                         update_target: %{changeset: changeset}
                                       } ->
        if Ecto.Changeset.get_change(changeset, :enabled) == false or
             Ecto.Changeset.get_change(changeset, :satisfies_mfa) == false do
          delete_provider_sessions(provider, repo)
        else
          {:ok, %{socket_topics: []}}
        end
      end)
      |> Multi.run(:stranded_credentials, fn repo,
                                             %{
                                               provider: provider,
                                               update_target: %{changeset: changeset}
                                             } ->
        if Ecto.Changeset.get_change(changeset, :enabled) == false,
          do: revoke_stranded_member_credentials(repo, provider, subject),
          else: {:ok, []}
      end)
      |> Multi.insert(:audit, fn %{
                                   update_target: %{provider: before},
                                   provider: updated
                                 } ->
        Audit.Events.identity_provider_updated(subject, before, updated)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{
                           provider: provider,
                           update_target: %{changeset: changeset},
                           session_effect: %{socket_topics: topics}
                         } ->
          Auth.disconnect_live_socket_topics(topics)
          _ = recompute_authorization_if_changed(provider, changeset)
          :ok
        end
      )
      |> case do
        {:ok, %{provider: provider}} -> {:ok, provider}
        {:error, %Ecto.Changeset{} = invalid} -> {:error, hide_secrets(invalid)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp provider_update_changeset(loaded_provider, attrs, subject) do
    # Judged from the PERSISTED kind, under the row lock — an edit never
    # chooses the kind, so a submitted one is not evidence of anything.
    attrs = edit_provider_attrs(loaded_provider, attrs)
    supplied_secret? = client_secret_supplied?(attrs)

    # The locked row is what the selection is resolved against: its account
    # owns the runners, so a cross-account id never gets here.
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

        enabling_unverified_provider?(loaded_provider, changeset) ->
          :sign_in_verification_required

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
  end

  @doc "Soft-delete a connection. `manage_sso` + Team or Enterprise. `{:ok, provider} | {:error, reason}`."
  def delete_provider(%IdentityProvider{id: id}, %Subject{} = subject) do
    with :ok <- ensure_can_manage_sso(subject),
         {:ok, scoped_provider} <- fetch_provider_by_id(id, subject) do
      Multi.new()
      # Provider removal can consult the account's require_sso invariant, while
      # OIDC/link capture already uses account -> provider. Take that same order
      # here so a collision fallback can never deadlock the revoker.
      |> put_active_account_lock(scoped_provider.account_id)
      |> Multi.run(:delete_target, fn repo, _changes ->
        queryable =
          IdentityProvider.Query.not_deleted()
          |> IdentityProvider.Query.by_id(id)
          |> IdentityProvider.Query.lock_for_update()
          |> Authorizer.for_subject(subject)

        with {:ok, loaded_provider} <- repo.fetch(queryable, IdentityProvider.Query),
             false <- removing_last_required_provider?(loaded_provider) do
          {:ok, loaded_provider}
        else
          true -> {:error, :require_sso_last_provider}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.update(:provider, fn %{delete_target: loaded_provider} ->
        loaded_provider
        |> IdentityProvider.Changeset.delete()
        |> then(&prepare_provider_authorization_change(loaded_provider, &1, true))
      end)
      |> Multi.run(:session_effect, fn repo, %{provider: provider} ->
        delete_provider_sessions(provider, repo)
      end)
      |> Multi.run(:stranded_credentials, fn repo, %{provider: provider} ->
        revoke_stranded_member_credentials(repo, provider, subject)
      end)
      |> Multi.insert(:audit, fn %{provider: provider} ->
        Audit.Events.identity_provider_deleted(subject, provider)
      end)
      # Both repairs commit WITH the tombstone. Post-commit they could not be
      # re-driven — `fetch_provider_by_id/2` starts at `not_deleted()`, so a
      # second "Delete connection" answers `:not_found` — and a failure there
      # froze every synced member's role behind `directory_managed: true`
      # pointing at a provider nobody can name again. (The sibling
      # `disable_scim/2` keeps its repair post-commit precisely because its row
      # stays fetchable, so a retry repeats it.) Session tokens also disappear
      # atomically; only socket disconnects wait for the commit.
      |> Multi.run(:role_control, fn _repo, %{provider: provider} ->
        {:ok, return_role_control_to_operators(provider)}
      end)
      |> Multi.run(:dismissed_requests, fn _repo, %{provider: provider} ->
        {:ok, delete_pending_link_requests(provider)}
      end)
      |> Repo.commit_multi(
        after_commit: fn %{
                           session_effect: %{socket_topics: topics},
                           dismissed_requests: dismissed
                         } ->
          Auth.disconnect_live_socket_topics(topics)
          Enum.each(dismissed, &broadcast_link_request_dismissed/1)
        end
      )
      |> case do
        {:ok, %{provider: provider}} -> {:ok, provider}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Probe an operator-supplied issuer's OIDC discovery document — the "Check
  issuer" button, proving the issuer is reachable and serves a valid
  discovery doc *before* a connection is saved. `manage_sso` + Team or Enterprise;
  writes no row. The issuer is attacker-influenceable, so it's SSRF-validated
  (https + not a private/loopback/metadata host) before the fetch. Returns
  `{:ok, %{authorization_endpoint, token_endpoint, userinfo_endpoint, jwks_uri}}`
  or `{:error, :unauthorized | :sso_not_available | :invalid_issuer |
  :blocked_issuer | :rate_limited | term()}` (a discovery failure carries
  oidcc's reason).
  """
  def test_provider(issuer, %Subject{} = subject) do
    with :ok <- ensure_can_configure_sso(subject),
         {:ok, issuer} <- IssuerUrl.validate(issuer) do
      OIDC.discover(%IdentityProvider{issuer: issuer, account_id: subject.account.id})
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
  # a team role change gets: you may only grant what you already hold. Derived
  # from permissions via `covers_role?/2`, never a role-name list — the rule then
  # tracks a grant moving between roles on its own (admins gaining
  # `manage_billing` opened `:billing_manager` here with no edit).
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
    # Creation is always the save step, never activation. Even a crafted form
    # cannot put an unverified provider on the member sign-in surface.
    attrs = attrs |> drop_blank_secret() |> put_attr(:enabled, false)

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

  defp enabling_unverified_provider?(provider, changeset) do
    enabling? = not provider.enabled and Ecto.Changeset.get_change(changeset, :enabled) == true

    enabling? and
      changeset
      |> Ecto.Changeset.apply_changes()
      |> provider_sign_in_verification_status()
      |> Kernel.!=(:verified)
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

  # Preset issuer choices must not carry over to another kind's new connection.
  defp put_kind_issuer(attrs, %{kind: :jumpcloud}) do
    # Region selection owns this value. Clear another kind's fixed prefill, but
    # let the changeset reject any other unsupported issuer instead of hiding it.
    case fetch_attr(attrs, :issuer) do
      {:ok, "https://accounts.google.com"} -> put_attr(attrs, :issuer, "")
      _ -> attrs
    end
  end

  defp put_kind_issuer(attrs, %{fixed_issuer: nil}) do
    prefilled? =
      case fetch_attr(attrs, :issuer) do
        {:ok, issuer} -> issuer in ProviderKind.preset_issuers()
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

    account_requires_sso?(provider.account_id) and
      Billing.sso_available_for_account_id?(provider.account_id) and
      not another_enabled_provider?(provider)
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
    |> put_active_account_lock(subject.account.id)
    |> put_sso_entitlement(subject.account.id)
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
      %{
        groups: mapping.runner_scope_groups,
        runner_ids: mapping.runner_scope_runner_ids,
        pack_ids: mapping.pack_scope_pack_ids
      }
    )
  end

  # The picker's raw `"group:<name>"` / `"runner:<id>"` and `"pack:<id>"` values
  # are the only accepted way to name reach: a submitted persisted array is
  # dropped here, and the selection is resolved against `account_id`'s live
  # runners and known packs, so a crafted submission can never widen reach past
  # what the account offers.
  defp put_runner_selection(attrs, account_id, fields, stored) do
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
      membership_ids = provider |> provider_identities() |> Enum.map(& &1.membership_id)

      {:ok, _version} =
        Accounts.mark_directory_authorization_pending(
          Repo,
          provider.account_id,
          provider.id,
          membership_ids,
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
  # Session rows carry the identity that authenticated them, so removal is exact:
  # unrelated magic-link and other-provider credentials and sockets survive.
  # API keys end only for a Member without a verified address that is left with
  # no usable identity (`revoke_stranded_member_credentials/3`); a verified
  # address still signs in, so it still backs the keys of a Member that has one.
  # A pending request is a person waiting on an admin. Once the connection they
  # arrived through is gone, approval is impossible — `approve_link_request` can
  # no longer fetch the provider — so leaving them queued showed admins a
  # decision they could not make and left the waiting browsers on a page that
  # would never resolve. The caller broadcasts the returned rows once its
  # transaction commits, so every waiting browser is still told.
  #
  # RETURNING, not read-then-delete: a request created between the two statements
  # was deleted WITHOUT a broadcast, leaving exactly the waiting browser on a
  # never-resolving page this exists to prevent.
  defp delete_pending_link_requests(%IdentityProvider{} = provider) do
    queryable =
      LinkRequest.Query.all()
      |> LinkRequest.Query.by_provider_id(provider.id)
      |> LinkRequest.Query.select_all()

    {_count, dismissed} = Repo.delete_all(queryable)
    dismissed
  end

  defp delete_provider_sessions(%IdentityProvider{} = provider, repo) do
    # Retired identities can still carry valid cookies. Revoke every identity
    # the provider vouched for, not just the currently visible ones.
    ids =
      UserIdentity.Query.all()
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> repo.all()
      |> Enum.map(& &1.id)

    Auth.delete_identity_sessions(ids, repo)
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
        Accounts.clear_directory_managed_for_memberships(
          membership.account_id,
          membership.directory_provider_id,
          [membership.id]
        )

        :ok
    end
  end

  @doc "Internal — a fail-closed membership transition's current directory version, without reversing the provider/membership lock order."
  def directory_authorization_version(account_id, provider_id, repo)
      when is_binary(provider_id) do
    # A tombstoned provider still identifies the pending handoff; the retry
    # worker will release its directory ownership without restoring access.
    provider =
      IdentityProvider.Query.all()
      |> IdentityProvider.Query.by_account_id(account_id)
      |> IdentityProvider.Query.by_id(provider_id)
      |> repo.peek()

    case provider do
      %IdentityProvider{authorization_version: version} -> version
      nil -> 0
    end
  end

  def directory_authorization_version(_account_id, _provider_id, _repo), do: 0

  defp reconcile_pending_from_provider(provider, membership) do
    case peek_member_identity(provider, membership.id) do
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
        Accounts.clear_directory_managed_for_memberships(
          membership.account_id,
          membership.directory_provider_id,
          [membership.id]
        )

        :ok
    end
  end

  # -- Sign-in discovery (pre-Subject) ---------------------------------

  @doc "Internal — sign-in: an account's enabled SSO providers, name-ordered, for the per-account sign-in page (pre-Subject)."
  def list_enabled_providers_for_account(account_id) when is_binary(account_id) do
    if Billing.sso_available_for_account_id?(account_id) do
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.enabled()
      |> IdentityProvider.Query.by_account_id(account_id)
      |> IdentityProvider.Query.ordered_by_name()
      |> Repo.all()
    else
      []
    end
  end

  @doc "Internal — sign-in: an enabled provider by id, for the begin-auth redirect (pre-Subject)."
  def fetch_provider_for_sign_in(id) do
    if Repo.valid_uuid?(id) do
      provider_query =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.enabled()
        |> IdentityProvider.Query.with_active_account()
        |> IdentityProvider.Query.by_id(id)

      with {:ok, provider} <- Repo.fetch(provider_query, IdentityProvider.Query),
           true <- Billing.sso_available_for_account_id?(provider.account_id) do
        {:ok, provider}
      else
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # -- Authenticated SSO reauthentication ------------------------------
  # Ceremonies a signed-in Member runs at its own workspace's IdP. None of them
  # enters the JIT, link or sign-in flow, provisions, or mints a session.

  # An enrollment proof's IdP sign-in may be this old when the authenticator is
  # finally confirmed; the proof itself lives shorter.
  @mfa_enrollment_completion_max_age_seconds 10 * 60

  @doc """
  Presentation facts for the acting browser's usable SSO reset step-up. Only
  the exact active identity behind this session qualifies, and its current
  provider must still be enabled and marked as satisfying MFA.
  """
  def fetch_member_mfa_reset_reauthentication_facts(%Subject{} = subject) do
    with {:ok, {_identity, provider}} <- fetch_member_mfa_reset_identity(subject) do
      {:ok, %{provider_name: provider.name}}
    end
  end

  @doc """
  Begin a dedicated, authenticated SSO reauthentication for an administrator
  MFA reset. This never enters the JIT/link/sign-in flow. Fixed `prompt=login`
  and `max_age=0` request a fresh IdP ceremony; completion separately requires a
  recent integer `auth_time` because oidcc does not enforce that claim.
  """
  def begin_member_mfa_reset_reauthentication(
        redirect_uri,
        actor_session_token_digest,
        %Subject{} = subject
      )
      when is_binary(redirect_uri) and is_binary(actor_session_token_digest) do
    with {:ok, {identity, provider}} <- fetch_member_mfa_reset_identity(subject),
         {:ok, begun} <-
           OIDC.begin_authorization(provider,
             redirect_uri: redirect_uri,
             url_extension: @fresh_sign_in_url_extension
           ) do
      {:ok,
       Map.merge(begun, %{
         account_id: subject.account.id,
         actor_membership_id: subject.membership_id,
         actor_session_token_digest: actor_session_token_digest,
         identity_id: identity.id,
         provider_identifier: identity.provider_identifier,
         provider_id: provider.id,
         namespace: callback_namespace(provider),
         started_at: System.system_time(:second)
       })}
    end
  end

  @doc """
  Complete the dedicated reset reauthentication. The callback may only prove
  the exact active identity already carried by the authenticated session; it
  never provisions, links, touches last-seen state, or mints a login session.
  The boundary's stash names the target Member and its exact enrollment epoch
  and row version (`:target_membership_id`, `:target_mfa_enabled_at`,
  `:target_updated_at`), which the returned reauthentication carries into
  `Accounts.issue_member_mfa_reset_sso_proof/4`.
  """
  def complete_member_mfa_reset_reauthentication(
        params,
        stashed,
        actor_session_token_digest,
        %Subject{} = subject
      )
      when is_map(params) and is_map(stashed) and is_binary(actor_session_token_digest) do
    with :ok <-
           ensure_member_mfa_reset_stash(stashed, actor_session_token_digest, subject),
         {:ok, {identity, provider}} <- fetch_member_mfa_reset_identity(subject),
         :ok <- ensure_reauthentication_started_identity(stashed, identity, provider),
         {:ok, %{identifier: identifier, claims: claims}} <-
           OIDC.verify_callback(provider, params, stashed),
         true <- identifier == identity.provider_identifier,
         {:ok, auth_time} <- fresh_reauthentication_auth_time(claims, stashed),
         reauthentication = %{
           provider_id: provider.id,
           identity_id: identity.id,
           provider_identifier: identity.provider_identifier,
           namespace: callback_namespace(provider),
           auth_time: auth_time,
           target_membership_id: Map.get(stashed, :target_membership_id),
           target_mfa_enabled_at: Map.get(stashed, :target_mfa_enabled_at),
           target_updated_at: Map.get(stashed, :target_updated_at)
         },
         {:ok, current} <-
           lock_member_mfa_reset_reauthentication(reauthentication, subject) do
      {:ok, current}
    else
      _other -> {:error, :mfa_reset_reauthentication_invalid}
    end
  end

  def complete_member_mfa_reset_reauthentication(_params, _stashed, _token_digest, %Subject{}),
    do: {:error, :mfa_reset_reauthentication_invalid}

  @doc """
  Internal — Accounts calls this inside the final reset transaction. Lock and
  recheck the exact provider and identity so a disable, MFA-trust downgrade,
  namespace edit, rebind, or retirement that lands after the callback wins and
  invalidates the handoff before the target credential changes.
  """
  def ensure_member_mfa_reset_reauthentication_current(
        repo,
        %{auth_time: auth_time} = reauthentication,
        membership_id,
        account_id
      )
      when is_integer(auth_time) do
    with :ok <- ensure_auth_time_within(auth_time, @reauthentication_max_age_seconds),
         {:ok, %IdentityProvider{satisfies_mfa: true}} <-
           lock_reauthentication_route(repo, reauthentication, membership_id, account_id) do
      {:ok, reauthentication}
    else
      _other -> {:error, :mfa_reset_proof_stale}
    end
  end

  def ensure_member_mfa_reset_reauthentication_current(
        _repo,
        _reauthentication,
        _membership_id,
        _account_id
      ),
      do: {:error, :mfa_reset_proof_stale}

  @doc """
  Begin the SSO reauthentication a Member gives before adding an authenticator:
  the fresh proof of its own credential a Member without a verified address
  gives instead of an emailed code (`Auth.issue_mfa_enrollment_proof_for_sso/3`).
  Self-service, gated by the Member's live session alone, so a Member a
  workspace's MFA requirement sends to enrollment can reach it. Only the exact
  identity behind this SSO session qualifies, on an enabled connection of a
  workspace whose plan includes SSO, only while the Member has no
  authenticator, and only from the session whose digest is `session_digest`.
  Unlike the reset reauthentication, the connection need not satisfy MFA. Fixed
  `prompt=login` and `max_age=0` ask for a fresh IdP sign-in.

  Returns `{:ok, begun}`: the authorization URL plus the state the boundary
  keeps in its encrypted session for `complete_mfa_enrollment_reauthentication/4`,
  bound to the workspace, the Member, the session digest, the identity, the
  provider and its namespace, the OIDC state, nonce and PKCE verifier, and the
  start time. Otherwise `{:error, :mfa_enrollment_reauthentication_unavailable}`.
  """
  def begin_mfa_enrollment_reauthentication(
        redirect_uri,
        session_digest,
        %Subject{actor: %Accounts.Membership{}, account: %Accounts.Account{}} = subject
      )
      when is_binary(redirect_uri) and is_binary(session_digest) do
    with {:ok, {identity, provider}} <- fetch_mfa_enrollment_identity(session_digest, subject),
         {:ok, begun} <-
           OIDC.begin_authorization(provider,
             redirect_uri: redirect_uri,
             url_extension: @fresh_sign_in_url_extension
           ) do
      {:ok,
       Map.merge(begun, %{
         purpose: :mfa_enrollment,
         account_id: subject.account.id,
         membership_id: subject.membership_id,
         session_digest: session_digest,
         identity_id: identity.id,
         provider_identifier: identity.provider_identifier,
         provider_id: provider.id,
         namespace: callback_namespace(provider),
         started_at: System.system_time(:second)
       })}
    end
  end

  def begin_mfa_enrollment_reauthentication(_redirect_uri, _session_digest, %Subject{}),
    do: {:error, :mfa_enrollment_reauthentication_unavailable}

  @doc """
  Complete the MFA-enrollment reauthentication. The callback may only prove the
  exact identity behind the session the ceremony began from, with an IdP
  sign-in made after it began; it never provisions, links, or mints a session.
  Returns `{:ok, reauthentication}` — the provider, the identity and its
  subject, the namespace (issuer, client and identifier claim), the IdP
  `auth_time` and the session digest, for
  `Auth.issue_mfa_enrollment_proof_for_sso/3` — or
  `{:error, :mfa_enrollment_reauthentication_invalid}`.
  """
  def complete_mfa_enrollment_reauthentication(
        params,
        stashed,
        session_digest,
        %Subject{actor: %Accounts.Membership{}, account: %Accounts.Account{}} = subject
      )
      when is_map(params) and is_map(stashed) and is_binary(session_digest) do
    with :ok <- ensure_mfa_enrollment_stash(stashed, session_digest, subject),
         {:ok, {identity, provider}} <- fetch_mfa_enrollment_identity(session_digest, subject),
         :ok <- ensure_reauthentication_started_identity(stashed, identity, provider),
         {:ok, %{identifier: identifier, claims: claims}} <-
           OIDC.verify_callback(provider, params, stashed),
         true <- identifier == identity.provider_identifier,
         {:ok, auth_time} <- fresh_reauthentication_auth_time(claims, stashed) do
      {:ok,
       %{
         provider_id: provider.id,
         identity_id: identity.id,
         provider_identifier: identity.provider_identifier,
         namespace: callback_namespace(provider),
         auth_time: auth_time,
         session_digest: session_digest
       }}
    else
      _other -> {:error, :mfa_enrollment_reauthentication_invalid}
    end
  end

  def complete_mfa_enrollment_reauthentication(_params, _stashed, _digest, %Subject{}),
    do: {:error, :mfa_enrollment_reauthentication_invalid}

  @doc """
  Internal — `Auth.enable_mfa/5` calls this inside the enrollment transaction,
  after the workspace lock and before the Member's. Locks and rechecks the SSO
  entitlement, the provider (still enabled, still the namespace the ceremony
  verified) and the identity (still this Member's, same subject, unretired),
  and that the IdP sign-in is no older than ten minutes, so a disable,
  namespace edit, rebind or retirement that lands after the callback wins
  before the factor is written. Returns `{:ok, reauthentication}` or
  `{:error, :mfa_enrollment_proof_stale}`.
  """
  def ensure_mfa_enrollment_reauthentication_current(
        repo,
        %{auth_time: auth_time} = reauthentication,
        membership_id,
        account_id
      )
      when is_integer(auth_time) do
    with :ok <- ensure_auth_time_within(auth_time, @mfa_enrollment_completion_max_age_seconds),
         {:ok, %IdentityProvider{}} <-
           lock_reauthentication_route(repo, reauthentication, membership_id, account_id) do
      {:ok, reauthentication}
    else
      _other -> {:error, :mfa_enrollment_proof_stale}
    end
  end

  def ensure_mfa_enrollment_reauthentication_current(
        _repo,
        _reauthentication,
        _membership_id,
        _account_id
      ),
      do: {:error, :mfa_enrollment_proof_stale}

  # The acting administrator's exact SSO route.
  defp fetch_member_mfa_reset_identity(
         %Subject{
           actor: %Accounts.Membership{},
           account: %Accounts.Account{id: account_id},
           auth_method: :sso,
           user_identity_id: identity_id
         } = subject
       )
       when is_binary(identity_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_sso_posture_permission()
           ),
         %UserIdentity{provider: %IdentityProvider{} = provider} = identity <-
           peek_member_mfa_reset_identity(identity_id, account_id, subject),
         true <- provider.enabled and provider.satisfies_mfa,
         true <- Billing.sso_available?(subject.account) do
      {:ok, {identity, provider}}
    else
      _other -> {:error, :mfa_reset_reauthentication_unavailable}
    end
  end

  defp fetch_member_mfa_reset_identity(%Subject{}),
    do: {:error, :mfa_reset_reauthentication_unavailable}

  defp peek_member_mfa_reset_identity(identity_id, account_id, subject) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.provider_identifier_active()
    |> UserIdentity.Query.by_id(identity_id)
    |> UserIdentity.Query.by_membership_id(subject.membership_id)
    |> UserIdentity.Query.by_account_id(account_id)
    |> UserIdentity.Query.with_preloaded_provider()
    |> Authorizer.for_subject(subject)
    |> Repo.peek()
  end

  # The live session, re-read through the per-request predicate, must be this
  # exact one and an SSO session of a Member with no authenticator yet; the
  # predicate already holds its identity live and unretired and its provider
  # enabled at the frozen issuer. No permission check: a Member a workspace's
  # MFA requirement holds back still enrolls.
  defp fetch_mfa_enrollment_identity(session_digest, %Subject{} = subject) do
    with {:ok,
          %{
            auth_method: :sso,
            token: digest,
            membership: %Accounts.Membership{mfa_enabled_at: nil},
            user_identity:
              %UserIdentity{provider: %IdentityProvider{enabled: true} = provider} = identity
          }} <- Auth.fetch_current_session(subject),
         true <- Crypto.secure_compare(digest, session_digest),
         true <- Billing.sso_available?(subject.account) do
      {:ok, {identity, provider}}
    else
      _other -> {:error, :mfa_enrollment_reauthentication_unavailable}
    end
  end

  defp ensure_member_mfa_reset_stash(stashed, actor_session_token_digest, subject) do
    if Map.get(stashed, :account_id) == subject.account.id and
         Map.get(stashed, :actor_membership_id) == subject.membership_id and
         Map.get(stashed, :actor_session_token_digest) == actor_session_token_digest and
         is_integer(Map.get(stashed, :started_at)) and
         is_binary(Map.get(stashed, :target_membership_id)) and
         is_struct(Map.get(stashed, :target_mfa_enabled_at), DateTime) and
         is_struct(Map.get(stashed, :target_updated_at), DateTime),
       do: :ok,
       else: {:error, :mfa_reset_reauthentication_invalid}
  end

  defp ensure_mfa_enrollment_stash(stashed, session_digest, subject) do
    stashed_digest = Map.get(stashed, :session_digest)

    if Map.get(stashed, :purpose) == :mfa_enrollment and
         Map.get(stashed, :account_id) == subject.account.id and
         Map.get(stashed, :membership_id) == subject.membership_id and
         is_binary(stashed_digest) and Crypto.secure_compare(stashed_digest, session_digest) and
         is_integer(Map.get(stashed, :started_at)),
       do: :ok,
       else: {:error, :mfa_enrollment_reauthentication_invalid}
  end

  defp ensure_reauthentication_started_identity(stashed, identity, provider) do
    if Map.get(stashed, :identity_id) == identity.id and
         Map.get(stashed, :provider_id) == provider.id and
         Map.get(stashed, :provider_identifier) == identity.provider_identifier and
         Map.get(stashed, :namespace) == callback_namespace(provider),
       do: :ok,
       else: {:error, :reauthentication_invalid}
  end

  # The IdP sign-in the callback reports happened after the ceremony began and
  # within the last two minutes.
  defp fresh_reauthentication_auth_time(%{"auth_time" => auth_time}, %{started_at: started_at})
       when is_integer(auth_time) and is_integer(started_at) do
    with true <- auth_time >= started_at - @reauthentication_clock_skew_seconds,
         :ok <- ensure_auth_time_within(auth_time, @reauthentication_max_age_seconds) do
      {:ok, auth_time}
    else
      _stale -> {:error, :reauthentication_invalid}
    end
  end

  defp fresh_reauthentication_auth_time(_claims, _stashed),
    do: {:error, :reauthentication_invalid}

  defp ensure_auth_time_within(auth_time, max_age_seconds) when is_integer(auth_time) do
    now = System.system_time(:second)
    skew = @reauthentication_clock_skew_seconds

    if auth_time >= now - max_age_seconds - skew and auth_time <= now + skew,
      do: :ok,
      else: {:error, :reauthentication_invalid}
  end

  # The exact route a reauthentication proved, locked in sign-in's order:
  # entitlement, provider, identity. The provider must still be enabled at the
  # namespace the callback verified, and the identity still this Member's with
  # the same unretired subject. Returns the locked provider.
  defp lock_reauthentication_route(
         repo,
         %{
           provider_id: provider_id,
           identity_id: identity_id,
           provider_identifier: provider_identifier,
           namespace: namespace
         },
         membership_id,
         account_id
       )
       when is_binary(provider_id) and is_binary(identity_id) and
              is_binary(provider_identifier) and is_tuple(namespace) and
              is_binary(membership_id) and is_binary(account_id) do
    provider_query =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(account_id)
      |> IdentityProvider.Query.by_id(provider_id)
      |> IdentityProvider.Query.lock_for_update()

    identity_query =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.provider_identifier_active()
      |> UserIdentity.Query.by_id(identity_id)
      |> UserIdentity.Query.by_membership_id(membership_id)
      |> UserIdentity.Query.by_account_id(account_id)
      |> UserIdentity.Query.by_provider_id(provider_id)
      |> UserIdentity.Query.by_provider_identifier(provider_identifier)
      |> UserIdentity.Query.lock_for_update()

    with true <- Billing.sso_available_for_account_id?(account_id, repo: repo, lock?: true),
         %IdentityProvider{enabled: true} = provider <- repo.peek(provider_query),
         true <- callback_namespace(provider) == namespace,
         %UserIdentity{} <- repo.peek(identity_query) do
      {:ok, provider}
    else
      _other -> {:error, :reauthentication_invalid}
    end
  end

  defp lock_reauthentication_route(_repo, _reauthentication, _membership_id, _account_id),
    do: {:error, :reauthentication_invalid}

  defp lock_member_mfa_reset_reauthentication(reauthentication, subject) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(subject.account.id, repo: repo)
    end)
    |> Multi.run(:reauthentication, fn repo, _changes ->
      ensure_member_mfa_reset_reauthentication_current(
        repo,
        reauthentication,
        subject.membership_id,
        subject.account.id
      )
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{reauthentication: current}} -> {:ok, current}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Login flow (pre-Subject — it IS the authentication) -------------

  @doc """
  Build the IdP authorization redirect for an enabled provider. The public
  boundary — the web layer never calls the internal `OIDC` wrapper directly.
  Returns `{:ok, %{authorize_url, state, nonce, pkce_verifier}}`; the web layer
  stashes the secrets in its encrypted browser session for `complete_auth/4`.
  The callback response clears them; the shared provider-work budget bounds
  replay of a copied pre-response cookie.
  """
  def begin_auth(%IdentityProvider{} = provider, opts),
    do: OIDC.begin_authorization(provider, opts)

  @doc """
  Validate the OIDC callback (state/nonce/PKCE + ID-token signature/iss/aud/exp
  + RFC 9207 issuer check), then resolve the identity strictly by
  `(provider, identifier_claim)` — the `sub` for every provider except Entra, which
  uses `oid` — and never by email. An unknown `sub` is captured as a pending link
  request, returning `{:pending, request}` for the web layer's pending-approval
  page, when the provider's `provisioner` is `:manual`, when directory sync is on,
  or when its verified email names a live Member of this account. Otherwise
  `:jit` creates a new Member; an address a Member took since the match is
  refused with `{:error, :member_email_taken}`. Returns
  `{:ok, %{membership, identity, provider}}` — the one Member this identity
  signs in, for `Auth.complete_sso_sign_in/5`; the workspace is the provider's.
  A validated identity its workspace refuses (seat suspended or removed, email
  domain no longer allowed, connection changed or disabled) writes
  `user.sign_in_failed` for that Member, with `context`.
  """
  def complete_auth(%IdentityProvider{} = provider, params, stashed, %RequestContext{} = context) do
    with {:ok, %{identifier: identifier, claims: claims}} <-
           OIDC.verify_callback(provider, params, stashed) do
      provider
      |> commit_verified_auth(callback_namespace(provider), identifier, claims, 0)
      |> record_refused_sign_in(provider, identifier, context)
    end
  end

  # As a wrong emailed code does, a refused SSO sign-in leaves a row in the
  # workspace's trail, so an admin sees an offboarded person still trying the
  # door. The transaction that refused it rolled back, so the row is its own
  # insert; an identity no Member holds names nobody and is only logged.
  @attributable_refusals [
    :membership_unavailable,
    :email_domain_not_allowed,
    :identity_namespace_changed,
    :provider_disabled
  ]

  defp record_refused_sign_in({:error, reason} = refused, provider, identifier, context)
       when reason in @attributable_refusals do
    with %UserIdentity{membership: %Accounts.Membership{} = member} <-
           peek_identity_member(provider, identifier),
         {:error, _not_recorded} <-
           Audit.record(
             Audit.Events.member_security_event(member, "user.sign_in_failed", context, %{
               method: "sso",
               reason: Atom.to_string(reason)
             })
           ) do
      Logger.warning("sso refusal not audited reason=#{reason}")
    end

    refused
  end

  defp record_refused_sign_in(result, _provider, _identifier, _context), do: result

  defp peek_identity_member(%IdentityProvider{} = provider, identifier) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_identifier(provider.id, identifier)
    |> UserIdentity.Query.with_preloaded_membership()
    |> Repo.peek()
  end

  @verified_auth_retry_limit 1

  defp commit_verified_auth(started_provider, namespace, identifier, claims, attempt) do
    Multi.new()
    |> put_active_account_lock(started_provider.account_id)
    |> put_sso_entitlement(started_provider.account_id)
    |> put_callback_provider_lock(started_provider, namespace, claims)
    |> Multi.merge(fn %{locked_provider: provider} ->
      verified_auth_writes(provider, identifier, claims)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{auth_result: {:pending, request} = result}} ->
        broadcast_link_request_pending(request)
        result

      {:ok, %{auth_result: result}} ->
        result

      {:error, %Ecto.Changeset{data: %UserIdentity{}} = changeset}
      when attempt < @verified_auth_retry_limit ->
        if Repo.Changeset.unique_constraint_error?(changeset) do
          commit_verified_auth(started_provider, namespace, identifier, claims, attempt + 1)
        else
          {:error, changeset}
        end

      {:error, %Ecto.Changeset{data: %LinkRequest{}}} ->
        {:error, :identity_pending_approval}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_callback_provider_lock(multi, started_provider, namespace, claims) do
    Multi.run(multi, :locked_provider, fn repo, _changes ->
      current =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.by_account_id(started_provider.account_id)
        |> IdentityProvider.Query.by_id(started_provider.id)
        |> IdentityProvider.Query.lock_for_update()
        |> repo.peek()

      case current do
        %IdentityProvider{enabled: true} = provider ->
          if callback_namespace(provider) != namespace do
            {:error, :identity_namespace_changed}
          else
            case ensure_email_domain_allowed(provider, claims) do
              :ok -> {:ok, provider}
              {:error, reason} -> {:error, reason}
            end
          end

        _missing_or_disabled ->
          {:error, :provider_disabled}
      end
    end)
  end

  # Callback state is process-local and can retain typed boundaries. Persisted
  # link requests keep their historical hash encoding for compatibility, but a
  # live callback compares the three fields directly so embedded delimiters can
  # never make two namespaces equal.
  defp callback_namespace(%IdentityProvider{} = provider),
    do: {provider.issuer, provider.client_id, provider.identifier_claim}

  @doc """
  Internal — an invitee in a workspace that refuses email sign-in proved the
  invited inbox (`Auth.complete_magic_link_sign_in/4` returned `proof`) and
  continues at one of that workspace's identity providers. The invitation and
  the proved code are the authority, so there is no Subject. Checks the proof
  from the same browser, then begins the provider's authorization with a forced
  fresh sign-in (`prompt=login`, `max_age=0`), so an IdP session already open in
  a shared browser cannot be bound to the invitee. Returns `{:ok, begun}` — the
  authorization URL plus the state the boundary keeps in its encrypted session
  for `complete_invitation_sso_sign_in/5`, bound to the workspace, the pending
  Member, its invitation token, the provider and its namespace, the OIDC state,
  nonce and PKCE verifier, and the start time — or
  `{:error, :invitation_sso_invalid | :not_found}`. The proof itself stays where
  the boundary already keeps it; the completion is handed it again, so the
  session never carries two copies.
  """
  def begin_invitation_sso_sign_in(proof, provider_id, redirect_uri, browser_id)
      when is_binary(redirect_uri) do
    with {:ok, invitation} <- Auth.verify_invitation_sso_proof(proof, browser_id),
         {:ok, provider} <- fetch_provider_for_sign_in(provider_id),
         true <- provider.account_id == invitation.account_id,
         {:ok, begun} <-
           OIDC.begin_authorization(provider,
             redirect_uri: redirect_uri,
             url_extension: @fresh_sign_in_url_extension
           ) do
      {:ok,
       Map.merge(begun, %{
         account_id: invitation.account_id,
         membership_id: invitation.membership_id,
         invitation_token_digest: invitation.token_digest,
         provider_id: provider.id,
         namespace: callback_namespace(provider),
         started_at: System.system_time(:second)
       })}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — finishes an invitation's SSO step. Verifies the provider's callback
  exactly like ordinary sign-in (state, nonce, PKCE, issuer, the provider's
  email-domain rule) and requires an IdP sign-in made after the step began
  (`auth_time`), then in ONE transaction locks the workspace, its SSO
  entitlement and the provider (still enabled, still the namespace the step
  began with); accepts the still-pending invitation by workspace, Member and
  invitation token, with the name the invitee gave and the address verified;
  binds the returned identity to that Member — refused while another live
  Member holds it; consumes the proved code; and mints the Member's SSO session
  for that identity. No Subject: the invitation, the proved code and the
  callback are the authentication. `proof` is the one the step began with, and
  must come from the same browser (`browser_id` as in
  `Auth.complete_sso_sign_in/5`); the name and address it accepts with are read
  from the proved code (`Auth.peek_invitation_sso_acceptance/1`).

  Returns `{:ok, raw_token, %Accounts.Membership{account: account}}`, or
  `{:error, :invitation_sso_invalid | :invitation_invalid | :invalid_or_expired |
  :identity_already_linked | :provider_disabled | :sso_not_available | term()}`.
  """
  def complete_invitation_sso_sign_in(
        params,
        stashed,
        proof,
        browser_id,
        %RequestContext{} = context
      )
      when is_map(params) and is_map(stashed) and is_binary(browser_id) do
    with {:ok, proved} <- Auth.verify_invitation_sso_proof(proof, browser_id),
         :ok <- ensure_invitation_sso_stash(stashed, proved),
         {:ok, provider} <- fetch_identity_link_provider_from_stash(stashed),
         {:ok, %{identifier: identifier, claims: claims}} <-
           OIDC.verify_callback(provider, params, stashed),
         {:ok, _auth_time} <- fresh_invitation_sign_in(claims, stashed),
         {:ok, invitation} <- Auth.peek_invitation_sso_acceptance(proved) do
      commit_invitation_sso_sign_in(
        provider,
        identifier,
        claims,
        stashed,
        invitation,
        browser_id,
        context
      )
    end
  end

  defp fresh_invitation_sign_in(claims, stashed) do
    case fresh_reauthentication_auth_time(claims, stashed) do
      {:ok, auth_time} -> {:ok, auth_time}
      {:error, :reauthentication_invalid} -> {:error, :invitation_sso_invalid}
    end
  end

  defp ensure_invitation_sso_stash(stashed, invitation) do
    valid? =
      Map.get(stashed, :account_id) == invitation.account_id and
        Map.get(stashed, :membership_id) == invitation.membership_id and
        Map.get(stashed, :invitation_token_digest) == invitation.token_digest and
        is_binary(Map.get(stashed, :provider_id)) and
        is_tuple(Map.get(stashed, :namespace)) and
        is_integer(Map.get(stashed, :started_at))

    if valid?, do: :ok, else: {:error, :invitation_sso_invalid}
  end

  defp commit_invitation_sso_sign_in(
         provider,
         identifier,
         claims,
         stashed,
         invitation,
         browser_id,
         context
       ) do
    {token, digest} = Crypto.session_token()

    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(invitation.account_id, repo: repo)
    end)
    |> put_sso_entitlement(invitation.account_id)
    |> put_callback_provider_lock(provider, stashed.namespace, claims)
    |> Accounts.put_invitation_acceptance(invitation, invitation.sent_to)
    |> Multi.run(:identity, fn repo, %{accepted: membership, locked_provider: locked_provider} ->
      bind_invitee_identity(repo, locked_provider, membership, identifier, claims)
    end)
    |> Multi.insert(:identity_audit, fn %{accepted: membership, locked_provider: locked_provider} ->
      Audit.Events.invitee_identity_linked(membership, locked_provider, context)
    end)
    |> Auth.put_invitation_sso_session(invitation, digest, browser_id, context)
    |> Repo.commit_multi(after_commit: &Accounts.after_membership_activation_committed/1)
    |> case do
      {:ok, %{account: account, accepted: membership}} ->
        {:ok, token, %{membership | account: account}}

      {:error, %Ecto.Changeset{data: %UserIdentity{}} = changeset} ->
        if Repo.Changeset.unique_constraint_error?(changeset),
          do: {:error, :identity_already_linked},
          else: {:error, changeset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The identity this provider returned becomes the invited Member's. While a
  # live Member holds it, it is that Member's sign-in here, so the step is
  # refused. One left on a removed seat moves to the invited Member, the way a
  # person invited back after removal returns.
  defp bind_invitee_identity(repo, provider, %Accounts.Membership{} = member, identifier, claims) do
    current =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_and_identifier(provider.id, identifier)
      |> UserIdentity.Query.lock_for_update()
      |> repo.peek()

    case current do
      nil ->
        changeset =
          UserIdentity.Changeset.create(provider.account_id, provider.id, member, %{
            provider_identifier: identifier,
            claims: claims,
            created_by: :user,
            provisioned_via: :oidc_link
          })

        repo.insert(changeset)

      %UserIdentity{} = identity ->
        rebind_removed_seat_identity(repo, identity, member, identifier, claims)
    end
  end

  defp rebind_removed_seat_identity(repo, identity, member, identifier, claims) do
    case Accounts.peek_sync_membership_by_id(identity.account_id, identity.membership_id) do
      nil ->
        identity
        |> UserIdentity.Changeset.verify_by_user(identifier, claims)
        |> UserIdentity.Changeset.bind_membership(member)
        |> repo.update()

      %Accounts.Membership{} ->
        {:error, :identity_already_linked}
    end
  end

  defp verified_auth_writes(provider, identifier, claims) do
    Multi.new()
    # The first read only tells us which identity, and which seat, to judge; the
    # identity is locked and re-read below. The account and provider locks above
    # serialize same-account rebinds while this hint is consumed.
    |> Multi.run(:identity_hint, fn repo, _changes ->
      hint =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_and_identifier(provider.id, identifier)
        |> UserIdentity.Query.with_preloaded_membership()
        |> repo.peek()

      {:ok, hint}
    end)
    |> Multi.merge(fn
      %{identity_hint: %UserIdentity{} = identity} ->
        existing_identity_auth_writes(provider, identifier, identity, claims)

      %{identity_hint: nil} ->
        unknown_identity_writes(provider, identifier, claims)
    end)
  end

  defp existing_identity_auth_writes(provider, identifier, identity_hint, claims) do
    Multi.new()
    |> Multi.run(:resolved_identity, fn repo, _changes ->
      current =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_and_identifier(provider.id, identifier)
        |> UserIdentity.Query.lock_for_update()
        |> repo.peek()

      case current do
        %UserIdentity{membership_id: seat_id} = identity
        when seat_id == identity_hint.membership_id ->
          {:ok, identity}

        nil ->
          {:ok, nil}

        %UserIdentity{} ->
          {:error, :identity_pending_approval}
      end
    end)
    |> Multi.merge(fn
      %{resolved_identity: %UserIdentity{} = identity} ->
        existing_auth_writes(provider, identity, identity_hint.membership, claims)

      %{resolved_identity: nil} ->
        unknown_identity_writes(provider, identifier, claims)
    end)
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
  defp existing_auth_writes(%IdentityProvider{} = provider, identity, member, claims) do
    if synthesized_oidc_identifier?(identity) do
      if claims_name_the_same_person?(provider, identity, member, claims) do
        returning_auth_writes(provider, identity)
      else
        pending_auth_writes(provider, identity.provider_identifier, claims)
      end
    else
      returning_auth_writes(provider, identity)
    end
  end

  # An identity signs in only to the seat it is bound to; it never moves to
  # another seat by itself.
  defp returning_auth_writes(provider, identity) do
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      case Accounts.fetch_and_lock_active_membership(
             repo,
             provider.account_id,
             identity.membership_id
           ) do
        {:ok, member} -> {:ok, member}
        {:error, :not_found} -> {:error, :membership_unavailable}
      end
    end)
    |> Multi.update(:identity, UserIdentity.Changeset.touch_last_seen(identity))
    |> Multi.run(:auth_result, fn _repo, changes ->
      {:ok, {:ok, auth_result(changes, provider)}}
    end)
  end

  defp auth_result(%{membership: member, identity: identity}, provider),
    do: %{membership: member, identity: identity, provider: provider}

  defp synthesized_oidc_identifier?(%UserIdentity{provisioned_via: :scim} = identity),
    do: identity.provider_identifier == identity.scim_external_id

  defp synthesized_oidc_identifier?(%UserIdentity{}), do: false

  # Entra and Okta omit `email_verified` from real ID tokens. Email remains
  # unusable as identity evidence, but their tenant-bound stable identifiers can
  # converge with the exact active SCIM resource whose externalId created this
  # binding. This stays provider-specific: the issuer must be the one the
  # callback already verified, the claim must name the same synthesized
  # identifier, the SCIM lifecycle must be live, and the account membership must
  # still be active. An explicit false email claim never rides this omission-only
  # path.
  defp claims_name_the_same_person?(
         %IdentityProvider{
           kind: :entra,
           scim_enabled: true,
           identifier_claim: :oid
         } = provider,
         %UserIdentity{
           provisioned_via: :scim,
           scim_active: true,
           scim_deleted_at: nil,
           provider_identifier_retired_at: nil
         } = identity,
         _member,
         %{"iss" => issuer, "oid" => oid} = claims
       ) do
    oid == identity.provider_identifier and
      oid == identity.scim_external_id and
      issuer == provider.issuer and
      not Map.has_key?(claims, "email_verified") and
      active_scim_membership?(provider, identity)
  end

  defp claims_name_the_same_person?(
         %IdentityProvider{
           kind: :okta,
           scim_enabled: true,
           identifier_claim: :sub
         } = provider,
         %UserIdentity{
           provisioned_via: :scim,
           scim_active: true,
           scim_deleted_at: nil,
           provider_identifier_retired_at: nil
         } = identity,
         _member,
         %{"iss" => issuer, "sub" => sub} = claims
       ) do
    sub == identity.provider_identifier and
      sub == identity.scim_external_id and
      issuer == provider.issuer and
      not Map.has_key?(claims, "email_verified") and
      active_scim_membership?(provider, identity)
  end

  # Everywhere else the token must carry a verified email equal to this
  # workspace's contact for the seat the identity signs into. Only the account's
  # own contact is compared; the citext column compares case-insensitively, and
  # so does this.
  defp claims_name_the_same_person?(
         provider,
         _identity,
         %Accounts.Membership{email: contact},
         claims
       )
       when is_binary(contact) do
    case verified_email(provider, claims) do
      email when is_binary(email) -> String.downcase(email) == String.downcase(contact)
      nil -> false
    end
  end

  defp claims_name_the_same_person?(_provider, _identity, _member, _claims), do: false

  defp active_scim_membership?(provider, identity) do
    case Accounts.peek_sync_membership_by_id(provider.account_id, identity.membership_id) do
      %Accounts.Membership{disabled_at: nil, directory_suspended: false} -> true
      _missing_or_inactive -> false
    end
  end

  # Directory sync on: the directory decides who exists. An identifier it never
  # provisioned belongs to someone not yet synced, or someone who should not be
  # here — and JIT-creating them minted a SECOND member for a person the
  # directory already knew under its own externalId. The two members share no
  # row, so deactivating the directory's left this one signed in. Park it for an
  # admin, exactly as a `:manual` connection does. (Ordering: this clause must
  # precede the `:jit` one, which would otherwise match first.)
  defp unknown_identity_writes(
         %IdentityProvider{scim_enabled: true} = provider,
         identifier,
         claims
       ),
       do: pending_auth_writes(provider, identifier, claims)

  defp unknown_identity_writes(
         %IdentityProvider{provisioner: :manual} = provider,
         identifier,
         claims
       ),
       do: pending_auth_writes(provider, identifier, claims)

  # Email is never identity. A verified email naming a live Member of this
  # account is held for an admin to link, exactly as `:manual` holds everyone.
  # Otherwise the person is new here: a new Member, whatever seats the same
  # person holds in other workspaces.
  defp unknown_identity_writes(
         %IdentityProvider{provisioner: :jit} = provider,
         identifier,
         claims
       ) do
    case member_contact_match(provider, verified_email(provider, claims)) do
      :none ->
        build_provision_writes(provider, identifier, claims, [])
        |> Multi.run(:auth_result, fn _repo, changes ->
          {:ok, {:ok, auth_result(changes, provider)}}
        end)

      {:ok, _member} ->
        pending_auth_writes(provider, identifier, claims)
    end
  end

  # The unknown identity is captured as a pending link request (the real `sub` +
  # claims, so an admin recognizes the person) and parked — re-attempts upsert,
  # never pile up. When the email matches an existing member the request records
  # them, so approving REBINDS that member's identity rather than adding a person.
  defp pending_auth_writes(%IdentityProvider{} = provider, identifier, claims) do
    Multi.new()
    |> put_link_request(
      :link_request,
      provider,
      identifier,
      claims["email"],
      claims["name"],
      claims,
      :oidc
    )
    |> Multi.run(:auth_result, fn _repo, %{link_request: request} ->
      {:ok, {:pending, request}}
    end)
  end

  # A new Member: its workspace profile comes from the token, and only a
  # verified email becomes its contact (still unverified for email sign-in).
  defp build_provision_writes(%IdentityProvider{} = provider, identifier, claims, opts) do
    created_by = Keyword.get(opts, :created_by, :provider)
    provisioned_via = Keyword.get(opts, :provisioned_via, :oidc_jit)
    audit = Keyword.get(opts, :audit, &Audit.Events.user_provisioned_via_sso(&1, provider))
    runner_access = Keyword.get(opts, :runner_access, provider_runner_access(provider))

    Multi.new()
    |> Accounts.put_sso_membership(
      provider.account_id,
      provider.default_role,
      runner_access,
      display_name: claims["name"],
      email: verified_email(provider, claims)
    )
    |> Multi.run(:identity, fn _repo, %{membership: member} ->
      create_identity(provider, member, identifier, claims, created_by, provisioned_via)
    end)
    |> Multi.insert(:audit, fn %{membership: member} -> audit.(member) end)
  end

  defp create_identity(
         %IdentityProvider{} = provider,
         member,
         identifier,
         claims,
         created_by,
         via
       ) do
    attrs = %{
      provider_identifier: identifier,
      claims: claims,
      created_by: created_by,
      provisioned_via: via
    }

    changeset = UserIdentity.Changeset.create(provider.account_id, provider.id, member, attrs)
    Repo.insert(changeset)
  end

  defp email_explicitly_unverified?(claims), do: claims["email_verified"] in [false, "false"]

  # H1: Google's `hd` is an issuer-owned tenant boundary. Other OIDC providers
  # do not define it, so only an explicitly verified email can prove their
  # domain. Raw email remains display context and never grants membership.
  defp ensure_email_domain_allowed(%IdentityProvider{allowed_email_domain: nil}, _claims), do: :ok

  defp ensure_email_domain_allowed(
         %IdentityProvider{allowed_email_domain: domain} = provider,
         claims
       ) do
    if claimed_domain_matches?(provider, claims, domain),
      do: :ok,
      else: {:error, :email_domain_not_allowed}
  end

  defp claimed_domain_matches?(
         %IdentityProvider{kind: :google_workspace} = provider,
         claims,
         domain
       ) do
    case claims["hd"] do
      hd when is_binary(hd) ->
        not email_explicitly_unverified?(claims) and domains_equal?(hd, domain)

      _ ->
        verified_email_matches_domain?(provider, claims, domain)
    end
  end

  defp claimed_domain_matches?(%IdentityProvider{} = provider, claims, domain),
    do: verified_email_matches_domain?(provider, claims, domain)

  defp verified_email_matches_domain?(provider, claims, domain) do
    case verified_email(provider, claims) do
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

  defp domains_equal?(a, b),
    do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  # Ensure the matched member is active, reinstating it — the link-approval flow,
  # where an admin explicitly grants access. Runs inside the approval's Multi, so
  # a committed reinstate is TAGGED for the commit site to fire its broadcast
  # after the transaction, never from within it.
  defp ensure_active_membership_multi(
         %IdentityProvider{},
         %Accounts.Membership{disabled_at: nil} = membership
       ),
       do: Multi.run(Multi.new(), :membership, fn _repo, _changes -> {:ok, membership} end)

  defp ensure_active_membership_multi(%IdentityProvider{} = provider, membership) do
    Accounts.put_sync_membership_lifecycle(Multi.new(), membership, provider, :reinstate)
    |> Multi.run(:membership, fn _repo, %{membership_transition: transition} ->
      {:ok, transition.membership}
    end)
  end

  @doc """
  Internal — the SSO facts Auth's sign-in transaction locks before minting a
  session for one Member, after it has locked the workspace: the workspace's
  SSO entitlement (`:sso_entitlement`), the identity's provider, still enabled
  at the issuer the identity was found under (`:sso_provider`), and the identity
  itself, still unretired, still bound to the same seat and still carrying the
  `provider_identifier` the callback asserted (`:sso_identity`), in that order.
  Anything missing, disabled, moved or rebound fails the transaction with
  `:provider_disabled`. No Subject: the callback is the authentication.
  """
  def put_sign_in_authority(%Multi{} = multi, account_id, identity_id, provider_identifier)
      when is_binary(provider_identifier) do
    if Repo.valid_uuid?(account_id) and Repo.valid_uuid?(identity_id) do
      multi
      |> Multi.run(:sso_entitlement, fn repo, _changes ->
        if Billing.sso_available_for_account_id?(account_id, repo: repo, lock?: true),
          do: {:ok, :available},
          else: {:error, :provider_disabled}
      end)
      |> Multi.run(:sso_identity_hint, fn repo, _changes ->
        sign_in_identity_hint(repo, account_id, identity_id, provider_identifier)
      end)
      |> Multi.run(:sso_provider, fn repo, %{sso_identity_hint: hint} ->
        lock_sign_in_provider(repo, hint)
      end)
      |> Multi.run(:sso_identity, fn repo, %{sso_identity_hint: hint} ->
        lock_sign_in_identity(repo, hint)
      end)
    else
      Multi.error(multi, :sso_provider, :provider_disabled)
    end
  end

  def put_sign_in_authority(%Multi{} = multi, _account_id, _identity_id, _provider_identifier),
    do: Multi.error(multi, :sso_provider, :provider_disabled)

  # The unlocked read only names the provider and seat to lock next; the
  # identity itself is locked after its provider, the order revocation takes.
  defp sign_in_identity_hint(repo, account_id, identity_id, provider_identifier) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.provider_identifier_active()
      |> UserIdentity.Query.by_id(identity_id)
      |> UserIdentity.Query.by_account_id(account_id)
      |> UserIdentity.Query.by_provider_identifier(provider_identifier)
      |> UserIdentity.Query.with_preloaded_provider()

    case repo.peek(queryable) do
      %UserIdentity{} = identity -> {:ok, identity}
      nil -> {:error, :provider_disabled}
    end
  end

  defp lock_sign_in_provider(repo, %UserIdentity{} = hint) do
    current =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(hint.account_id)
      |> IdentityProvider.Query.by_id(hint.provider_id)
      |> IdentityProvider.Query.lock_for_update()
      |> repo.peek()

    case current do
      %IdentityProvider{enabled: true, issuer: issuer} = provider
      when issuer == hint.provider.issuer ->
        {:ok, provider}

      _missing_disabled_or_moved ->
        {:error, :provider_disabled}
    end
  end

  defp lock_sign_in_identity(repo, %UserIdentity{} = hint) do
    queryable =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.provider_identifier_active()
      |> UserIdentity.Query.by_id(hint.id)
      |> UserIdentity.Query.by_account_id(hint.account_id)
      |> UserIdentity.Query.by_provider_id(hint.provider_id)
      |> UserIdentity.Query.by_provider_identifier(hint.provider_identifier)
      |> UserIdentity.Query.lock_for_update()

    case repo.peek(queryable) do
      %UserIdentity{membership_id: membership_id} = identity
      when membership_id == hint.membership_id ->
        {:ok, identity}

      _missing_retired_or_rebound ->
        {:error, :provider_disabled}
    end
  end

  # Sign-in and revocation take the same provider lock, so a callback carrying
  # a stale enabled snapshot cannot mint a session after revocation commits.
  defp put_enabled_provider_lock(multi, %IdentityProvider{} = provider) do
    Multi.run(multi, :locked_provider, fn repo, _changes ->
      with {:ok, locked} <- lock_provider_row(provider, repo) do
        if locked.enabled, do: {:ok, locked}, else: {:error, :provider_disabled}
      end
    end)
  end

  @doc """
  Internal — recompute one identity's role from its synced group memberships:
  the HIGHEST mapped role over the groups it belongs to (`:admin > :operator >
  :viewer`; never `:owner`), applied to its membership in the provider's account
  via `Accounts.sync_set_membership_authorization/4`. An identity in NO mapped group
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

      membership =
        Accounts.peek_sync_membership_by_id(provider.account_id, identity.membership_id)

      apply_recomputed_authorization(provider, role, access, membership)
    else
      {:ok, Accounts.peek_sync_membership_by_id(provider.account_id, identity.membership_id)}
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

  # #14: a DirectoryGroupMember always belongs to its user_identity's provider,
  # so no in-app provider filter is needed.
  defp identity_group_ids(%UserIdentity{} = identity) do
    DirectoryGroupMember.Query.not_deleted()
    |> DirectoryGroupMember.Query.by_user_identity_id(identity.id)
    |> Repo.all()
    |> Enum.map(& &1.directory_group_id)
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

      Multi.new()
      |> put_active_account_lock(subject.account.id)
      |> put_directory_sync_entitlement(subject.account.id)
      |> Multi.run(:scim_target, fn repo, _changes ->
        queryable =
          IdentityProvider.Query.not_deleted()
          |> IdentityProvider.Query.by_id(id)
          |> IdentityProvider.Query.lock_for_update()
          |> Authorizer.for_subject(subject)

        with {:ok, loaded_provider} <- repo.fetch(queryable, IdentityProvider.Query),
             true <- ProviderKind.supports_scim?(loaded_provider.kind) do
          {:ok,
           %{
             provider: loaded_provider,
             changeset:
               IdentityProvider.Changeset.scim_token(loaded_provider, prefix, hash, enabled)
           }}
        else
          false -> {:error, :scim_not_supported}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.update(:provider, fn %{scim_target: %{changeset: changeset}} -> changeset end)
      |> Multi.insert(:audit, fn %{scim_target: %{provider: before}, provider: updated} ->
        Audit.Events.identity_provider_updated(subject, before, updated)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{provider: provider}} -> {:ok, provider, raw}
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
        audit: &Audit.Events.identity_provider_updated(subject, &2.data, &1),
        # Sync no longer owns these members' roles — hand control back to operators.
        after_commit: &return_role_control_to_operators/1
      )
    end
  end

  defp return_role_control_to_operators(%IdentityProvider{} = provider) do
    membership_ids =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_id(provider.id)
      |> UserIdentity.Query.select_membership_ids()
      |> Repo.all()

    Accounts.clear_directory_managed_for_memberships(
      provider.account_id,
      provider.id,
      membership_ids
    )

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
  One account-scoped page of synced groups and retired groups with saved role
  or access mappings. Retired rows remain removable after directory deletion or a SCIM
  reset; they are not candidates for new mappings. Requires `manage_sso`.
  """
  def list_group_access(%IdentityProvider{} = provider, %Subject{} = subject, opts \\ []) do
    with {:ok, provider} <- fetch_provider_by_id(provider.id, subject),
         queryable =
           DirectoryGroup.Query.active_or_mapped()
           |> DirectoryGroup.Query.by_account_id(provider.account_id)
           |> DirectoryGroup.Query.by_provider_id(provider.id)
           |> Authorizer.for_subject(subject),
         {:ok, groups, metadata} <- Repo.list(queryable, DirectoryGroup.Query, opts) do
      {:ok, annotate_synced_groups(groups, provider, subject), metadata}
    end
  end

  # The picker never renders a member count or a mapping badge, so its rows are
  # the group rows themselves — no annotation reads behind a search box that
  # runs on every keystroke.
  @synced_group_search_limit 10

  @doc """
  Search a provider's synced groups by display name or external id, capped at
  #{@synced_group_search_limit} rows — the mapping picker's source, so choosing
  a group never depends on the console having preloaded the whole directory. A
  blank term returns the first groups by display name. `manage_sso` +
  Enterprise; account-scoped. Returns `{:ok, [%DirectoryGroup{}]}`.
  """
  def search_synced_groups(%IdentityProvider{} = provider, term, %Subject{} = subject) do
    with {:ok, provider} <- fetch_provider_by_id(provider.id, subject) do
      groups =
        DirectoryGroup.Query.not_deleted()
        |> DirectoryGroup.Query.by_account_id(provider.account_id)
        |> DirectoryGroup.Query.by_provider_id(provider.id)
        |> DirectoryGroup.Query.matching(term, @synced_group_search_limit)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, groups}
    end
  end

  # Counts and mappings are bounded to the page's groups.
  defp annotate_synced_groups(groups, %IdentityProvider{} = provider, %Subject{} = subject) do
    group_ids = Enum.map(groups, & &1.id)

    counts =
      directory_roster_query(subject, provider_id: provider.id)
      |> DirectoryGroupMember.Query.by_directory_group_ids(group_ids)
      |> DirectoryGroupMember.Query.roster_group_counts()
      |> Authorizer.for_subject(subject)
      |> Repo.all()
      |> Map.new(&{&1.directory_group_id, &1})

    # Both maps are narrowed to the page's groups like the member counts above:
    # a directory can push thousands of groups, and a whole-provider read per
    # page render is exactly the load paging the list was meant to remove.
    role_mappings =
      GroupRoleMapping.Query.not_deleted()
      |> GroupRoleMapping.Query.by_provider_id(provider.id)
      |> GroupRoleMapping.Query.by_directory_group_ids(group_ids)
      |> Authorizer.for_subject(subject)
      |> Repo.all()
      |> Map.new(&{&1.directory_group_id, &1})

    runner_access_mappings =
      GroupRunnerAccessMapping.Query.not_deleted()
      |> GroupRunnerAccessMapping.Query.by_provider_id(provider.id)
      |> GroupRunnerAccessMapping.Query.by_directory_group_ids(group_ids)
      |> Authorizer.for_subject(subject)
      |> Repo.all()
      |> Map.new(&{&1.directory_group_id, &1})

    default_access = provider_runner_access(provider)

    Enum.map(groups, fn group ->
      counted = Map.get(counts, group.id, %{})
      access_mapping = Map.get(runner_access_mappings, group.id)

      %{
        id: group.id,
        external_group_id: group.external_group_id,
        display: group.display,
        retired?: not is_nil(group.deleted_at),
        member_count: Map.get(counted, :member_count, 0),
        mapping: Map.get(role_mappings, group.id),
        runner_access_mapping: access_mapping,
        # A row shows this connection and group's access, not a member's final
        # access across all groups. Editors still use the explicit mapping.
        access: GroupAccess.effective(default_access, List.wrap(access_mapping))
      }
    end)
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
         {:ok, provider} <- fetch_provider_by_id(provider.id, subject),
         form = GroupRoleMapping.Changeset.form(provider.account_id, provider.id, attrs),
         :ok <- valid_mapping_form(form) do
      multi = create_group_mapping_multi(provider, attrs, subject)

      case Repo.commit_multi(multi,
             after_commit: fn %{mapping: mapping} -> recompute_mapping_members(mapping) end
           ) do
        {:ok, %{mapping: mapping}} -> {:ok, mapping}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp valid_mapping_form(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_mapping_form(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp create_group_mapping_multi(%IdentityProvider{} = provider, attrs, %Subject{} = subject) do
    directory_group_id = attrs["directory_group_id"] || attrs[:directory_group_id]

    Multi.new()
    |> put_directory_mapping_fence(subject.account.id)
    |> Multi.run(:authorization_change, fn _repo, _changes ->
      prepare_mapping_authorization_change(provider.account_id, provider.id, directory_group_id)
    end)
    |> Multi.insert(:mapping, fn %{authorization_change: %{group: group}} ->
      GroupRoleMapping.Changeset.create(provider.account_id, provider.id, group, attrs)
    end)
    |> Multi.insert(:audit, fn %{mapping: mapping} ->
      Audit.Events.group_role_mapping_created(subject, provider, mapping)
    end)
  end

  @doc "Update a group→role mapping's role. `manage_sso` + enterprise; account-scoped. Reconciles current group members after commit and rejects `:owner`."
  def update_group_mapping(
        %GroupRoleMapping{id: id, provider_id: provider_id},
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject),
         :ok <- ensure_grantable_role(attrs["role"] || attrs[:role], subject) do
      Multi.new()
      |> put_directory_mapping_fence(subject.account.id)
      |> put_mapping_provider_lock(provider_id, subject)
      |> put_locked_mapping(GroupRoleMapping.Query, id, subject)
      |> Multi.run(:validated_mapping, fn _repo, %{locked_mapping: mapping} ->
        changeset = GroupRoleMapping.Changeset.update(mapping, attrs)
        if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
      end)
      |> Multi.run(:authorization_change, fn _repo,
                                             %{
                                               locked_provider: provider,
                                               locked_mapping: mapping,
                                               validated_mapping: changeset
                                             } ->
        prepare_mapping_update_authorization(provider, mapping, changeset, [:role])
      end)
      |> Multi.update(:mapping, & &1.validated_mapping)
      |> Multi.insert(:audit, fn %{mapping: mapping} ->
        Audit.Events.group_role_mapping_updated(subject, mapping)
      end)
      |> Repo.commit_multi(
        after_commit: fn
          %{authorization_change: :unchanged} -> :ok
          %{mapping: mapping} -> recompute_mapping_members(mapping)
        end
      )
      |> mapping_result()
    end
  end

  @doc "Soft-delete a group→role mapping. `manage_sso` + enterprise; account-scoped. Reconciles current group members after commit."
  def delete_group_mapping(
        %GroupRoleMapping{id: id, provider_id: provider_id},
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      Multi.new()
      |> put_directory_mapping_fence(subject.account.id)
      |> put_mapping_provider_lock(provider_id, subject)
      |> put_locked_mapping(GroupRoleMapping.Query, id, subject)
      |> Multi.run(:authorization_change, fn _repo,
                                             %{
                                               locked_provider: provider,
                                               locked_mapping: mapping
                                             } ->
        prepare_locked_mapping_authorization_change(
          provider,
          mapping.directory_group_id,
          :including_deleted
        )
      end)
      |> Multi.update(:mapping, fn %{locked_mapping: mapping} ->
        GroupRoleMapping.Changeset.delete(mapping)
      end)
      |> Multi.insert(:audit, fn %{mapping: mapping} ->
        Audit.Events.group_role_mapping_deleted(subject, mapping)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{mapping: mapping} ->
          recompute_mapping_members(mapping)
        end
      )
      |> mapping_result()
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
         form =
           GroupRunnerAccessMapping.Changeset.form(
             provider.account_id,
             provider.id,
             attrs,
             allowlist
           ),
         {:ok, access} <- runner_access_mapping_from_changeset(form, provider),
         :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access) do
      Multi.new()
      |> put_directory_mapping_fence(subject.account.id)
      |> Multi.run(:authorization_change, fn _repo, _changes ->
        prepare_mapping_authorization_change(
          provider.account_id,
          provider.id,
          Ecto.Changeset.get_field(form, :directory_group_id)
        )
      end)
      |> Multi.run(:grant_allowed, fn _repo, %{authorization_change: %{provider: current}} ->
        with {:ok, access} <- runner_access_mapping_from_changeset(form, current),
             :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access),
             do: {:ok, true}
      end)
      |> Multi.insert(:mapping, fn %{authorization_change: %{group: group}} ->
        GroupRunnerAccessMapping.Changeset.create(
          provider.account_id,
          provider.id,
          group,
          attrs,
          allowlist
        )
      end)
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
        %GroupRunnerAccessMapping{id: id, provider_id: provider_id},
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      Multi.new()
      |> put_directory_mapping_fence(subject.account.id)
      |> put_mapping_provider_lock(provider_id, subject)
      |> put_locked_mapping(GroupRunnerAccessMapping.Query, id, subject)
      |> Multi.run(:validated_mapping, fn _repo,
                                          %{locked_mapping: mapping, locked_provider: provider} ->
        {attrs, allowlist} = mapping_selection(attrs, mapping.account_id, mapping)
        changeset = GroupRunnerAccessMapping.Changeset.update(mapping, attrs, allowlist)

        with {:ok, access} <- runner_access_mapping_from_changeset(changeset, provider),
             :ok <- Accounts.ensure_runner_access_grant_allowed(subject, access) do
          {:ok, changeset}
        end
      end)
      |> Multi.run(:authorization_change, fn _repo,
                                             %{
                                               locked_provider: provider,
                                               locked_mapping: mapping,
                                               validated_mapping: changeset
                                             } ->
        prepare_mapping_update_authorization(
          provider,
          mapping,
          changeset,
          [
            :runner_access_mode,
            :runner_scope_groups,
            :runner_scope_runner_ids,
            :pack_access_mode,
            :pack_scope_pack_ids
          ]
        )
      end)
      |> Multi.update(:mapping, & &1.validated_mapping)
      |> Multi.insert(:audit, fn %{locked_mapping: before_mapping, mapping: mapping} ->
        Audit.Events.group_runner_access_mapping_updated(subject, before_mapping, mapping)
      end)
      |> Repo.commit_multi(
        after_commit: fn
          %{authorization_change: :unchanged} -> :ok
          %{mapping: mapping} -> recompute_runner_access_mapping_members(mapping)
        end
      )
      |> mapping_result()
    end
  end

  @doc "Delete an IdP-group runner-access grant and immediately revoke its derived reach."
  def delete_group_runner_access_mapping(
        %GroupRunnerAccessMapping{id: id, provider_id: provider_id},
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_directory_sync(subject) do
      Multi.new()
      |> put_directory_mapping_fence(subject.account.id)
      |> put_mapping_provider_lock(provider_id, subject)
      |> put_locked_mapping(GroupRunnerAccessMapping.Query, id, subject)
      |> Multi.run(:authorization_change, fn _repo,
                                             %{
                                               locked_provider: provider,
                                               locked_mapping: mapping
                                             } ->
        prepare_locked_mapping_authorization_change(
          provider,
          mapping.directory_group_id,
          :including_deleted
        )
      end)
      |> Multi.update(:mapping, fn %{locked_mapping: mapping} ->
        GroupRunnerAccessMapping.Changeset.delete(mapping)
      end)
      |> Multi.insert(:audit, fn %{mapping: mapping} ->
        Audit.Events.group_runner_access_mapping_deleted(subject, mapping)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{mapping: mapping} ->
          recompute_runner_access_mapping_members(mapping)
        end
      )
      |> mapping_result()
    end
  end

  defp mapping_result({:ok, %{mapping: mapping}}), do: {:ok, mapping}
  defp mapping_result({:error, reason}), do: {:error, reason}

  defp put_directory_mapping_fence(multi, account_id) do
    multi
    |> put_active_account_lock(account_id)
    |> put_directory_sync_entitlement(account_id)
  end

  # The mapping row under the provider lock: not deleted, that provider's, this
  # id, `FOR UPDATE`, and account-scoped — the same read every mapping mutation
  # opens with, for either mapping schema.
  defp put_locked_mapping(multi, query, id, %Subject{} = subject) do
    Multi.run(multi, :locked_mapping, fn _repo, %{locked_provider: provider} ->
      query.not_deleted()
      |> query.by_provider_id(provider.id)
      |> query.by_id(id)
      |> query.lock_for_update()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(query)
    end)
  end

  # After the shared account -> subscription entitlement fence, SCIM mapping
  # writes lock provider -> group before touching mapping snapshots. Every
  # operator mapping mutation keeps that order, so a rename cannot deadlock
  # against an update/delete that grabbed the mapping row first.
  defp put_mapping_provider_lock(multi, provider_id, %Subject{} = subject) do
    Multi.run(multi, :locked_provider, fn _repo, _changes ->
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_id(provider_id)
      |> IdentityProvider.Query.lock_for_update()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(IdentityProvider.Query)
    end)
  end

  defp runner_access_mapping_from_changeset(%Ecto.Changeset{} = changeset, provider) do
    if changeset.valid? do
      GroupAccess.authorization_access(
        provider_runner_access(provider),
        Ecto.Changeset.apply_changes(changeset)
      )
    else
      {:error, changeset}
    end
  end

  defp prepare_mapping_authorization_change(account_id, provider_id, directory_group_id) do
    provider =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(account_id)
      |> IdentityProvider.Query.by_id(provider_id)
      |> IdentityProvider.Query.lock_for_update()
      |> Repo.fetch(IdentityProvider.Query)

    with {:ok, %IdentityProvider{} = provider} <- provider,
         {:ok, group} <- fetch_live_directory_group(provider, directory_group_id) do
      maybe_prepare_mapping_authorization_change(provider, group)
    end
  end

  defp maybe_prepare_mapping_authorization_change(
         %IdentityProvider{scim_enabled: true} = provider,
         %DirectoryGroup{} = group
       ) do
    with {:ok, updated_provider} <- bump_provider_authorization_version(provider) do
      membership_ids = directory_group_membership_ids(provider, group.id)

      {:ok, _version} =
        Accounts.mark_directory_authorization_pending(
          Repo,
          provider.account_id,
          provider.id,
          membership_ids,
          updated_provider.authorization_version
        )

      {:ok, %{provider: updated_provider, group: group}}
    end
  end

  defp maybe_prepare_mapping_authorization_change(
         %IdentityProvider{} = provider,
         %DirectoryGroup{} = group
       ),
       do: {:ok, %{provider: provider, group: group}}

  defp fetch_live_directory_group(%IdentityProvider{} = provider, directory_group_id) do
    if Repo.valid_uuid?(directory_group_id) do
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_id(directory_group_id)
      |> DirectoryGroup.Query.lock_for_update()
      |> Repo.fetch(DirectoryGroup.Query)
    else
      {:error, :not_found}
    end
  end

  # Virtual selection fields are rebuilt on every form submission. Only changed
  # persisted grants need to fence directory authorization and reconnect members.
  defp prepare_mapping_update_authorization(provider, mapping, changeset, fields) do
    if Enum.any?(fields, &Map.has_key?(changeset.changes, &1)) do
      prepare_locked_mapping_authorization_change(provider, mapping.directory_group_id, :live)
    else
      {:ok, :unchanged}
    end
  end

  defp prepare_locked_mapping_authorization_change(provider, directory_group_id, group_scope) do
    fetch =
      case group_scope do
        :live -> &fetch_live_directory_group/2
        :including_deleted -> &fetch_directory_group/2
      end

    with {:ok, group} <- fetch.(provider, directory_group_id) do
      maybe_prepare_mapping_authorization_change(provider, group)
    end
  end

  defp fetch_directory_group(%IdentityProvider{} = provider, directory_group_id) do
    if Repo.valid_uuid?(directory_group_id) do
      DirectoryGroup.Query.all()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_id(directory_group_id)
      |> DirectoryGroup.Query.lock_for_update()
      |> Repo.fetch(DirectoryGroup.Query)
    else
      {:error, :not_found}
    end
  end

  defp directory_group_membership_ids(provider, directory_group_id) do
    provider
    |> current_group_members(directory_group_id)
    |> Enum.map(& &1.user_identity_id)
    |> then(&load_identities(provider, &1))
    |> Enum.map(& &1.membership_id)
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
          |> current_group_members(mapping.directory_group_id)
          |> Enum.map(& &1.user_identity_id)

        provider
        |> load_identities(identity_ids)
        |> then(&recompute_role_for_affected(provider, &1))

      _ ->
        :ok
    end
  end

  # -- Manual link requests (Subject-gated) ----------------------------

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

  @doc """
  Cheap account-scoped count for the Team navigation badge. It uses the same
  `manage_sso` gate as the pending-request queue and returns `0` when the
  caller cannot review it, so the navigation does not disclose hidden work.
  """
  def count_pending_link_requests(%Subject{} = subject) do
    case ensure_can_manage_sso(subject) do
      :ok ->
        LinkRequest.Query.all()
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      _error ->
        0
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
      default_role: provider.default_role,
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

  @doc "Internal — whether this held sign-in matched an unresolved team invitation."
  def link_request_invitation_pending?(%LinkRequest{
        account_id: account_id,
        matched_membership_id: membership_id
      })
      when is_binary(membership_id) do
    case Accounts.peek_sync_membership_by_id(account_id, membership_id) do
      %Accounts.Membership{} = membership ->
        Accounts.membership_invitation_pending?(membership)

      nil ->
        false
    end
  end

  def link_request_invitation_pending?(%LinkRequest{}), do: false

  @doc """
  Approve a pending manual-link request and delete it, atomically: a request
  that matched a live Member binds the captured identity to that Member; any
  other provisions a new Member at the provider's
  `default_role`. `manage_sso` + Team or Enterprise; account-scoped. Binds the
  captured `sub` (never email — H1). Rebinding a Member's existing identity to
  another identifier ends the sessions signed in through the old one and
  disconnects their sockets after commit.
  `{:ok, %{membership: member, identity: identity}}`.
  """
  def approve_link_request(
        %LinkRequest{id: id},
        %Accounts.RunnerAccess{} = access,
        %Subject{} = subject
      ) do
    with :ok <- ensure_can_configure_sso(subject),
         {:ok, request} <- fetch_link_request(id, subject),
         {:ok, provider} <- fetch_provider_for_request(request, subject),
         :ok <-
           ensure_link_target_within_authority(request, provider, subject.role, subject, Repo),
         :ok <- ensure_approval_runner_access_allowed(request, access, subject) do
      multi = approve_link_request_multi(provider, request, access, subject)

      case Repo.commit_multi(multi) do
        {:ok, %{membership: member, identity: identity} = changes} ->
          :ok = link_approval_membership_effects(changes)
          :ok = disconnect_rebound_identity_sessions(changes)
          broadcast_link_request_approved(request)
          {:ok, %{membership: member, identity: identity}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The topics were captured by the rebind's session delete inside the
  # transaction; an adoption or a provisioning approval rebinds nothing and
  # has none to disconnect.
  defp disconnect_rebound_identity_sessions(%{session_effect: %{socket_topics: [_ | _] = topics}}) do
    Auth.disconnect_live_socket_topics(topics)
    :ok
  end

  defp disconnect_rebound_identity_sessions(_changes), do: :ok

  # An approval that reinstated a directory-suspended membership owes the team
  # page its broadcast — fired here, after the commit, like every sync side
  # effect (the membership step tags a committed reinstate for exactly this).
  defp link_approval_membership_effects(changes) do
    case changes do
      %{membership_transition: %{effect: {:reinstated, membership}}} ->
        :ok = Accounts.membership_reinstated_effects(membership)

      _ ->
        :ok
    end

    Accounts.after_membership_activation_committed(changes)
  end

  # Approving a MATCH binds a new IdP credential to an EXISTING Member, so
  # whoever holds that credential can afterwards sign in as them. The approver is
  # also whoever configured the IdP, so without a limit they can assert any
  # email, approve their own request, and authenticate as that member — an admin
  # reaching owner. A Member is one seat in this workspace, so nothing the
  # binding reaches lies outside it.
  #
  # Three limits, all judged on the matched member rather than on the request:
  #
  #   * an unresolved invitation cannot receive an IdP credential before the
  #     invitee proves possession and accepts the account access;
  #   * the approver's permissions must COVER the target's role — the same
  #     no-escalation primitive role changes and invites use — so an admin can
  #     never bind themselves onto an owner;
  #   * the approver's own runner and pack reach must cover the target's, the
  #     rule every grant obeys: the binding hands the credential that reach, so
  #     an admin scoped to some runners can never take on a wider seat.
  #
  # A request with no match provisions a new Member and escalates nothing.
  defp ensure_link_target_within_authority(
         %LinkRequest{matched_membership_id: nil},
         _provider,
         _approver_role,
         _subject,
         _repo
       ),
       do: :ok

  defp ensure_link_target_within_authority(
         %LinkRequest{} = request,
         %IdentityProvider{} = provider,
         approver_role,
         %Subject{} = subject,
         repo
       ) do
    with %Accounts.Membership{} = matched <- peek_matched_membership(provider, request),
         # LOCKED, because this decision has to still be true when the binding
         # commits. Re-reading inside the transaction was not enough on its own:
         # nothing stopped a concurrent promotion to owner from committing in the
         # gap — leaving the approver's IdP credential bound to someone they have
         # no authority over.
         {:ok, _locked} <-
           Accounts.fetch_and_lock_sync_membership(repo, provider.account_id, matched.id) do
      # Re-read under those locks: the decision judges the member's current row.
      matched_membership = peek_matched_membership(provider, request)

      cond do
        not match?(%Accounts.Membership{}, matched_membership) ->
          {:error, :matched_user_unavailable}

        Accounts.membership_invitation_pending?(matched_membership) ->
          {:error, :invitation_pending}

        # Against the role read under lock, not the session's. An owner demoted to
        # admin keeps manage_sso, so the check above still passes — but they no
        # longer cover an owner, and the cached subject said they did. Judged on
        # the MATCHED row: `memberships` drops a suspended one, so reading the
        # role from there waved a suspended owner through — a target this
        # approval may itself reinstate.
        not Auth.Permissions.role_covers_role?(approver_role, matched_membership.role) ->
          {:error, :link_target_outranks_approver}

        # While the directory reconciles this member its stored reach reads as
        # none, and the reconciliation may grant more: judge it once settled.
        is_integer(matched_membership.directory_authorization_pending_version) ->
          {:error, :link_target_authorization_pending}

        not reaches_link_target?(subject, matched_membership) ->
          {:error, :link_target_reach_exceeds_approver}

        true ->
          :ok
      end
    else
      nil -> {:error, :matched_user_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # Read off the locked row itself, suspended or not: the approval may reinstate
  # it, and the reach it keeps is what the new credential gets.
  defp reaches_link_target?(%Subject{} = subject, %Accounts.Membership{} = matched) do
    target_access = Map.fetch!(Accounts.runner_access_for_memberships([matched]), matched.id)
    Accounts.ensure_runner_access_grant_allowed(subject, target_access) == :ok
  end

  defp peek_matched_membership(%IdentityProvider{} = provider, %LinkRequest{} = request),
    do: Accounts.peek_sync_membership_by_id(provider.account_id, request.matched_membership_id)

  defp ensure_approval_runner_access_allowed(
         %LinkRequest{matched_membership_id: nil},
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

  @doc "Internal — authenticated navigation subscribes to its account's pending SSO work."
  def subscribe_account_link_requests(account_id) when is_binary(account_id),
    do: Emisar.PubSub.subscribe(account_link_requests_topic(account_id))

  defp broadcast_link_request_pending(%LinkRequest{} = request) do
    broadcast_account_link_requests_changed(request.account_id)
  end

  defp broadcast_link_request_approved(%LinkRequest{} = request) do
    :ok =
      Emisar.PubSub.broadcast(
        link_request_topic(request.id),
        {:sso_link_request, :approved, %{id: request.id, provider_id: request.provider_id}}
      )

    broadcast_account_link_requests_changed(request.account_id)
  end

  defp broadcast_link_request_dismissed(%LinkRequest{} = request) do
    :ok =
      Emisar.PubSub.broadcast(
        link_request_topic(request.id),
        {:sso_link_request, :dismissed, %{id: request.id}}
      )

    broadcast_account_link_requests_changed(request.account_id)
  end

  defp link_request_topic(id), do: "sso_link_request:#{id}"

  defp broadcast_account_link_requests_changed(account_id) do
    Emisar.PubSub.broadcast(
      account_link_requests_topic(account_id),
      {:sso_link_requests_changed, account_id}
    )
  end

  defp account_link_requests_topic(account_id), do: "sso_link_requests:#{account_id}"

  # No existing member matched → provision a new Member.
  defp approve_link_request_multi(
         %IdentityProvider{} = provider,
         %LinkRequest{matched_membership_id: nil} = request,
         access,
         subject
       ) do
    # This branch creates a membership, an identity and an audit row, and it
    # never re-checked the approver — so an admin demoted, suspended or removed
    # while the request sat open could still run all of it on a cached subject.
    # Nothing here reads the approver's row otherwise.
    Multi.new()
    |> put_active_account_lock(provider.account_id)
    |> put_sso_entitlement(provider.account_id)
    |> put_enabled_provider_lock(provider)
    |> Multi.merge(fn %{locked_provider: locked_provider} ->
      if locked_provider.scim_enabled do
        Multi.error(Multi.new(), :link_request, :scim_identity_unmatched)
      else
        case ensure_request_matches_current_namespace(locked_provider, request) do
          :ok ->
            Multi.new()
            |> Multi.run(:approver, fn repo, _changes ->
              ensure_approver_still_holds_authority(locked_provider, subject, repo)
            end)
            |> Multi.append(
              build_provision_writes(
                locked_provider,
                request.provider_identifier,
                request.claims,
                created_by: :admin,
                provisioned_via: :manual,
                runner_access: access,
                audit: &Audit.Events.sso_link_request_approved(subject, &1, locked_provider)
              )
            )
            |> Multi.delete(:link_request, request)

          {:error, reason} ->
            Multi.error(Multi.new(), :request_namespace, reason)
        end
      end
    end)
  end

  # An existing account member matched → bind this IdP identity to THAT member (no
  # new member, no email merge — the admin's approval is the gate). OIDC claims
  # bind only provider_identifier; a SCIM request also owns scim_external_id.
  # Keeping the directory column nil until the directory asserts it lets later
  # retirement distinguish an OIDC-only link from a lifecycle row. The member's
  # existing role and access are left as-is (never downgraded, never granted owner).
  defp approve_link_request_multi(
         %IdentityProvider{} = provider,
         %LinkRequest{} = request,
         _access,
         %Subject{} = subject
       ) do
    Multi.new()
    |> put_active_account_lock(provider.account_id)
    |> put_sso_entitlement(provider.account_id)
    # Re-read that the connection is still ENABLED under the lock: disabling a
    # compromised connection is how an operator revokes it, and binding a new
    # IdP credential onto an existing member through a closed door is exactly
    # what that revocation must stop (the fresh-user branch already does this).
    |> put_enabled_provider_lock(provider)
    |> Multi.merge(fn %{locked_provider: locked_provider} ->
      Multi.new()
      |> Multi.run(:matched_member, fn repo, _changes ->
        fetch_matched_member(locked_provider, request, subject, repo)
      end)
      |> Multi.merge(fn %{matched_member: member} ->
        ensure_active_membership_multi(locked_provider, member)
      end)
      |> Multi.run(:member_identity, fn repo, %{membership: member} ->
        {:ok, lock_member_identity(locked_provider, member.id, repo)}
      end)
      |> Multi.run(:identity, fn repo, %{membership: member, member_identity: current} ->
        link_identity(locked_provider, member, current, request, repo)
      end)
      |> Multi.run(:session_effect, fn repo, %{member_identity: current, identity: identity} ->
        end_rebound_identity_sessions(repo, current, identity)
      end)
      |> Multi.insert(:audit, fn %{membership: member} ->
        Audit.Events.sso_existing_user_linked(subject, member, locked_provider)
      end)
      |> Multi.delete(:link_request, request)
    end)
  end

  # Sessions signed in through the OLD identifier fail the per-request predicate
  # the moment the rebind commits, but their rows and their connected LiveViews
  # — still subscribed, still receiving broadcasts — would otherwise linger
  # until each one's next check. A rebound identifier is a credential change,
  # so those sessions end here, in the transaction that rebinds, and their
  # sockets are disconnected after commit. Adopting a directory `externalId`
  # changes no sign-in credential and keeps them.
  defp end_rebound_identity_sessions(
         repo,
         %UserIdentity{provider_identifier: before},
         %UserIdentity{id: identity_id, provider_identifier: after_rebind}
       )
       when before != after_rebind,
       do: Auth.delete_identity_sessions([identity_id], repo)

  defp end_rebound_identity_sessions(_repo, _current, _identity),
    do: {:ok, %{count: 0, socket_topics: []}}

  # Re-verify at approval time (the match was recorded at capture): the matched
  # member must still be live in this account.
  # Re-judge the target INSIDE the transaction, not just re-fetch them. The
  # authority check that runs before the approval reads state the approval then
  # acts on moments later: a concurrent promotion to owner landed after
  # validation and before the binding — leaving an attacker-supplied credential
  # attached to a Member who had since become someone this admin has no
  # authority over.
  defp fetch_matched_member(
         %IdentityProvider{} = provider,
         %LinkRequest{} = request,
         %Subject{} = subject,
         repo
       ) do
    with :ok <- ensure_request_matches_current_namespace(provider, request),
         :ok <- ensure_matched_request_has_trusted_email(provider, request),
         {:ok, approver_role} <- ensure_approver_still_holds_authority(provider, subject, repo),
         :ok <-
           ensure_link_target_within_authority(request, provider, approver_role, subject, repo),
         %Accounts.Membership{} = member <- peek_matched_membership(provider, request) do
      {:ok, member}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :matched_user_unavailable}
    end
  end

  # The migration repairs historical rows, but approval is the durable trust
  # boundary: a stale node or restored database must not turn raw OIDC display
  # email into an existing-member credential binding. SCIM email is asserted by
  # the directory and remains the separate authoritative path.
  defp ensure_matched_request_has_trusted_email(
         %IdentityProvider{} = provider,
         %LinkRequest{source: :oidc, claims: claims}
       ) do
    if is_binary(verified_email(provider, claims)) do
      :ok
    else
      {:error, :unverified_email}
    end
  end

  defp ensure_matched_request_has_trusted_email(
         %IdentityProvider{},
         %LinkRequest{source: :scim}
       ),
       do: :ok

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
  defp link_identity(
         %IdentityProvider{} = provider,
         member,
         current_identity,
         %LinkRequest{} = request,
         repo
       ) do
    case current_identity do
      %UserIdentity{scim_deleted_at: %DateTime{}} ->
        {:error, :scim_resource_retired}

      %UserIdentity{} = identity ->
        identity
        |> rebind_changeset(request)
        |> UserIdentity.Changeset.bind_membership(member)
        |> repo.update()

      nil ->
        # OIDC does not get to reserve the directory namespace. A SCIM request
        # owns both values; an OIDC-only row stays adoptable until the directory
        # later claims it through `adopt_scim_external_id/2`.
        attrs = %{
          provider_identifier: request.provider_identifier,
          scim_external_id: scim_external_id(request),
          claims: request.claims,
          created_by: :admin,
          provisioned_via: :manual
        }

        provider.account_id
        |> UserIdentity.Changeset.create(provider.id, member, attrs)
        |> repo.insert()
    end
  end

  defp scim_external_id(%LinkRequest{source: :scim, provider_identifier: identifier}),
    do: identifier

  defp scim_external_id(%LinkRequest{}), do: nil

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

  # The Member's own identity for this connection; it holds at most one live.
  defp peek_member_identity(%IdentityProvider{} = provider, membership_id),
    do: provider |> member_identity_query(membership_id) |> Repo.peek()

  # The same row, locked for the rebind that follows it.
  defp lock_member_identity(%IdentityProvider{} = provider, membership_id, repo) do
    provider
    |> member_identity_query(membership_id)
    |> UserIdentity.Query.lock_for_update()
    |> repo.peek()
  end

  defp member_identity_query(%IdentityProvider{} = provider, membership_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider.id)
    |> UserIdentity.Query.by_membership_id(membership_id)
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
  regional, per-customer, or the kind is unknown. Takes the atom or its string form.
  """
  def provider_fixed_issuer(kind) do
    case ProviderKind.fetch(kind) do
      {:ok, metadata} -> metadata.fixed_issuer
      :error -> nil
    end
  end

  @doc "Supported region names and exact issuer URLs for a provider kind."
  def provider_issuer_regions(kind), do: ProviderKind.issuer_regions(kind)

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
  # SEE or TAKE AWAY. Expiry makes OIDC and SCIM credentials dormant, but an owner
  # must still be able to retire stored trust and configuration. Reads and exact
  # cleanup operations therefore check permission alone.
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

  defp ensure_can_update_provider(subject, true), do: ensure_can_manage_sso(subject)
  defp ensure_can_update_provider(subject, false), do: ensure_can_configure_sso(subject)

  defp provider_disable_only?(attrs) when is_map(attrs) do
    case Map.to_list(attrs) do
      [{key, value}] when key in [:enabled, "enabled"] and value in [false, "false"] -> true
      _ -> false
    end
  end

  defp provider_disable_only?(_attrs), do: false

  defp maybe_put_sso_entitlement(multi, _account_id, true), do: multi

  defp maybe_put_sso_entitlement(multi, account_id, false),
    do: put_sso_entitlement(multi, account_id)

  defp ensure_can_configure_directory_sync(%Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_sso_permission()) do
      if Billing.directory_sync_available?(account),
        do: :ok,
        else: {:error, :directory_sync_not_available}
    end
  end

  defp put_sso_entitlement(multi, account_id) do
    Multi.run(multi, :sso_entitlement, fn repo, _changes ->
      if Billing.sso_available_for_account_id?(account_id, repo: repo, lock?: true),
        do: {:ok, :available},
        else: {:error, :sso_not_available}
    end)
  end

  defp put_directory_sync_entitlement(multi, account_id) do
    Multi.run(multi, :directory_sync_entitlement, fn repo, _changes ->
      if Billing.directory_sync_available_for_account_id?(account_id,
           repo: repo,
           lock?: true
         ),
         do: {:ok, :available},
         else: {:error, :directory_sync_not_available}
    end)
  end

  # -- SCIM (directory sync) ---------------------------------------------------
  #
  # The wire implementation moved to Emisar.SSO.SCIM; these keep the boundary the
  # SCIM controllers call. AGENTS.md §1.4 lists this whole family as the internal
  # exception that carries no %Subject{} — authenticate_scim_token/1 resolves the
  # per-provider `ems-` bearer, and every later call is scoped by the
  # %IdentityProvider{} it returns.

  @doc "Internal — resolves a per-provider `ems-` SCIM bearer to its provider."
  defdelegate authenticate_scim_token(raw), to: SCIM

  @doc "Internal — SCIM provisions a user into this provider's account."
  defdelegate scim_provision_user(provider, attrs), to: SCIM

  @doc "Internal — SCIM replaces a provisioned user's attributes."
  defdelegate scim_update_user(provider, id, update), to: SCIM

  @doc "Internal — retires one provisioned SCIM User resource."
  defdelegate scim_delete_user(provider, id), to: SCIM

  @doc "Internal — SCIM applies a PATCH operation list to a provisioned user."
  defdelegate scim_patch_user(provider, id, operations), to: SCIM

  @doc "Internal — reads one provisioned user by its server-issued SCIM id."
  defdelegate scim_fetch_user(provider, id), to: SCIM

  @doc "Internal — lists provisioned users, filtered and paged per SCIM."
  def scim_list_users(provider, opts \\ []), do: SCIM.scim_list_users(provider, opts)

  @doc "Internal — lists synced groups, filtered and paged per SCIM."
  def scim_list_groups(provider, opts \\ []), do: SCIM.scim_list_groups(provider, opts)

  @doc "Internal — reads one synced group by its server-issued SCIM id."
  defdelegate scim_fetch_group(provider, id), to: SCIM

  @doc "Internal — creates or replaces a synced group."
  defdelegate scim_upsert_group(provider, attrs), to: SCIM

  @doc "Internal — replaces a synced group by its server-issued SCIM id."
  defdelegate scim_replace_group(provider, id, attrs), to: SCIM

  @doc "Internal — removes a synced group and recomputes affected members."
  defdelegate scim_delete_group(provider, id), to: SCIM

  @doc "Internal — applies a PATCH operation list to a synced group."
  defdelegate scim_patch_group(provider, id, operations), to: SCIM

  @doc "Validates a SCIM group display name, or returns the reason it is invalid."
  defdelegate validate_scim_group_display(display), to: SCIM
end
