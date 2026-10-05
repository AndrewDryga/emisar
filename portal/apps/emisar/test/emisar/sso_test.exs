defmodule Emisar.SSOTest do
  @moduledoc """
  The SSO authorization boundary — the context's primary test: every public
  function has its own `describe "fun/arity"`, in `sso.ex` order. Covers the
  enterprise+permission-gated provider/group/link config, the pre-Subject
  sign-in discovery + relying-party login core (identity resolution strictly by
  `(provider, sub)`, never email; JIT provisioning; the verified-email rule §9
  C2/R6; the domain gate H1; the per-provider MFA toggle N2), and the
  provider-scoped SCIM directory-sync lifecycle (no `%Subject{}` — the bearer's
  provider-scope IS the authz, so the backstop is the provider-account scope).

  The `oidcc` protocol layer is stubbed (`StubOIDC`) so these exercise the real
  resolution/JIT/gate logic with canned claims and no live IdP.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Crypto, Repo, RequestContext, SSO}
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Auth.UserToken
  alias Emisar.Fixtures
  alias Emisar.SSO.{DirectoryGroup, DirectoryGroupMember, GroupRoleMapping}
  alias Emisar.SSO.{GroupRunnerAccessMapping, IdentityProvider, LinkRequest}
  alias Emisar.SSO.{SCIMUser, SCIMUserUpdate, UserIdentity}

  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts) do
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    # The test supplies the validated claims via `params["_claims"]`.
    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, params, _stashed) do
      claims = params["_claims"] || %{}
      {:ok, %{identifier: claims["sub"], claims: claims}}
    end

    # Discovery for test_provider/2: a sentinel issuer simulates an unreachable
    # IdP; every other (already SSRF-validated) issuer "discovers" cleanly.
    @impl Emisar.SSO.OIDC
    def discover(%{issuer: "https://unreachable.test"}), do: {:error, :discovery_failed}

    def discover(%{issuer: issuer}) do
      {:ok,
       %{
         authorization_endpoint: issuer <> "/authorize",
         token_endpoint: issuer <> "/token",
         userinfo_endpoint: nil,
         jwks_uri: issuer <> "/jwks"
       }}
    end
  end

  defmodule RecordingResetOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, opts) do
      send(self(), {:reset_oidc_begin_options, opts})
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, params, _stashed) do
      claims = params["_claims"] || %{}
      {:ok, %{identifier: claims["sub"], claims: claims}}
    end

    @impl Emisar.SSO.OIDC
    def discover(provider), do: StubOIDC.discover(provider)
  end

  defmodule IdentifierClaimOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(provider, opts), do: StubOIDC.begin_authorization(provider, opts)

    @impl Emisar.SSO.OIDC
    def verify_callback(provider, params, _stashed) do
      claims = params["_claims"] || %{}
      identifier = claims[Atom.to_string(provider.identifier_claim)]
      {:ok, %{identifier: identifier, claims: claims}}
    end

    @impl Emisar.SSO.OIDC
    def discover(provider), do: StubOIDC.discover(provider)
  end

  defmodule RecordingDiscoveryOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(provider, opts) do
      send(self(), {:oidc_begin, provider.id})
      StubOIDC.begin_authorization(provider, opts)
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(provider, params, stashed),
      do: StubOIDC.verify_callback(provider, params, stashed)

    @impl Emisar.SSO.OIDC
    def discover(provider) do
      send(self(), {:oidc_discover, provider.issuer})
      StubOIDC.discover(provider)
    end
  end

  defmodule RecordingSessionDisconnector do
    def disconnect_live_sessions(topics) do
      owner = Emisar.Config.fetch_env!(:emisar, :scim_delete_disconnect_test_pid)
      send(owner, {:scim_delete_disconnect, topics, Emisar.Repo.in_transaction?()})
    end
  end

  defmodule BarrierOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts), do: {:error, :not_used}

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, %{"_barrier" => {owner, ref}, "_claims" => claims}, _stash) do
      send(owner, {:oidc_claims_verified, ref})

      receive do
        {:release_oidc_callback, ^ref} ->
          {:ok, %{identifier: claims["sub"], claims: claims}}
      end
    end
  end

  @redirect_uri "https://portal.test/sign_in/sso/callback"

  setup do
    Emisar.Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
    :ok
  end

  defp enterprise_owner do
    Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
  end

  # Thin wrapper over the shared fixture: this file's tests pass the account
  # struct first and often pin `name: "Okta"` implicitly.
  defp provider_fixture(account, attrs \\ %{}) do
    attrs = attrs |> Map.new() |> Map.put_new(:name, "Okta") |> Map.put(:account_id, account.id)
    Fixtures.SSO.create_identity_provider(attrs)
  end

  defp callback(claims), do: %{"_claims" => claims}

  defp callback_after_verified(provider, claims, while_verified) do
    Emisar.Config.put_override(:emisar, :sso_oidc_impl, BarrierOIDC)
    ref = make_ref()
    owner = self()

    task =
      Task.async(fn ->
        SSO.complete_auth(
          provider,
          %{"_barrier" => {owner, ref}, "_claims" => claims},
          %{},
          %RequestContext{}
        )
      end)

    assert_receive {:oidc_claims_verified, ^ref}, 5_000

    try do
      during = while_verified.()
      send(task.pid, {:release_oidc_callback, ref})
      {during, Task.await(task, 10_000)}
    after
      send(task.pid, {:release_oidc_callback, ref})
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  defp link_requests(provider_id) do
    LinkRequest.Query.all()
    |> LinkRequest.Query.by_provider_id(provider_id)
    |> Repo.all()
  end

  # Drive a manual-provider sign-in for an unknown sub → the captured request.
  defp capture_request(provider, claims) do
    {:pending, %LinkRequest{} = request} =
      SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

    request
  end

  # A held sign-in by a subject the approver's own IdP made up, carrying the
  # target's verified address.
  defp capture_matched_request(provider, %Accounts.Membership{} = target) do
    request =
      capture_request(provider, %{
        "sub" => "okta|impersonator-#{System.unique_integer([:positive])}",
        "email" => target.email,
        "email_verified" => true
      })

    assert request.matched_membership_id == target.id
    request
  end

  defp scoped_admin(account, %RunnerAccess{} = access) do
    Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    |> Fixtures.Memberships.force_runner_access(access)
    |> Fixtures.Subjects.subject_for()
  end

  # Accept a pending invitation the way the proved code does, without a session.
  defp accept_invitation(invitation_token, email) do
    {:ok, ^email, intent} =
      Accounts.prepare_invitation_acceptance(invitation_token, %{"display_name" => "Accepted"})

    {:ok, %{accepted: accepted}} =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(intent.account_id, repo: repo)
      end)
      |> Accounts.put_invitation_acceptance(intent, email)
      |> Repo.commit_multi(after_commit: &Accounts.after_membership_activation_committed/1)

    accepted
  end

  defp namespace(%IdentityProvider{} = provider),
    do: {provider.issuer, provider.client_id, provider.identifier_claim}

  defp member_identities(%Accounts.Membership{} = member) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_membership_id(member.id)
    |> Repo.all()
  end

  defp session_count(%Accounts.Membership{} = member) do
    UserToken.Query.by_membership(member.account_id, member.id)
    |> UserToken.Query.by_context("session")
    |> Repo.aggregate(:count)
  end

  # A Member's session minted through the real SSO sign-in for `identity`.
  defp sso_session(member, identity, provider) do
    {:ok, raw, _mfa} =
      Auth.complete_sso_sign_in(
        member,
        identity,
        provider,
        Crypto.random_secret(),
        %RequestContext{}
      )

    {:ok, session} = Auth.fetch_session_by_token(raw, provider.account_id)
    {raw, session}
  end

  # The Subject of a Member acting through an SSO session at `provider`.
  defp provider_subject(member, provider) do
    identity =
      Fixtures.SSO.create_user_identity(
        account_id: provider.account_id,
        provider_id: provider.id,
        membership: member
      )

    {raw, _session} = sso_session(member, identity, provider)
    Fixtures.Subjects.subject_for(member, session: raw)
  end

  defp viewer_in(account) do
    viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: :viewer)

    Fixtures.Subjects.subject_for(viewer)
  end

  # A SCIM-enabled enterprise provider + its owner subject + account.
  defp scim_provider(provider_attrs \\ %{}) do
    {_owner, account, subject} = enterprise_owner()
    provider = provider_fixture(account, provider_attrs)
    {:ok, provider, raw_token} = SSO.enable_scim(provider, subject)
    %{provider: provider, token: raw_token, subject: subject, account: account}
  end

  defp scim_attrs(attrs) do
    Map.merge(
      %{external_id: "okta|#{System.unique_integer([:positive])}", full_name: "Dir User"},
      Map.new(attrs)
    )
  end

  # Provision a directory user and hand back its identity + membership.
  defp provision(provider, external_id, attrs \\ %{}) do
    attrs = scim_attrs(Map.merge(%{external_id: external_id}, Map.new(attrs)))

    {:ok, %{identity: identity, membership: membership}} =
      SSO.scim_provision_user(provider, attrs)

    %{identity: identity, membership: membership}
  end

  defp role_of(identity), do: Fixtures.SSO.identity_membership(identity).role

  defp map_group(provider, subject, external_group_id, role) do
    attrs = %{external_group_id: external_group_id, role: role}
    {:ok, mapping} = create_group_mapping_fixture(provider, attrs, subject)
    mapping
  end

  # Older context cases name their fixture group by externalId. Materialize the
  # real SCIM resource, then call the production API with its immutable UUID.
  # Denial paths never get fixture-side writes before their authorization check.
  defp create_group_mapping_fixture(provider, attrs, subject) do
    with true <- subject.account.id == provider.account_id,
         true <- SSO.subject_can_configure_directory_sync?(subject),
         {:ok, group} <- mapping_group_fixture(provider, attrs) do
      attrs = put_directory_group_id(attrs, group.id)
      SSO.create_group_mapping(provider, attrs, subject)
    else
      false -> SSO.create_group_mapping(provider, attrs, subject)
      {:error, :missing_group} -> SSO.create_group_mapping(provider, attrs, subject)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_group_runner_access_mapping_fixture(provider, attrs, subject) do
    with true <- subject.account.id == provider.account_id,
         true <- SSO.subject_can_configure_directory_sync?(subject),
         {:ok, group} <- mapping_group_fixture(provider, attrs) do
      attrs = put_directory_group_id(attrs, group.id)
      SSO.create_group_runner_access_mapping(provider, attrs, subject)
    else
      false -> SSO.create_group_runner_access_mapping(provider, attrs, subject)
      {:error, :missing_group} -> SSO.create_group_runner_access_mapping(provider, attrs, subject)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mapping_group_fixture(provider, attrs) do
    directory_group_id = attrs[:directory_group_id] || attrs["directory_group_id"]
    external_group_id = attrs[:external_group_id] || attrs["external_group_id"]

    cond do
      is_binary(directory_group_id) ->
        group =
          DirectoryGroup.Query.not_deleted()
          |> DirectoryGroup.Query.by_account_id(provider.account_id)
          |> DirectoryGroup.Query.by_provider_id(provider.id)
          |> DirectoryGroup.Query.by_id(directory_group_id)
          |> Repo.peek()

        if group, do: {:ok, group}, else: {:error, :missing_group}

      is_binary(external_group_id) ->
        fetch_or_create_mapping_group_fixture(provider, external_group_id, attrs)

      true ->
        {:error, :missing_group}
    end
  end

  defp put_directory_group_id(attrs, id) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: Map.put(attrs, "directory_group_id", id),
      else: Map.put(attrs, :directory_group_id, id)
  end

  defp fetch_or_create_mapping_group_fixture(provider, external_group_id, attrs) do
    group =
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_external_group_id(external_group_id)
      |> Repo.peek()

    if group do
      {:ok, group}
    else
      SSO.scim_upsert_group(provider, %{
        external_id: external_group_id,
        display: attrs[:external_group_display] || attrs["external_group_display"],
        member_ids: []
      })
    end
  end

  defp user_resource_id(provider, external_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> Repo.fetch!(UserIdentity.Query)
    |> Map.fetch!(:id)
  end

  defp group_resource_id(provider, external_group_id) do
    DirectoryGroup.Query.not_deleted()
    |> DirectoryGroup.Query.by_provider_id(provider.id)
    |> DirectoryGroup.Query.by_external_group_id(external_group_id)
    |> Repo.fetch!(DirectoryGroup.Query)
    |> Map.fetch!(:id)
  end

  defp create_group_resource(provider, external_group_id) do
    {:ok, group} =
      SSO.scim_upsert_group(provider, %{external_id: external_group_id, member_ids: []})

    group.id
  end

  defp members_op(verb, ids),
    do: %{"op" => verb, "path" => "members", "value" => Enum.map(ids, &%{"value" => &1})}

  # The `replace` with `path: "displayName"` and a bare string, one of the two
  # rename spellings the reducer accepts.
  defp rename_op(display), do: %{"op" => "replace", "path" => "displayName", "value" => display}

  # -- list_providers_for_account/2 ------------------------------------

  describe "list_providers_for_account/2" do
    test "lists the account's providers, name-ordered, for an enterprise admin" do
      {_owner, account, subject} = enterprise_owner()
      _b = provider_fixture(account, %{kind: :keycloak, name: "B-Keycloak"})
      _a = provider_fixture(account, %{kind: :okta, name: "A-Okta"})

      assert {:ok, providers, _meta} = SSO.list_providers_for_account(subject)
      assert Enum.map(providers, & &1.name) == ["A-Okta", "B-Keycloak"]
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      _provider = provider_fixture(account)

      assert SSO.list_providers_for_account(viewer_in(account)) == {:error, :unauthorized}
    end

    test "a downgraded plan still lists what it has — you can't retire what you can't see" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{})
      provider = provider_fixture(account)
      provider_id = provider.id

      assert {:ok, [%IdentityProvider{id: ^provider_id}], _meta} =
               SSO.list_providers_for_account(subject)
    end

    test "is account-scoped — B never sees A's providers" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      _provider = provider_fixture(account_a)

      assert {:ok, [], _meta} = SSO.list_providers_for_account(sb)
    end
  end

  # -- list_provider_facts/2 -------------------------------------------

  describe "list_provider_facts/2" do
    test "returns presentation facts, name-ordered, and no raw configuration" do
      {_owner, account, subject} = enterprise_owner()
      _b = provider_fixture(account, %{kind: :keycloak, name: "B-Keycloak", enabled: false})
      _a = provider_fixture(account, %{kind: :okta, name: "A-Okta"})

      assert {:ok, [first, second], _meta} = SSO.list_provider_facts(subject)
      assert Enum.map([first, second], & &1.name) == ["A-Okta", "B-Keycloak"]
      assert first.enabled?
      refute second.enabled?

      assert Map.keys(first) |> Enum.sort() ==
               ~w[directory_sync? enabled? id identifier_claim last_synced_at name]a
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      _provider = provider_fixture(account)

      assert SSO.list_provider_facts(viewer_in(account)) == {:error, :unauthorized}
    end

    test "is account-scoped — B never sees A's connections" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      _provider = provider_fixture(account_a)

      assert {:ok, [], _meta} = SSO.list_provider_facts(sb)
    end
  end

  # -- provider_facts/1 ------------------------------------------------

  describe "provider_facts/1" do
    test "projects identity, enablement, and directory-sync state" do
      %{provider: provider} = scim_provider()

      facts = SSO.provider_facts(provider)

      assert facts.id == provider.id
      assert facts.name == provider.name
      assert facts.enabled?
      assert facts.directory_sync?
      assert facts.last_synced_at == provider.scim_last_seen_at
      assert facts.identifier_claim == :sub
    end

    test "an OIDC-only connection reports no directory sync" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: false})

      facts = SSO.provider_facts(provider)

      refute facts.enabled?
      refute facts.directory_sync?
      assert facts.last_synced_at == nil
    end
  end

  # -- fetch_account_connection_facts/1 --------------------------------

  describe "fetch_account_connection_facts/1" do
    test "counts the account's enabled connections" do
      {_owner, account, subject} = enterprise_owner()
      _disabled = provider_fixture(account, %{kind: :keycloak, enabled: false})

      assert SSO.fetch_account_connection_facts(subject) ==
               {:ok, %{enabled?: false, enabled_count: 0}}

      _enabled = provider_fixture(account, %{kind: :okta, enabled: true})

      assert SSO.fetch_account_connection_facts(subject) ==
               {:ok, %{enabled?: true, enabled_count: 1}}
    end

    test "a viewer holds the posture permission without manage_sso" do
      {_owner, account, _owner_subject} = enterprise_owner()
      _provider = provider_fixture(account, %{enabled: true})
      viewer = viewer_in(account)

      assert SSO.fetch_account_connection_facts(viewer) ==
               {:ok, %{enabled?: true, enabled_count: 1}}

      assert SSO.list_provider_facts(viewer) == {:error, :unauthorized}
    end

    test "an API client holds no posture permission" do
      {_owner, account, _subject} = enterprise_owner()

      api_client =
        Fixtures.Subjects.build_subject(
          account: account,
          role: :api_client,
          permissions: Emisar.Auth.Permissions.for_role(:api_client)
        )

      assert SSO.fetch_account_connection_facts(api_client) == {:error, :unauthorized}
    end

    test "is account-scoped — A's enabled connection doesn't count for B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      _provider = provider_fixture(account_a, %{enabled: true})

      assert SSO.fetch_account_connection_facts(sb) ==
               {:ok, %{enabled?: false, enabled_count: 0}}
    end
  end

  # -- member_directory_facts/2 ----------------------------------------

  describe "member_directory_facts/2" do
    test "attributes a synced member to their connection" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|alice")

      assert {:ok, facts} = SSO.member_directory_facts([identity.membership_id], subject)
      assert Map.keys(facts) == [identity.membership_id]
      member = facts[identity.membership_id]
      assert member.directory_managed?
      assert member.identity.provider_id == provider.id
      assert member.identity.provider_name == provider.name
      assert member.identity.provisioned_via == :scim
    end

    test "several identities resolve deterministically — directory-managed first" do
      %{provider: scim, account: account, subject: subject} = scim_provider()
      %{identity: identity} = provision(scim, "okta|alice")

      oidc =
        provider_fixture(account, %{kind: :keycloak, name: "A-Keycloak", enabled: true})

      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: oidc.id,
        membership: Fixtures.SSO.identity_membership(identity)
      )

      assert {:ok, facts} = SSO.member_directory_facts([identity.membership_id], subject)
      member = facts[identity.membership_id]

      # A-Keycloak sorts first by name, but directory sync outranks the name.
      assert member.directory_managed?
      assert member.identity.provider_id == scim.id
    end

    test "turning directory sync off changes the answer for an already-read member" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|bob")

      assert {:ok, %{} = before} = SSO.member_directory_facts([identity.membership_id], subject)
      assert before[identity.membership_id].directory_managed?

      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert {:ok, %{} = after_disable} =
               SSO.member_directory_facts([identity.membership_id], subject)

      refute after_disable[identity.membership_id].directory_managed?
      assert after_disable[identity.membership_id].identity.provider_id == provider.id
    end

    test "a deleted connection drops the attribution entirely" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|carol")

      assert {:ok, facts} = SSO.member_directory_facts([identity.membership_id], subject)
      assert Map.has_key?(facts, identity.membership_id)

      {:ok, _provider} = SSO.delete_provider(provider, subject)

      assert SSO.member_directory_facts([identity.membership_id], subject) == {:ok, %{}}
    end

    test "the provider join matches the identity's own account" do
      %{provider: provider, account: account, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|dave")

      # Another account's connection sharing the id space must never resolve:
      # re-point the identity at it and the join drops the row.
      {_ub, account_b, _sb} = enterprise_owner()
      foreign = provider_fixture(account_b, %{kind: :okta, name: "Foreign"})

      {1, _} =
        UserIdentity.Query.all()
        |> UserIdentity.Query.by_id(identity.id)
        |> Repo.update_all(set: [provider_id: foreign.id])

      assert SSO.member_directory_facts([identity.membership_id], subject) == {:ok, %{}}
      assert account.id != account_b.id
    end

    test "a viewer (no manage_sso) is denied" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|erin")

      assert SSO.member_directory_facts([identity.membership_id], viewer_in(account)) ==
               {:error, :unauthorized}
    end

    test "is account-scoped — B never sees A's synced members" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|frank")
      {_ub, _account_b, sb} = enterprise_owner()

      assert SSO.member_directory_facts([identity.membership_id], sb) == {:ok, %{}}
    end
  end

  describe "member_profile_directory_managed?/2" do
    test "true for a member synced under a SCIM-enabled provider" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|managed")

      assert SSO.member_profile_directory_managed?(account.id, identity.membership_id)
    end

    test "false once directory sync is disabled — the lock lifts with SCIM" do
      %{provider: provider, account: account, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|unlocked")

      {:ok, _provider} = SSO.disable_scim(provider, subject)

      refute SSO.member_profile_directory_managed?(account.id, identity.membership_id)
    end

    test "false for a member with no directory identity" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      refute SSO.member_profile_directory_managed?(account.id, member.id)
    end
  end

  # -- list_synced_users/3 --------------------------------------------

  describe "list_refused_changes/2" do
    test "lists this connection's refusals from the last seven days, newest first" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
      %{identity: older} = provision(provider, "okta|older", %{email: "older@acme.test"})
      %{identity: newer} = provision(provider, "okta|newer", %{email: "newer@acme.test"})
      %{identity: stale} = provision(provider, "okta|stale", %{email: "stale@acme.test"})
      title = [%{"op" => "replace", "path" => "title", "value" => "CTO"}]

      assert SSO.scim_patch_user(provider, stale.id, title) == {:error, :unsupported_scim_patch}
      assert SSO.scim_patch_user(provider, older.id, title) == {:error, :unsupported_scim_patch}
      assert SSO.scim_patch_user(provider, newer.id, title) == {:error, :unsupported_scim_patch}
      backdate_refusal(account.id, "stale@acme.test", hours: 8 * 24)
      backdate_refusal(account.id, "older@acme.test", hours: 2)

      # A second connection in the same workspace keeps its own refusals.
      other = provider_fixture(account, %{kind: :jumpcloud, name: "JumpCloud"})
      {:ok, other, _token} = SSO.enable_scim(other, subject)
      %{identity: elsewhere} = provision(other, "jc|elsewhere", %{email: "elsewhere@acme.test"})
      assert SSO.scim_patch_user(other, elsewhere.id, title) == {:error, :unsupported_scim_patch}

      assert {:ok, refused} = SSO.list_refused_changes(provider, subject)

      assert Enum.map(refused, &{&1.resource, &1.change, &1.reason}) == [
               {"newer@acme.test", :update_user, :unsupported_scim_patch},
               {"older@acme.test", :update_user, :unsupported_scim_patch}
             ]
    end

    test "a viewer (no manage_sso) is denied" do
      %{provider: provider, account: account} = scim_provider()

      assert SSO.list_refused_changes(provider, viewer_in(account)) == {:error, :unauthorized}
    end

    test "another account's subject can't read the provider (:not_found)" do
      %{provider: provider} = scim_provider()
      {_ub, _account_b, sb} = enterprise_owner()

      assert SSO.list_refused_changes(provider, sb) == {:error, :not_found}
    end
  end

  describe "list_synced_users/3" do
    test "returns the provider's provisioned members with the member preloaded" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|alice")

      assert {:ok, [synced], metadata} = SSO.list_synced_users(provider, subject)
      assert synced.id == identity.id
      assert synced.membership.id == identity.membership_id
      assert metadata.count == 1
    end

    test "pages the roster, newest first, with the whole count in the metadata" do
      # A directory is exactly what makes this list long, so it cannot come back
      # whole: the connection page held every identity plus a preloaded user in
      # one socket's assigns.
      %{provider: provider, subject: subject} = scim_provider()

      for n <- 1..5, do: provision(provider, "okta|paged-#{n}")

      assert {:ok, first_page, metadata} =
               SSO.list_synced_users(provider, subject, page: [limit: 2])

      assert length(first_page) == 2
      assert metadata.count == 5

      assert {:ok, second_page, _metadata} =
               SSO.list_synced_users(provider, subject, page: [cursor: metadata.next_page_cursor])

      assert length(second_page) == 3
      assert hd(first_page).scim_external_id == "okta|paged-5"
      assert List.last(second_page).scim_external_id == "okta|paged-1"

      all_ids = Enum.map(first_page ++ second_page, & &1.id)
      assert length(Enum.uniq(all_ids)) == 5
    end

    test "a viewer (no manage_sso) is denied" do
      %{provider: provider, account: account} = scim_provider()

      assert SSO.list_synced_users(provider, viewer_in(account)) == {:error, :unauthorized}
    end

    test "another account's subject can't read the provider (:not_found)" do
      %{provider: provider} = scim_provider()
      {_ub, _account_b, sb} = enterprise_owner()

      assert SSO.list_synced_users(provider, sb) == {:error, :not_found}
    end
  end

  # -- provider_sync_stats/1 ------------------------------------------

  describe "provider_sync_stats/1" do
    test "counts synced users and distinct synced groups (NOT group→role mappings)" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity_a} = provision(provider, "okta|a")
      %{identity: identity_b} = provision(provider, "okta|b")

      # The directory pushes TWO groups over SCIM...
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-ops", member_ids: [identity_a.id]})

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-eng",
          member_ids: [identity_a.id, identity_b.id]
        })

      # ...and the admin maps only ONE of them. The tally counts the 2 groups the
      # directory synced, not the 1 group→role mapping configured.
      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, stats} = SSO.provider_sync_stats(subject)
      assert stats[provider.id] == %{users: 2, groups: 2}
    end

    test "a viewer (no manage_sso) is denied" do
      %{account: account} = scim_provider()

      assert SSO.provider_sync_stats(viewer_in(account)) == {:error, :unauthorized}
    end

    test "is account-scoped — B's stats never include A's connection" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|a")
      # A synced group for A too — the group tally is account-scoped via the
      # DirectoryGroupMember for_subject clause, so B never sees A's group counts.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-a", member_ids: [identity.id]})

      {_ub, _account_b, sb} = enterprise_owner()

      assert {:ok, stats} = SSO.provider_sync_stats(sb)
      refute Map.has_key?(stats, provider.id)
    end
  end

  # -- fetch_provider_by_id/2 ------------------------------------------

  describe "fetch_provider_by_id/2" do
    test "resolves a provider in the subject's account" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{id: id}} = SSO.fetch_provider_by_id(provider.id, subject)
      assert id == provider.id
    end

    test "a malformed (non-UUID) id is :not_found, never a crash" do
      {_owner, _account, subject} = enterprise_owner()

      assert SSO.fetch_provider_by_id("not-a-uuid", subject) == {:error, :not_found}
    end

    test "a viewer is denied (:unauthorized)" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert SSO.fetch_provider_by_id(provider.id, viewer_in(account)) == {:error, :unauthorized}
    end

    test "cross-account: B cannot fetch A's provider (:not_found)" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert SSO.fetch_provider_by_id(provider.id, sb) == {:error, :not_found}
    end
  end

  # -- change_provider/3 -----------------------------------------------

  describe "change_provider/3" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      %{account: account, subject: subject}
    end

    test "builds a provider config changeset from attrs (the phx-change form)", %{
      subject: subject
    } do
      assert {:ok, changeset} =
               SSO.change_provider(%IdentityProvider{}, %{kind: :okta, name: "Okta"}, subject)

      assert changeset.changes == %{
               default_pack_scope: [],
               default_runner_scope: [],
               kind: :okta,
               name: "Okta"
             }
    end

    test "defaults to an empty provider + no attrs", %{subject: subject} do
      assert {:ok, %Ecto.Changeset{data: %IdentityProvider{}}} = SSO.change_provider(subject)
    end

    test "a subject that can't manage single sign-on gets no form" do
      {_owner, account, _subject} = enterprise_owner()
      viewer_subject = viewer_in(account)

      assert SSO.change_provider(viewer_subject) == {:error, :unauthorized}

      assert SSO.change_provider(%IdentityProvider{}, %{name: "Okta"}, viewer_subject) ==
               {:error, :unauthorized}
    end

    test "surfaces validation errors (a non-https issuer) for inline display", %{
      subject: subject
    } do
      assert {:ok, changeset} =
               SSO.change_provider(%IdentityProvider{}, %{issuer: "http://idp.test"}, subject)

      assert "must be an https URL" in errors_on(changeset).issuer
    end

    test "a new connection takes its kind's fixed issuer and identifier claim", %{
      subject: subject
    } do
      {:ok, google} =
        SSO.change_provider(%IdentityProvider{}, %{"kind" => "google_workspace"}, subject)

      {:ok, jumpcloud} =
        SSO.change_provider(%IdentityProvider{}, %{"kind" => "jumpcloud"}, subject)

      {:ok, entra} = SSO.change_provider(%IdentityProvider{}, %{"kind" => "entra"}, subject)
      {:ok, okta} = SSO.change_provider(%IdentityProvider{}, %{"kind" => "okta"}, subject)

      assert Ecto.Changeset.get_field(google, :issuer) == "https://accounts.google.com"
      assert Ecto.Changeset.get_field(jumpcloud, :issuer) == nil
      assert Ecto.Changeset.get_field(entra, :identifier_claim) == :oid
      assert Ecto.Changeset.get_field(okta, :identifier_claim) == :sub
      # A per-customer issuer is the operator's to type.
      assert Ecto.Changeset.get_field(okta, :issuer) == nil
    end

    test "a fixed issuer we prefilled is cleared when the kind switches away from it", %{
      subject: subject
    } do
      params = %{"kind" => "okta", "issuer" => "https://accounts.google.com"}

      assert {:ok, changeset} = SSO.change_provider(%IdentityProvider{}, params, subject)
      assert "can't be blank" in errors_on(changeset).issuer
    end

    test "regional issuer selections survive validation but clear when the kind changes", %{
      subject: subject
    } do
      for issuer <- [
            "https://oauth.id.jumpcloud.com/",
            "https://oauth.id.eu.jumpcloud.com/",
            "https://oauth.id.in.jumpcloud.com/"
          ] do
        params = %{"kind" => "jumpcloud", "issuer" => issuer}
        assert {:ok, selected} = SSO.change_provider(%IdentityProvider{}, params, subject)
        assert selected.changes.issuer == issuer

        params = Map.put(params, "kind", "okta")
        assert {:ok, switched} = SSO.change_provider(%IdentityProvider{}, params, subject)
        assert "can't be blank" in errors_on(switched).issuer
      end
    end

    test "an existing connection's changeset never carries its stored client secret", %{
      account: account,
      subject: subject
    } do
      provider = provider_fixture(account, %{client_secret: "stored-secret-value"})

      assert {:ok, changeset} = SSO.change_provider(provider, %{"name" => "Renamed"}, subject)
      assert changeset.data.client_secret == nil

      # A secret being typed still renders — it rides in `changes`, not in data.
      assert {:ok, typed} =
               SSO.change_provider(provider, %{"client_secret" => "being-typed"}, subject)

      assert typed.changes == %{client_secret: "being-typed"}
    end

    test "an untouched edit form seeds the picker from the stored scope", %{
      account: account,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      provider =
        provider_fixture(account, %{
          default_runner_access_mode: :restricted,
          default_runner_scope_groups: ["database"]
        })

      assert {:ok, changeset} = SSO.change_provider(provider, %{}, subject)

      assert Ecto.Changeset.get_field(changeset, :default_runner_scope) == ["group:database"]
      assert Ecto.Changeset.get_field(changeset, :default_runner_scope_groups) == ["database"]
    end

    test "an edit derives from the PERSISTED kind — a submitted kind is ignored", %{
      account: account,
      subject: subject
    } do
      google = provider_fixture(account, %{kind: :google_workspace})

      params = %{"kind" => "okta", "issuer" => "https://evil.test", "name" => "Renamed"}
      assert {:ok, changeset} = SSO.change_provider(google, params, subject)

      # kind is create-only, and Google's issuer is not an editable field at all.
      assert changeset.changes == %{name: "Renamed"}
    end

    test "an unrelated edit leaves a stored identifier claim alone", %{
      account: account,
      subject: subject
    } do
      provider = provider_fixture(account, %{kind: :keycloak, identifier_claim: :oid})

      assert {:ok, changeset} = SSO.change_provider(provider, %{"name" => "Renamed"}, subject)

      # Narrowing the claim list must not retype a connection people already
      # sign in through — the form tells the truth about what is stored.
      assert changeset.changes == %{name: "Renamed"}
      assert Ecto.Changeset.get_field(changeset, :identifier_claim) == :oid
    end

    test "another account cannot build an existing provider's form", %{account: account} do
      provider = provider_fixture(account)
      {_owner, _other_account, other_subject} = enterprise_owner()

      assert SSO.change_provider(provider, %{}, other_subject) == {:error, :not_found}
    end
  end

  # -- change_group_mapping/2 ------------------------------------------

  describe "change_group_mapping/2" do
    test "from a %IdentityProvider{} it's a CREATE changeset (account/provider from the provider)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      directory_group_id = Ecto.UUID.generate()

      changeset =
        SSO.change_group_mapping(provider, %{
          directory_group_id: directory_group_id,
          role: :operator
        })

      assert %Ecto.Changeset{data: %GroupRoleMapping{}} = changeset

      assert changeset.changes == %{
               account_id: account.id,
               directory_group_id: directory_group_id,
               provider_id: provider.id,
               role: :operator
             }
    end

    test "from a %GroupRoleMapping{} it's the inline EDIT changeset (only role)" do
      mapping = %GroupRoleMapping{external_group_id: "grp-1", role: :viewer}

      changeset = SSO.change_group_mapping(mapping, %{role: :admin})

      assert %Ecto.Changeset{data: %GroupRoleMapping{}} = changeset
      assert changeset.changes == %{role: :admin}
    end

    test "rejects an :owner role (sync can never grant owner — decision 7)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      directory_group_id = Ecto.UUID.generate()

      changeset =
        SSO.change_group_mapping(provider, %{
          directory_group_id: directory_group_id,
          role: :owner
        })

      assert "directory sync cannot grant owner" in errors_on(changeset).role
    end
  end

  describe "change_group_runner_access_mapping/3" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      %{account: account, provider: provider, subject: subject}
    end

    test "builds explicit create and update changesets", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      directory_group_id = Ecto.UUID.generate()

      create_attrs = %{
        directory_group_id: directory_group_id,
        runner_access_mode: :restricted,
        scope: ["group:db"]
      }

      assert {:ok, create} =
               SSO.change_group_runner_access_mapping(provider, create_attrs, subject)

      assert %Ecto.Changeset{data: %GroupRunnerAccessMapping{}} = create
      assert Ecto.Changeset.get_field(create, :account_id) == account.id
      assert Ecto.Changeset.get_field(create, :provider_id) == provider.id
      assert Ecto.Changeset.get_field(create, :runner_scope_groups) == ["db"]

      mapping = %GroupRunnerAccessMapping{
        account_id: account.id,
        runner_access_mode: :restricted
      }

      update_attrs = %{runner_access_mode: :all}

      assert {:ok, update} =
               SSO.change_group_runner_access_mapping(mapping, update_attrs, subject)

      assert update.changes == %{pack_scope: [], runner_access_mode: :all, scope: []}
    end

    test "an injected persisted array never becomes the grant", %{
      provider: provider,
      subject: subject
    } do
      attrs = %{
        directory_group_id: Ecto.UUID.generate(),
        runner_access_mode: :restricted,
        runner_scope_groups: ["db"]
      }

      assert {:ok, changeset} = SSO.change_group_runner_access_mapping(provider, attrs, subject)

      # Only the raw picker selection grants reach, and there was none.
      assert "is invalid" in errors_on(changeset).runner_access_mode
    end

    test "rejects selected access without a group or runner", %{
      provider: provider,
      subject: subject
    } do
      attrs = %{directory_group_id: Ecto.UUID.generate(), runner_access_mode: :restricted}

      assert {:ok, changeset} = SSO.change_group_runner_access_mapping(provider, attrs, subject)
      assert "is invalid" in errors_on(changeset).runner_access_mode
    end

    test "a subject that can't manage single sign-on gets no form", %{
      account: account,
      provider: provider
    } do
      viewer_subject = viewer_in(account)

      assert SSO.change_group_runner_access_mapping(provider, %{}, viewer_subject) ==
               {:error, :unauthorized}
    end

    test "another account cannot build a group runner-access form", %{
      account: account,
      provider: provider
    } do
      {_owner, _other_account, other_subject} = enterprise_owner()
      mapping = %GroupRunnerAccessMapping{account_id: account.id, provider_id: provider.id}

      assert SSO.change_group_runner_access_mapping(provider, %{}, other_subject) ==
               {:error, :not_found}

      assert SSO.change_group_runner_access_mapping(mapping, %{}, other_subject) ==
               {:error, :not_found}
    end
  end

  # -- configure_provider/2 --------------------------------------------

  describe "configure_provider/2 gating" do
    test "a malformed selection from a subject without manage_sso is still unauthorized" do
      {_owner, account, _subject} = enterprise_owner()

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        default_runner_access_mode: :restricted,
        default_runner_scope: ["crafted"]
      }

      assert SSO.configure_provider(attrs, viewer_in(account)) == {:error, :unauthorized}
    end

    test "a free account cannot configure SSO" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject(%{})

      assert SSO.configure_provider(%{kind: :okta, name: "Okta"}, subject) ==
               {:error, :sso_not_available}
    end

    test "a Team account can configure an OIDC provider — SSO is Team and up" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      assert {:ok, %IdentityProvider{}} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   client_secret: "secret"
                 },
                 subject
               )
    end

    test "a non-admin (no manage_sso) cannot configure SSO" do
      {_owner, account, _owner_subject} = enterprise_owner()
      viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: :viewer)

      viewer_subject = Fixtures.Subjects.subject_for(viewer)

      assert SSO.configure_provider(%{kind: :okta, name: "Okta"}, viewer_subject) ==
               {:error, :unauthorized}
    end

    test "an enterprise admin configures a provider" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:ok, %IdentityProvider{} = provider} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   client_secret: "secret"
                 },
                 subject
               )

      assert provider.kind == :okta
      assert provider.default_role == :viewer

      # Trusting the provider's MFA is a claim the operator makes deliberately.
      # It used to default ON, so a password-only OIDC server silently satisfied
      # the account's MFA requirement.
      refute provider.satisfies_mfa

      assert {:ok, [event], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_configured"]])

      assert event.payload["runner_access"] == %{
               "mode" => "none",
               "groups" => [],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }
    end

    test "rejects a default that names a runner in another account" do
      {_owner, _account, subject} = enterprise_owner()
      foreign_runner = Fixtures.Runners.create_runner()

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        default_runner_access_mode: :restricted,
        default_runner_scope: ["runner:#{foreign_runner.id}"]
      }

      assert {:error, changeset} = SSO.configure_provider(attrs, subject)
      assert "is invalid" in errors_on(changeset).default_runner_access_mode
      refute Repo.one(IdentityProvider)
    end

    test "a rejected create does not echo the typed client secret back" do
      {_owner, _account, subject} = enterprise_owner()
      foreign_runner = Fixtures.Runners.create_runner()

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        client_secret: "typed-idp-secret",
        default_runner_access_mode: :restricted,
        default_runner_scope: ["runner:#{foreign_runner.id}"]
      }

      assert {:error, changeset} = SSO.configure_provider(attrs, subject)
      assert "is invalid" in errors_on(changeset).default_runner_access_mode
      refute Map.has_key?(changeset.changes, :client_secret)
      refute Map.has_key?(changeset.params, "client_secret")
    end

    test "an injected persisted scope array is ignored, so it never becomes the default" do
      {_owner, account, subject} = enterprise_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        client_secret: "secret",
        default_runner_access_mode: :restricted,
        default_runner_scope_groups: ["database"],
        default_runner_scope_runner_ids: [runner.id]
      }

      assert {:error, changeset} = SSO.configure_provider(attrs, subject)
      assert "is invalid" in errors_on(changeset).default_runner_access_mode
      refute Repo.one(IdentityProvider)
    end

    test "a selected default is canonicalized: trimmed, deduplicated, sorted, group-covered" do
      {_owner, account, subject} = enterprise_owner()
      Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      covered = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      exact = Fixtures.Runners.create_runner(account_id: account.id, group: "web")

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        client_secret: "secret",
        default_runner_access_mode: :restricted,
        default_runner_scope: [
          "group:  database ",
          "group:database",
          "runner:#{covered.id}",
          "runner:#{exact.id}"
        ]
      }

      assert {:ok, provider} = SSO.configure_provider(attrs, subject)
      assert provider.default_runner_scope_groups == ["database"]
      # The covered runner's group already grants it; only the "web" one stays.
      assert provider.default_runner_scope_runner_ids == [exact.id]
    end

    test "switching a selected default back to none or all clears the stored scope" do
      {_owner, account, subject} = enterprise_owner()
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        client_secret: "secret",
        default_runner_access_mode: :restricted,
        default_runner_scope: ["group:database"]
      }

      assert {:ok, provider} = SSO.configure_provider(attrs, subject)

      for mode <- [:all, :none] do
        assert {:ok, updated} =
                 SSO.update_provider(
                   provider,
                   %{default_runner_access_mode: mode, default_runner_scope: ["group:database"]},
                   subject
                 )

        assert updated.default_runner_access_mode == mode
        assert updated.default_runner_scope_groups == []
        assert updated.default_runner_scope_runner_ids == []
      end
    end

    test "a stale selection is rejected on the mode field, leaving the connection untouched" do
      {_owner, account, subject} = enterprise_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      provider = provider_fixture(account)
      Fixtures.Runners.mark_deleted(runner)

      attrs = %{
        default_runner_access_mode: :restricted,
        default_runner_scope: ["group:database"]
      }

      assert {:error, changeset} = SSO.update_provider(provider, attrs, subject)
      assert "is invalid" in errors_on(changeset).default_runner_access_mode
      assert Ecto.Changeset.get_field(changeset, :default_runner_scope) == ["group:database"]
      assert Repo.reload!(provider).default_runner_access_mode == :none
    end

    test "a cross-account update with a malformed selection is still not_found" do
      {_owner, account, _subject} = enterprise_owner()
      {_other_user, _other_account, other_subject} = enterprise_owner()
      provider = provider_fixture(account)

      attrs = %{default_runner_access_mode: :restricted, default_runner_scope: ["crafted"]}

      assert SSO.update_provider(provider, attrs, other_subject) == {:error, :not_found}
    end

    test "a restricted admin cannot configure or update a broader provider default" do
      {_owner, account, owner_subject} = enterprise_owner()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      assert {:ok, _membership} =
               Accounts.update_membership_runner_access(
                 membership,
                 db_access,
                 owner_subject
               )

      admin_subject = Fixtures.Subjects.subject_for(membership)

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        default_runner_access_mode: :all
      }

      assert SSO.configure_provider(attrs, admin_subject) ==
               {:error, :runner_access_exceeds_subject}

      provider = provider_fixture(account)

      assert SSO.update_provider(
               provider,
               %{default_runner_access_mode: :all},
               admin_subject
             ) == {:error, :runner_access_exceeds_subject}
    end

    test "JumpCloud stores the selected region and starts disabled" do
      {_owner, account, subject} = enterprise_owner()

      assert :jumpcloud in SSO.identity_provider_kinds()

      for issuer <- [
            "https://oauth.id.jumpcloud.com/",
            "https://oauth.id.eu.jumpcloud.com/",
            "https://oauth.id.in.jumpcloud.com/"
          ] do
        attrs = Fixtures.SSO.identity_provider_attrs(kind: :jumpcloud, issuer: issuer)

        assert {:ok, provider} = SSO.configure_provider(attrs, subject)
        assert provider.kind == :jumpcloud
        assert provider.account_id == account.id
        assert provider.issuer == issuer
        refute provider.enabled
      end
    end

    test "JumpCloud requires a supported region rather than silently choosing one" do
      {_owner, _account, subject} = enterprise_owner()

      for issuer <- [nil, "", "https://idp.test", "https://accounts.google.com"] do
        attrs = Fixtures.SSO.identity_provider_attrs(kind: :jumpcloud, issuer: issuer)

        assert {:error, %Ecto.Changeset{} = changeset} = SSO.configure_provider(attrs, subject)
        assert Map.has_key?(errors_on(changeset), :issuer)
      end

      refute Repo.one(IdentityProvider)
    end

    test "the issuer must be an https URL" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:error, changeset} =
               SSO.configure_provider(
                 %{kind: :okta, name: "Okta", issuer: "http://idp.test", client_id: "cid"},
                 subject
               )

      assert "must be an https URL" in errors_on(changeset).issuer
    end

    test "a fixed-issuer kind stores its own issuer, whatever was submitted" do
      {_owner, _account, subject} = enterprise_owner()

      attrs = %{
        kind: :google_workspace,
        name: "Google",
        issuer: "https://evil.test",
        client_id: "cid",
        client_secret: "secret"
      }

      # Google serves one issuer for every customer, so it is an invariant of the
      # connection — not a console prefill a crafted request can step around.
      assert {:ok, provider} = SSO.configure_provider(attrs, subject)
      assert provider.issuer == "https://accounts.google.com"
    end

    test "the identifier claim comes from the kind — oid for Entra, sub elsewhere" do
      {_owner, _account, subject} = enterprise_owner()

      entra_attrs = %{
        kind: :entra,
        name: "Entra",
        issuer: "https://login.microsoftonline.com/tenant/v2.0",
        client_id: "cid",
        client_secret: "secret"
      }

      keycloak_attrs = %{
        kind: :keycloak,
        name: "Keycloak",
        issuer: "https://kc.test/realms/main",
        client_id: "cid",
        client_secret: "secret",
        identifier_claim: :oid
      }

      # Entra's `sub` is pairwise, so sign-in and directory sync only agree on
      # `oid`; every other provider joins on the OIDC-standard `sub`, and a
      # submitted claim doesn't get to pick a different namespace.
      assert {:ok, entra} = SSO.configure_provider(entra_attrs, subject)
      assert entra.identifier_claim == :oid

      assert {:ok, keycloak} = SSO.configure_provider(keycloak_attrs, subject)
      assert keycloak.identifier_claim == :sub
    end

    test "an https issuer with no host is rejected" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:error, changeset} =
               SSO.configure_provider(
                 %{kind: :okta, name: "Okta", issuer: "https://", client_id: "cid"},
                 subject
               )

      assert "must be an https URL" in errors_on(changeset).issuer
    end

    test "allowed_email_domain is normalized — leading @ stripped, trimmed (casing kept for citext)" do
      {_owner, _account, subject} = enterprise_owner()

      # Trimmed + leading-@ stripped; the casing is deliberately preserved (the
      # column is citext, so it matches case-insensitively without an app-side
      # downcase — §3).
      assert {:ok, %IdentityProvider{allowed_email_domain: "Example.com"}} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   client_secret: "secret",
                   allowed_email_domain: "  @Example.com "
                 },
                 subject
               )
    end

    test "a blank allowed_email_domain normalizes to nil (no domain gate)" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:ok, %IdentityProvider{allowed_email_domain: nil}} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   client_secret: "secret",
                   allowed_email_domain: "   "
                 },
                 subject
               )
    end

    test "a crafted create cannot enable a provider before verification" do
      {_owner, account, subject} = enterprise_owner()
      _first = provider_fixture(account, %{kind: :okta, enabled: true})

      assert {:ok, provider} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Second Okta",
                   issuer: "https://idp2.test",
                   client_id: "cid2",
                   client_secret: "secret",
                   enabled: true
                 },
                 subject
               )

      refute provider.enabled
    end

    test "a crafted create stays disabled even when its email domain is already active" do
      {_owner, account, subject} = enterprise_owner()
      _first = provider_fixture(account, %{kind: :okta, allowed_email_domain: "acme.test"})

      assert {:ok, provider} =
               SSO.configure_provider(
                 %{
                   kind: :keycloak,
                   name: "Keycloak",
                   issuer: "https://kc.test",
                   client_id: "cid2",
                   client_secret: "secret",
                   enabled: true,
                   allowed_email_domain: "acme.test"
                 },
                 subject
               )

      refute provider.enabled
      assert provider.allowed_email_domain == "acme.test"
    end

    test "omitting kind / name / issuer / client_id surfaces the required-field errors" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:error, changeset} = SSO.configure_provider(%{}, subject)

      errors = errors_on(changeset)
      assert "can't be blank" in errors.kind
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.issuer
      assert "can't be blank" in errors.client_id
    end

    test "a blank client_secret is not stored (an empty secret never persists)" do
      {_owner, _account, subject} = enterprise_owner()

      # The LV strips a blank secret before it reaches the context; even passed
      # through directly, `cast/3` treats "" as an empty value and never records
      # it as a change — so the stored secret is nil, not a half-configured "".
      assert {:ok, %IdentityProvider{client_secret: nil}} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   client_secret: ""
                 },
                 subject
               )
    end

    test "a create always lands in the SUBJECT's account — never a foreign one" do
      {_ua, _account_a, _sa} = enterprise_owner()
      {_ub, account_b, sb} = enterprise_owner()

      # The created provider's account is read off the subject, so B's subject
      # can only ever provision into B — there is no caller-supplied account to
      # redirect into A.
      assert {:ok, %IdentityProvider{account_id: account_id}} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   client_secret: "secret"
                 },
                 sb
               )

      assert account_id == account_b.id
    end

    test "rejects an :owner default_role (owner is never assignable via SSO)" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:error, changeset} =
               SSO.configure_provider(
                 %{
                   kind: :okta,
                   name: "Okta",
                   issuer: "https://idp.test",
                   client_id: "cid",
                   default_role: :owner
                 },
                 subject
               )

      assert "can't be owner" in errors_on(changeset).default_role
    end
  end

  # -- update_provider/3 -----------------------------------------------

  describe "update_provider/3 endpoint rebinding" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      %{account: account, subject: subject}
    end

    test "repointing the issuer without the secret is refused", %{
      account: account,
      subject: subject
    } do
      # The secret is write-only. Carrying it over to a new issuer would post it
      # to whatever token endpoint that issuer's discovery names — so anyone with
      # manage_sso could aim the connection at infrastructure they control and
      # have us hand over a credential they were never able to read.
      provider = provider_fixture(account, client_secret: "the-customer-s-secret")

      assert SSO.update_provider(provider, %{"issuer" => "https://attacker.test"}, subject) ==
               {:error, :client_secret_required}

      unchanged = Repo.reload!(provider)
      assert unchanged.issuer == provider.issuer
      assert unchanged.client_secret == "the-customer-s-secret"
    end

    test "repointing the client id without the secret is refused too", %{
      account: account,
      subject: subject
    } do
      provider = provider_fixture(account, client_secret: "the-customer-s-secret")

      assert SSO.update_provider(provider, %{"client_id" => "attacker-client"}, subject) ==
               {:error, :client_secret_required}
    end

    test "repointing WITH the secret is allowed — holding it is the point", %{
      account: account,
      subject: subject
    } do
      # Supplying the SAME value is fine. The rule is that you must hold the
      # secret, not that it must change.
      provider = provider_fixture(account, client_secret: "the-customer-s-secret")

      assert {:ok, updated} =
               SSO.update_provider(
                 provider,
                 %{
                   "issuer" => "https://new-idp.test",
                   "client_secret" => "the-customer-s-secret"
                 },
                 subject
               )

      assert updated.issuer == "https://new-idp.test"
    end

    test "an ordinary edit still keeps the stored secret without re-typing it", %{
      account: account,
      subject: subject
    } do
      provider = provider_fixture(account, client_secret: "the-customer-s-secret")

      assert {:ok, updated} =
               SSO.update_provider(
                 provider,
                 %{"name" => "Renamed", "client_secret" => ""},
                 subject
               )

      assert updated.name == "Renamed"
      assert updated.client_secret == "the-customer-s-secret"
    end
  end

  describe "JumpCloud region updates" do
    setup do
      {owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, kind: :jumpcloud)
      %{owner: owner, account: account, subject: subject, provider: provider}
    end

    test "preserves an existing US connection on an unrelated edit", %{
      subject: subject,
      provider: provider
    } do
      assert {:ok, updated} = SSO.update_provider(provider, %{name: "Work JumpCloud"}, subject)
      assert updated.issuer == "https://oauth.id.jumpcloud.com/"
      assert updated.client_secret == provider.client_secret
    end

    test "changing region requires the client secret", %{subject: subject, provider: provider} do
      attrs = %{issuer: "https://oauth.id.eu.jumpcloud.com/"}

      assert SSO.update_provider(provider, attrs, subject) == {:error, :client_secret_required}
      assert Repo.reload!(provider).issuer == "https://oauth.id.jumpcloud.com/"

      assert {:ok, updated} =
               SSO.update_provider(
                 provider,
                 Map.put(attrs, :client_secret, "eu-client-secret"),
                 subject
               )

      assert updated.issuer == "https://oauth.id.eu.jumpcloud.com/"
      assert updated.client_secret == "eu-client-secret"
    end

    test "a forged kind cannot bypass the regional issuer restriction", %{
      subject: subject,
      provider: provider
    } do
      attrs = %{kind: :okta, issuer: "https://attacker.test", client_secret: "supplied"}

      assert {:error, %Ecto.Changeset{} = changeset} =
               SSO.update_provider(provider, attrs, subject)

      assert "must match a supported JumpCloud region" in errors_on(changeset).issuer
      assert Repo.reload!(provider).issuer == provider.issuer
      assert Repo.reload!(provider).kind == :jumpcloud
    end

    test "a linked identity locks the region even when the secret is supplied", %{
      owner: owner,
      account: account,
      subject: subject,
      provider: provider
    } do
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        membership: owner
      )

      attrs = %{issuer: "https://oauth.id.in.jumpcloud.com/", client_secret: "supplied"}

      assert SSO.update_provider(provider, attrs, subject) == {:error, :identity_namespace_locked}
      assert Repo.reload!(provider).issuer == provider.issuer
    end

    test "viewers and another account cannot change the region", %{
      account: account,
      provider: provider
    } do
      {_other_user, _other_account, other_subject} = enterprise_owner()
      viewer = viewer_in(account)
      attrs = %{issuer: "https://oauth.id.eu.jumpcloud.com/", client_secret: "supplied"}

      assert SSO.update_provider(provider, attrs, viewer) == {:error, :unauthorized}
      assert SSO.update_provider(provider, attrs, other_subject) == {:error, :not_found}

      assert SSO.configure_provider(
               Fixtures.SSO.identity_provider_attrs(kind: :jumpcloud),
               viewer
             ) ==
               {:error, :unauthorized}

      assert Repo.reload!(provider).issuer == provider.issuer
    end
  end

  describe "configure_provider/2 role coverage" do
    test "an admin can't stand up a connection defaulting to a role they can't grant" do
      # Creation was the one path that never asked whether the caller may hand
      # out the role it defaults to. The escalation check runs before the insert,
      # so it — not the changeset's narrower :owner exclusion — owns the answer.
      {_owner, account, _owner_subject} = enterprise_owner()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.example.test",
        client_id: "cid",
        client_secret: "secret",
        default_role: :owner
      }

      assert SSO.configure_provider(attrs, admin) == {:error, :role_exceeds_your_permissions}
    end

    # Admins hold manage_billing, so the finance seat is theirs to hand out and
    # the coverage check — derived from permissions, not a role-name list — lets
    # it through with no special case.
    test "an admin CAN stand up a connection defaulting to billing_manager" do
      {_owner, account, _owner_subject} = enterprise_owner()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.example.test",
        client_id: "cid",
        client_secret: "secret",
        default_role: :billing_manager
      }

      assert {:ok, provider} = SSO.configure_provider(attrs, admin)
      assert provider.default_role == :billing_manager
    end
  end

  describe "update_provider/3" do
    test "account A's provider cannot be fetched or updated by account B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert SSO.fetch_provider_by_id(provider.id, sb) == {:error, :not_found}
      assert SSO.update_provider(provider, %{name: "Hijacked"}, sb) == {:error, :not_found}
      assert SSO.delete_provider(provider, sb) == {:error, :not_found}
    end

    test "a disabled provider cannot be activated before a real sign-in is verified" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: false})

      assert SSO.update_provider(provider, %{enabled: true}, subject) ==
               {:error, :sign_in_verification_required}

      refute Repo.reload!(provider).enabled
    end

    test "another account may claim the same allowed email domain" do
      # The domain gate is a per-provider sign-in restriction, not a route, so
      # nothing needs it unique across tenants — and global uniqueness let one
      # account squat a domain the real owner could then never set, refused by a
      # constraint naming a row in a workspace they cannot see.
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, account_b, sb} = enterprise_owner()
      _squatter = provider_fixture(account_a, %{allowed_email_domain: "bigcorp.test"})
      provider_b = provider_fixture(account_b)

      assert {:ok, updated} =
               SSO.update_provider(provider_b, %{allowed_email_domain: "bigcorp.test"}, sb)

      assert updated.allowed_email_domain == "bigcorp.test"
    end

    test "two enabled connections in ONE account cannot share an allowed email domain" do
      {_owner, account, subject} = enterprise_owner()
      _okta = provider_fixture(account, %{kind: :okta, allowed_email_domain: "acme.test"})
      keycloak = provider_fixture(account, %{kind: :keycloak, name: "Keycloak"})

      assert {:error, changeset} =
               SSO.update_provider(keycloak, %{allowed_email_domain: "acme.test"}, subject)

      assert "has already been taken" in errors_on(changeset).allowed_email_domain
      refute Repo.reload!(keycloak).allowed_email_domain
    end

    test "changing the issuer to a non-https URL is rejected on update" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, changeset} =
               SSO.update_provider(provider, %{issuer: "http://idp.test"}, subject)

      assert "must be an https URL" in errors_on(changeset).issuer
      # The stored issuer is unchanged.
      assert Repo.reload!(provider).issuer == provider.issuer
    end

    test "setting :owner as the default_role is rejected on update" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, changeset} =
               SSO.update_provider(provider, %{default_role: :owner}, subject)

      assert "can't be owner" in errors_on(changeset).default_role
      assert Repo.reload!(provider).default_role == :viewer
    end

    test "a mutable identifier_claim (email) is rejected; oid is allowed — the (provider, sub) takeover guard" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, changeset} =
               SSO.update_provider(provider, %{identifier_claim: "email"}, subject)

      # identifier_claim is an Ecto.Enum [:sub, :oid] — the cast rejects a mutable
      # claim like "email", keeping the (provider, sub) identity binding immutable.
      assert "is invalid" in errors_on(changeset).identifier_claim
      assert Repo.reload!(provider).identifier_claim == :sub

      assert {:ok, updated} = SSO.update_provider(provider, %{identifier_claim: "oid"}, subject)
      assert updated.identifier_claim == :oid
    end

    test "the provider type (kind) is create-only — a crafted update can't morph it" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{kind: :okta})

      # kind is the IdP preset (and half of the (account, kind) uniqueness): the
      # edit form renders it read-only, and update/2 never casts it — so even a
      # forged param can't turn an Okta connection into a Google one.
      assert {:ok, updated} =
               SSO.update_provider(provider, %{kind: :google_workspace, name: "Renamed"}, subject)

      assert updated.kind == :okta
      assert updated.name == "Renamed"
      assert Repo.reload!(provider).kind == :okta
    end

    test "a new client_secret rotates the stored value" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "old-secret"})

      assert {:ok, _} = SSO.update_provider(provider, %{client_secret: "rotated-secret"}, subject)
      assert Repo.reload!(provider).client_secret == "rotated-secret"
    end

    test "the audit records exact safe config changes and only a secret-rotation boolean" do
      {_owner, account, subject} = enterprise_owner()

      provider =
        provider_fixture(account, %{
          name: "Old provider",
          issuer: "https://old-idp.test/tenant",
          client_id: "old-client",
          client_secret: "OLD_CLIENT_SECRET_SENTINEL",
          identifier_claim: :sub,
          provisioner: :jit,
          allowed_email_domain: "old.test",
          default_role: :viewer,
          enabled: true,
          satisfies_mfa: false
        })

      assert {:ok, _updated} =
               SSO.update_provider(
                 provider,
                 %{
                   name: "New provider",
                   issuer: "https://new-idp.test/tenant",
                   client_id: "new-client",
                   client_secret: "NEW_CLIENT_SECRET_SENTINEL",
                   identifier_claim: :oid,
                   provisioner: :manual,
                   allowed_email_domain: "new.test",
                   default_role: :operator,
                   enabled: false,
                   satisfies_mfa: true
                 },
                 subject
               )

      assert {:ok, [event], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      assert event.payload["changes"] == %{
               "name" => %{"before" => "Old provider", "after" => "New provider"},
               "issuer" => %{
                 "before" => "https://old-idp.test/tenant",
                 "after" => "https://new-idp.test/tenant"
               },
               "client_id" => %{"before" => "old-client", "after" => "new-client"},
               "identifier_claim" => %{"before" => "sub", "after" => "oid"},
               "provisioner" => %{"before" => "jit", "after" => "manual"},
               "allowed_email_domain" => %{"before" => "old.test", "after" => "new.test"},
               "default_role" => %{"before" => "viewer", "after" => "operator"},
               "enabled" => %{"before" => true, "after" => false},
               "satisfies_mfa" => %{"before" => false, "after" => true}
             }

      assert event.payload["client_secret_rotated"] == true
      refute Map.has_key?(event.payload, "scim_token_issued")
      refute Map.has_key?(event.payload, "scim_token_rotated")
      refute Map.has_key?(event.payload, "scim_token_revoked")

      payload = inspect(event.payload)
      refute payload =~ "OLD_CLIENT_SECRET_SENTINEL"
      refute payload =~ "NEW_CLIENT_SECRET_SENTINEL"
      refute Map.has_key?(event.payload["changes"], "client_secret")
      refute payload =~ "scim_token_hash"
    end

    test "the audit preserves an explicit default port in an otherwise safe issuer" do
      {_owner, account, subject} = enterprise_owner()

      provider =
        provider_fixture(account, %{
          issuer: "https://idp.test/tenant",
          client_secret: "old-secret"
        })

      assert {:ok, _updated} =
               SSO.update_provider(
                 provider,
                 %{issuer: "https://idp.test:443/tenant", client_secret: "new-secret"},
                 subject
               )

      assert {:ok, [event], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      assert event.payload["changes"]["issuer"] == %{
               "before" => "https://idp.test/tenant",
               "after" => "https://idp.test:443/tenant"
             }
    end

    test "an update with no client_secret key keeps the stored secret (never wiped)" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "keep-this-secret"})

      # A secret nobody can read back must survive an unrelated edit — the
      # context drops the key rather than casting a missing value over it.
      assert {:ok, _} = SSO.update_provider(provider, %{name: "Renamed"}, subject)

      reloaded = Repo.reload!(provider)
      assert reloaded.name == "Renamed"
      assert reloaded.client_secret == "keep-this-secret"

      assert {:ok, [event], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      refute Map.has_key?(event.payload, "client_secret_rotated")
    end

    test "a blank or whitespace-only client_secret keeps the stored one" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "keep-this-secret"})

      # The form posts the empty field on every save, and a stray space is the
      # same "I didn't type one" — neither may clobber the credential.
      assert {:ok, _} = SSO.update_provider(provider, %{"client_secret" => ""}, subject)
      assert Repo.reload!(provider).client_secret == "keep-this-secret"

      assert {:ok, _} = SSO.update_provider(provider, %{"client_secret" => "   "}, subject)
      assert Repo.reload!(provider).client_secret == "keep-this-secret"
    end

    test "a rejected update returns a changeset holding no secret at all" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "stored-secret-value"})
      attrs = %{"issuer" => "http://idp.test", "client_secret" => "typed-replacement"}

      assert {:error, changeset} = SSO.update_provider(provider, attrs, subject)

      # The console renders this changeset and holds it in socket state, so
      # neither the stored credential nor the replacement travels with it.
      assert "must be an https URL" in errors_on(changeset).issuer
      assert changeset.data.client_secret == nil
      refute Map.has_key?(changeset.changes, :client_secret)
    end

    test "a fixed-issuer connection ignores a submitted issuer" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{kind: :google_workspace})

      # Google's issuer is a constant, so the field is not editable — a forged
      # one can't repoint the connection at infrastructure the caller controls,
      # and the stored value is left exactly as it is.
      attrs = %{"issuer" => "https://evil.test", "client_secret" => "supplied", "name" => "G"}

      assert {:ok, updated} = SSO.update_provider(provider, attrs, subject)
      assert updated.issuer == provider.issuer
      assert updated.name == "G"
    end

    test "kind is immutable on edit — a kind change in attrs is ignored" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{kind: :okta})

      # The update changeset casts only the config fields, not :kind, so an
      # attempt to change it is silently dropped (the provider type is fixed at
      # creation).
      assert {:ok, _} =
               SSO.update_provider(provider, %{kind: :keycloak, name: "Renamed"}, subject)

      reloaded = Repo.reload!(provider)
      assert reloaded.kind == :okta
      assert reloaded.name == "Renamed"
    end

    test "a SCIM provider default change reconciles members and audits before/after access" do
      %{provider: provider, account: account, subject: subject} = scim_provider()
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      %{membership: membership} = provision(provider, "okta|default-change")

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.none()

      assert {:ok, _updated} =
               SSO.update_provider(
                 provider,
                 %{
                   default_runner_access_mode: :restricted,
                   default_runner_scope: ["group:database"]
                 },
                 subject
               )

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               %RunnerAccess{mode: :restricted, groups: ["database"], runner_ids: []}

      assert {:ok, [event | _], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      assert event.payload["before"] == %{
               "mode" => "none",
               "groups" => [],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }

      assert event.payload["after"] == %{
               "mode" => "restricted",
               "groups" => ["database"],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }

      assert event.payload["changes"] == %{}
    end

    test "a free plan is denied on update (:sso_not_available)" do
      # The row exists (built via the fixture, bypassing the gate), but the plan
      # gate (`ensure_can_configure_sso`) fires before any row touch.
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{})
      provider = provider_fixture(account)

      assert SSO.update_provider(provider, %{name: "Renamed"}, subject) ==
               {:error, :sso_not_available}

      assert Repo.reload!(provider).name == "Okta"
    end

    test "an expired account may disable a retained provider but cannot edit it" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: true})
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      assert SSO.update_provider(provider, %{name: "Renamed"}, subject) ==
               {:error, :sso_not_available}

      assert {:ok, %IdentityProvider{enabled: false}} =
               SSO.update_provider(provider, %{enabled: false}, subject)

      assert Repo.reload!(provider).name == "Okta"
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert SSO.update_provider(provider, %{name: "Renamed"}, viewer_in(account)) ==
               {:error, :unauthorized}
    end

    test "disabling one of two enabled providers is allowed (not the last)" do
      {owner, account, _subject} = enterprise_owner()
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      keep = provider_fixture(account, %{name: "Keep", kind: :okta, enabled: true})
      extra = provider_fixture(account, %{name: "Extra", kind: :keycloak, enabled: true})
      subject = provider_subject(owner, keep)

      # Even under require_sso, disabling a provider while another enabled one
      # remains is fine — the last-provider guard only fires on the final one.
      assert {:ok, %IdentityProvider{enabled: false}} =
               SSO.update_provider(extra, %{enabled: false}, subject)
    end

    test "cannot disable the last enabled connection when require_sso is on" do
      {owner, account, _subject} = enterprise_owner()
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      provider = provider_fixture(account)
      subject = provider_subject(owner, provider)

      assert SSO.update_provider(provider, %{enabled: false}, subject) ==
               {:error, :require_sso_last_provider}

      assert Repo.reload!(provider).enabled
    end
  end

  # -- delete_provider/2 -----------------------------------------------

  describe "delete_provider/2" do
    test "soft-deletes a provider for an enterprise admin" do
      {_owner, account, subject} = enterprise_owner()
      # A second enabled provider so require_sso (unset here anyway) can't bite.
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{} = deleted} = SSO.delete_provider(provider, subject)
      assert deleted.deleted_at
      assert SSO.fetch_provider_by_id(provider.id, subject) == {:error, :not_found}
    end

    test "a downgraded plan cannot delete a mapping, because deleting one can promote" do
      # A member left in no mapped group falls back to `default_role`. With the
      # provider defaulting to :admin and the group mapped to :viewer, deleting
      # the mapping RAISES everyone it touches — so it is not cleanup, and an
      # unentitled account does not get to do it.
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, default_role: :admin)
      {:ok, provider, _raw} = SSO.enable_scim(provider, subject)

      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp", role: :viewer},
          subject
        )

      Fixtures.Accounts.create_subscription(account, "free")

      assert SSO.delete_group_mapping(mapping, subject) == {:error, :directory_sync_not_available}
    end

    test "a downgraded plan can still delete — the connection outlived the plan, not the risk" do
      # Expiry makes the connection dormant; deleting the stored trust remains
      # an owner recovery and cleanup action, not a paid feature.
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{})
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{}} = SSO.delete_provider(provider, subject)
      assert Repo.reload!(provider).deleted_at
    end

    test "dismisses the requests waiting on it, and tells the browsers holding them" do
      # Approval needs the provider, so a request that outlives it can never be
      # approved — it just sat in the admin's queue while someone's browser waited
      # on a page that would never resolve.
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)

      request =
        capture_request(provider, %{
          "sub" => "okta|waiting",
          "email" => "waiting@acme.test",
          "email_verified" => true
        })

      SSO.subscribe_link_request(request.id)

      assert {:ok, _} = SSO.delete_provider(provider, subject)

      request_id = request.id
      assert_receive {:sso_link_request, :dismissed, %{id: ^request_id}}
      assert link_requests(provider.id) == []
    end

    test "returns role control to operators, so a synced member is editable again" do
      # `directory_managed: true` makes the role read-only, and the delete cannot
      # be re-driven — the tombstoned connection reads back `:not_found`. Run
      # after the commit, this repair had one unretryable chance at the flag.
      %{provider: provider, subject: subject} = scim_provider()
      %{membership: membership} = provision(provider, "okta|synced")

      assert membership.directory_managed

      assert Accounts.update_membership_role(membership, "admin", subject) ==
               {:error, :role_managed_by_directory}

      assert {:ok, _deleted} = SSO.delete_provider(provider, subject)

      released = Repo.reload!(membership)
      refute released.directory_managed
      refute released.directory_provider_id

      assert {:ok, %Accounts.Membership{role: :admin}} =
               Accounts.update_membership_role(released, "admin", subject)
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert SSO.delete_provider(provider, viewer_in(account)) == {:error, :unauthorized}
      refute Repo.reload!(provider).deleted_at
    end
  end

  # -- require_sso lock-out guard on provider removal ------------------

  describe "require_sso lock-out guard on provider removal" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      %{account: account, subject: subject}
    end

    test "cannot delete the last enabled connection", %{account: account, subject: subject} do
      provider = provider_fixture(account)
      subject = provider_subject(subject.actor, provider)

      assert SSO.delete_provider(provider, subject) == {:error, :require_sso_last_provider}
      refute Repo.reload!(provider).deleted_at
    end

    test "CAN delete one connection while another enabled one remains", %{
      account: account,
      subject: subject
    } do
      # Two enabled connections of DIFFERENT kinds (the unique index is one enabled
      # provider per (account, kind)).
      keep = provider_fixture(account, %{name: "Keep", kind: :okta})
      extra = provider_fixture(account, %{name: "Extra", kind: :keycloak})
      subject = provider_subject(subject.actor, keep)

      assert {:ok, _} = SSO.delete_provider(extra, subject)
      assert Repo.reload!(keep).enabled
    end

    test "CAN delete the last connection once require_sso is off", %{
      account: account,
      subject: subject
    } do
      Fixtures.Accounts.set_account_settings(account, %{require_sso: false})
      provider = provider_fixture(account)

      assert {:ok, _} = SSO.delete_provider(provider, subject)
    end
  end

  describe "test_provider/2" do
    test "an enterprise admin gets the discovered endpoints for a reachable issuer" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:ok, summary} = SSO.test_provider("https://idp.test", subject)
      assert summary.authorization_endpoint == "https://idp.test/authorize"
      assert summary.jwks_uri == "https://idp.test/jwks"
    end

    test "a discovery failure surfaces the reason and writes no row" do
      {_owner, _account, subject} = enterprise_owner()

      assert SSO.test_provider("https://unreachable.test", subject) == {:error, :discovery_failed}
      refute Repo.one(IdentityProvider)
    end

    test "saved providers and unsaved discovery share one account-wide work budget" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingDiscoveryOIDC)
      {_owner, account, subject} = enterprise_owner()

      providers = [
        provider_fixture(account, %{kind: :okta, name: "Okta"}),
        provider_fixture(account, %{kind: :keycloak, name: "Keycloak"}),
        provider_fixture(account, %{kind: :entra, name: "Entra"}),
        provider_fixture(account, %{kind: :openid_connect, name: "OIDC"})
      ]

      for provider <- Enum.take(Stream.cycle(providers), 8) do
        provider_id = provider.id
        assert {:ok, _begin} = SSO.begin_auth(provider, [])
        assert_receive {:oidc_begin, ^provider_id}
      end

      for _attempt <- 1..52 do
        assert {:ok, _summary} = SSO.test_provider("https://idp.test", subject)
        assert_receive {:oidc_discover, "https://idp.test"}
      end

      underused_provider = hd(providers)

      assert SSO.begin_auth(underused_provider, []) == {:error, :rate_limited}
      refute_receive {:oidc_begin, _provider_id}
      assert SSO.test_provider("https://idp.test", subject) == {:error, :rate_limited}
      refute_receive {:oidc_discover, "https://idp.test"}

      {_other_owner, other_account, other_subject} = enterprise_owner()
      other_provider = provider_fixture(other_account)
      other_provider_id = other_provider.id

      assert {:ok, _begin} = SSO.begin_auth(other_provider, [])
      assert_receive {:oidc_begin, ^other_provider_id}
      assert {:ok, _summary} = SSO.test_provider("https://idp.test", other_subject)
      assert_receive {:oidc_discover, "https://idp.test"}
    end

    test "a non-https or malformed issuer is rejected before any fetch" do
      {_owner, _account, subject} = enterprise_owner()

      assert SSO.test_provider("http://idp.test", subject) == {:error, :invalid_issuer}
      assert SSO.test_provider("not a url", subject) == {:error, :invalid_issuer}
    end

    test "an SSRF issuer (private/loopback/metadata) is blocked before any fetch" do
      {_owner, _account, subject} = enterprise_owner()

      # Each is blocked even though the stub would happily "discover" it — proving
      # the SSRF guard runs ahead of the fetch, not after.
      assert SSO.test_provider("https://169.254.169.254", subject) == {:error, :blocked_issuer}
      assert SSO.test_provider("https://10.0.0.5", subject) == {:error, :blocked_issuer}
      assert SSO.test_provider("https://localhost:8443", subject) == {:error, :blocked_issuer}
    end

    test "a non-admin (no manage_sso) cannot test a connection" do
      {_owner, account, _owner_subject} = enterprise_owner()

      assert SSO.test_provider("https://idp.test", viewer_in(account)) == {:error, :unauthorized}
    end

    test "a free account cannot test a connection (Team-and-up gate)" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject(%{})

      assert SSO.test_provider("https://idp.test", subject) == {:error, :sso_not_available}
    end
  end

  # -- list_enabled_providers_for_account/1 (pre-Subject) --------------

  describe "list_enabled_providers_for_account/1" do
    test "returns an account's ENABLED providers, name-ordered (the sign-in page source)" do
      {_owner, account, _subject} = enterprise_owner()
      _b = provider_fixture(account, %{kind: :keycloak, name: "B-Keycloak", enabled: true})
      _a = provider_fixture(account, %{kind: :okta, name: "A-Okta", enabled: true})
      _off = provider_fixture(account, %{kind: :jumpcloud, name: "Off", enabled: false})

      providers = SSO.list_enabled_providers_for_account(account.id)
      assert Enum.map(providers, & &1.name) == ["A-Okta", "B-Keycloak"]
    end

    test "an account with no enabled provider returns []" do
      {_owner, account, _subject} = enterprise_owner()
      _off = provider_fixture(account, %{enabled: false})

      assert SSO.list_enabled_providers_for_account(account.id) == []
    end

    test "is scoped to the account — never another account's providers" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, account_b, _sb} = enterprise_owner()
      _a = provider_fixture(account_a, %{name: "A"})

      assert SSO.list_enabled_providers_for_account(account_b.id) == []
    end

    test "an expired account discovers no SSO provider" do
      {_owner, account, _subject} = enterprise_owner()
      _provider = provider_fixture(account, %{enabled: true})
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      assert SSO.list_enabled_providers_for_account(account.id) == []
    end
  end

  # -- fetch_provider_for_sign_in/1 (pre-Subject) ----------------------

  describe "fetch_provider_for_sign_in/1" do
    test "resolves an ENABLED provider by id for the begin-auth redirect" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: true})

      assert {:ok, %IdentityProvider{id: id}} = SSO.fetch_provider_for_sign_in(provider.id)
      assert id == provider.id
    end

    test "a DISABLED provider is :not_found (sign-in only offers enabled ones)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: false})

      assert SSO.fetch_provider_for_sign_in(provider.id) == {:error, :not_found}
    end

    test "an unknown or malformed id is :not_found, never a crash" do
      assert SSO.fetch_provider_for_sign_in(Ecto.UUID.generate()) == {:error, :not_found}
      assert SSO.fetch_provider_for_sign_in("not-a-uuid") == {:error, :not_found}
    end

    test "an expired account cannot begin through a retained provider" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: true})
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      assert SSO.fetch_provider_for_sign_in(provider.id) == {:error, :not_found}
    end
  end

  describe "fetch_member_mfa_reset_reauthentication_facts/1" do
    test "offers only the current session identity on an enabled MFA-satisfying provider" do
      reset = member_mfa_reset_sso_fixture()

      assert SSO.fetch_member_mfa_reset_reauthentication_facts(reset.subject) ==
               {:ok, %{provider_name: reset.provider.name}}

      reset.provider
      |> Ecto.Changeset.change(satisfies_mfa: false)
      |> Repo.update!()

      assert SSO.fetch_member_mfa_reset_reauthentication_facts(reset.subject) ==
               {:error, :mfa_reset_reauthentication_unavailable}

      local_subject = %{reset.subject | auth_method: :magic_link, user_identity_id: nil}

      assert SSO.fetch_member_mfa_reset_reauthentication_facts(local_subject) ==
               {:error, :mfa_reset_reauthentication_unavailable}
    end
  end

  describe "begin_member_mfa_reset_reauthentication/3" do
    test "requests a fresh IdP login and stashes the exact actor identity" do
      reset = member_mfa_reset_sso_fixture()
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingResetOIDC)

      assert {:ok, begun} =
               SSO.begin_member_mfa_reset_reauthentication(
                 "https://portal.test/sign_in/sso/callback",
                 reset.actor_session_token_digest,
                 reset.subject
               )

      assert_receive {:reset_oidc_begin_options, opts}
      assert opts[:url_extension] == [{"prompt", "login"}, {"max_age", "0"}]
      assert begun.actor_membership_id == reset.subject.membership_id
      assert begun.account_id == reset.account.id
      assert begun.identity_id == reset.identity.id
      assert begun.provider_identifier == reset.identity.provider_identifier
      assert begun.provider_id == reset.provider.id
      assert is_integer(begun.started_at)
    end

    test "refuses an actor whose current session did not authenticate through the IdP" do
      reset = member_mfa_reset_sso_fixture()
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingResetOIDC)

      local_subject = Fixtures.Subjects.subject_for(reset.actor, auth_method: :magic_link)

      assert SSO.begin_member_mfa_reset_reauthentication(
               "https://portal.test/sign_in/sso/callback",
               reset.actor_session_token_digest,
               local_subject
             ) == {:error, :mfa_reset_reauthentication_unavailable}
    end
  end

  describe "complete_member_mfa_reset_reauthentication/4" do
    test "proves only the stashed current identity without mutating login state" do
      reset = member_mfa_reset_sso_fixture()

      {:ok, begun} =
        SSO.begin_member_mfa_reset_reauthentication(
          "https://portal.test/sign_in/sso/callback",
          reset.actor_session_token_digest,
          reset.subject
        )

      begun = member_mfa_reset_stash(reset, begun)

      before_identity = Repo.reload!(reset.identity)

      claims = %{
        "sub" => reset.identity.provider_identifier,
        "auth_time" => System.system_time(:second)
      }

      assert {:ok, reauthentication} =
               SSO.complete_member_mfa_reset_reauthentication(
                 callback(claims),
                 begun,
                 reset.actor_session_token_digest,
                 reset.subject
               )

      assert reauthentication.identity_id == reset.identity.id
      assert reauthentication.provider_id == reset.provider.id
      assert Repo.reload!(reset.identity).last_seen_at == before_identity.last_seen_at

      assert {:ok, %UserToken{membership_id: actor_id}} =
               Auth.fetch_session_by_token(reset.actor_session_token, reset.account.id)

      assert actor_id == reset.actor.id
    end

    test "wrong identity, stale auth_time, or a different actor produces no auth result" do
      reset = member_mfa_reset_sso_fixture()

      {:ok, begun} =
        SSO.begin_member_mfa_reset_reauthentication(
          "https://portal.test/sign_in/sso/callback",
          reset.actor_session_token_digest,
          reset.subject
        )

      begun = member_mfa_reset_stash(reset, begun)

      for claims <- [
            %{"sub" => "someone-else", "auth_time" => System.system_time(:second)},
            %{
              "sub" => reset.identity.provider_identifier,
              "auth_time" => System.system_time(:second) - 300
            }
          ] do
        assert SSO.complete_member_mfa_reset_reauthentication(
                 callback(claims),
                 begun,
                 reset.actor_session_token_digest,
                 reset.subject
               ) == {:error, :mfa_reset_reauthentication_invalid}
      end

      {_other, _account, other_subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

      assert SSO.complete_member_mfa_reset_reauthentication(
               callback(%{
                 "sub" => reset.identity.provider_identifier,
                 "auth_time" => System.system_time(:second)
               }),
               begun,
               reset.actor_session_token_digest,
               other_subject
             ) == {:error, :mfa_reset_reauthentication_invalid}

      assert Repo.reload!(reset.identity).last_seen_at == reset.identity.last_seen_at
    end

    test "an identity rebind during the IdP round-trip invalidates the ceremony" do
      reset = member_mfa_reset_sso_fixture()

      {:ok, begun} =
        SSO.begin_member_mfa_reset_reauthentication(
          "https://portal.test/sign_in/sso/callback",
          reset.actor_session_token_digest,
          reset.subject
        )

      begun = member_mfa_reset_stash(reset, begun)

      rebound =
        reset.identity
        |> Ecto.Changeset.change(
          provider_identifier: "reset-actor-rebound-sub",
          created_by: :admin
        )
        |> Repo.update!()

      assert SSO.complete_member_mfa_reset_reauthentication(
               callback(%{
                 "sub" => rebound.provider_identifier,
                 "auth_time" => System.system_time(:second)
               }),
               begun,
               reset.actor_session_token_digest,
               reset.subject
             ) == {:error, :mfa_reset_reauthentication_invalid}

      assert Repo.reload!(rebound).last_seen_at == reset.identity.last_seen_at

      # The ceremony wrote nothing; the rebind itself is what ended the
      # session's authority, through the per-request predicate.
      assert Repo.exists?(UserToken.Query.by_token_digest(reset.actor_session_token_digest))

      assert Auth.fetch_session_by_token(reset.actor_session_token, reset.account.id) ==
               {:error, :not_found}
    end
  end

  describe "ensure_member_mfa_reset_reauthentication_current/4" do
    test "locks and rejects expired freshness or provider trust revoked after the callback" do
      reset = member_mfa_reset_sso_fixture()
      reauthentication = member_mfa_reset_reauthentication(reset)

      assert {:ok, ^reauthentication} =
               SSO.ensure_member_mfa_reset_reauthentication_current(
                 Repo,
                 reauthentication,
                 reset.subject.membership_id,
                 reset.account.id
               )

      stale = %{reauthentication | auth_time: System.system_time(:second) - 300}

      assert SSO.ensure_member_mfa_reset_reauthentication_current(
               Repo,
               stale,
               reset.subject.membership_id,
               reset.account.id
             ) == {:error, :mfa_reset_proof_stale}

      reset.provider
      |> Ecto.Changeset.change(satisfies_mfa: false)
      |> Repo.update!()

      assert SSO.ensure_member_mfa_reset_reauthentication_current(
               Repo,
               reauthentication,
               reset.subject.membership_id,
               reset.account.id
             ) == {:error, :mfa_reset_proof_stale}
    end
  end

  describe "begin_mfa_enrollment_reauthentication/3" do
    test "asks the IdP for a fresh sign-in and stashes the session, Member, identity and provider" do
      enrollment = mfa_enrollment_sso_fixture()
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingResetOIDC)

      assert {:ok, begun} =
               SSO.begin_mfa_enrollment_reauthentication(
                 @redirect_uri,
                 enrollment.session_digest,
                 enrollment.subject
               )

      assert_receive {:reset_oidc_begin_options, opts}
      assert opts[:url_extension] == [{"prompt", "login"}, {"max_age", "0"}]
      assert opts[:redirect_uri] == @redirect_uri

      assert Map.drop(begun, [:started_at]) == %{
               authorize_url: "https://idp.test/auth",
               state: "s",
               nonce: "n",
               pkce_verifier: "v",
               purpose: :mfa_enrollment,
               account_id: enrollment.account.id,
               membership_id: enrollment.member.id,
               session_digest: enrollment.session_digest,
               identity_id: enrollment.identity.id,
               provider_identifier: enrollment.identity.provider_identifier,
               provider_id: enrollment.provider.id,
               namespace: namespace(enrollment.provider)
             }

      assert is_integer(begun.started_at)
    end

    test "refuses an email-code session, another session's digest, an enrolled Member and a workspace without SSO" do
      enrollment = mfa_enrollment_sso_fixture()
      unavailable = {:error, :mfa_enrollment_reauthentication_unavailable}

      local_raw = Fixtures.Auth.create_session_token!(enrollment.member, :magic_link, nil)
      local_subject = Fixtures.Subjects.subject_for(enrollment.member, session: local_raw)

      assert SSO.begin_mfa_enrollment_reauthentication(
               @redirect_uri,
               Crypto.hash(local_raw),
               local_subject
             ) == unavailable

      assert SSO.begin_mfa_enrollment_reauthentication(
               @redirect_uri,
               Crypto.hash(Crypto.random_secret()),
               enrollment.subject
             ) == unavailable

      Fixtures.Memberships.set_mfa_state(enrollment.member,
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now()
      )

      assert SSO.begin_mfa_enrollment_reauthentication(
               @redirect_uri,
               enrollment.session_digest,
               enrollment.subject
             ) == unavailable

      free_account = Fixtures.Accounts.create_account()
      no_sso = mfa_enrollment_sso_fixture({free_account, provider_fixture(free_account)})

      assert SSO.begin_mfa_enrollment_reauthentication(
               @redirect_uri,
               no_sso.session_digest,
               no_sso.subject
             ) == unavailable
    end
  end

  describe "complete_mfa_enrollment_reauthentication/4" do
    test "proves the exact identity behind the session with a sign-in made after the ceremony began, and writes nothing" do
      enrollment = mfa_enrollment_sso_fixture()

      {:ok, begun} =
        SSO.begin_mfa_enrollment_reauthentication(
          @redirect_uri,
          enrollment.session_digest,
          enrollment.subject
        )

      before_identity = Repo.reload!(enrollment.identity)
      auth_time = System.system_time(:second)

      assert {:ok, reauthentication} =
               SSO.complete_mfa_enrollment_reauthentication(
                 callback(%{
                   "sub" => enrollment.identity.provider_identifier,
                   "auth_time" => auth_time
                 }),
                 begun,
                 enrollment.session_digest,
                 enrollment.subject
               )

      assert reauthentication == %{
               provider_id: enrollment.provider.id,
               identity_id: enrollment.identity.id,
               provider_identifier: enrollment.identity.provider_identifier,
               namespace: namespace(enrollment.provider),
               auth_time: auth_time,
               session_digest: enrollment.session_digest
             }

      assert Repo.reload!(enrollment.identity) == before_identity
      assert is_nil(Repo.reload!(enrollment.member).mfa_enabled_at)
      assert session_count(enrollment.member) == 1
    end

    test "refuses another session's or Member's stash, a stash for another purpose, a sign-in before the ceremony or a stale one, and another subject" do
      enrollment = mfa_enrollment_sso_fixture()
      refused = {:error, :mfa_enrollment_reauthentication_invalid}

      {:ok, begun} =
        SSO.begin_mfa_enrollment_reauthentication(
          @redirect_uri,
          enrollment.session_digest,
          enrollment.subject
        )

      fresh = fn ->
        callback(%{
          "sub" => enrollment.identity.provider_identifier,
          "auth_time" => System.system_time(:second)
        })
      end

      # Bound to the session it began from, on both sides of the stash.
      other_digest = Crypto.hash(Crypto.random_secret())

      assert SSO.complete_mfa_enrollment_reauthentication(
               fresh.(),
               begun,
               other_digest,
               enrollment.subject
             ) == refused

      assert SSO.complete_mfa_enrollment_reauthentication(
               fresh.(),
               %{begun | session_digest: other_digest},
               enrollment.session_digest,
               enrollment.subject
             ) == refused

      # Another Member of the same connection cannot finish it.
      other = mfa_enrollment_sso_fixture({enrollment.account, enrollment.provider})

      assert SSO.complete_mfa_enrollment_reauthentication(
               fresh.(),
               begun,
               other.session_digest,
               other.subject
             ) == refused

      # A reset or connection-verification stash is not an enrollment stash.
      assert SSO.complete_mfa_enrollment_reauthentication(
               fresh.(),
               Map.delete(begun, :purpose),
               enrollment.session_digest,
               enrollment.subject
             ) == refused

      # The IdP sign-in must postdate the ceremony, be recent, and name the
      # identity the session holds.
      now = System.system_time(:second)
      sub = enrollment.identity.provider_identifier

      for claims <- [
            %{"sub" => sub},
            %{"sub" => sub, "auth_time" => begun.started_at - 31},
            %{"sub" => sub, "auth_time" => now - 200},
            %{"sub" => "someone-else", "auth_time" => now}
          ] do
        assert SSO.complete_mfa_enrollment_reauthentication(
                 callback(claims),
                 begun,
                 enrollment.session_digest,
                 enrollment.subject
               ) == refused
      end

      assert is_nil(Repo.reload!(enrollment.member).mfa_enabled_at)
    end
  end

  describe "ensure_mfa_enrollment_reauthentication_current/4" do
    test "locks the route and refuses a sign-in older than ten minutes, another Member or workspace, a rebound or retired identity and a disabled or repointed connection" do
      enrollment = mfa_enrollment_sso_fixture()
      stale = {:error, :mfa_enrollment_proof_stale}
      reauthentication = mfa_enrollment_reauthentication(enrollment)
      member_id = enrollment.member.id
      account_id = enrollment.account.id

      current = fn reauthentication, member_id, account_id ->
        SSO.ensure_mfa_enrollment_reauthentication_current(
          Repo,
          reauthentication,
          member_id,
          account_id
        )
      end

      assert {:ok, ^reauthentication} = current.(reauthentication, member_id, account_id)

      # Older than a callback accepts, young enough to still scan the QR code.
      aged = %{reauthentication | auth_time: System.system_time(:second) - 500}
      assert {:ok, ^aged} = current.(aged, member_id, account_id)

      expired = %{reauthentication | auth_time: System.system_time(:second) - 700}
      assert current.(expired, member_id, account_id) == stale

      other = Fixtures.Memberships.create_membership(account_id: account_id)
      foreign = Fixtures.Accounts.create_account(plan: "enterprise")
      assert current.(reauthentication, other.id, account_id) == stale
      assert current.(reauthentication, member_id, foreign.id) == stale

      assert current.(%{reauthentication | provider_identifier: "rebound"}, member_id, account_id) ==
               stale

      repointed = %{
        reauthentication
        | namespace:
            {"https://other.test", enrollment.provider.client_id,
             enrollment.provider.identifier_claim}
      }

      assert current.(repointed, member_id, account_id) == stale

      disabled = Fixtures.SSO.disable_provider(enrollment.provider)
      assert current.(reauthentication, member_id, account_id) == stale

      disabled |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
      assert {:ok, ^reauthentication} = current.(reauthentication, member_id, account_id)

      Fixtures.SSO.retire_identity(enrollment.identity)
      assert current.(reauthentication, member_id, account_id) == stale
    end
  end

  # -- begin_auth/2 (pre-Subject) --------------------------------------

  describe "begin_auth/2" do
    test "delegates to the OIDC wrapper, returning the authorize-url + stash secrets" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, %{authorize_url: url, state: state, nonce: nonce, pkce_verifier: verifier}} =
               SSO.begin_auth(provider, [])

      assert url == "https://idp.test/auth"
      assert is_binary(state)
      assert is_binary(nonce)
      assert is_binary(verifier)
    end

    test "fails closed before OIDC work without a canonical provider id" do
      assert SSO.begin_auth(%IdentityProvider{}, []) == {:error, :provider_not_ready}
    end
  end

  # -- complete_auth/4 -------------------------------------------------

  describe "complete_auth/4 — resolution + JIT" do
    test "first login JIT-provisions a Member + identity at default_role" do
      {_owner, account, subject} = enterprise_owner()

      provider =
        provider_fixture(account,
          default_role: :operator,
          default_runner_access_mode: :restricted,
          default_runner_scope_groups: ["production"]
        )

      claims = %{
        "sub" => "okta|new-1",
        "email" => "new@acme.test",
        "email_verified" => true,
        "name" => "New Operator"
      }

      assert {:ok, %{membership: membership, identity: identity, provider: current_provider}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert current_provider.id == provider.id
      assert membership.display_name == "New Operator"
      assert membership.email == "new@acme.test"
      # The IdP asserted the address; nobody proved the inbox.
      refute membership.email_verified_at
      assert identity.provider_identifier == "okta|new-1"
      assert identity.created_by == :provider
      assert identity.membership_id == membership.id
      assert membership.role == :operator

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               %RunnerAccess{mode: :restricted, groups: ["production"], runner_ids: []}

      assert {:ok, [event], _meta} =
               Audit.list_events(subject,
                 filter: [event_type: ["user.provisioned_via_sso"]]
               )

      assert event.payload["runner_access"] == %{
               "mode" => "restricted",
               "groups" => ["production"],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }
    end

    test "a Member elsewhere with the same address is NEVER matched — JIT creates a new Member" do
      {_owner, account, _subject} = enterprise_owner()
      {_other_owner, other_account, _other_subject} = enterprise_owner()
      provider = provider_fixture(account)

      existing =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          email: "taken@acme.test"
        )

      claims = %{"sub" => "okta|other", "email" => "taken@acme.test", "email_verified" => true}

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert membership.account_id == account.id
      assert membership.id != existing.id
      assert membership.email == "taken@acme.test"

      # The Member elsewhere is untouched: no identity bound to it, no seat here.
      assert member_identities(existing) == []
      assert is_nil(Accounts.peek_sync_membership_by_id(account.id, existing.id))
    end

    test "a repeated (provider, sub) login resolves to the SAME member — no duplicate" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|stable", "email" => "stable@acme.test", "email_verified" => true}

      assert {:ok, %{membership: first}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert {:ok, %{membership: second}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert first.id == second.id
    end

    test "an identity on a Member resolves to that Member alone" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          membership: membership,
          provider_identifier: "okta|unlinked"
        )

      claims = %{
        "sub" => "okta|unlinked",
        "email" => "unlinked@acme.test",
        "email_verified" => true
      }

      membership_id = membership.id
      identity_id = identity.id

      assert {:ok,
              %{
                membership: %Accounts.Membership{id: ^membership_id},
                identity: %UserIdentity{id: ^identity_id}
              }} = SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})
    end

    test "a directory identifier on a Member is parked, not matched by email" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{kind: :keycloak})
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        membership: membership,
        provider_identifier: "scim-unlinked",
        scim_external_id: "scim-unlinked",
        provisioned_via: :scim,
        scim_active: true
      )

      claims = %{
        "sub" => "scim-unlinked",
        "email" => "someone@acme.test",
        "email_verified" => true
      }

      assert {:pending, %LinkRequest{provider_identifier: "scim-unlinked"}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})
    end

    test "a no-email IdP JIT-provisions a Member with no contact (identified by sub)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|nomail", "name" => "No Email"}

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      refute membership.email
      assert membership.display_name == "No Email"
      assert identity.provider_identifier == "okta|nomail"
    end

    test "an unverified email claim is not trusted — the Member's contact stays nil (R6)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|unverified", "email" => "unverified@acme.test"}

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      refute membership.email
    end

    test "JIT trusts email_verified arriving as the string \"true\"" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|str", "email" => "str@acme.test", "email_verified" => "true"}

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert membership.email == "str@acme.test"
    end

    test "a string \"false\" email_verified is NOT trusted even with an hd claim (the email is dropped)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)

      # email_verified is the STRING "false" (some IdPs / the SCIM path send strings)
      # paired with a Google-style `hd` — a forged hd must not launder an unverified
      # email. The member still provisions (identity binds by sub), with NO contact.
      claims = %{
        "sub" => "okta|strfalse",
        "email" => "unverified@acme.test",
        "email_verified" => "false",
        "hd" => "acme.test"
      }

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert is_nil(membership.email)
    end

    test "a :manual provisioner parks an unknown sub as a pending request, never auto-creating" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      claims = %{"sub" => "okta|unknown", "email" => "u@acme.test", "email_verified" => true}

      assert {:pending, %LinkRequest{} = request} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      # The real sub + claims are captured for the admin; no user/identity yet.
      assert request.provider_identifier == "okta|unknown"
      assert request.email == "u@acme.test"
      assert request.claims["sub"] == "okta|unknown"
      assert [_only] = link_requests(provider.id)
      assert UserIdentity.Query.not_deleted() |> Repo.all() == []
    end

    test "with directory sync on, an unknown sub is parked — never a second member" do
      # The split this prevents: SCIM provisions externalId `directory-123` with
      # no email, OIDC later presents `oid-456` with no email either. Nothing
      # links them, so JIT minted a whole second user + membership for the same
      # person — and deactivating `directory-123` left `oid-456` signed in.
      %{provider: provider, account: account} = scim_provider(%{provisioner: :jit})

      {:ok, %{membership: directory_member}} =
        SSO.scim_provision_user(provider, %{external_id: "directory-123"})

      claims = %{"sub" => "oid-456"}

      assert {:pending, %LinkRequest{} = request} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert request.provider_identifier == "oid-456"

      # The directory's member is the only one, and still the only identity.
      identities =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_id(provider.id)
        |> Repo.all()

      assert Enum.map(identities, & &1.provider_identifier) == ["directory-123"]

      assert Accounts.peek_sync_membership_by_id(account.id, directory_member.id)
    end

    test "a :jit login matching an existing member is parked for approval (not auto-merged)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: :viewer,
          email: "jit@acme.test"
        )

      claims = %{
        "sub" => "okta|jit",
        "email" => "  JIT@ACME.TEST  ",
        "email_verified" => true
      }

      assert {:pending, request} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert request.matched_membership_id == membership.id
      assert request.email == "  JIT@ACME.TEST  "
    end

    test "an unverified OIDC email stays display-only and never preselects a member" do
      for {label, verified} <- [{"absent", :absent}, {"false", false}, {"string-false", "false"}] do
        {_owner, account, _subject} = enterprise_owner()
        provider = provider_fixture(account, provisioner: :manual)
        email = "unverified-#{label}@acme.test"

        _member =
          Fixtures.Memberships.create_membership(
            account_id: account.id,
            role: :viewer,
            email: email
          )

        claims = %{"sub" => "okta|#{label}", "email" => email}

        claims =
          if verified == :absent, do: claims, else: Map.put(claims, "email_verified", verified)

        assert {:pending, %LinkRequest{} = request} =
                 SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

        assert request.email == email
        assert request.claims["email"] == email
        assert is_nil(request.matched_membership_id)
      end
    end

    test "the shared link-capture boundary cannot be handed raw OIDC match authority" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: :viewer,
          email: "raw-capture@acme.test"
        )

      assert {:ok, %{request: request}} =
               Ecto.Multi.new()
               |> SSO.Provisioning.put_link_request(
                 :request,
                 provider,
                 "okta|raw-capture",
                 member.email,
                 "Raw Claim",
                 %{"email" => member.email},
                 :oidc
               )
               |> Repo.commit_multi()

      assert request.email == member.email
      assert is_nil(request.matched_membership_id)
    end

    test "provisioning into account A's provider never matches or lands in account B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, account_b, _sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      b_member =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          email: "scoped@acme.test"
        )

      claims = %{"sub" => "okta|scoped", "email" => "scoped@acme.test", "email_verified" => true}

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert membership.account_id == account_a.id
      refute membership.id == b_member.id
      assert link_requests(provider.id) == []

      assert Accounts.peek_sync_membership_by_email(account_b.id, "scoped@acme.test") ==
               b_member
    end
  end

  describe "complete_auth/4 — current provider policy after verification" do
    test "rejects a changed namespace even when its legacy persisted hash collides" do
      {_owner, account, subject} = enterprise_owner()

      provider =
        provider_fixture(account,
          issuer: "https://idp.example/x",
          client_id: "tenant\nclient"
        )

      claims = %{
        "sub" => "okta|delimiter-collision",
        "email" => "delimiter-collision@acme.test",
        "email_verified" => true
      }

      {{:ok, updated}, callback_result} =
        callback_after_verified(provider, claims, fn ->
          SSO.update_provider(
            provider,
            %{
              issuer: "https://idp.example/x\ntenant",
              client_id: "client",
              client_secret: "replacement-secret"
            },
            subject
          )
        end)

      assert Emisar.SSO.Provisioning.namespace_fingerprint(provider) ==
               Emisar.SSO.Provisioning.namespace_fingerprint(updated)

      assert callback_result == {:error, :identity_namespace_changed}
      assert link_requests(provider.id) == []

      refute Repo.exists?(
               Accounts.Membership.Query.not_deleted()
               |> Accounts.Membership.Query.by_email(claims["email"])
             )

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(provider.id)
             )

      refute Repo.exists?(
               Audit.Event.Query.all()
               |> Audit.Event.Query.by_account_id(account.id)
               |> Audit.Event.Query.by_event_type("user.provisioned_via_sso")
             )
    end

    test "network verification holds no DB lock and a changed namespace is rejected without writes" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      claims = %{
        "sub" => "okta|namespace-race",
        "email" => "namespace@acme.test",
        "email_verified" => true
      }

      {{:ok, updated}, callback_result} =
        callback_after_verified(provider, claims, fn ->
          SSO.update_provider(
            provider,
            %{issuer: "https://replacement-idp.test", client_secret: "replacement-secret"},
            subject
          )
        end)

      assert updated.issuer == "https://replacement-idp.test"
      assert callback_result == {:error, :identity_namespace_changed}
      assert link_requests(provider.id) == []

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(provider.id)
             )

      refute Repo.exists?(
               Audit.Event.Query.all()
               |> Audit.Event.Query.by_account_id(account.id)
               |> Audit.Event.Query.by_event_type("user.provisioned_via_sso")
             )
    end

    test "a current manual policy parks the verified identity instead of using stale JIT" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)
      claims = %{"sub" => "okta|manual-race", "email" => "manual@acme.test"}

      {{:ok, updated}, callback_result} =
        callback_after_verified(provider, claims, fn ->
          SSO.update_provider(provider, %{provisioner: :manual}, subject)
        end)

      assert updated.provisioner == :manual
      assert {:pending, %LinkRequest{provider_identifier: "okta|manual-race"}} = callback_result

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(provider.id)
             )
    end

    test "directory sync enabled after verification also prevents stale JIT provisioning" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)
      claims = %{"sub" => "okta|scim-race", "email" => "scim@acme.test"}

      {{:ok, updated, _token}, callback_result} =
        callback_after_verified(provider, claims, fn ->
          SSO.enable_scim(provider, subject)
        end)

      assert updated.scim_enabled
      assert {:pending, %LinkRequest{provider_identifier: "okta|scim-race"}} = callback_result

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(provider.id)
             )
    end

    test "current role and runner/pack defaults own every JIT write and its audit" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, default_role: :viewer)
      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id, pack_id: "postgres")

      claims = %{
        "sub" => "okta|current-defaults",
        "email" => "defaults@acme.test",
        "email_verified" => true
      }

      attrs = %{
        default_role: :operator,
        default_runner_access_mode: :all,
        default_runner_scope: [],
        default_pack_access_mode: :restricted,
        default_pack_scope: ["pack:postgres"]
      }

      {{:ok, updated}, callback_result} =
        callback_after_verified(provider, claims, fn ->
          SSO.update_provider(provider, attrs, subject)
        end)

      assert updated.default_role == :operator
      assert {:ok, %{membership: membership, provider: current}} = callback_result
      assert current.id == updated.id
      assert current.default_role == :operator
      assert membership.role == :operator

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               %RunnerAccess{
                 mode: :all,
                 groups: [],
                 runner_ids: [],
                 pack_mode: :restricted,
                 pack_ids: ["postgres"]
               }

      assert {:ok, [event], _metadata} =
               Audit.list_events(subject,
                 filter: [event_type: ["user.provisioned_via_sso"]]
               )

      assert event.payload["role"] == "operator"
      assert event.payload["runner_access"]["mode"] == "all"
      assert event.payload["runner_access"]["pack_mode"] == "restricted"
    end

    test "a tightened current domain rejects a returning identity before last_seen changes" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      claims = %{
        "sub" => "okta|domain-race",
        "email" => "returning@acme.test",
        "email_verified" => true
      }

      assert {:ok, %{identity: identity}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      {{:ok, updated}, callback_result} =
        callback_after_verified(provider, claims, fn ->
          SSO.update_provider(provider, %{allowed_email_domain: "other.test"}, subject)
        end)

      assert updated.allowed_email_domain == "other.test"
      assert callback_result == {:error, :email_domain_not_allowed}
      assert Repo.reload!(identity).last_seen_at == identity.last_seen_at
    end
  end

  describe "complete_auth/4 — a connection disabled mid-flight" do
    test "a first login cannot land through a door the account just closed" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      {:ok, disabled} = SSO.update_provider(provider, %{enabled: false}, subject)

      claims = %{"sub" => "okta|mid-flight", "email" => "mf@acme.test", "email_verified" => true}

      assert SSO.complete_auth(disabled, callback(claims), %{}, %RequestContext{}) ==
               {:error, :provider_disabled}
    end

    test "a returning member cannot either" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|returning", "email" => "ret@acme.test", "email_verified" => true}

      assert {:ok, _} = SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      {:ok, disabled} = SSO.update_provider(provider, %{enabled: false}, subject)

      assert SSO.complete_auth(disabled, callback(claims), %{}, %RequestContext{}) ==
               {:error, :provider_disabled}
    end

    test "a cancellation committed before callback completion refuses the session" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)

      claims = %{
        "sub" => "okta|expired",
        "email" => "expired@acme.test",
        "email_verified" => true
      }

      {_canceled, callback_result} =
        callback_after_verified(provider, claims, fn ->
          Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")
        end)

      assert callback_result == {:error, :sso_not_available}

      refute Repo.exists?(
               Accounts.Membership.Query.not_deleted()
               |> Accounts.Membership.Query.by_email(claims["email"])
             )
    end
  end

  describe "complete_auth/4 — allowed_email_domain gate (H1)" do
    setup do
      {_owner, account, _subject} = enterprise_owner()
      %{account: account}
    end

    test "a verified email in the allowed domain is admitted", %{account: account} do
      provider = provider_fixture(account, allowed_email_domain: "acme.test")
      claims = %{"sub" => "okta|in", "email" => "ok@acme.test", "email_verified" => true}

      assert {:ok, %{membership: _}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})
    end

    test "a verified email outside the allowed domain is refused", %{account: account} do
      provider = provider_fixture(account, allowed_email_domain: "acme.test")
      claims = %{"sub" => "okta|out", "email" => "x@evil.test", "email_verified" => true}

      assert SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{}) ==
               {:error, :email_domain_not_allowed}
    end

    test "Google Workspace hd proves the domain but not the email address", %{account: account} do
      provider =
        provider_fixture(account,
          kind: :google_workspace,
          allowed_email_domain: "acme.test"
        )

      claims = %{"sub" => "g|hd", "email" => "x@acme.test", "hd" => "acme.test"}

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert is_nil(membership.email)
    end

    test "an explicit unverified-email claim cannot use hd to pass the domain gate", %{
      account: account
    } do
      provider =
        provider_fixture(account,
          kind: :google_workspace,
          allowed_email_domain: "acme.test"
        )

      claims = %{
        "sub" => "g|unverified-hd",
        "email" => "x@acme.test",
        "email_verified" => "false",
        "hd" => "acme.test"
      }

      assert SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{}) ==
               {:error, :email_domain_not_allowed}
    end

    test "Google Workspace treats a present hd as authoritative", %{account: account} do
      provider =
        provider_fixture(account,
          kind: :google_workspace,
          allowed_email_domain: "acme.test"
        )

      claims = %{
        "sub" => "g|wrong-hd",
        "email" => "x@acme.test",
        "email_verified" => true,
        "hd" => "other.test"
      }

      assert SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{}) ==
               {:error, :email_domain_not_allowed}
    end

    test "Okta and generic OIDC ignore hd without an explicitly verified email" do
      for kind <- [:okta, :openid_connect] do
        {_owner, account, _subject} = enterprise_owner()
        domain = "#{kind}.test"
        provider = provider_fixture(account, kind: kind, allowed_email_domain: domain)
        claims = %{"sub" => "#{kind}|hd", "email" => "x@#{domain}", "hd" => domain}

        assert SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{}) ==
                 {:error, :email_domain_not_allowed}
      end
    end

    test "a non-Google provider uses verified email and ignores a misleading hd", %{
      account: account
    } do
      provider = provider_fixture(account, kind: :okta, allowed_email_domain: "acme.test")

      claims = %{
        "sub" => "okta|verified-email",
        "email" => "ok@acme.test",
        "email_verified" => "true",
        "hd" => "evil.test"
      }

      assert {:ok, %{membership: membership}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert membership.email == "ok@acme.test"
    end

    test "no verified domain is refused when a domain is required", %{account: account} do
      provider = provider_fixture(account, allowed_email_domain: "acme.test")
      claims = %{"sub" => "okta|nodomain"}

      assert SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{}) ==
               {:error, :email_domain_not_allowed}
    end
  end

  describe "begin_invitation_sso_sign_in/4" do
    test "checks the proof from the same browser and begins a forced fresh sign-in at one of the workspace's connections" do
      fixture = invitation_sso_fixture()
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingResetOIDC)

      assert {:ok, begun} =
               SSO.begin_invitation_sso_sign_in(
                 fixture.proof,
                 fixture.provider.id,
                 @redirect_uri,
                 fixture.browser_id
               )

      assert_receive {:reset_oidc_begin_options, opts}
      assert opts[:url_extension] == [{"prompt", "login"}, {"max_age", "0"}]
      assert opts[:redirect_uri] == @redirect_uri

      assert Map.drop(begun, [:started_at]) == %{
               authorize_url: "https://idp.test/auth",
               state: "s",
               nonce: "n",
               pkce_verifier: "v",
               account_id: fixture.account.id,
               membership_id: fixture.invitation.id,
               invitation_token_digest: Crypto.user_invite_token_digest(fixture.invitation_token),
               provider_id: fixture.provider.id,
               namespace: namespace(fixture.provider)
             }

      assert is_integer(begun.started_at)
      assert_invitation_untouched(fixture)
    end

    test "refuses another browser's or a forged proof, and a connection of another workspace or a disabled one" do
      fixture = invitation_sso_fixture()

      assert SSO.begin_invitation_sso_sign_in(
               fixture.proof,
               fixture.provider.id,
               @redirect_uri,
               Crypto.random_secret()
             ) == {:error, :invitation_sso_invalid}

      assert SSO.begin_invitation_sso_sign_in(
               "not-a-proof",
               fixture.provider.id,
               @redirect_uri,
               fixture.browser_id
             ) == {:error, :invitation_sso_invalid}

      {_other_owner, other_account, _other_subject} = enterprise_owner()
      foreign = provider_fixture(other_account)

      assert SSO.begin_invitation_sso_sign_in(
               fixture.proof,
               foreign.id,
               @redirect_uri,
               fixture.browser_id
             ) == {:error, :not_found}

      Fixtures.SSO.disable_provider(fixture.provider)

      assert SSO.begin_invitation_sso_sign_in(
               fixture.proof,
               fixture.provider.id,
               @redirect_uri,
               fixture.browser_id
             ) == {:error, :not_found}

      assert_invitation_untouched(fixture)
    end
  end

  describe "complete_invitation_sso_sign_in/5" do
    test "accepts the invitation, binds the returned identity and mints the Member's SSO session in one transaction, once" do
      fixture = invitation_sso_fixture()
      {:ok, begun} = begin_invitation_sso(fixture)
      claims = invitee_claims(fixture, "okta|invitee")

      assert {:ok, raw,
              %Accounts.Membership{account: %Accounts.Account{id: account_id}} = accepted} =
               SSO.complete_invitation_sso_sign_in(
                 callback(claims),
                 begun,
                 fixture.proof,
                 fixture.browser_id,
                 %RequestContext{}
               )

      assert {account_id, accepted.id} == {fixture.account.id, fixture.invitation.id}
      assert accepted.display_name == "Invited Name"
      assert %DateTime{} = accepted.invitation_accepted_at
      assert %DateTime{} = accepted.email_verified_at
      assert is_nil(accepted.invitation_token_digest)

      assert [%UserIdentity{} = identity] = member_identities(accepted)
      assert identity.provider_id == fixture.provider.id
      assert identity.provider_identifier == "okta|invitee"
      assert identity.created_by == :user
      assert identity.provisioned_via == :oidc_link
      refute identity.scim_external_id

      assert {:ok, %UserToken{} = session} = Auth.fetch_session_by_token(raw, fixture.account.id)
      assert session.membership_id == accepted.id
      assert session.auth_method == :sso
      assert session.user_identity_id == identity.id
      assert session.sso_issuer == fixture.provider.issuer
      assert session.sso_provider_identifier == "okta|invitee"
      assert session.browser_digest == Crypto.hash(fixture.browser_id)
      assert session_count(accepted) == 1

      # The proved code is spent with the acceptance.
      refute Repo.get(UserToken, fixture.code_id)

      event_types =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_account_id(fixture.account.id)
        |> Repo.all()
        |> Enum.map(& &1.event_type)

      for type <- ["user.invitation_accepted", "sso.identity_linked", "user.signed_in"] do
        assert type in event_types
      end

      # A replayed callback finds the proved code spent.
      assert SSO.complete_invitation_sso_sign_in(
               callback(claims),
               begun,
               fixture.proof,
               fixture.browser_id,
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      assert session_count(accepted) == 1
    end

    test "refuses a missing, pre-ceremony or stale auth_time and accepts, binds and mints nothing" do
      fixture = invitation_sso_fixture()
      {:ok, begun} = begin_invitation_sso(fixture)
      now = System.system_time(:second)

      for auth_time <- [nil, "soon", begun.started_at - 31, now - 200] do
        claims = fixture |> invitee_claims("okta|invitee") |> put_auth_time(auth_time)

        assert SSO.complete_invitation_sso_sign_in(
                 callback(claims),
                 begun,
                 fixture.proof,
                 fixture.browser_id,
                 %RequestContext{}
               ) == {:error, :invitation_sso_invalid}
      end

      assert_invitation_untouched(fixture)
    end

    test "refuses another browser, a stash naming another invitation or missing its proof, and a connection disabled or repointed since the step began" do
      fixture = invitation_sso_fixture()
      {:ok, begun} = begin_invitation_sso(fixture)

      complete = fn stash, proof, browser_id ->
        SSO.complete_invitation_sso_sign_in(
          callback(invitee_claims(fixture, "okta|invitee")),
          stash,
          proof,
          browser_id,
          %RequestContext{}
        )
      end

      assert complete.(begun, fixture.proof, Crypto.random_secret()) ==
               {:error, :invitation_sso_invalid}

      assert complete.(
               %{begun | membership_id: Ecto.UUID.generate()},
               fixture.proof,
               fixture.browser_id
             ) == {:error, :invitation_sso_invalid}

      assert complete.(begun, nil, fixture.browser_id) == {:error, :invitation_sso_invalid}

      repointed = %{
        begun
        | namespace:
            {"https://other.test", fixture.provider.client_id, fixture.provider.identifier_claim}
      }

      assert complete.(repointed, fixture.proof, fixture.browser_id) ==
               {:error, :identity_namespace_changed}

      Fixtures.SSO.disable_provider(fixture.provider)
      assert complete.(begun, fixture.proof, fixture.browser_id) == {:error, :provider_disabled}

      assert_invitation_untouched(fixture)
    end

    test "a live Member holding the returned identity refuses the step; one left on a removed seat moves to the invitee" do
      fixture = invitation_sso_fixture()
      holder = Fixtures.Memberships.create_membership(account_id: fixture.account.id)

      held =
        Fixtures.SSO.create_user_identity(%{
          account_id: fixture.account.id,
          provider_id: fixture.provider.id,
          membership: holder,
          provider_identifier: "okta|held"
        })

      {:ok, begun} = begin_invitation_sso(fixture)

      assert SSO.complete_invitation_sso_sign_in(
               callback(invitee_claims(fixture, "okta|held")),
               begun,
               fixture.proof,
               fixture.browser_id,
               %RequestContext{}
             ) == {:error, :identity_already_linked}

      assert_invitation_untouched(fixture)
      assert Fixtures.SSO.identity_membership(held).id == holder.id

      assert {:ok, _removed} = Accounts.delete_membership(holder, fixture.subject)

      assert {:ok, _raw, accepted} =
               SSO.complete_invitation_sso_sign_in(
                 callback(invitee_claims(fixture, "okta|held")),
                 begun,
                 fixture.proof,
                 fixture.browser_id,
                 %RequestContext{}
               )

      assert accepted.id == fixture.invitation.id
      rebound = Repo.reload!(held)
      assert rebound.membership_id == accepted.id
      assert rebound.created_by == :user
      refute rebound.provider_identifier_retired_at
    end

    test "SCIM after the step: a directory create for the bound subject adopts the identity onto the same Member" do
      fixture = invitation_sso_fixture()
      provider = Fixtures.SSO.enable_scim(fixture.provider)
      accepted = accept_through_sso(fixture, "okta|invitee")
      [identity] = member_identities(accepted)

      assert {:ok, %{identity: adopted, membership: same}} =
               SSO.scim_provision_user(provider, %{
                 external_id: "okta|invitee",
                 email: fixture.email,
                 full_name: "Directory Name"
               })

      assert adopted.id == identity.id
      assert adopted.scim_external_id == "okta|invitee"
      assert adopted.provider_identifier == "okta|invitee"
      assert same.id == accepted.id
      assert same.role == :operator
      assert [%UserIdentity{id: adopted_id}] = member_identities(accepted)
      assert adopted_id == identity.id

      assert Accounts.Membership.Query.not_deleted()
             |> Accounts.Membership.Query.by_account_id(fixture.account.id)
             |> Accounts.Membership.Query.by_email(fixture.email)
             |> Repo.aggregate(:count) == 1
    end

    test "SCIM after the step: another externalId for the invited address parks a link request whose approval rebinds the same identity" do
      fixture = invitation_sso_fixture()
      provider = Fixtures.SSO.enable_scim(fixture.provider)
      accepted = accept_through_sso(fixture, "okta|invitee")
      [identity] = member_identities(accepted)

      assert SSO.scim_provision_user(provider, %{
               external_id: "directory|other",
               email: fixture.email,
               full_name: "Directory Name"
             }) == {:error, :identity_pending_approval}

      assert [%LinkRequest{source: :scim} = request] = link_requests(provider.id)
      assert request.matched_membership_id == accepted.id

      assert {:ok, %{identity: rebound, membership: linked}} =
               SSO.approve_link_request(request, RunnerAccess.none(), fixture.subject)

      assert rebound.id == identity.id
      assert rebound.provider_identifier == "okta|invitee"
      assert rebound.scim_external_id == "directory|other"
      assert linked.id == accepted.id
      assert [%UserIdentity{id: rebound_id}] = member_identities(accepted)
      assert rebound_id == identity.id
    end

    test "SCIM after the step: a seat the directory created first for the returned subject refuses the step and leaves the invitation pending" do
      fixture = invitation_sso_fixture()
      provider = Fixtures.SSO.enable_scim(fixture.provider)

      assert {:ok, %{identity: seated_identity, membership: seated}} =
               SSO.scim_provision_user(provider, %{
                 external_id: "okta|invitee",
                 email: "someone-else@acme.test",
                 full_name: "Someone Else"
               })

      {:ok, begun} = begin_invitation_sso(fixture)

      assert SSO.complete_invitation_sso_sign_in(
               callback(invitee_claims(fixture, "okta|invitee")),
               begun,
               fixture.proof,
               fixture.browser_id,
               %RequestContext{}
             ) == {:error, :identity_already_linked}

      assert_invitation_untouched(fixture)
      assert Fixtures.SSO.identity_membership(seated_identity).id == seated.id
      refute Repo.reload!(seated).disabled_at
    end
  end

  # -- authenticate_scim_token/1 (provider-scoped) ---------------------

  describe "authenticate_scim_token/1" do
    setup do
      scim_provider()
    end

    test "resolves the right provider by prefix + hash", %{provider: provider, token: token} do
      assert {:ok, resolved} = SSO.authenticate_scim_token(token)
      assert resolved.id == provider.id
      assert resolved.account_id == provider.account_id
    end

    test "stamps scim_last_seen_at on a successful auth (the 'is sync working?' signal)", %{
      provider: provider,
      token: token
    } do
      assert is_nil(provider.scim_last_seen_at)

      assert {:ok, _resolved} = SSO.authenticate_scim_token(token)

      assert %DateTime{} = Repo.reload!(provider).scim_last_seen_at
    end

    test "a garbage / too-short / wrong token is :unauthorized", %{token: token} do
      assert SSO.authenticate_scim_token("") == {:error, :unauthorized}
      assert SSO.authenticate_scim_token("ems-") == {:error, :unauthorized}
      assert SSO.authenticate_scim_token("ems-totally-wrong-secret") == {:error, :unauthorized}
      # A correct prefix but a tampered tail must still fail the hash compare.
      assert SSO.authenticate_scim_token(token <> "x") == {:error, :unauthorized}
    end

    test "a token whose provider has scim disabled is :unauthorized", %{
      provider: provider,
      token: token,
      subject: subject
    } do
      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert SSO.authenticate_scim_token(token) == {:error, :unauthorized}
    end

    test "an expired account refuses its retained token without touching last-seen", %{
      account: account,
      provider: provider,
      token: token
    } do
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      assert SSO.authenticate_scim_token(token) == {:error, :unauthorized}
      assert is_nil(Repo.reload!(provider).scim_last_seen_at)
    end

    test "token A resolves to provider A only — never account B's provider", %{
      provider: provider_a,
      token: token_a
    } do
      %{provider: provider_b} = scim_provider()

      assert {:ok, resolved} = SSO.authenticate_scim_token(token_a)
      assert resolved.id == provider_a.id
      refute resolved.id == provider_b.id
      assert resolved.account_id != provider_b.account_id
    end

    test "a soft-deleted provider sharing the prefix doesn't crash the lookup", %{
      provider: provider,
      token: token
    } do
      # The partial-unique prefix index only covers live rows, so a soft-deleted
      # provider may carry the same prefix. The lookup must scope to live rows
      # and resolve the live provider — not raise on two prefix matches.
      %{provider: ghost} = scim_provider()

      ghost
      |> Ecto.Changeset.change(
        scim_token_prefix: provider.scim_token_prefix,
        deleted_at: DateTime.utc_now()
      )
      |> Repo.update!()

      assert {:ok, resolved} = SSO.authenticate_scim_token(token)
      assert resolved.id == provider.id
    end
  end

  # -- scim_provision_user/2 (provider-scoped) -------------------------

  describe "pulling a connection ends the sessions it vouched for" do
    setup do
      scim_provider()
    end

    test "disabling deletes the sessions in its transaction and disconnects them after", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity, membership: member} = provision(provider, "okta|live")

      token =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      marker = record_session_effects()
      expected_topic = Auth.live_socket_topic(Crypto.hash(token))
      refute Repo.in_transaction?()
      assert {:ok, _} = SSO.update_provider(provider, %{enabled: false}, subject)

      assert_received {^marker, true}
      refute_received {^marker, false}
      assert_received {:scim_delete_disconnect, [^expected_topic], false}

      assert Auth.fetch_session_by_token(token, provider.account_id) == {:error, :not_found}
      refute Repo.exists?(UserToken.Query.by_token_digest(Crypto.hash(token)))
    end

    test "deleting deletes the sessions in its transaction and disconnects them after", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity, membership: member} = provision(provider, "okta|gone")

      token =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      marker = record_session_effects()
      expected_topic = Auth.live_socket_topic(Crypto.hash(token))
      refute Repo.in_transaction?()
      assert {:ok, _} = SSO.delete_provider(provider, subject)

      assert_received {^marker, true}
      refute_received {^marker, false}
      assert_received {:scim_delete_disconnect, [^expected_topic], false}

      assert Auth.fetch_session_by_token(token, provider.account_id) == {:error, :not_found}
      refute Repo.exists?(UserToken.Query.by_token_digest(Crypto.hash(token)))
    end

    test "an MFA-trust downgrade revokes only that provider's sessions", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      provider = provider |> Ecto.Changeset.change(satisfies_mfa: true) |> Repo.update!()
      %{identity: identity, membership: member} = provision(provider, "okta|mfa-downgrade")
      other_provider = provider_fixture(account, kind: :entra, name: "Entra")

      other_identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: other_provider.id,
          membership: member,
          provider_identifier: "entra|same-member"
        })

      provider_token =
        Fixtures.Auth.create_session_token!(member, :sso, DateTime.utc_now(), %{},
          user_identity_id: identity.id
        )

      other_token =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{},
          user_identity_id: other_identity.id
        )

      magic_token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      marker = record_session_effects()
      expected_topic = Auth.live_socket_topic(Crypto.hash(provider_token))
      refute Repo.in_transaction?()

      assert {:ok, downgraded} =
               SSO.update_provider(provider, %{satisfies_mfa: false}, subject)

      assert_received {^marker, true}
      refute_received {^marker, false}
      assert_received {:scim_delete_disconnect, [^expected_topic], false}
      refute downgraded.satisfies_mfa
      assert Auth.fetch_session_by_token(provider_token, account.id) == {:error, :not_found}

      member_id = member.id

      assert {:ok, %UserToken{membership_id: ^member_id}} =
               Auth.fetch_session_by_token(other_token, account.id)

      assert {:ok, %UserToken{membership_id: ^member_id}} =
               Auth.fetch_session_by_token(magic_token, account.id)
    end

    test "unchanged or increasing MFA trust does not revoke a provider session", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity, membership: member} = provision(provider, "okta|mfa-noop")

      token =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      assert {:ok, still_false} =
               SSO.update_provider(provider, %{satisfies_mfa: false}, subject)

      assert {:ok, now_true} =
               SSO.update_provider(still_false, %{satisfies_mfa: true}, subject)

      assert {:ok, _still_true} =
               SSO.update_provider(now_true, %{satisfies_mfa: true}, subject)

      member_id = member.id

      assert {:ok, %UserToken{membership_id: ^member_id}} =
               Auth.fetch_session_by_token(token, provider.account_id)
    end
  end

  describe "provider_identity_namespace_locked?/2" do
    setup do
      scim_provider()
    end

    test "the namespace-lock read follows live identities, with permission and account isolation",
         %{
           provider: provider,
           subject: subject,
           account: account
         } do
      assert SSO.provider_identity_namespace_locked?(provider, subject) == {:ok, false}
      _ = provision(provider, "okta|namespace-lock")
      assert SSO.provider_identity_namespace_locked?(provider, subject) == {:ok, true}

      assert SSO.provider_identity_namespace_locked?(provider, viewer_in(account)) ==
               {:error, :unauthorized}

      {_owner, _account, stranger} = enterprise_owner()
      assert SSO.provider_identity_namespace_locked?(provider, stranger) == {:error, :not_found}
    end
  end

  describe "update_provider/3 — the identity namespace is settled by the first identity" do
    setup do
      scim_provider()
    end

    test "refuses to repoint issuer, client id or identifier claim once someone is bound", %{
      provider: provider,
      subject: subject
    } do
      _ = provision(provider, "okta|victim")

      # The takeover this closes: repoint the connection at an IdP the admin
      # controls, mint a token whose claim equals an existing member's stored
      # identifier, and sign in as them — the identity row matches on
      # (provider_id, provider_identifier) and never notices the issuer moved.
      for attrs <- [
            %{issuer: "https://attacker.example.com"},
            %{client_id: "attacker-client"},
            %{identifier_claim: "oid"}
          ] do
        assert SSO.update_provider(provider, attrs, subject) ==
                 {:error, :identity_namespace_locked},
               "#{inspect(attrs)} must not be editable once identities exist"
      end

      reloaded = Repo.reload!(provider)
      assert reloaded.issuer == provider.issuer
      assert reloaded.client_id == provider.client_id
    end

    test "still allows a secret rotation, a rename and role retargeting", %{
      provider: provider,
      subject: subject
    } do
      _ = provision(provider, "okta|bound")

      assert {:ok, updated} =
               SSO.update_provider(
                 provider,
                 %{name: "Renamed", client_secret: "rotated-secret", default_role: :viewer},
                 subject
               )

      assert updated.name == "Renamed"
      assert updated.default_role == :viewer
    end

    test "a connection nobody has signed in through is still fully editable", %{
      provider: provider,
      subject: subject
    } do
      # The NAMESPACE is what the first identity settles. Repointing the issuer
      # separately requires the client secret — carrying a write-only one over to
      # a new issuer would post it to that issuer's token endpoint — so this
      # supplies it.
      attrs = %{issuer: "https://new-idp.example.com", client_secret: "secret"}

      assert {:ok, updated} = SSO.update_provider(provider, attrs, subject)
      assert updated.issuer == "https://new-idp.example.com"
    end
  end

  describe "scim_provision_user/2" do
    setup do
      scim_provider()
    end

    test "a provider authenticated before cancellation cannot write afterward", %{
      account: account,
      token: token
    } do
      assert {:ok, stale_provider} = SSO.authenticate_scim_token(token)
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      email = "expired-scim-#{System.unique_integer([:positive])}@acme.test"

      assert SSO.scim_provision_user(stale_provider, %{
               external_id: "expired-scim",
               email: email,
               full_name: "Expired SCIM"
             }) == {:error, :directory_sync_disabled}

      refute Repo.exists?(
               Accounts.Membership.Query.not_deleted()
               |> Accounts.Membership.Query.by_email(email)
             )
    end

    test "a duplicate create carrying active:false offboards rather than reactivating", %{
      provider: provider
    } do
      # A replayed or duplicated POST used to force the member active: the IdP
      # said "inactive" and we heard "active", silently undoing an offboarding.
      %{membership: created} = provision(provider, "departed-1", %{active: false})
      refute is_nil(created.disabled_at)

      %{identity: identity, membership: membership} =
        provision(provider, "departed-1", %{active: false})

      refute identity.scim_active
      refute is_nil(membership.disabled_at), "a repeated active:false must not reinstate"
    end

    test "a create carrying active:false deactivates a member who is currently active", %{
      provider: provider
    } do
      %{membership: active} = provision(provider, "leaver-1")
      assert is_nil(active.disabled_at)

      %{identity: identity, membership: membership} =
        provision(provider, "leaver-1", %{active: false})

      refute identity.scim_active
      refute is_nil(membership.disabled_at)
    end

    test "adopts an OIDC-first identity so SCIM can later offboard it", %{
      provider: provider,
      account: account
    } do
      # An identity created by an SSO sign-in has a provider_identifier but no
      # scim_external_id. The directory reuses it here and stamps its own
      # correlation value for later POST reconciliation and externalId filters.
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, oidc_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "shared-id",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )
        |> Repo.insert()

      assert is_nil(oidc_identity.scim_external_id)

      %{identity: adopted} = provision(provider, "shared-id")
      assert adopted.id == oidc_identity.id
      assert adopted.scim_external_id == "shared-id"

      # …and the lifecycle endpoints can now find it.
      assert {:ok, %{identity: deactivated}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "shared-id"),
                 %SCIMUserUpdate{active: false}
               )

      refute deactivated.scim_active
    end

    test "a create asserting active:false for an identity with no membership offboards nothing",
         %{
           provider: provider,
           account: account
         } do
      # An IdP replays offboarding as a POST against an OIDC-first identity whose
      # membership an operator already removed locally. Answering :not_found made
      # Okta/Entra retry the deactivate forever or re-create the person.
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, _oidc_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "departed-sub",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )
        |> Repo.insert()

      Fixtures.Memberships.mark_membership_as_deleted(member)

      assert {:ok, %{membership: nil}} =
               SSO.scim_provision_user(
                 provider,
                 scim_attrs(%{external_id: "departed-sub", active: false})
               )

      refute Accounts.peek_sync_membership_by_id(account.id, member.id)
      assert Repo.reload!(member).deleted_at
    end

    test "a sign-in cannot land on a directory-created identity for someone else", %{
      account: account,
      provider: provider
    } do
      # SCIM provisioning writes its externalId into the OIDC column too, so a
      # later login by `sub` converges on the same person. Sound while both
      # namespaces belong to one directory — but wire SCIM to a different system
      # and the id spaces are unrelated, and then one person's sub can equal
      # another's externalId. Before this guard, the second person's login resolved
      # the first person's identity and signed them in AS them.
      {:ok, %{membership: alice}} =
        SSO.scim_provision_user(provider, %{
          external_id: "shared-value",
          email: "alice@acme.test"
        })

      # Pin the precondition this whole test rests on: SCIM wrote its externalId
      # into the OIDC column too.
      alice_identity = Repo.one(SSO.UserIdentity)
      assert alice_identity.provider_identifier == "shared-value"
      assert alice_identity.scim_external_id == "shared-value"
      assert alice_identity.provisioned_via == :scim

      # Bob presents the same value as his sub, with his own email.
      bob_claims = %{
        "sub" => "shared-value",
        "email" => "bob@acme.test",
        "email_verified" => true,
        "name" => "Bob"
      }

      # He gets an admin decision, not Alice's account.
      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(provider, callback(bob_claims), %{}, %RequestContext{})

      # Alice herself still converges — same value, and the verified email names
      # her seat's workspace contact.
      alice_claims = %{
        "sub" => "shared-value",
        "email" => "  ALICE@ACME.TEST  ",
        "email_verified" => true
      }

      assert {:ok, %{membership: signed_in}} =
               SSO.complete_auth(provider, callback(alice_claims), %{}, %RequestContext{})

      assert signed_in.id == alice.id
      assert signed_in.account_id == account.id
    end

    test "an unverified email cannot converge a synthesized directory identity", %{
      provider: okta_provider
    } do
      provider = Repo.update!(Ecto.Changeset.change(okta_provider, kind: :openid_connect))

      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{
          external_id: "shared-unverified",
          email: "alice-unverified@acme.test"
        })

      claims = %{
        "sub" => "shared-unverified",
        "email" => "alice-unverified@acme.test"
      }

      assert {:pending, %LinkRequest{} = request} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert request.email == "alice-unverified@acme.test"
      assert is_nil(request.matched_membership_id)
      assert Repo.reload!(identity).last_seen_at == identity.last_seen_at
    end

    test "the same-person rule reads the seat's workspace contact — another address for the sub is parked",
         %{
           provider: okta_provider
         } do
      provider = Repo.update!(Ecto.Changeset.change(okta_provider, kind: :openid_connect))

      %{identity: identity, membership: member} =
        provision(provider, "contact-rule", %{email: "contact@acme.test"})

      # A token naming another address is not the seat's person, whatever its sub.
      personal = %{
        "sub" => "contact-rule",
        "email" => "personal@acme.test",
        "email_verified" => true
      }

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(provider, callback(personal), %{}, %RequestContext{})

      assert Repo.reload!(identity).last_seen_at == identity.last_seen_at

      contact = %{
        "sub" => "contact-rule",
        "email" => "contact@acme.test",
        "email_verified" => true
      }

      assert {:ok, %{membership: signed_in}} =
               SSO.complete_auth(provider, callback(contact), %{}, %RequestContext{})

      assert signed_in.id == member.id
    end

    test "Okta converges an exact active SCIM sub when its token omits email_verified" do
      issuer = "https://certification.okta.test"

      %{provider: provider} =
        scim_provider(%{kind: :okta, issuer: issuer, identifier_claim: :sub})

      %{identity: identity} =
        provision(provider, "00u-certification-user", %{email: "okta-cert@acme.test"})

      claims = %{
        "iss" => issuer,
        "sub" => identity.scim_external_id,
        "email" => "okta-cert@acme.test",
        "name" => "Okta Cert"
      }

      assert {:ok, %{identity: signed_in}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert signed_in.id == identity.id
      assert Repo.reload!(identity).last_seen_at
    end

    test "the Okta omission rule refuses wrong issuer, explicit false, and inactive SCIM state" do
      issuer = "https://certification.okta.test"

      %{provider: provider} =
        scim_provider(%{kind: :okta, issuer: issuer, identifier_claim: :sub})

      %{identity: identity} =
        provision(provider, "00u-certification-denial", %{email: "okta-denial@acme.test"})

      claims = %{
        "iss" => issuer,
        "sub" => identity.scim_external_id,
        "email" => "okta-denial@acme.test"
      }

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(
                 provider,
                 callback(%{claims | "iss" => "https://evil.test"}),
                 %{},
                 %RequestContext{}
               )

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(
                 provider,
                 callback(Map.put(claims, "email_verified", false)),
                 %{},
                 %RequestContext{}
               )

      assert {:ok, %{identity: inactive}} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})

      refute inactive.scim_active

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert Repo.reload!(identity).last_seen_at == identity.last_seen_at
    end

    test "Entra converges an exact active SCIM oid when its v2 token omits email_verified" do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, IdentifierClaimOIDC)
      issuer = "https://login.microsoftonline.com/cert-tenant/v2.0"

      %{provider: provider} =
        scim_provider(%{
          kind: :entra,
          name: "Entra",
          issuer: issuer,
          identifier_claim: :oid
        })

      %{identity: identity} =
        provision(provider, "11111111-2222-3333-4444-555555555555", %{
          email: "entra-cert@acme.test"
        })

      claims = %{
        "iss" => issuer,
        "oid" => identity.scim_external_id,
        "email" => "entra-cert@acme.test",
        "name" => "Entra Cert"
      }

      assert {:ok, %{identity: signed_in}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert signed_in.id == identity.id
      assert Repo.reload!(identity).last_seen_at
    end

    test "the Entra omission rule refuses wrong issuer, explicit false, and inactive SCIM state" do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, IdentifierClaimOIDC)
      issuer = "https://login.microsoftonline.com/cert-tenant/v2.0"

      %{provider: provider} =
        scim_provider(%{
          kind: :entra,
          name: "Entra",
          issuer: issuer,
          identifier_claim: :oid
        })

      %{identity: identity} =
        provision(provider, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", %{
          email: "entra-denial@acme.test"
        })

      claims = %{
        "iss" => issuer,
        "oid" => identity.scim_external_id,
        "email" => "entra-denial@acme.test"
      }

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(
                 provider,
                 callback(%{claims | "iss" => "https://evil.test"}),
                 %{},
                 %RequestContext{}
               )

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(
                 provider,
                 callback(Map.put(claims, "email_verified", false)),
                 %{},
                 %RequestContext{}
               )

      assert {:ok, %{identity: inactive}} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})

      refute inactive.scim_active

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert Repo.reload!(identity).last_seen_at == identity.last_seen_at
    end

    test "the Entra omission rule refuses a deleted SCIM resource" do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, IdentifierClaimOIDC)
      issuer = "https://login.microsoftonline.com/cert-tenant/v2.0"

      %{provider: provider} =
        scim_provider(%{
          kind: :entra,
          name: "Entra",
          issuer: issuer,
          identifier_claim: :oid
        })

      %{identity: identity} = provision(provider, "99999999-8888-7777-6666-555555555555")
      assert {:ok, _deleted} = SSO.scim_delete_user(provider, identity.id)

      claims = %{
        "iss" => issuer,
        "oid" => identity.scim_external_id,
        "email" => "retired@acme.test"
      }

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert Repo.reload!(identity).last_seen_at == identity.last_seen_at
    end

    test "a re-capture from the other namespace takes that namespace with it", %{
      account: account,
      provider: provider
    } do
      # The upsert keys on (provider, identifier). When the SAME identifier arrives
      # from the other namespace it describes a different person — email, claims
      # and matched user are all replaced — so the source has to be replaced too.
      # Leaving the original behind made the approval stamp the column the request
      # no longer belonged to.
      first = Fixtures.Memberships.create_membership(account_id: account.id)

      second = Fixtures.Memberships.create_membership(account_id: account.id)

      # OIDC captures the identifier first.
      capture_request(provider, %{
        "sub" => "shared-identifier",
        "email" => first.email,
        "email_verified" => true
      })

      # The directory then presents the SAME identifier for someone else.
      assert SSO.scim_provision_user(provider, %{
               external_id: "shared-identifier",
               email: second.email
             }) == {:error, :identity_pending_approval}

      request =
        SSO.LinkRequest.Query.all()
        |> SSO.LinkRequest.Query.by_provider_id(provider.id)
        |> Repo.one()

      # One row, describing the second person, and carrying the namespace that
      # last described them.
      assert request.email == second.email
      assert request.source == :scim
    end

    test "a directory externalId does not overwrite the OIDC sub it disagrees with", %{
      provider: provider,
      account: account
    } do
      # The oscillation. With sub=S and externalId=E, approval used to stamp
      # whichever value the request carried into `provider_identifier`: approving a
      # SCIM request overwrote S, the next OIDC login then could not find the person
      # and parked its own request, and approving that overwrote E. Back and forth,
      # with whichever side was not current unable to see them at all.
      #
      # The request now records which namespace it came from, so each stamps its own
      # column and the row ends up holding both.
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "oidc-sub-S",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )
        |> Repo.insert()

      # The directory pushes a DIFFERENT identifier for the same person; the email
      # names their seat's contact, so it parks a link request rather than
      # creating a second identity.
      assert SSO.scim_provision_user(provider, %{
               external_id: "directory-external-E",
               email: member.email
             }) == {:error, :identity_pending_approval}

      request =
        SSO.LinkRequest.Query.all()
        |> SSO.LinkRequest.Query.by_provider_id(provider.id)
        |> Repo.one()

      assert request.source == :scim

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner_membership)

      assert {:ok, _} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 subject
               )

      # Both identifiers live on the one row: the login still resolves by its sub,
      # and the directory can now find the person by its externalId.
      linked = Repo.reload!(identity)
      assert linked.provider_identifier == "oidc-sub-S"
      assert linked.scim_external_id == "directory-external-E"
    end

    test "adoption is one-way, so a later externalId cannot re-stamp it", %{
      provider: provider,
      account: account
    } do
      # What keeps an OIDC-first identity from oscillating between identifiers.
      # Adoption fires only while scim_external_id is null and nothing ever returns
      # it to null, so the first externalId to claim the identity keeps it; a
      # different one later is a different resource, not a re-stamp of this one.
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, oidc_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "sub-and-external-agree",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )
        |> Repo.insert()

      %{identity: adopted} = provision(provider, "sub-and-external-agree")
      assert adopted.id == oidc_identity.id
      assert adopted.scim_external_id == "sub-and-external-agree"

      # A push under a different externalId must not move the stamp. The person
      # already holds this connection's one identity, so it cannot quietly become a
      # second — the directory is told, rather than the two values alternating.
      assert {:error, _reason} =
               SSO.scim_provision_user(provider, %{
                 external_id: "a-different-external-id",
                 email: member.email
               })

      assert Repo.reload!(adopted).scim_external_id == "sub-and-external-agree"
    end

    test "creates a user_identity + directory-owned membership at the provider defaults" do
      %{provider: provider, account: account, subject: subject} =
        scim_provider(%{
          default_role: :operator,
          default_runner_access_mode: :restricted,
          default_runner_scope_groups: ["production"]
        })

      attrs = scim_attrs(%{external_id: "okta|prov-1", email: "prov@acme.test"})

      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      assert membership.email == "prov@acme.test"
      # A directory asserts an address; nobody proved the inbox.
      refute membership.email_verified_at

      assert identity.created_by == :provider
      assert identity.provisioned_via == :scim
      # The externalId is stored as BOTH the binding identifier and the
      # scim_external_id (decision 4) so OIDC + SCIM converge on one identity.
      assert identity.provider_identifier == "okta|prov-1"
      assert identity.scim_external_id == "okta|prov-1"
      assert identity.scim_active

      assert membership.account_id == account.id
      assert membership.role == :operator
      assert membership.directory_managed
      assert membership.runner_access_directory_managed
      refute membership.disabled_at

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               %RunnerAccess{mode: :restricted, groups: ["production"], runner_ids: []}

      assert {:ok, [event], _meta} =
               Audit.list_events(subject,
                 filter: [event_type: ["user.provisioned_via_scim"]]
               )

      assert event.payload["runner_access"] == %{
               "mode" => "restricted",
               "groups" => ["production"],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }
    end

    test "a provision with active:false is born suspended — a user deactivated in the IdP never holds access",
         %{provider: provider} do
      attrs =
        scim_attrs(%{external_id: "okta|disabled", email: "disabled@acme.test", active: false})

      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      refute identity.scim_active
      assert membership.disabled_at
    end

    test "a repeated provision for the same externalId reconciles — no duplicate", %{
      provider: provider
    } do
      attrs = scim_attrs(%{external_id: "okta|stable", email: "stable@acme.test"})

      assert {:ok, %{membership: first, identity: id1}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{membership: second, identity: id2}} =
               SSO.scim_provision_user(provider, attrs)

      assert first.id == second.id
      assert id1.id == id2.id

      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_provider_id(provider.id)
             |> Repo.aggregate(:count) == 1
    end

    test "a re-POST of a deprovisioned (suspended) user reactivates them (#4)", %{
      provider: provider,
      account: account
    } do
      attrs = scim_attrs(%{external_id: "okta|readd", email: "readd@acme.test"})

      assert {:ok, %{membership: member}} = SSO.scim_provision_user(provider, attrs)

      {:ok, _} =
        SSO.scim_update_user(provider, user_resource_id(provider, "okta|readd"), %SCIMUserUpdate{
          active: false
        })

      assert Accounts.peek_sync_membership_by_id(account.id, member.id).disabled_at

      # Some IdPs re-POST rather than PATCH active:true — the re-POST restores
      # access (reinstate the membership + scim_active), never staying suspended.
      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      refute membership.disabled_at
      assert identity.scim_active
    end

    test "a re-POST does NOT undo a MANUAL suspend (still active in the IdP) — break-glass holds",
         %{
           provider: provider,
           account: account
         } do
      attrs = scim_attrs(%{external_id: "okta|manual", email: "manual@acme.test"})
      assert {:ok, %{membership: member}} = SSO.scim_provision_user(provider, attrs)

      # An operator suspends them in the portal; the IdP still lists them active,
      # so scim_active stays true — this is NOT an IdP deprovision.
      membership = Accounts.peek_sync_membership_by_id(account.id, member.id)
      assert Fixtures.Memberships.suspend_membership(membership).disabled_at

      # A routine re-POST (an IdP that re-creates the still-active user) must NOT
      # lift the manual suspend.
      assert {:ok, %{membership: reprovisioned}} = SSO.scim_provision_user(provider, attrs)
      assert reprovisioned.disabled_at
    end

    test "a re-POST re-seats a removed person once no invitation holds their address",
         %{provider: provider, subject: subject} do
      attrs = scim_attrs(%{external_id: "okta|reinvited", email: "reinvited@acme.test"})

      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      # The person was removed from the workspace, then their address was
      # invited back by hand — the identity survives both. The invitation names
      # only the address, so it is not the person's seat, but one address is one
      # Member here: the directory's push is refused while the invitation holds
      # it and re-adds the person after.
      assert {:ok, _removed} = Accounts.delete_membership(membership, subject)

      invitation_attrs = Fixtures.Accounts.invitation_attrs(email: "reinvited@acme.test")

      assert {:ok, %{membership: invitation}} =
               Accounts.invite_user_to_account(invitation_attrs, subject)

      assert SSO.scim_provision_user(provider, attrs) == {:error, :member_email_taken}
      assert Accounts.membership_invitation_pending?(Repo.reload!(invitation))
      assert is_nil(Accounts.peek_sync_membership_by_id(provider.account_id, membership.id))

      assert {:ok, _revoked} = Accounts.delete_membership(invitation, subject)

      assert {:ok, %{membership: reprovisioned}} = SSO.scim_provision_user(provider, attrs)
      assert reprovisioned.email == "reinvited@acme.test"
      refute reprovisioned.disabled_at
      assert Fixtures.SSO.identity_membership(identity).id == reprovisioned.id

      resource_id = user_resource_id(provider, "okta|reinvited")
      assert {:ok, scim_user} = SSO.scim_fetch_user(provider, resource_id)
      assert scim_user.active
    end

    test "a Member elsewhere with the same address is never matched — a new Member is created", %{
      provider: provider,
      account: account
    } do
      existing = Fixtures.Memberships.create_membership(email: "taken@acme.test")
      attrs = scim_attrs(%{external_id: "okta|collide", email: "taken@acme.test"})

      assert {:ok, %{membership: membership}} = SSO.scim_provision_user(provider, attrs)
      assert membership.account_id == account.id
      assert membership.id != existing.id

      # The Member elsewhere is untouched: no identity bound to it, no seat here.
      assert member_identities(existing) == []
      assert is_nil(Accounts.peek_sync_membership_by_id(account.id, existing.id))
    end

    test "a provider-A-scoped provision never lands in account B (cross-account)", %{
      provider: provider_a,
      account: account_a
    } do
      %{account: account_b} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|scoped", email: "scoped@acme.test"})

      assert {:ok, %{membership: membership}} = SSO.scim_provision_user(provider_a, attrs)

      assert membership.account_id == account_a.id
      assert is_nil(Accounts.peek_sync_membership_by_email(account_b.id, attrs.email))
    end
  end

  # -- scim_update_user/3 (provider-scoped) ----------------------------

  describe "scim_update_user/3 tenancy" do
    test "a rename changes only this workspace's Member — a namesake elsewhere keeps its name" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|shared", %{email: "shared@acme.test"})
      other_account = Fixtures.Accounts.create_account()

      elsewhere =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          email: "shared@acme.test",
          display_name: "Own Name"
        )

      assert {:ok, _} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|shared"),
                 %SCIMUserUpdate{name: {:replace, "Renamed By Acme"}}
               )

      assert Fixtures.SSO.identity_membership(identity).display_name == "Renamed By Acme"
      assert Repo.reload!(elsewhere).display_name == "Own Name"
    end

    test "the workspace's label for a Member is audited when the directory moves it" do
      # `display_name` is the label every surface of this workspace renders —
      # the roster, run attribution, and the actor/target name on EXISTING
      # audit events. A directory that moves it relabels the audit trail
      # retroactively, so the move is itself an audit event.
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|relabel")

      assert {:ok, _} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|relabel"),
                 %SCIMUserUpdate{name: {:replace, "Someone Else"}}
               )

      assert event =
               Enum.find(
                 Repo.all(Emisar.Audit.Event),
                 &(&1.event_type == "membership.renamed_via_scim")
               )

      assert event.account_id == account.id
      assert event.actor_kind == "directory_sync"
      assert event.actor_id == provider.id
      assert {event.target_kind, event.target_id} == {"membership", identity.membership_id}
      assert event.payload["to"] == "Someone Else"
    end
  end

  describe "scim_provision_user/2 key spaces" do
    test "one person's externalId can't adopt another's OIDC identity" do
      # An OIDC subject and a directory externalId are minted by different parts
      # of an IdP and can collide. Matching a CLAIMED row by its subject let
      # Bob's create take over Alice's identity and reconcile her access to what
      # his payload asserted.
      %{provider: provider, account: account} = scim_provider()
      alice = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, alices} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(alice),
          %{
            provider_identifier: "collides",
            scim_external_id: "alice-directory-id",
            created_by: :provider,
            provisioned_via: :scim
          }
        )
        |> Repo.insert()

      # Refused, not absorbed. The identifier column is unique per connection and
      # Alice holds this value, so there is no row Bob can honestly occupy — the
      # directory is told, rather than handed someone else's identity.
      assert SSO.scim_provision_user(provider, %{
               external_id: "collides",
               email: "bob@acme.test"
             }) == {:error, :identifier_taken}

      untouched = Repo.reload!(alices)
      assert untouched.scim_external_id == "alice-directory-id"
      assert untouched.membership_id == alices.membership_id
    end

    test "an unclaimed OIDC-first row is still adopted by a matching externalId" do
      # The fallback that makes OIDC-first convergence work must survive the fix.
      %{provider: provider, account: account} = scim_provider()
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, oidc_first} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "unclaimed",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )
        |> Repo.insert()

      assert is_nil(oidc_first.scim_external_id)

      {:ok, %{identity: adopted}} =
        SSO.scim_provision_user(provider, %{external_id: "unclaimed"})

      assert adopted.id == oidc_first.id
      assert adopted.scim_external_id == "unclaimed"
    end
  end

  describe "scim_update_user/3 atomicity" do
    test "a rename bundled with a refused deactivation commits neither" do
      # A PATCH may carry a rename alongside the deactivation. Committing the
      # rename and THEN answering 409 told the directory its whole operation was
      # rejected when half of it had landed — one transaction commits all of the
      # requested changes or none.
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|onlyowner")

      # Make the synced member the account's ONLY owner — the state the
      # last-active-owner guard exists for.
      membership = Fixtures.SSO.identity_membership(identity)
      owner = Fixtures.Memberships.force_role(membership, "owner")
      assert owner.role == :owner

      subject.actor
      |> Repo.reload!()
      |> Fixtures.Memberships.force_role("admin")

      update = %SCIMUserUpdate{name: {:replace, "Half Landed"}, active: false}

      assert SSO.scim_update_user(
               provider,
               user_resource_id(provider, "okta|onlyowner"),
               update
             ) == {:error, :last_owner}

      # Nothing landed: not the lifecycle, not the name, not the identity flag.
      unchanged = Fixtures.SSO.identity_membership(identity)
      refute unchanged.disabled_at
      assert unchanged.display_name == "Dir User"
      assert Repo.reload!(identity).scim_active
    end

    test "a rejected rename rolls the whole operation back" do
      # The rename's own changeset can refuse (a >255-char name); the operation
      # also carried the deactivation, and the directory is told the whole PATCH
      # failed — so no part of it may stay.
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|badname")

      update = %SCIMUserUpdate{
        name: {:replace, String.duplicate("x", 256)},
        active: false
      }

      assert {:error, %Ecto.Changeset{}} =
               SSO.scim_update_user(provider, user_resource_id(provider, "okta|badname"), update)

      unchanged = Fixtures.SSO.identity_membership(identity)
      refute unchanged.disabled_at
      assert unchanged.display_name == "Dir User"
      assert Repo.reload!(identity).scim_active
    end

    test "a rename for a member an operator removed is :not_found and commits nothing" do
      # The rename step rolls the transaction back from INSIDE
      # `sync_member_display_name`'s own (joined) transaction — the error must
      # surface as `{:error, :not_found}`, and the deactivation and identity
      # flag the operation also carried must not survive it.
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity, membership: membership} = provision(provider, "okta|removed")
      Fixtures.Memberships.mark_membership_as_deleted(membership)
      refute Accounts.peek_sync_membership_by_id(account.id, identity.membership_id)

      update = %SCIMUserUpdate{name: {:replace, "New Name"}, active: false}

      assert SSO.scim_update_user(provider, user_resource_id(provider, "okta|removed"), update) ==
               {:error, :not_found}

      assert Repo.reload!(identity).scim_active
    end
  end

  describe "scim_update_user/3" do
    test "ends the Member's sessions — a Member elsewhere with the same address stays signed in" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|multi", email: "multi@acme.test"})
      {:ok, %{identity: identity, membership: member}} = SSO.scim_provision_user(provider, attrs)
      other_account = Fixtures.Accounts.create_account()

      elsewhere =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          email: "multi@acme.test",
          role: "operator"
        )

      sso_session =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      magic_link_session = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      elsewhere_session = Fixtures.Auth.create_session_token!(elsewhere, :magic_link, nil)

      assert {:ok, _} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|multi"),
                 %SCIMUserUpdate{active: false}
               )

      assert Auth.fetch_session_by_token(sso_session, provider.account_id) == {:error, :not_found}

      assert Auth.fetch_session_by_token(magic_link_session, provider.account_id) ==
               {:error, :not_found}

      elsewhere_id = elsewhere.id

      assert {:ok, %UserToken{membership_id: ^elsewhere_id}} =
               Auth.fetch_session_by_token(elsewhere_session, other_account.id)
    end

    test "suspends the membership (disabled_at) + flips scim_active, never deleting the member" do
      %{provider: provider} = scim_provider(%{default_role: :admin})
      attrs = scim_attrs(%{external_id: "okta|deprov", email: "deprov@acme.test"})

      {:ok, %{membership: member, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{membership: membership, identity: deactivated}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|deprov"),
                 %SCIMUserUpdate{active: false}
               )

      assert membership.disabled_at
      refute deactivated.scim_active

      # The member + identity survive (audit preservation) — only access is cut.
      assert Accounts.peek_sync_membership_by_id(provider.account_id, member.id)
      assert {:ok, _scim_user} = SSO.scim_fetch_user(provider, identity.id)
    end

    test "marks the membership directory_suspended, so the DOMAIN refuses a manual reinstate" do
      %{provider: provider, subject: subject} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|dsusp", email: "dsusp@acme.test"})
      {:ok, _} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{membership: membership}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|dsusp"),
                 %SCIMUserUpdate{active: false}
               )

      assert membership.directory_suspended

      # An operator can't lift an IdP deactivation — the guard is judged on the
      # locked row's own flag, so a stale UI / crafted event is refused too.
      assert Accounts.reinstate_membership(membership, subject) == {:error, :deactivated_in_idp}
      assert Repo.reload!(membership).disabled_at
    end

    test "deactivating the last active owner is refused (:last_owner), flag left untouched" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :viewer})
      attrs = scim_attrs(%{external_id: "okta|owner"})

      {:ok, %{membership: membership, identity: identity}} =
        SSO.scim_provision_user(provider, attrs)

      # Promote the lone provisioned member to the account's only owner.
      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: membership.id)

      assert SSO.scim_update_user(
               provider,
               user_resource_id(provider, "okta|owner"),
               %SCIMUserUpdate{active: false}
             ) == {:error, :last_owner}

      # The membership stays active and the SCIM flag is left untouched, so the
      # projection still answers active.
      refute Accounts.peek_sync_membership_by_id(account.id, membership.id).disabled_at
      assert {:ok, unchanged} = SSO.scim_fetch_user(provider, identity.id)
      assert unchanged.active
    end

    test "returns :not_found when no identity matches the resource id" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_update_user(provider, Ecto.UUID.generate(), %SCIMUserUpdate{active: false}) ==
               {:error, :not_found}
    end
  end

  # -- scim_update_user/3 reactivate ----------------------------------

  describe "scim_update_user/3 reactivate" do
    test "clears disabled_at on a suspended membership + flips scim_active back on" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|react", email: "react@acme.test"})

      {:ok, %{membership: member}} = SSO.scim_provision_user(provider, attrs)

      {:ok, _} =
        SSO.scim_update_user(provider, user_resource_id(provider, "okta|react"), %SCIMUserUpdate{
          active: false
        })

      assert Accounts.peek_sync_membership_by_id(account.id, member.id).disabled_at

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|react"),
                 %SCIMUserUpdate{active: true}
               )

      refute membership.disabled_at
      assert identity.scim_active
      # The IdP reactivating clears the directory-suspended mark — an operator can
      # reinstate them again if suspended manually later.
      refute membership.directory_suspended
      refute Accounts.peek_sync_membership_by_id(account.id, member.id).disabled_at
    end

    test "returns :not_found when no identity matches the resource id" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_update_user(provider, Ecto.UUID.generate(), %SCIMUserUpdate{active: true}) ==
               {:error, :not_found}
    end

    test "a manual break-glass suspension survives an IdP deactivate→reactivate cycle" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|held", email: "held@acme.test"})

      {:ok, %{membership: membership}} = SSO.scim_provision_user(provider, attrs)
      Fixtures.Memberships.suspend_membership(membership)

      {:ok, _} =
        SSO.scim_update_user(provider, user_resource_id(provider, "okta|held"), %SCIMUserUpdate{
          active: false
        })

      assert {:ok, %{membership: returned}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|held"),
                 %SCIMUserUpdate{active: true}
               )

      # The IdP never owned the suspension, so its reactivate can't lift it —
      # the member stays out until an operator reinstates locally.
      assert returned.disabled_at
      refute returned.directory_suspended
      assert Accounts.peek_sync_membership_by_id(account.id, membership.id).disabled_at
    end
  end

  # -- scim_update_user/3 rename --------------------------------------

  describe "scim_update_user/3 rename" do
    test "replaces only the workspace display name, audited to the directory" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|rename", full_name: "Old Name"})
      {:ok, %{membership: member, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{identity: %UserIdentity{} = returned}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|rename"),
                 %SCIMUserUpdate{
                   name: {:replace, "New Name"}
                 }
               )

      assert returned.id == identity.id
      assert Repo.reload!(member).display_name == "New Name"

      assert event =
               Enum.find(
                 Repo.all(Emisar.Audit.Event),
                 &(&1.event_type == "membership.renamed_via_scim")
               )

      assert event.actor_kind == "directory_sync"
      assert event.payload["from"] == "Old Name"
      assert event.payload["to"] == "New Name"
    end

    test "an unchanged name is a no-op — no audit row" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|same", full_name: "Keep Name"})
      {:ok, %{membership: member}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{identity: %UserIdentity{}}} =
               SSO.scim_update_user(
                 provider,
                 user_resource_id(provider, "okta|same"),
                 %SCIMUserUpdate{
                   name: {:replace, "Keep Name"}
                 }
               )

      assert Repo.reload!(member).display_name == "Keep Name"

      refute Enum.any?(
               Repo.all(Emisar.Audit.Event),
               &(&1.event_type == "membership.renamed_via_scim")
             )
    end

    test "an unknown resource id is :not_found" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_update_user(provider, Ecto.UUID.generate(), %SCIMUserUpdate{
               name: {:replace, "Anyone"}
             }) == {:error, :not_found}
    end

    test "is provider-scoped — provider B can't rename provider A's user" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|scoped", full_name: "A Name"})

      {:ok, %{membership: member_a, identity: identity_a}} =
        SSO.scim_provision_user(provider_a, attrs)

      assert SSO.scim_update_user(provider_b, identity_a.id, %SCIMUserUpdate{
               name: {:replace, "Hijack"}
             }) == {:error, :not_found}

      assert Repo.reload!(member_a).display_name == "A Name"
    end
  end

  # -- scim_delete_user/2 ----------------------------------------------

  describe "scim_delete_user/2" do
    test "retires the resource and its group grants, then POST revives the same person" do
      %{provider: provider, account: account, subject: subject} = scim_provider()
      Fixtures.Runners.create_runner(account_id: account.id, group: "production")

      {:ok, _role_mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-retired", role: :admin},
          subject
        )

      {:ok, _access_mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{
            external_group_id: "grp-retired",
            runner_access_mode: :restricted,
            scope: ["group:production"]
          },
          subject
        )

      attrs = scim_attrs(%{external_id: "okta|retire", email: "retire@acme.test"})
      {:ok, %{membership: member, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-retired",
          member_ids: [identity.id]
        })

      privileged = Repo.reload!(member)
      assert privileged.role == :admin

      assert Accounts.runner_access_for_membership(account.id, privileged.id) ==
               %RunnerAccess{mode: :restricted, groups: ["production"], runner_ids: []}

      assert {:ok, %{identity: retired, membership: suspended}} =
               SSO.scim_delete_user(provider, identity.id)

      refute retired.deleted_at
      assert retired.scim_deleted_at
      assert retired.provider_identifier_retired_at
      refute retired.scim_active
      assert suspended.disabled_at
      assert SSO.scim_fetch_user(provider, identity.id) == {:error, :not_found}
      assert {:ok, [], 0} = SSO.scim_list_users(provider)

      reset_membership = Repo.reload!(member)
      assert reset_membership.role == :viewer

      assert Accounts.runner_access_for_membership(account.id, reset_membership.id) ==
               RunnerAccess.none()

      refute DirectoryGroupMember.Query.not_deleted()
             |> DirectoryGroupMember.Query.by_user_identity_id(identity.id)
             |> Repo.exists?()

      assert {:ok, %{identity: revived, membership: inactive_membership}} =
               SSO.scim_provision_user(provider, Map.put(attrs, :active, false))

      assert inactive_membership.id == member.id
      assert revived.id == identity.id
      refute revived.deleted_at
      refute revived.scim_deleted_at
      assert revived.provider_identifier_retired_at
      refute revived.scim_active
      assert inactive_membership.disabled_at

      assert {:ok, %{membership: active_membership}} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: true})

      refute active_membership.disabled_at
      assert active_membership.role == :viewer

      assert Accounts.runner_access_for_membership(account.id, active_membership.id) ==
               RunnerAccess.none()

      identities =
        UserIdentity.Query.all()
        |> UserIdentity.Query.by_membership_id(member.id)
        |> Repo.all()

      assert [%UserIdentity{id: revived_id}] = identities
      assert revived_id == identity.id
    end

    test "delete and recreation are provider scoped, and a second delete is not found" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      attrs_a = scim_attrs(%{external_id: "okta|scoped-delete", email: "scoped-a@acme.test"})
      {:ok, %{identity: identity}} = SSO.scim_provision_user(provider_a, attrs_a)

      assert SSO.scim_delete_user(provider_b, identity.id) == {:error, :not_found}
      assert {:ok, _user} = SSO.scim_fetch_user(provider_a, identity.id)

      assert {:ok, _result} = SSO.scim_delete_user(provider_a, identity.id)
      assert SSO.scim_delete_user(provider_a, identity.id) == {:error, :not_found}

      assert {:ok, %{identity: identity_b}} =
               SSO.scim_provision_user(
                 provider_b,
                 scim_attrs(%{
                   external_id: "okta|scoped-delete",
                   email: "scoped-b@acme.test"
                 })
               )

      refute identity_b.id == identity.id
      assert Repo.reload!(identity).scim_deleted_at

      assert {:ok, %{identity: revived_a}} = SSO.scim_provision_user(provider_a, attrs_a)
      assert revived_a.id == identity.id
      refute revived_a.scim_deleted_at
    end

    test "recreation restores SCIM but not a rebound OIDC subject that another member claimed" do
      %{provider: provider, account: account, subject: subject} =
        scim_provider(%{provisioner: :manual})

      attrs =
        scim_attrs(%{
          external_id: "directory-resource",
          email: "rebound-delete@acme.test"
        })

      {:ok, %{membership: member, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      # The login's verified email names the directory Member's workspace contact.
      claims = %{
        "sub" => "admin-linked-subject",
        "email" => "rebound-delete@acme.test",
        "email_verified" => true
      }

      request = capture_request(provider, claims)

      assert {:ok, %{identity: rebound}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      refute rebound.provider_identifier_retired_at
      assert {:ok, _result} = SSO.scim_delete_user(provider, rebound.id)

      retired_request = capture_request(provider, claims)

      assert SSO.approve_link_request(retired_request, RunnerAccess.none(), subject) ==
               {:error, :scim_resource_retired}

      assert Repo.reload!(rebound).scim_deleted_at
      assert Accounts.peek_sync_membership_by_id(account.id, member.id).disabled_at
      assert {:ok, _dismissed} = SSO.dismiss_link_request(retired_request, subject)

      other_member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: :viewer,
          email: "new-subject-owner@acme.test"
        )

      other_request =
        capture_request(provider, %{
          "sub" => "directory-resource",
          "email" => other_member.email,
          "email_verified" => true
        })

      assert {:ok, %{identity: other_identity}} =
               SSO.approve_link_request(other_request, RunnerAccess.none(), subject)

      assert {:ok, %{identity: revived}} = SSO.scim_provision_user(provider, attrs)
      assert revived.id == identity.id
      assert revived.provider_identifier_retired_at
      refute revived.scim_deleted_at
      assert Repo.reload!(other_identity).provider_identifier_retired_at == nil

      assert {:ok, %{membership: signed_in}} =
               SSO.complete_auth(
                 provider,
                 callback(%{"sub" => "directory-resource"}),
                 %{},
                 %RequestContext{}
               )

      assert signed_in.id == other_member.id

      assert {:pending, %LinkRequest{provider_identifier: "admin-linked-subject"}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      identities =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_id(provider.id)
        |> Repo.all()

      assert Enum.sort(Enum.map(identities, & &1.id)) ==
               Enum.sort([identity.id, other_identity.id])

      assert {:ok, %{identity: retired_other}} =
               SSO.scim_delete_user(provider, other_identity.id)

      refute retired_other.scim_external_id
      assert retired_other.scim_deleted_at
      assert {:ok, %SCIMUser{id: original_id}} = SSO.scim_fetch_user(provider, identity.id)
      assert original_id == identity.id

      assert {:ok, %{identity: reconciled_original}} =
               SSO.scim_provision_user(provider, attrs)

      assert reconciled_original.id == identity.id
      assert Repo.reload!(other_identity).scim_deleted_at
    end

    test "an already-suspended delete cannot restore retired browser proof" do
      %{provider: provider} = scim_provider()

      %{identity: identity, membership: member} =
        provision(provider, "okta|session-retire", %{email: "session-retire@acme.test"})

      other_account = Fixtures.Accounts.create_account()

      elsewhere =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          email: "session-retire@acme.test"
        )

      sso_session =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      elsewhere_session = Fixtures.Auth.create_session_token!(elsewhere, :magic_link, nil)
      expected_topic = Auth.live_socket_topic(Crypto.hash(sso_session))

      assert {:ok, _result} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})

      Emisar.Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      Emisar.Config.put_override(:emisar, :scim_delete_disconnect_test_pid, self())

      assert {:ok, %{identity: retired}} = SSO.scim_delete_user(provider, identity.id)
      assert retired.scim_deleted_at

      refute_receive {:scim_delete_disconnect, [^expected_topic], _in_transaction?}
      assert Auth.fetch_session_by_token(sso_session, provider.account_id) == {:error, :not_found}

      elsewhere_id = elsewhere.id

      assert {:ok, %UserToken{membership_id: ^elsewhere_id}} =
               Auth.fetch_session_by_token(elsewhere_session, other_account.id)

      assert {:ok, %{identity: revived}} =
               SSO.scim_provision_user(
                 provider,
                 scim_attrs(%{
                   external_id: "okta|session-retire",
                   email: "session-retire@acme.test"
                 })
               )

      assert revived.provider_identifier_retired_at

      assert {:pending, %LinkRequest{provider_identifier: "okta|session-retire"}} =
               SSO.complete_auth(
                 provider,
                 callback(%{
                   "sub" => "okta|session-retire",
                   "email" => "session-retire@acme.test",
                   "email_verified" => true
                 }),
                 %{},
                 %RequestContext{}
               )
    end

    test "a rendered OIDC-only SCIM resource reserves its fallback externalId on delete" do
      %{provider: provider, account: account} = scim_provider(%{provisioner: :manual})

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "oidc-first-delete@acme.test"
        )

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member,
          provider_identifier: "oidc-first-delete",
          scim_external_id: nil,
          created_by: :provider,
          provisioned_via: :oidc_jit
        })

      assert {:ok, %SCIMUser{external_id: "oidc-first-delete"}} =
               SSO.scim_fetch_user(provider, identity.id)

      assert {:ok, %{identity: retired}} = SSO.scim_delete_user(provider, identity.id)
      assert retired.scim_external_id == "oidc-first-delete"

      assert {:ok, %{identity: revived, membership: revived_membership}} =
               SSO.scim_provision_user(
                 provider,
                 scim_attrs(%{
                   external_id: "oidc-first-delete",
                   email: member.email
                 })
               )

      assert revived_membership.id == member.id
      assert revived.id == identity.id
    end

    test "disabling SCIM returns a retired member to operator control" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|deleted-before-disable")

      assert {:ok, _result} = SSO.scim_delete_user(provider, identity.id)
      assert {:ok, _disabled} = SSO.disable_scim(provider, subject)

      returned = Fixtures.SSO.identity_membership(identity)
      refute returned.directory_managed
      refute returned.directory_suspended
      refute returned.directory_provider_id

      assert {:ok, reinstated} = Accounts.reinstate_membership(returned, subject)
      refute reinstated.disabled_at
    end
  end

  # -- scim_fetch_user/2 (provider-scoped) -----------------------------

  describe "scim_fetch_user/2" do
    test "returns the directory-user projection for a provider-scoped resource id" do
      %{provider: provider} = scim_provider()

      {:ok, _} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|fetch",
          email: "fetch@acme.test",
          full_name: "Fetch Person"
        })

      assert SSO.scim_fetch_user(provider, user_resource_id(provider, "okta|fetch")) ==
               {:ok,
                %SCIMUser{
                  id: user_resource_id(provider, "okta|fetch"),
                  external_id: "okta|fetch",
                  user_name: "fetch@acme.test",
                  display_name: "Fetch Person",
                  active: true
                }}
    end

    test "a no-email directory user's userName falls back to the opaque externalId" do
      %{provider: provider} = scim_provider()
      _ = provision(provider, "okta|nomail", %{full_name: nil})

      assert {:ok, scim_user} =
               SSO.scim_fetch_user(provider, user_resource_id(provider, "okta|nomail"))

      assert scim_user.user_name == "okta|nomail"
      refute scim_user.display_name
    end

    test "a deprovisioned (suspended) member reports inactive" do
      %{provider: provider} = scim_provider()
      _ = provision(provider, "okta|off")

      {:ok, _} =
        SSO.scim_update_user(provider, user_resource_id(provider, "okta|off"), %SCIMUserUpdate{
          active: false
        })

      assert {:ok, scim_user} =
               SSO.scim_fetch_user(provider, user_resource_id(provider, "okta|off"))

      refute scim_user.active
    end

    test "a manual break-glass hold reports inactive while scim_active still says true" do
      %{provider: provider} = scim_provider()
      %{identity: identity, membership: membership} = provision(provider, "okta|held")
      Fixtures.Memberships.suspend_membership(membership)

      # The identity's own flag still says active — the directory has not
      # deactivated them — but the person cannot sign in, and that is what the
      # IdP has to be told: a hold is never hidden behind the directory's flag.
      assert Repo.reload!(identity).scim_active

      assert {:ok, scim_user} =
               SSO.scim_fetch_user(provider, user_resource_id(provider, "okta|held"))

      refute scim_user.active
    end

    test "an orphaned identity (membership removed by an operator) is found and reports inactive" do
      %{provider: provider} = scim_provider()
      %{membership: membership} = provision(provider, "okta|orphan")
      Fixtures.Memberships.mark_membership_as_deleted(membership)

      assert {:ok, scim_user} =
               SSO.scim_fetch_user(provider, user_resource_id(provider, "okta|orphan"))

      refute scim_user.active
    end

    test "an unknown resource id is :not_found" do
      %{provider: provider} = scim_provider()
      assert SSO.scim_fetch_user(provider, Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "is provider-scoped — provider B can't fetch provider A's user" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      %{identity: identity_a} = provision(provider_a, "okta|onlyA")

      assert SSO.scim_fetch_user(provider_b, identity_a.id) == {:error, :not_found}
    end
  end

  # -- scim_list_users/2 (provider-scoped) -----------------------------

  describe "scim_list_users/2" do
    setup do
      scim_provider()
    end

    test "lists the provider's directory users as projections, paginated", %{provider: provider} do
      _ = provision(provider, "okta|l1")
      _ = provision(provider, "okta|l2")

      assert {:ok, scim_users, 2} = SSO.scim_list_users(provider)
      assert length(scim_users) == 2
      assert Enum.all?(scim_users, &match?(%SCIMUser{}, &1))
    end

    test "each row carries its own effective active state", %{provider: provider} do
      _ = provision(provider, "okta|on")
      _ = provision(provider, "okta|gone")

      {:ok, _} =
        SSO.scim_update_user(provider, user_resource_id(provider, "okta|gone"), %SCIMUserUpdate{
          active: false
        })

      assert {:ok, scim_users, 2} = SSO.scim_list_users(provider)

      assert Map.new(scim_users, &{&1.external_id, &1.active}) ==
               %{"okta|on" => true, "okta|gone" => false}
    end

    test "another account's membership never decides a row's active state", %{
      provider: provider
    } do
      %{membership: member} =
        provision(provider, "okta|two-tenant", %{email: "two-tenant@acme.test"})

      # The same address is also a (suspended) Member of an unrelated account —
      # only the provider's own account may decide what its directory is told.
      other_account = Fixtures.Accounts.create_account()

      other_membership =
        Fixtures.Memberships.create_membership(account_id: other_account.id, email: member.email)

      Fixtures.Memberships.suspend_membership(other_membership)

      assert {:ok, [scim_user], 1} = SSO.scim_list_users(provider)
      assert scim_user.external_id == "okta|two-tenant"
      assert scim_user.active
    end

    test "a :scim_filter by external_id matches anywhere in the directory (past the page)", %{
      provider: provider
    } do
      _ = provision(provider, "okta|needle")
      _ = provision(provider, "okta|hay")

      assert {:ok, [scim_user], 1} =
               SSO.scim_list_users(provider, scim_filter: {:external_id, "okta|needle"})

      assert scim_user.external_id == "okta|needle"
    end

    test "is provider-scoped — provider B's list never includes provider A's users" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      _ = provision(provider_a, "okta|onlyA")

      assert SSO.scim_list_users(provider_b) === {:ok, [], 0}
    end

    test "returns a truthful total independently of the requested page", %{provider: provider} do
      _ = provision(provider, "okta|one")
      _ = provision(provider, "okta|two")
      _ = provision(provider, "okta|three")

      assert {:ok, first, 3} = SSO.scim_list_users(provider, offset: 0, limit: 2)
      assert {:ok, second, 3} = SSO.scim_list_users(provider, offset: 2, limit: 2)
      assert length(first) == 2
      assert length(second) == 1

      assert MapSet.disjoint?(
               MapSet.new(first, & &1.external_id),
               MapSet.new(second, & &1.external_id)
             )
    end
  end

  # -- scim_list_groups/2 (provider-scoped) ----------------------------

  describe "scim_list_groups/2" do
    setup do
      scim_provider()
    end

    test "lists synced groups with mapped displays and member resource ids", %{
      provider: provider,
      subject: subject
    } do
      %{identity: alice} = provision(provider, "okta|alice")
      %{identity: bob} = provision(provider, "okta|bob")

      {:ok, _mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Operations",
          member_ids: [bob.id, alice.id]
        })

      assert {:ok, [group], 1} = SSO.scim_list_groups(provider)
      assert group.external_group_id == "grp-ops"
      assert group.display == "Operations"
      assert group.member_ids == Enum.sort([alice.id, bob.id])
    end

    test "filters by the display the directory pushed, mapped or not", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|member")

      {:ok, _mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Operations",
          member_ids: [identity.id]
        })

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_ids: [identity.id]
        })

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-nameless",
          member_ids: [identity.id]
        })

      {:ok, _mapping} =
        create_group_mapping_fixture(
          provider,
          %{
            external_group_id: "grp-nameless",
            external_group_display: "Stale mapping name",
            role: :viewer
          },
          subject
        )

      assert {:ok, [%{external_group_id: "grp-ops"}], 1} =
               SSO.scim_list_groups(provider, display_name: "Operations")

      assert {:ok, [%{external_group_id: "grp-unmapped"}], 1} =
               SSO.scim_list_groups(provider, display_name: "Security Review")

      # Only a group whose directory never sent a displayName answers on its id.
      assert {:ok, [%{external_group_id: "grp-nameless"}], 1} =
               SSO.scim_list_groups(provider, display_name: "grp-nameless")

      # A mapping's administrative label does not rename the SCIM resource.
      # Filtering and serialization therefore use the same display precedence.
      assert SSO.scim_list_groups(provider, display_name: "Stale mapping name") === {:ok, [], 0}

      assert SSO.scim_list_groups(provider, display_name: "grp-unmapped") === {:ok, [], 0}
    end

    test "a filter naming BOTH attributes is honored as their intersection", %{
      provider: provider
    } do
      # The domain takes a plain keyword list, so the "only one key ever arrives"
      # guarantee lived in the controller's regex. Both narrowings now compose,
      # and answering nothing instead would read as "no such group" to an IdP's
      # existence probe — which then re-creates the group as a duplicate.
      {:ok, _ops} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Operations",
          member_ids: []
        })

      {:ok, _security} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-sec",
          display: "Security Review",
          member_ids: []
        })

      assert {:ok, [%{external_group_id: "grp-ops"}], 1} =
               SSO.scim_list_groups(provider, display_name: "Operations", external_id: "grp-ops")

      assert SSO.scim_list_groups(provider, display_name: "Operations", external_id: "grp-sec") ===
               {:ok, [], 0}
    end

    test "a group whose display was cleared still answers on its id", %{provider: provider} do
      # SCIM treats displayName as optional, so clearing it stores an empty string
      # — and SQL coalesce counts '' as a value, so the fallback to the external id
      # never happened. Entra's existence probe missed and it re-POSTed the group
      # as a duplicate on every sync.
      {:ok, group} = SSO.scim_upsert_group(provider, %{external_id: "grp-empty", member_ids: []})
      {:ok, %{display: ""}} = SSO.scim_patch_group(provider, group.id, [rename_op("")])

      assert {:ok, [%{external_group_id: "grp-empty"}], 1} =
               SSO.scim_list_groups(provider, display_name: "grp-empty")
    end

    test "an unmapped group keeps the display its directory pushed", %{provider: provider} do
      %{identity: identity} = provision(provider, "okta|member")

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_ids: [identity.id]
        })

      assert {:ok, [group], 1} = SSO.scim_list_groups(provider)
      assert group.external_group_id == "grp-unmapped"
      assert group.display == "Security Review"
      assert group.member_ids == [identity.id]
    end

    test "a rename moves an unmapped group's display", %{provider: provider} do
      %{identity: identity} = provision(provider, "okta|member")

      {:ok, group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_ids: [identity.id]
        })

      {:ok, _group} = SSO.scim_patch_group(provider, group.id, [rename_op("Security Council")])

      assert {:ok, [%{display: "Security Council"}], 1} = SSO.scim_list_groups(provider)
    end

    test "a PATCH-added member does not erase the group's display", %{provider: provider} do
      %{identity: member} = provision(provider, "okta|member")
      %{identity: joiner} = provision(provider, "okta|joiner")

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_ids: [member.id]
        })

      {:ok, _group} =
        SSO.scim_patch_group(provider, group_resource_id(provider, "grp-unmapped"), [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => joiner.id}]}
        ])

      assert {:ok, [%{display: "Security Review", member_ids: members}], 1} =
               SSO.scim_list_groups(provider)

      assert members == Enum.sort([joiner.id, member.id])
    end

    test "is provider-scoped", %{provider: provider_a} do
      %{provider: provider_b} = scim_provider()
      %{identity: identity} = provision(provider_a, "okta|only-a")

      {:ok, _group} =
        SSO.scim_upsert_group(provider_a, %{
          external_id: "grp-a",
          member_ids: [identity.id]
        })

      assert SSO.scim_list_groups(provider_b) === {:ok, [], 0}
    end
  end

  # -- scim_fetch_group/2 (provider-scoped) ----------------------------

  describe "scim_fetch_group/2" do
    test "returns one synced group with its member resource ids" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|member")

      {:ok, group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-fetch",
          member_ids: [identity.id]
        })

      assert SSO.scim_fetch_group(provider, group.id) ==
               {:ok,
                %{
                  id: group.id,
                  external_group_id: "grp-fetch",
                  display: nil,
                  member_ids: [identity.id]
                }}
    end

    test "returns :not_found for an unknown group" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_fetch_group(provider, Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "is provider-scoped" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      %{identity: identity} = provision(provider_a, "okta|only-a")

      {:ok, group} =
        SSO.scim_upsert_group(provider_a, %{
          external_id: "grp-a",
          member_ids: [identity.id]
        })

      assert SSO.scim_fetch_group(provider_b, group.id) == {:error, :not_found}
    end
  end

  # -- scim_upsert_group/2 (provider-scoped) ---------------------------

  describe "scim_upsert_group/2" do
    setup do
      scim_provider()
    end

    test "replaces the group's synced membership + recomputes roles to the mapped role", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|u1")
      assert role_of(identity) == :viewer

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{external_group_id: "grp-ops", display: "Operators", member_ids: [id]}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-ops",
                 display: "Operators",
                 member_ids: [identity.id]
               })

      assert id == identity.id
      assert role_of(identity) == :operator
    end

    test "rejects a display the varchar(255) column can't hold, measured in code points", %{
      provider: provider
    } do
      # 255 combining-mark graphemes = 510 code points: String.length reads 255
      # and passes, but Postgres measures varchar(255) in code points, so the old
      # grapheme check let it through to a 22001 (a 500) rather than invalidValue.
      combining = String.duplicate("e" <> <<0x0301::utf8>>, 255)
      assert String.length(combining) == 255

      assert SSO.scim_upsert_group(provider, %{
               external_id: "grp-combining",
               display: combining,
               member_ids: []
             }) == {:error, :invalid_scim_group}
    end

    test "a group request authenticated before cancellation cannot mutate afterward", %{
      account: account,
      token: token
    } do
      assert {:ok, stale_provider} = SSO.authenticate_scim_token(token)
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      assert SSO.scim_upsert_group(stale_provider, %{
               external_id: "grp-after-expiry",
               display: "After expiry",
               member_ids: []
             }) == {:error, :directory_sync_disabled}

      refute Repo.exists?(
               DirectoryGroup.Query.not_deleted()
               |> DirectoryGroup.Query.by_account_id(account.id)
               |> DirectoryGroup.Query.by_external_group_id("grp-after-expiry")
             )
    end

    test "an unknown member resource id is ignored (not yet provisioned)", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|known")

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-mix", role: :admin},
          subject
        )

      assert {:ok, %{member_ids: [member_id]}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-mix",
                 member_ids: [identity.id, Ecto.UUID.generate()]
               })

      assert member_id == identity.id
      assert role_of(identity) == :admin
    end

    test "removing a member from the group resets them to the provider default_role (#3)", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|drop")

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-adm", role: :admin},
          subject
        )

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      assert role_of(identity) == :admin

      # Re-push the group with an empty member set → the member leaves it and
      # resets to the provider default (:viewer).
      assert {:ok, %{member_ids: []}} =
               SSO.scim_upsert_group(provider, %{external_id: "grp-adm", member_ids: []})

      assert role_of(identity) == :viewer
    end
  end

  # -- scim_patch_group/3 renames (provider-scoped) -----------------

  describe "scim_patch_group/3 — a displayName replace" do
    setup do
      scim_provider()
    end

    test "moves the display onto the mapping and keeps the id the IdP addresses", %{
      provider: provider,
      subject: subject
    } do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-ops", external_group_display: "Ops", role: :operator},
          subject
        )

      {:ok, group} = SSO.scim_upsert_group(provider, %{external_id: "grp-ops", member_ids: []})

      assert {:ok, %{external_group_id: "grp-ops", display: "Platform"}} =
               SSO.scim_patch_group(provider, group.id, [rename_op("Platform")])

      # The id is the IdP's handle on the group, so a rename must not move it —
      # only the human label the console shows changes.
      reloaded = Repo.reload!(mapping)
      assert reloaded.external_group_id == "grp-ops"
      assert reloaded.external_group_display == "Platform"
      assert reloaded.role == :operator
    end

    test "a group nobody has mapped is still renamable", %{provider: provider} do
      {:ok, group} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-unmapped", member_ids: []})

      assert {:ok, %{external_group_id: "grp-unmapped", display: "Renamed"}} =
               SSO.scim_patch_group(provider, group.id, [rename_op("Renamed")])
    end

    test "rejects a malformed id, but takes a blank display", %{provider: provider} do
      assert SSO.scim_patch_group(provider, "not-a-uuid", [rename_op("Platform")]) ==
               {:error, :not_found}

      {:ok, group} = SSO.scim_upsert_group(provider, %{external_id: "grp-ops", member_ids: []})

      # displayName is optional in SCIM, so clearing it is a rename, not an error —
      # the group keeps answering on the id the IdP addresses it by.
      assert {:ok, %{external_group_id: "grp-ops", display: ""}} =
               SSO.scim_patch_group(provider, group.id, [rename_op("")])
    end
  end

  describe "put_sign_in_authority/4" do
    test "locks the entitlement, the enabled provider and the live identity, and refuses once the connection is disabled" do
      {_owner, account, subject} = enterprise_owner()
      provider = account |> provider_fixture() |> Fixtures.SSO.enable_scim()
      %{identity: identity} = provision(provider, "okta|session-guard")
      identity_id = identity.id
      provider_id = provider.id

      assert {:ok,
              %{
                sso_entitlement: :available,
                sso_provider: %IdentityProvider{id: ^provider_id},
                sso_identity: %UserIdentity{id: ^identity_id}
              }} =
               Ecto.Multi.new()
               |> SSO.put_sign_in_authority(account.id, identity.id, identity.provider_identifier)
               |> Repo.commit_multi()

      {:ok, _disabled} = SSO.update_provider(provider, %{enabled: false}, subject)

      assert Ecto.Multi.new()
             |> SSO.put_sign_in_authority(account.id, identity.id, identity.provider_identifier)
             |> Repo.commit_multi() == {:error, :provider_disabled}
    end

    test "a foreign workspace, a rebound subject, an unknown or retired identity and a malformed route fail closed" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      authority = fn account_id, identity_id, identifier ->
        Ecto.Multi.new()
        |> SSO.put_sign_in_authority(account_id, identity_id, identifier)
        |> Repo.commit_multi()
      end

      foreign = Fixtures.Accounts.create_account(plan: "enterprise")
      refused = {:error, :provider_disabled}

      assert authority.(foreign.id, identity.id, identity.provider_identifier) == refused
      assert authority.(account.id, identity.id, "another-subject") == refused
      assert authority.(account.id, Ecto.UUID.generate(), identity.provider_identifier) == refused
      assert authority.("not-a-uuid", identity.id, identity.provider_identifier) == refused

      Fixtures.SSO.retire_identity(identity)
      assert authority.(account.id, identity.id, identity.provider_identifier) == refused
    end
  end

  describe "validate_scim_group_display/1" do
    test "accepts an absent display and a reasonable one" do
      # The SCIM boundary asks this BEFORE it writes, so a batch carrying both a
      # membership change and a bad rename fails without half-applying.
      assert SSO.validate_scim_group_display(nil) == :ok
      assert SSO.validate_scim_group_display("Platform Engineers") == :ok
    end

    test "refuses what a group write would refuse" do
      assert {:error, _} = SSO.validate_scim_group_display(String.duplicate("n", 300))
      assert {:error, _} = SSO.validate_scim_group_display(123)
    end
  end

  # -- scim_patch_group/3 (provider-scoped) ----------------------------

  describe "scim_replace_group/3" do
    setup do
      scim_provider()
    end

    test "replaces the display and the whole member set, and roles follow", %{
      provider: provider,
      subject: subject
    } do
      %{identity: kept} = provision(provider, "okta|kept")
      %{identity: dropped} = provision(provider, "okta|dropped")
      map_group(provider, subject, "grp-ops", :operator)
      group_id = create_group_resource(provider, "grp-ops")

      assert {:ok, %{external_group_id: "grp-ops", display: "Ops", member_ids: member_ids}} =
               SSO.scim_replace_group(provider, group_id, %{
                 display: "Ops",
                 member_ids: [kept.id, dropped.id]
               })

      assert Enum.sort(member_ids) == Enum.sort([kept.id, dropped.id])
      assert role_of(dropped) == :operator

      # PUT carries the absolute set: a member the body omits is removed and
      # loses the role the mapping granted.
      assert {:ok, %{external_group_id: "grp-ops", display: "Platform", member_ids: [member_id]}} =
               SSO.scim_replace_group(provider, group_id, %{
                 display: "Platform",
                 member_ids: [kept.id]
               })

      assert member_id == kept.id
      assert role_of(kept) == :operator
      assert role_of(dropped) == :viewer
    end

    test "refuses a body whose externalId names a different group", %{provider: provider} do
      group_id = create_group_resource(provider, "grp-ops")

      # The id in the URL is the identity; a body that names another group is a
      # redirect attempt, not a rename.
      assert {:error, :invalid_scim_group} =
               SSO.scim_replace_group(provider, group_id, %{
                 external_id: "grp-other",
                 display: "Ops",
                 member_ids: []
               })

      assert {:ok, %{external_group_id: "grp-ops", member_ids: []}} =
               SSO.scim_fetch_group(provider, group_id)
    end

    test "rejects a malformed id", %{provider: provider} do
      assert SSO.scim_replace_group(provider, "not-a-uuid", %{display: "Ops", member_ids: []}) ==
               {:error, :not_found}
    end
  end

  describe "scim_patch_group/3" do
    setup do
      scim_provider()
    end

    test "add then remove applies both in wire order", %{
      provider: provider,
      subject: subject
    } do
      %{identity: kept} = provision(provider, "okta|kept")
      %{identity: dropped} = provision(provider, "okta|dropped")
      map_group(provider, subject, "grp-ops", :operator)
      group_id = create_group_resource(provider, "grp-ops")

      operations = [
        members_op("Add", [kept.id, dropped.id]),
        members_op("remove", [dropped.id])
      ]

      assert {:ok, %{external_group_id: "grp-ops", member_ids: [member_id]}} =
               SSO.scim_patch_group(provider, group_id, operations)

      assert member_id == kept.id
      assert role_of(kept) == :operator
      assert role_of(dropped) == :viewer
    end

    test "a whole-set replace hands over the absolute set a later remove applies to", %{
      provider: provider,
      subject: subject
    } do
      %{identity: kept} = provision(provider, "okta|kept")
      %{identity: victim} = provision(provider, "okta|victim")
      map_group(provider, subject, "grp-adm", :admin)
      group_id = create_group_resource(provider, "grp-adm")

      # An IdP rewriting a group and then offboarding in one request: the remove
      # applies to the replaced set, not to a set the batch already superseded.
      operations = [
        members_op("replace", [kept.id, victim.id]),
        members_op("remove", [victim.id])
      ]

      assert {:ok, %{member_ids: [member_id]}} =
               SSO.scim_patch_group(provider, group_id, operations)

      assert member_id == kept.id
      assert role_of(kept) == :admin
      assert role_of(victim) == :viewer
    end

    test "Okta's filtered remove takes the named member out", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|filtered")
      map_group(provider, subject, "grp-adm", :admin)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      assert role_of(identity) == :admin

      operations = [%{"op" => "remove", "path" => ~s(members[value eq "#{identity.id}"])}]

      assert {:ok, _summary} =
               SSO.scim_patch_group(provider, group_resource_id(provider, "grp-adm"), operations)

      assert role_of(identity) == :viewer
    end

    test "Okta's pathless `{id, displayName}` settle renames the group it addresses", %{
      provider: provider,
      subject: subject
    } do
      mapping = map_group(provider, subject, "grp-ops", :operator)
      group_id = create_group_resource(provider, "grp-ops")

      operations = [
        %{"op" => "replace", "value" => %{"id" => group_id, "displayName" => "Platform"}}
      ]

      assert {:ok, %{external_group_id: "grp-ops", display: "Platform"}} =
               SSO.scim_patch_group(provider, group_id, operations)

      assert Repo.reload!(mapping).external_group_display == "Platform"
    end

    test "an unacceptable rename takes the membership change batched with it", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|atomic")
      map_group(provider, subject, "grp-adm", :admin)
      group_id = create_group_resource(provider, "grp-adm")

      operations = [
        %{"op" => "replace", "path" => "displayName", "value" => String.duplicate("n", 300)},
        members_op("add", [identity.id])
      ]

      assert SSO.scim_patch_group(provider, group_id, operations) ==
               {:error, :invalid_scim_group}

      # The privilege change must not land under a rename we refuse.
      assert role_of(identity) == :viewer
    end

    test "an operation list past the cap is refused before anything is applied", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|flood")
      map_group(provider, subject, "grp-adm", :admin)
      group_id = create_group_resource(provider, "grp-adm")
      operations = List.duplicate(members_op("add", [identity.id]), 101)

      assert SSO.scim_patch_group(provider, group_id, operations) ==
               {:error, :invalid_scim_group}

      assert role_of(identity) == :viewer
    end

    test "one pathless map cannot expand past the operation cap", %{provider: provider} do
      group_id = create_group_resource(provider, "grp-adm")
      value = Map.new(1..101, &{"attribute#{&1}", &1})
      operations = [%{"op" => "replace", "value" => value}]

      assert SSO.scim_patch_group(provider, group_id, operations) ==
               {:error, :invalid_scim_group}
    end

    test "member changes past the AGGREGATE cap are refused, not just one oversized op", %{
      provider: provider
    } do
      group_id = create_group_resource(provider, "grp-adm")
      half = for _n <- 1..2600, do: Ecto.UUID.generate()
      rest = for _n <- 2601..5200, do: Ecto.UUID.generate()

      assert SSO.scim_patch_group(provider, group_id, [
               members_op("add", half),
               members_op("add", rest)
             ]) == {:error, :invalid_scim_group}
    end

    test "an operation on an attribute we do not model is refused, not a silent no-op", %{
      provider: provider
    } do
      group_id = create_group_resource(provider, "grp-adm")
      operations = [%{"op" => "replace", "path" => "description", "value" => "Ops team"}]

      assert SSO.scim_patch_group(provider, group_id, operations) ==
               {:error, :unsupported_scim_patch}
    end

    test "an externalId settle alone answers with the group as it stands", %{provider: provider} do
      %{identity: identity} = provision(provider, "okta|settled")

      {:ok, group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_ids: [identity.id]
        })

      # Entra reads a group back and PATCHes `externalId` to the value it already
      # has; answering 400 stopped that group's sync dead.
      operations = [%{"op" => "replace", "path" => "externalId", "value" => "grp-ops"}]

      assert SSO.scim_patch_group(provider, group.id, operations) ==
               {:ok,
                %{
                  id: group.id,
                  external_group_id: "grp-ops",
                  display: "Ops",
                  member_ids: [identity.id]
                }}
    end

    test "a member resource id belonging to another account is ignored, never reached", %{
      provider: provider_a,
      subject: subject_a
    } do
      %{provider: provider_b, subject: subject_b} = scim_provider()
      %{identity: identity_b} = provision(provider_b, "okta|b-only")
      map_group(provider_a, subject_a, "grp-adm", :admin)
      map_group(provider_b, subject_b, "grp-adm", :admin)
      group_id = create_group_resource(provider_a, "grp-adm")

      operations = [members_op("add", [identity_b.id])]

      assert {:ok, %{member_ids: []}} =
               SSO.scim_patch_group(provider_a, group_id, operations)

      assert role_of(identity_b) == :viewer
    end
  end

  # -- recompute_role_for_identity/2 (provider-scoped) -----------------

  describe "directory_authorization_version/3" do
    test "reads the latest account-bound version, including a pending handoff's deleted provider" do
      provider = Fixtures.SSO.create_identity_provider()
      assert SSO.directory_authorization_version(provider.account_id, provider.id, Repo) == 0
      updated = provider |> Ecto.Changeset.change(authorization_version: 7) |> Repo.update!()
      assert SSO.directory_authorization_version(provider.account_id, provider.id, Repo) == 7
      Fixtures.SSO.mark_provider_deleted(updated)
      assert SSO.directory_authorization_version(provider.account_id, provider.id, Repo) == 7
    end

    test "missing, unbound and cross-account providers cannot supply a directory version" do
      provider = Fixtures.SSO.create_identity_provider()
      provider |> Ecto.Changeset.change(authorization_version: 9) |> Repo.update!()
      other = Fixtures.Accounts.create_account()

      assert SSO.directory_authorization_version(other.id, provider.id, Repo) == 0

      assert SSO.directory_authorization_version(provider.account_id, Ecto.UUID.generate(), Repo) ==
               0

      assert SSO.directory_authorization_version(provider.account_id, nil, Repo) == 0
    end
  end

  describe "recompute_role_for_identity/2" do
    setup do
      scim_provider()
    end

    test "applies the HIGHEST mapped role over the identity's synced groups", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity} = provision(provider, "okta|hi")

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-op", role: :operator},
          subject
        )

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-adm", role: :admin},
          subject
        )

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-op",
          member_ids: [identity.id]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      assert {:ok, %Accounts.Membership{role: :admin}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert role_of(identity) == :admin
    end

    test "marks the role directory-managed, so the DOMAIN refuses an operator's manual change", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity, membership: membership} = provision(provider, "okta|locked")
      assert membership.directory_managed
      stale_membership = %{membership | directory_managed: false}

      # A sync recompute (even to the default role, no mapping) keeps the role marked.
      assert {:ok, _synced} = SSO.recompute_role_for_identity(provider, Repo.reload!(identity))
      assert Repo.reload!(membership).directory_managed

      # The reject is judged on the LOCKED row's own flag — passing the STALE
      # pre-sync struct (flag false) still refuses. No UI, no caller-supplied hint.
      assert Accounts.update_membership_role(stale_membership, "admin", subject) ==
               {:error, :role_managed_by_directory}
    end

    test "an identity in NO mapped group resets to the provider default_role (#3)", %{
      provider: provider
    } do
      %{identity: identity} = provision(provider, "okta|none")

      # No group mappings at all → reset to the provider default (:viewer).
      assert {:ok, %Accounts.Membership{role: :viewer}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert role_of(identity) == :viewer
    end

    test "never re-roles a human owner (#3 — owners out of sync scope)", %{
      provider: provider,
      subject: subject
    } do
      %{identity: identity, membership: membership} = provision(provider, "okta|ownerskip")
      Fixtures.Memberships.force_role(membership, "owner")

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-adm", role: :admin},
          subject
        )

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      # A mapped :admin group would otherwise demote owner→admin, but recompute
      # leaves a human owner untouched.
      assert {:ok, %Accounts.Membership{role: :owner}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert Repo.reload!(membership).role == :owner
    end
  end

  # -- enable_scim/2 ---------------------------------------------------

  describe "enable_scim/2" do
    test "mints a bearer + flips scim_enabled, returning the raw token once" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{scim_enabled: true} = enabled, raw} =
               SSO.enable_scim(provider, subject)

      assert String.starts_with?(raw, "ems-")
      assert enabled.scim_token_prefix == String.slice(raw, 0, 12)
      # The minted bearer authenticates immediately.
      assert {:ok, _} = SSO.authenticate_scim_token(raw)

      assert {:ok, [event], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      assert event.payload["changes"]["scim_enabled"] == %{
               "before" => false,
               "after" => true
             }

      assert event.payload["scim_token_issued"] == true
      refute Map.has_key?(event.payload, "scim_token_rotated")
      refute Map.has_key?(event.payload, "scim_token_revoked")
      refute inspect(event.payload) =~ raw
    end

    test "a Team plan can configure OIDC but is denied SCIM enable (:directory_sync_not_available)" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert SSO.enable_scim(provider, subject) == {:error, :directory_sync_not_available}
      refute Repo.reload!(provider).scim_enabled
    end

    test "the SCIM token prefix is unique across providers (partial index)" do
      {_owner, account, subject} = enterprise_owner()
      first = provider_fixture(account, %{kind: :okta})
      second = provider_fixture(account, %{kind: :keycloak})

      {:ok, enabled_first, _raw} = SSO.enable_scim(first, subject)
      prefix = enabled_first.scim_token_prefix
      assert is_binary(prefix)

      # Forcing the SAME prefix onto a second provider hits the partial unique
      # index (`WHERE scim_token_prefix IS NOT NULL AND deleted_at IS NULL`), so
      # a minted bearer's prefix can never collide and mis-route a token.
      assert {:error, changeset} =
               second
               |> IdentityProvider.Changeset.scim_token(prefix, "a-different-hash", true)
               |> Repo.update()

      assert errors_on(changeset).scim_token_prefix != []
    end

    test "a non-admin (no manage_sso) is denied → :unauthorized" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      # The account IS enterprise, so this isolates the ROLE gate (manage_sso
      # fails before the plan check) — not the :directory_sync_not_available
      # plan denial the test above covers.
      assert SSO.enable_scim(provider, viewer_in(account)) == {:error, :unauthorized}
      refute Repo.reload!(provider).scim_enabled
    end

    test "cross-account: account B cannot enable SCIM on account A's provider → :not_found" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert SSO.enable_scim(provider, sb) == {:error, :not_found}
    end

    test "a kind that can't push SCIM is refused, and keeps no token" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{kind: :google_workspace})

      # Google has no inbound SCIM for a custom app, so a bearer minted here
      # could only ever authenticate a directory that cannot exist.
      assert SSO.enable_scim(provider, subject) == {:error, :scim_not_supported}

      reloaded = Repo.reload!(provider)
      refute reloaded.scim_enabled
      assert is_nil(reloaded.scim_token_prefix)
      assert is_nil(reloaded.scim_token_hash)
    end
  end

  # -- rotate_scim_token/2 ---------------------------------------------

  describe "rotate_scim_token/2" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      %{account: account, subject: subject, provider: provider}
    end

    test "mints a new bearer and invalidates the old one", %{subject: subject, provider: provider} do
      {:ok, _enabled, raw1} = SSO.enable_scim(provider, subject)
      assert {:ok, _} = SSO.authenticate_scim_token(raw1)

      assert {:ok, %IdentityProvider{scim_enabled: true}, raw2} =
               SSO.rotate_scim_token(provider, subject)

      refute raw2 == raw1
      # The old bearer is dead the instant it's rotated; only the new one works.
      assert SSO.authenticate_scim_token(raw1) == {:error, :unauthorized}
      assert {:ok, _} = SSO.authenticate_scim_token(raw2)

      assert {:ok, events, _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      event = Enum.find(events, &(&1.payload["scim_token_rotated"] == true))
      assert event.payload["changes"] == %{}
      refute Map.has_key?(event.payload, "scim_token_issued")
      refute Map.has_key?(event.payload, "scim_token_revoked")
      refute inspect(event.payload) =~ raw1
      refute inspect(event.payload) =~ raw2
    end

    test "a non-admin (no manage_sso) is denied → :unauthorized", %{
      account: account,
      provider: provider
    } do
      assert SSO.rotate_scim_token(provider, viewer_in(account)) == {:error, :unauthorized}
    end

    test "a kind that can't push SCIM is refused", %{account: account, subject: subject} do
      google = provider_fixture(account, %{kind: :google_workspace, name: "Google"})

      assert SSO.rotate_scim_token(google, subject) == {:error, :scim_not_supported}
      assert is_nil(Repo.reload!(google).scim_token_prefix)
    end

    test "cross-account: account B cannot rotate account A's SCIM bearer → :not_found", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      assert SSO.rotate_scim_token(provider, sb) == {:error, :not_found}
    end
  end

  # -- disable_scim/2 --------------------------------------------------

  describe "disable_scim/2" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      %{account: account, subject: subject, provider: provider}
    end

    test "clears the bearer + flag so the token stops authenticating", %{
      subject: subject,
      provider: provider
    } do
      {:ok, _enabled, raw} = SSO.enable_scim(provider, subject)
      assert {:ok, _} = SSO.authenticate_scim_token(raw)

      assert {:ok, %IdentityProvider{} = disabled} = SSO.disable_scim(provider, subject)
      refute disabled.scim_enabled
      assert is_nil(disabled.scim_token_prefix)
      assert is_nil(disabled.scim_token_hash)
      assert SSO.authenticate_scim_token(raw) == {:error, :unauthorized}

      assert {:ok, events, _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_updated"]])

      event = Enum.find(events, &(&1.payload["scim_token_revoked"] == true))

      assert event.payload["changes"]["scim_enabled"] == %{
               "before" => true,
               "after" => false
             }

      refute Map.has_key?(event.payload, "scim_token_issued")
      refute Map.has_key?(event.payload, "scim_token_rotated")
      refute inspect(event.payload) =~ raw
    end

    test "discards the group snapshot, so re-enabling can't restore a revoked role", %{
      subject: subject,
      provider: provider
    } do
      # The group memberships are only true while the directory is pushing them.
      # Kept across a disable/re-enable, the first user to sync recomputed their
      # role from a stale snapshot — handing back an admin role the directory may
      # have revoked while sync was off, before any fresh push could correct it.
      {:ok, provider, _raw} = SSO.enable_scim(provider, subject)

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-adm", role: :admin},
          subject
        )

      %{identity: identity} = provision(provider, "okta|snapshot")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      assert role_of(identity) == :admin

      assert {:ok, disabled} = SSO.disable_scim(provider, subject)
      {:ok, reenabled, _raw} = SSO.enable_scim(disabled, subject)

      assert {:ok, []} = SSO.search_synced_groups(reenabled, "", subject)

      # SCIM does not order Users before Groups. Until the directory pushes
      # groups, there is no snapshot to reason from — so a user-first re-sync
      # leaves the membership alone rather than reading an absence as "in no
      # groups" and acting on it.
      %{identity: resynced} = provision(reenabled, "okta|snapshot")
      assert role_of(resynced) == :admin

      # Once groups DO arrive and this person is not among them, they drop to the
      # connection default — the old snapshot is not what restored anything.
      {:ok, _} =
        SSO.scim_upsert_group(reenabled, %{
          external_id: "grp-adm",
          member_ids: []
        })

      assert role_of(resynced) == :viewer
    end

    test "a downgraded plan can still retire the bearer", %{
      subject: subject,
      provider: provider,
      account: account
    } do
      # Expiry stops authentication immediately, but the owner must still be
      # able to retire the stored bearer and provider configuration.
      {:ok, _enabled, raw} = SSO.enable_scim(provider, subject)
      assert {:ok, _} = SSO.authenticate_scim_token(raw)

      Fixtures.Accounts.create_subscription(account, "free")

      assert {:ok, %IdentityProvider{scim_enabled: false}} = SSO.disable_scim(provider, subject)
      assert SSO.authenticate_scim_token(raw) == {:error, :unauthorized}
    end

    test "hands role and runner access control back while retaining the last synced values", %{
      subject: subject,
      provider: provider
    } do
      {:ok, provider, _raw} = SSO.enable_scim(provider, subject)
      %{identity: identity, membership: membership} = provision(provider, "okta|freed")
      {:ok, _} = SSO.recompute_role_for_identity(provider, Repo.reload!(identity))
      before = Repo.reload!(membership)
      assert before.directory_managed
      assert before.runner_access_directory_managed

      access_before =
        Accounts.runner_access_for_membership(membership.account_id, membership.id)

      {:ok, _} = SSO.disable_scim(provider, subject)

      after_disable = Repo.reload!(membership)
      refute after_disable.directory_managed
      refute after_disable.runner_access_directory_managed

      assert Accounts.runner_access_for_membership(membership.account_id, membership.id) ==
               access_before
    end

    test "a non-admin (no manage_sso) is denied → :unauthorized", %{
      account: account,
      provider: provider
    } do
      assert SSO.disable_scim(provider, viewer_in(account)) == {:error, :unauthorized}
    end

    test "cross-account: account B cannot disable account A's SCIM sync → :not_found", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      assert SSO.disable_scim(provider, sb) == {:error, :not_found}
    end
  end

  # -- Group access readout --------------------------------------------

  describe "list_group_access/3" do
    setup do
      scim_provider()
    end

    test "returns each distinct external group seen via SCIM with its member count", %{
      provider: provider,
      subject: subject
    } do
      %{identity: id1} = provision(provider, "okta|u1")
      %{identity: id2} = provision(provider, "okta|u2")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_ids: [id1.id]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          display: "Admins",
          member_ids: [id2.id]
        })

      assert {:ok, groups, metadata} = SSO.list_group_access(provider, subject)
      assert metadata.count == 2

      # Arrival order — the keyset the readout pages on, not the display name,
      # which SCIM leaves optional and a NULL cursor can never compare.
      assert [
               %{
                 id: ops_group_id,
                 display: "Ops",
                 external_group_id: "grp-ops",
                 member_count: 1,
                 mapping: nil,
                 runner_access_mapping: nil
               },
               %{
                 id: admin_group_id,
                 display: "Admins",
                 external_group_id: "grp-adm",
                 member_count: 1,
                 mapping: nil,
                 runner_access_mapping: nil
               }
             ] = groups

      assert Repo.valid_uuid?(admin_group_id)
      assert Repo.valid_uuid?(ops_group_id)
    end

    test "walks a directory larger than one page without repeating a group", %{
      provider: provider,
      subject: subject
    } do
      for n <- 1..25 do
        suffix = n |> Integer.to_string() |> String.pad_leading(2, "0")

        {:ok, _} =
          SSO.scim_upsert_group(provider, %{
            external_id: "grp-#{suffix}",
            display: "Group #{suffix}",
            member_ids: []
          })
      end

      assert {:ok, first, metadata} = SSO.list_group_access(provider, subject)
      assert length(first) == 20
      assert metadata.count == 25

      cursor = metadata.next_page_cursor

      assert {:ok, second, _metadata} =
               SSO.list_group_access(provider, subject, page: [cursor: cursor])

      assert length(second) == 5
      walked = Enum.map(first ++ second, & &1.external_group_id)
      assert length(Enum.uniq(walked)) == 25
    end

    test "a downgraded plan still reads its synced groups" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert {:ok, [], _metadata} = SSO.list_group_access(provider, subject)
    end

    test "is account-scoped — another account's enterprise owner can't read it", %{
      provider: provider
    } do
      {_u, _account_b, subject_b} = enterprise_owner()

      assert SSO.list_group_access(provider, subject_b) == {:error, :not_found}
    end
  end

  # -- search_synced_groups/3 ------------------------------------------

  describe "search_synced_groups/3" do
    setup do
      scim_provider()
    end

    test "matches the display name or the external id, and caps what it returns", %{
      provider: provider,
      subject: subject
    } do
      for n <- 1..12 do
        suffix = n |> Integer.to_string() |> String.pad_leading(2, "0")

        {:ok, _} =
          SSO.scim_upsert_group(provider, %{
            external_id: "grp-payments-#{suffix}",
            display: "Payments #{suffix}",
            member_ids: []
          })
      end

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "00g-oncall",
          display: "Incident responders",
          member_ids: []
        })

      assert {:ok, by_display} = SSO.search_synced_groups(provider, "incident", subject)
      assert [%{external_group_id: "00g-oncall"}] = by_display

      assert {:ok, by_external_id} = SSO.search_synced_groups(provider, "00g-", subject)
      assert [%{display: "Incident responders"}] = by_external_id

      # A blank term is the head of the same order, so an unopened picker is
      # already useful; both are capped well below what a directory can push.
      assert {:ok, matches} = SSO.search_synced_groups(provider, "payments", subject)
      assert length(matches) == 10
      assert {:ok, blank} = SSO.search_synced_groups(provider, "", subject)
      assert length(blank) == 10
    end

    test "a wildcard in the term matches literally rather than every group", %{
      provider: provider,
      subject: subject
    } do
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_ids: []
        })

      assert SSO.search_synced_groups(provider, "%", subject) == {:ok, []}
    end

    test "is account-scoped — another account's enterprise owner can't search it", %{
      provider: provider
    } do
      {_u, _account_b, subject_b} = enterprise_owner()

      assert SSO.search_synced_groups(provider, "", subject_b) == {:error, :not_found}
    end
  end

  # -- Group role readout -------------------------------------------

  describe "list_group_access/3 — role mappings" do
    setup do
      scim_provider()
    end

    test "lists a provider's group→role mappings for an enterprise admin", %{
      provider: provider,
      subject: subject
    } do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, subject, page: [limit: 100])

      assert [listed] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert listed.id == mapping.id
    end

    test "denies a viewer (no manage_sso)", %{provider: provider, account: account} do
      assert SSO.list_group_access(provider, viewer_in(account)) == {:error, :unauthorized}
    end

    test "a downgraded plan still reads its mappings — removing one needs no plan" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, subject, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
    end

    test "is account-scoped — B sees none of A's mappings", %{
      provider: provider,
      subject: subject
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      {:ok, _} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-a", role: :admin},
          subject
        )

      assert SSO.list_group_access(provider, sb) == {:error, :not_found}
    end
  end

  # -- create_group_mapping/3 ------------------------------------------

  describe "create_group_mapping/3" do
    setup do
      scim_provider()
    end

    test "creates a group→role mapping for an enterprise admin", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, %GroupRoleMapping{} = mapping} =
               create_group_mapping_fixture(
                 provider,
                 %{external_group_id: "grp-1", external_group_display: "Admins", role: :admin},
                 subject
               )

      assert mapping.external_group_id == "grp-1"
      assert mapping.role == :admin
    end

    test "rejects an :owner mapping (sync can never grant owner — decision 7)", %{
      provider: provider,
      subject: subject
    } do
      assert {:error, %Ecto.Changeset{} = changeset} =
               create_group_mapping_fixture(
                 provider,
                 %{external_group_id: "grp-owner", role: :owner},
                 subject
               )

      assert "directory sync cannot grant owner" in errors_on(changeset).role
    end

    test "a duplicate (provider, external_group_id) hits the unique index", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, _} =
               create_group_mapping_fixture(
                 provider,
                 %{external_group_id: "00g-dupe", role: :admin},
                 subject
               )

      assert {:error, changeset} =
               create_group_mapping_fixture(
                 provider,
                 %{external_group_id: "00g-dupe", role: :operator},
                 subject
               )

      assert "This group already has a role mapping." in errors_on(changeset).directory_group_id
      refute Map.has_key?(errors_on(changeset), :provider_id)
    end

    test "denies a viewer (no manage_sso)", %{provider: provider, account: account} do
      assert create_group_mapping_fixture(
               provider,
               %{external_group_id: "grp-x", role: :admin},
               viewer_in(account)
             ) == {:error, :unauthorized}
    end

    test "denies a Team plan (:directory_sync_not_available)", %{provider: provider} do
      {_owner, _team_account, team_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      assert create_group_mapping_fixture(
               provider,
               %{external_group_id: "grp-x", role: :admin},
               team_subject
             ) == {:error, :directory_sync_not_available}
    end

    test "cross-account: B can't create a mapping on A's provider (:not_found)", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      assert create_group_mapping_fixture(
               provider,
               %{external_group_id: "grp-x", role: :admin},
               sb
             ) ==
               {:error, :not_found}
    end
  end

  # -- update_group_mapping/3 ------------------------------------------

  describe "update_group_mapping/3" do
    setup do
      scim_provider()
    end

    test "updates a mapping's role for an enterprise admin", %{
      provider: provider,
      subject: subject
    } do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert {:ok, updated} = SSO.update_group_mapping(mapping, %{role: :operator}, subject)
      assert updated.role == :operator
    end

    test "granting every runner drops the selection it replaces", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "db")

      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      assert {:ok, updated} =
               SSO.update_group_runner_access_mapping(
                 mapping,
                 %{runner_access_mode: :all, scope: ["group:db"]},
                 subject
               )

      assert updated.runner_access_mode == :all
      assert updated.runner_scope_groups == []
      assert updated.runner_scope_runner_ids == []
    end

    test "denies a viewer without manage_sso", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert SSO.update_group_mapping(mapping, %{role: :viewer}, viewer_in(account)) ==
               {:error, :unauthorized}
    end

    test "rejects editing a mapping up to :owner", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert {:error, %Ecto.Changeset{} = changeset} =
               SSO.update_group_mapping(mapping, %{role: :owner}, subject)

      assert "directory sync cannot grant owner" in errors_on(changeset).role
    end

    test "cross-account: B can't update A's mapping (:not_found)", %{
      provider: provider,
      subject: subject
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      {:ok, mapping_a} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert SSO.update_group_mapping(mapping_a, %{role: :viewer}, sb) == {:error, :not_found}
    end
  end

  # -- delete_group_mapping/2 ------------------------------------------

  describe "delete_group_mapping/2" do
    setup do
      scim_provider()
    end

    test "soft-deletes a mapping for an enterprise admin", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert {:ok, deleted} = SSO.delete_group_mapping(mapping, subject)
      assert deleted.deleted_at

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, subject, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
    end

    test "denies a viewer without manage_sso", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, mapping} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert SSO.delete_group_mapping(mapping, viewer_in(account)) == {:error, :unauthorized}
    end

    test "cross-account: B can't delete A's mapping (:not_found)", %{
      provider: provider,
      subject: subject
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      {:ok, mapping_a} =
        create_group_mapping_fixture(
          provider,
          %{external_group_id: "grp-1", role: :admin},
          subject
        )

      assert SSO.delete_group_mapping(mapping_a, sb) == {:error, :not_found}
    end
  end

  describe "list_group_access/3 — runner and pack mappings" do
    setup do
      scim_provider()
    end

    test "lists only the provider's mappings", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "db")

      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, subject, page: [limit: 100])

      assert [listed] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      assert listed.id == mapping.id
    end

    test "is permission and account scoped", %{provider: provider, account: account} do
      assert SSO.list_group_access(provider, viewer_in(account)) ==
               {:error, :unauthorized}

      {_owner, _other_account, other_subject} = enterprise_owner()

      assert SSO.list_group_access(provider, other_subject) == {:error, :not_found}
    end
  end

  describe "create_group_runner_access_mapping/3" do
    setup do
      scim_provider()
    end

    test "creates an independent additive access grant", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "production")

      assert {:ok, %GroupRunnerAccessMapping{} = mapping} =
               create_group_runner_access_mapping_fixture(
                 provider,
                 %{
                   external_group_id: "grp-prod",
                   external_group_display: "Production",
                   runner_access_mode: :restricted,
                   scope: ["group:production"]
                 },
                 subject
               )

      assert mapping.external_group_id == "grp-prod"
      assert mapping.runner_access_mode == :restricted
      assert mapping.runner_scope_groups == ["production"]
      assert mapping.pack_access_mode == :all
      assert mapping.pack_scope_pack_ids == []

      assert {:ok, [event], _meta} =
               Audit.list_events(subject,
                 filter: [event_type: ["sso.group_runner_access_mapping_created"]]
               )

      assert event.payload["before"]["mode"] == "none"
      assert event.payload["after"]["mode"] == "restricted"
      assert event.payload["after"]["groups"] == ["production"]
    end

    test "rejects a grant that names a runner or group in another account", %{
      provider: provider,
      subject: subject
    } do
      foreign_runner = Fixtures.Runners.create_runner(group: "foreign")

      for scope <- [["runner:#{foreign_runner.id}"], ["group:foreign"]] do
        assert {:error, changeset} =
                 create_group_runner_access_mapping_fixture(
                   provider,
                   %{
                     external_group_id: "grp-foreign",
                     runner_access_mode: :restricted,
                     scope: scope
                   },
                   subject
                 )

        assert "is invalid" in errors_on(changeset).runner_access_mode
        # The rejected selection rides back so the picker still shows it.
        assert Ecto.Changeset.get_field(changeset, :scope) == scope
      end
    end

    test "an injected persisted array is ignored, so it never becomes the grant", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")

      assert {:error, changeset} =
               create_group_runner_access_mapping_fixture(
                 provider,
                 %{
                   external_group_id: "grp-injected",
                   runner_access_mode: :restricted,
                   runner_scope_groups: ["db"],
                   runner_scope_runner_ids: [runner.id]
                 },
                 subject
               )

      assert "is invalid" in errors_on(changeset).runner_access_mode
      refute Repo.one(GroupRunnerAccessMapping)
    end

    test "a valid same-account grant beyond the configuring admin is nondelegation, not input", %{
      account: account,
      provider: provider,
      subject: owner_subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "app")
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(membership, db_access, owner_subject)

      assert create_group_runner_access_mapping_fixture(
               provider,
               %{
                 external_group_id: "grp-app",
                 runner_access_mode: :restricted,
                 scope: ["group:app"]
               },
               Fixtures.Subjects.subject_for(membership)
             ) == {:error, :runner_access_exceeds_subject}
    end

    test "a malformed selection from another account is still not_found", %{provider: provider} do
      {_owner, _other_account, other_subject} = enterprise_owner()

      assert create_group_runner_access_mapping_fixture(
               provider,
               %{
                 external_group_id: "grp-x",
                 runner_access_mode: :restricted,
                 scope: ["not-a-selector"]
               },
               other_subject
             ) == {:error, :not_found}
    end

    test "a malformed selection a viewer submits is still unauthorized", %{
      provider: provider,
      account: account
    } do
      assert create_group_runner_access_mapping_fixture(
               provider,
               %{
                 external_group_id: "grp-x",
                 runner_access_mode: :restricted,
                 scope: ["not-a-selector"]
               },
               viewer_in(account)
             ) == {:error, :unauthorized}
    end

    test "the database rejects an account/provider tenant mismatch", %{
      provider: provider
    } do
      {_user, other_account, _subject} = enterprise_owner()
      group_id = create_group_resource(provider, "grp-cross-tenant")
      group = Repo.get!(DirectoryGroup, group_id)

      changeset =
        Emisar.SSO.GroupRunnerAccessMapping.Changeset.create(
          other_account.id,
          provider.id,
          group,
          %{runner_access_mode: :all}
        )

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).provider_id
    end

    test "refuses a grant broader than the configuring admin currently has", %{
      account: account,
      provider: provider,
      subject: owner_subject
    } do
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(membership, db_access, owner_subject)

      admin_subject = Fixtures.Subjects.subject_for(membership)

      assert create_group_runner_access_mapping_fixture(
               provider,
               %{external_group_id: "grp-all", runner_access_mode: :all},
               admin_subject
             ) == {:error, :runner_access_exceeds_subject}
    end

    test "denies a viewer (no manage_sso)", %{provider: provider, account: account} do
      assert create_group_runner_access_mapping_fixture(
               provider,
               %{external_group_id: "grp-x", runner_access_mode: :all},
               viewer_in(account)
             ) == {:error, :unauthorized}
    end

    test "is account scoped", %{provider: provider} do
      {_owner, _other_account, other_subject} = enterprise_owner()

      assert create_group_runner_access_mapping_fixture(
               provider,
               %{external_group_id: "grp-x", runner_access_mode: :all},
               other_subject
             ) == {:error, :not_found}
    end
  end

  describe "group runner access mapping pack scope" do
    setup do
      scim_provider()
    end

    test "narrows a mapping to the account's packs and refuses an unknown one", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id, pack_id: "postgres")

      attrs = %{
        external_group_id: "grp-dba",
        runner_access_mode: :restricted,
        scope: ["group:production"],
        pack_access_mode: :restricted,
        pack_scope: ["pack:postgres"]
      }

      assert {:ok, %GroupRunnerAccessMapping{} = mapping} =
               create_group_runner_access_mapping_fixture(provider, attrs, subject)

      assert mapping.pack_access_mode == :restricted
      assert mapping.pack_scope_pack_ids == ["postgres"]

      assert {:error, changeset} =
               create_group_runner_access_mapping_fixture(
                 provider,
                 %{attrs | external_group_id: "grp-other", pack_scope: ["pack:nope"]},
                 subject
               )

      assert "is invalid" in errors_on(changeset).pack_access_mode
    end
  end

  describe "update_group_runner_access_mapping/3" do
    setup do
      scim_provider()
    end

    test "replaces the mapped access", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      Fixtures.Runners.create_runner(account_id: account.id, group: "app")

      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      assert {:ok, updated} =
               SSO.update_group_runner_access_mapping(
                 mapping,
                 %{runner_access_mode: :restricted, scope: ["group:app"]},
                 subject
               )

      assert updated.runner_scope_groups == ["app"]

      assert {:ok, [event], _meta} =
               Audit.list_events(subject,
                 filter: [event_type: ["sso.group_runner_access_mapping_updated"]]
               )

      assert event.payload["before"]["groups"] == ["db"]
      assert event.payload["after"]["groups"] == ["app"]
    end

    test "denies a viewer without manage_sso", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      assert SSO.update_group_runner_access_mapping(
               mapping,
               %{runner_access_mode: :all},
               viewer_in(account)
             ) == {:error, :unauthorized}
    end

    test "another account cannot update it", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      {_owner, _other_account, other_subject} = enterprise_owner()

      assert SSO.update_group_runner_access_mapping(
               mapping,
               %{runner_access_mode: :all},
               other_subject
             ) == {:error, :not_found}
    end
  end

  describe "delete_group_runner_access_mapping/2" do
    setup do
      scim_provider()
    end

    test "soft-deletes the independent grant", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      assert {:ok, deleted} = SSO.delete_group_runner_access_mapping(mapping, subject)
      assert deleted.deleted_at

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, subject, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))
    end

    test "denies a viewer without manage_sso", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      assert SSO.delete_group_runner_access_mapping(mapping, viewer_in(account)) ==
               {:error, :unauthorized}
    end

    test "another account cannot delete it", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        create_group_runner_access_mapping_fixture(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      {_owner, _other_account, other_subject} = enterprise_owner()

      assert SSO.delete_group_runner_access_mapping(mapping, other_subject) ==
               {:error, :not_found}
    end
  end

  # -- list_link_requests/3 --------------------------------------------

  describe "list_pending_link_request_facts/2" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      %{account: account, subject: subject}
    end

    test "carries the connection's identity and its current default runner access", %{
      account: account,
      subject: subject
    } do
      provider =
        provider_fixture(account, %{
          name: "Okta",
          provisioner: :manual,
          default_runner_access_mode: :all
        })

      request = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})

      assert {:ok, [facts], _meta} = SSO.list_pending_link_request_facts(subject)
      assert facts.request.id == request.id
      assert facts.provider.id == provider.id
      assert facts.provider.name == "Okta"
      assert facts.provider.enabled?
      assert facts.default_role == :viewer
      assert facts.default_runner_access == RunnerAccess.all()
      assert facts.request.provider == nil
    end

    test "a disabled connection keeps its defaults", %{account: account, subject: subject} do
      provider =
        provider_fixture(account, %{
          provisioner: :manual,
          default_runner_access_mode: :all
        })

      _request = capture_request(provider, %{"sub" => "okta|b", "email" => "b@acme.test"})
      {:ok, _provider} = SSO.update_provider(provider, %{enabled: false}, subject)

      assert {:ok, [facts], _meta} = SSO.list_pending_link_request_facts(subject)
      refute facts.provider.enabled?
      assert facts.default_runner_access == RunnerAccess.all()
    end

    test "a deleted connection makes its request unavailable, never a silent no-access default",
         %{account: account, subject: subject} do
      provider =
        provider_fixture(account, %{
          provisioner: :manual,
          default_runner_access_mode: :all
        })

      _request = capture_request(provider, %{"sub" => "okta|c", "email" => "c@acme.test"})
      {:ok, _provider} = SSO.delete_provider(provider, subject)

      assert {:ok, [], _meta} = SSO.list_pending_link_request_facts(subject)
    end

    test "denies a viewer (no manage_sso)", %{account: account} do
      assert SSO.list_pending_link_request_facts(viewer_in(account)) == {:error, :unauthorized}
    end

    test "is account-scoped — B never sees A's pending", %{account: account} do
      provider = provider_fixture(account, provisioner: :manual)
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:ok, [], _meta} = SSO.list_pending_link_request_facts(sb)
    end
  end

  describe "count_pending_link_requests/1" do
    test "counts only reviewable requests in the subject's account" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      _first = capture_request(provider, %{"sub" => "okta|count-a", "email" => "a@acme.test"})
      _second = capture_request(provider, %{"sub" => "okta|count-b", "email" => "b@acme.test"})
      {_other_owner, _other_account, other_subject} = enterprise_owner()

      assert SSO.count_pending_link_requests(subject) == 2
      assert SSO.count_pending_link_requests(viewer_in(account)) == 0
      assert SSO.count_pending_link_requests(other_subject) == 0
    end
  end

  # -- fetch_pending_link_request/1 -----------------------------------

  describe "fetch_pending_link_request/1" do
    test "loads a captured request by id (no subject), account preloaded" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      request = capture_request(provider, %{"sub" => "okta|pending", "email" => "p@acme.test"})

      assert {:ok, loaded} = SSO.fetch_pending_link_request(request.id)
      assert loaded.id == request.id
      assert loaded.account.id == account.id
    end

    test "an unknown or malformed id is :not_found (approved/dismissed requests are gone)" do
      assert SSO.fetch_pending_link_request(Ecto.UUID.generate()) == {:error, :not_found}
      assert SSO.fetch_pending_link_request("not-a-uuid") == {:error, :not_found}
    end
  end

  describe "link_request_invitation_pending?/1" do
    test "distinguishes a token-backed invitation from a direct membership and a new user" do
      account = Fixtures.Accounts.create_account()

      pending =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          invitation_token_digest: "pending-invitation"
        )

      direct = Fixtures.Memberships.create_membership(account_id: account.id)

      assert SSO.link_request_invitation_pending?(%LinkRequest{
               account_id: account.id,
               matched_membership_id: pending.id
             })

      refute SSO.link_request_invitation_pending?(%LinkRequest{
               account_id: account.id,
               matched_membership_id: direct.id
             })

      refute SSO.link_request_invitation_pending?(%LinkRequest{account_id: account.id})
    end
  end

  # -- approve_link_request/3 ------------------------------------------

  describe "granting a role through SSO can't exceed the granter's own" do
    setup do
      {_owner, account, owner_subject} = enterprise_owner()
      provider = provider_fixture(account, default_role: :operator)
      {:ok, provider, _token} = SSO.enable_scim(provider, owner_subject)

      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      %{
        account: account,
        provider: provider,
        admin: Fixtures.Subjects.subject_for(membership)
      }
    end

    test "an admin can't make owner the connection default", %{
      provider: provider,
      admin: admin
    } do
      # Two independent guards refuse this and the changeset's exclusion is
      # simply the one reached first on the update path, so the reported error is
      # the field error rather than the escalation one. Pinned with an ADMIN
      # caller — who also fails `covers_role?/2` — to prove there is no ordering
      # hole between them.
      assert {:error, changeset} =
               SSO.update_provider(provider, %{default_role: :owner}, admin)

      assert "can't be owner" in errors_on(changeset).default_role
      assert Repo.reload!(provider).default_role == :operator
    end

    test "an admin can't map a group to owner", %{provider: provider, admin: admin} do
      assert create_group_mapping_fixture(
               provider,
               %{"external_group_id" => "grp-founders", "role" => "owner"},
               admin
             ) == {:error, :role_exceeds_your_permissions}
    end

    # Admins hold manage_billing, so the finance seat grants them nothing new and
    # the directory may hand it out on their authority.
    test "an admin CAN map a group to billing_manager", %{provider: provider, admin: admin} do
      assert {:ok, mapping} =
               create_group_mapping_fixture(
                 provider,
                 %{"external_group_id" => "grp-finance", "role" => "billing_manager"},
                 admin
               )

      assert mapping.role == :billing_manager

      assert {:ok, updated} =
               SSO.update_provider(provider, %{default_role: :billing_manager}, admin)

      assert updated.default_role == :billing_manager
    end

    test "an admin can still grant the roles they hold", %{provider: provider, admin: admin} do
      assert {:ok, _mapping} =
               create_group_mapping_fixture(
                 provider,
                 %{"external_group_id" => "grp-ops", "role" => "operator"},
                 admin
               )

      assert {:ok, updated} = SSO.update_provider(provider, %{default_role: :viewer}, admin)
      assert updated.default_role == :viewer
    end
  end

  describe "Provisioning.lock_provider_row/2" do
    test "refuses a concurrently-deleted provider instead of raising out of a Multi" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, locked} = SSO.Provisioning.lock_provider_row(provider)
      assert locked.id == provider.id

      Fixtures.SSO.mark_provider_deleted(provider)

      assert SSO.Provisioning.lock_provider_row(provider) == {:error, :provider_disabled}
    end
  end

  describe "approve_link_request/3" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      %{account: account, subject: subject, provider: provider}
    end

    test "a matched request cannot be approved once the connection is disabled", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "member@acme.test"
        )

      request =
        capture_request(provider, %{
          "sub" => "okta|member",
          "email" => "member@acme.test",
          "email_verified" => true
        })

      assert request.matched_membership_id == membership.id

      # The operator revokes a compromised connection between capture and review.
      Fixtures.SSO.disable_provider(provider)

      assert SSO.approve_link_request(request, RunnerAccess.none(), subject) ==
               {:error, :provider_disabled}

      refute Repo.one(UserIdentity)
    end

    test "an unmatched request cannot become a manual member once directory sync is enabled", %{
      subject: subject,
      provider: provider
    } do
      request =
        capture_request(provider, %{
          "sub" => "okta|not-in-directory",
          "email" => "not-in-directory@acme.test",
          "email_verified" => true
        })

      assert {:ok, _provider, _token} = SSO.enable_scim(provider, subject)

      assert SSO.approve_link_request(request, RunnerAccess.none(), subject) ==
               {:error, :scim_identity_unmatched}

      assert {:ok, still_pending} = SSO.fetch_pending_link_request(request.id)
      assert still_pending.id == request.id
      refute Repo.one(SSO.UserIdentity)
    end

    test "an admin can't link an identity onto an owner", %{
      account: account,
      provider: provider
    } do
      # The approver also configured the IdP, so without this they could assert
      # the owner's email under a subject they control, approve their own
      # request, and thereafter sign in as the owner.
      owner_member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "owner@acme.test"
        )

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|impersonator",
          "email" => owner_member.email,
          "email_verified" => true
        })

      assert request.matched_membership_id == owner_member.id

      assert SSO.approve_link_request(
               request,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               admin
             ) == {:error, :link_target_outranks_approver}

      refute Repo.one(UserIdentity)
      assert [_still_pending] = link_requests(provider.id)
    end

    test "a scoped admin can't link an identity onto a member who reaches more runners", %{
      account: account,
      provider: provider
    } do
      # The binding hands whoever holds the IdP credential the member's reach, so
      # an approver may bind only onto reach their own seat covers.
      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      admin = scoped_admin(account, db_only)
      wider = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      request = capture_matched_request(provider, wider)

      assert SSO.approve_link_request(request, RunnerAccess.none(), admin) ==
               {:error, :link_target_reach_exceeds_approver}

      refute Repo.one(UserIdentity)
      assert [_still_pending] = link_requests(provider.id)
    end

    test "a scoped admin can't link an identity onto a member who reaches more packs", %{
      account: account,
      provider: provider
    } do
      {:ok, core_packs_only} = RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])
      admin = scoped_admin(account, core_packs_only)
      wider = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      request = capture_matched_request(provider, wider)

      assert SSO.approve_link_request(request, RunnerAccess.none(), admin) ==
               {:error, :link_target_reach_exceeds_approver}

      refute Repo.one(UserIdentity)
    end

    test "no one links an identity onto a member while the directory reconciles its access", %{
      account: account,
      provider: provider
    } do
      # Mid-reconciliation the stored reach reads as none, and the directory may
      # grant more once it settles, so the reach check cannot judge it yet.
      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      admin = scoped_admin(account, db_only)

      reconciling =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
        |> Ecto.Changeset.change(directory_authorization_pending_version: 1)
        |> Repo.update!()

      request = capture_matched_request(provider, reconciling)

      assert SSO.approve_link_request(request, RunnerAccess.none(), admin) ==
               {:error, :link_target_authorization_pending}

      refute Repo.one(UserIdentity)
    end

    test "a scoped admin can still link an identity onto a member inside their reach", %{
      account: account,
      provider: provider
    } do
      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      admin = scoped_admin(account, db_only)

      narrower =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
        |> Fixtures.Memberships.force_runner_access(db_only)

      request = capture_matched_request(provider, narrower)

      assert {:ok, %{membership: linked}} =
               SSO.approve_link_request(request, RunnerAccess.none(), admin)

      assert linked.id == narrower.id
    end

    test "an admin can't link an identity onto a SUSPENDED owner", %{
      account: account,
      provider: provider
    } do
      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "held-owner@acme.test"
        )

      # An offboarding hold is exactly when the credential must not be rebound:
      # approving a directory suspension reinstates the membership in the same
      # transaction, so the escalation would complete unattended.
      Fixtures.Memberships.suspend_membership(owner_membership)

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|held-owner-impersonator",
          "email" => owner_membership.email,
          "email_verified" => true
        })

      assert request.matched_membership_id == owner_membership.id

      assert SSO.approve_link_request(request, RunnerAccess.none(), admin) ==
               {:error, :link_target_outranks_approver}

      refute Repo.one(UserIdentity)
    end

    test "an admin can't bind an identity before an owner accepts their invitation", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      {:ok, %{membership: invitation, invitation_token: invitation_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: "invited-owner@acme.test", role: "owner"),
          subject
        )

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|latent-owner-credential",
          "email" => "invited-owner@acme.test",
          "email_verified" => true
        })

      assert request.matched_membership_id == invitation.id

      assert SSO.approve_link_request(request, RunnerAccess.none(), admin) ==
               {:error, :invitation_pending}

      refute Repo.one(UserIdentity)
      assert {:ok, still_pending} = SSO.fetch_pending_link_request(request.id)
      assert still_pending.id == request.id
      assert Accounts.membership_invitation_pending?(Repo.reload!(invitation))

      accept_invitation(invitation_token, "invited-owner@acme.test")

      assert SSO.approve_link_request(request, RunnerAccess.none(), admin) ==
               {:error, :link_target_outranks_approver}
    end

    test "a request cannot bind after its matched membership is removed", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "removed-match@acme.test"
        )

      request =
        capture_request(provider, %{
          "sub" => "okta|removed-match",
          "email" => membership.email,
          "email_verified" => true
        })

      Fixtures.Memberships.mark_membership_as_deleted(membership)

      assert SSO.approve_link_request(request, RunnerAccess.none(), subject) ==
               {:error, :matched_user_unavailable}

      refute Repo.one(UserIdentity)
      assert {:ok, still_pending} = SSO.fetch_pending_link_request(request.id)
      assert still_pending.id == request.id
    end

    test "a request cannot bind a member who has moved to another address since", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, email: "moved@acme.test")

      request =
        capture_request(provider, %{
          "sub" => "okta|moved",
          "email" => membership.email,
          "email_verified" => true
        })

      Fixtures.Memberships.change_email(membership, "elsewhere@acme.test")

      assert SSO.approve_link_request(request, RunnerAccess.none(), subject) ==
               {:error, :matched_email_changed}

      refute Repo.one(UserIdentity)
      assert {:ok, still_pending} = SSO.fetch_pending_link_request(request.id)
      assert still_pending.id == request.id
    end

    test "a request inserted after the sweep is still refused", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      # The half deleting requests alongside the change cannot reach: a callback
      # that verified under the OLD issuer, paused, and inserted its request AFTER
      # the sweep ran. The row exists and looks legitimate; what gives it away is
      # the namespace it was made under.
      target_member = Fixtures.Memberships.create_membership(account_id: account.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|inserted-after-the-sweep",
          "email" => target_member.email,
          "email_verified" => true
        })

      assert {:ok, _provider} =
               SSO.update_provider(
                 provider,
                 %{
                   "issuer" => "https://an-idp-the-admin-controls.test",
                   "client_secret" => "the-admin-supplies-their-own"
                 },
                 subject
               )

      # Stand the row back up exactly as a late insert would leave it — same
      # fingerprint, taken under the issuer that has since been replaced.
      {:ok, late} = Repo.insert(Map.put(request, :id, Ecto.UUID.generate()))

      assert SSO.approve_link_request(
               late,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               subject
             ) == {:error, :identity_namespace_changed}

      refute Repo.one(SSO.UserIdentity)
    end

    test "a request captured under the old issuer does not survive a repoint", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      # Repointing is refused once an identity is bound, so it is allowed exactly
      # while none is — which is when pending requests exist. Approving one after
      # the repoint would bind its identifier against an IdP the approver never
      # vetted: whoever repointed it can then mint that identifier and sign in as
      # the person the request named.
      target_member = Fixtures.Memberships.create_membership(account_id: account.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|captured-before-repoint",
          "email" => target_member.email,
          "email_verified" => true
        })

      assert {:ok, _provider} =
               SSO.update_provider(
                 provider,
                 %{
                   "issuer" => "https://an-idp-the-admin-controls.test",
                   "client_secret" => "the-admin-supplies-their-own"
                 },
                 subject
               )

      assert SSO.approve_link_request(
               request,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               subject
             ) == {:error, :not_found}

      refute Repo.one(SSO.UserIdentity)
    end

    test "a demoted approver cannot provision a brand-new person either", %{
      account: account,
      provider: provider
    } do
      # The unmatched branch creates a user, an identity, a membership and an audit
      # row, and it never re-read the approver — so everything above applied to it
      # only by luck. Nothing else in that transaction touches the approver's row.
      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|nobody-here-yet",
          "email" => "brand-new@acme.test",
          "email_verified" => true
        })

      Fixtures.Memberships.force_role(admin_membership, "viewer")

      assert SSO.approve_link_request(
               request,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               admin
             ) == {:error, :unauthorized}

      refute Repo.one(SSO.UserIdentity)
    end

    test "an owner demoted to admin no longer covers an owner", %{
      account: account,
      provider: provider
    } do
      # The subtle half. An owner demoted to admin KEEPS manage_sso, so re-checking
      # that permission passes — but they no longer outrank an owner, and the
      # target check was still reading the session's cached permissions, which said
      # they did.
      owner_member = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      approver_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner"
        )

      approver = Fixtures.Subjects.subject_for(approver_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|owner-target",
          "email" => owner_member.email,
          "email_verified" => true
        })

      Fixtures.Memberships.force_role(approver_membership, "admin")

      assert SSO.approve_link_request(
               request,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               approver
             ) == {:error, :link_target_outranks_approver}
    end

    test "an approver demoted while their page sat open is refused", %{
      account: account,
      provider: provider
    } do
      # %Subject{}.permissions is a snapshot taken when the session was built. An
      # admin demoted (or suspended) while the approval page sat open still carried
      # the permissions it loaded with — one last credential binding after the
      # authority for it was taken away.
      target_member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator"
        )

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|stale-approver",
          "email" => target_member.email,
          "email_verified" => true
        })

      # The subject in hand still says admin; the row no longer does.
      Fixtures.Memberships.force_role(admin_membership, "viewer")

      assert SSO.approve_link_request(
               request,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               admin
             ) == {:error, :unauthorized}

      refute Repo.one(SSO.UserIdentity)
    end

    test "a target promoted between capture and approval is refused", %{
      account: account,
      provider: provider
    } do
      # The match is recorded at capture; authority is judged at approval. A
      # promotion in between must therefore be caught by the approval, not by
      # whatever was true when the request was captured.
      #
      # This drives the approval's own re-judgement. It does NOT cover the
      # transaction-time repeat of that check, which exists for a promotion landing
      # in the far narrower window between the pre-check and the commit — that needs
      # two connections racing, and what makes it safe is the row lock on the read
      # (pinned in accounts_test.exs), not logic this test can reach.
      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator"
        )

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.subject_for(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|late-promotion",
          "email" => target_membership.email,
          "email_verified" => true
        })

      Fixtures.Memberships.force_role(target_membership, "owner")

      assert SSO.approve_link_request(
               request,
               %RunnerAccess{mode: :none, groups: [], runner_ids: []},
               admin
             ) == {:error, :link_target_outranks_approver}

      # Nothing was bound.
      refute Repo.one(SSO.UserIdentity)
    end

    test "rebinds the member's existing identity instead of giving them a second", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      # Role and runner access are recomputed per identity onto the one
      # membership, so a second identity made the member's privileges depend on
      # iteration order — and the reconcile job's single-row read raised outright.
      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email: "member@acme.test"
        )

      {:ok, directory_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "directory-123",
            scim_external_id: "directory-123",
            created_by: :provider,
            provisioned_via: :scim
          }
        )
        |> Repo.insert()

      request =
        capture_request(provider, %{
          "sub" => "oid-456",
          "email" => "member@acme.test",
          "email_verified" => true
        })

      assert {:ok, %{identity: identity}} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 subject
               )

      assert identity.id == directory_identity.id
      assert identity.provider_identifier == "oid-456"
      assert identity.created_by == :admin

      # Rebinding the OIDC identifier leaves the directory correlation value
      # intact for repeated creates and filters.
      assert identity.scim_external_id == "directory-123"

      assert Enum.map(member_identities(member), & &1.id) == [directory_identity.id]
    end

    test "an OIDC-first row adopted by SCIM keeps its directory key through an approval rebind",
         %{
           account: account,
           subject: subject,
           provider: provider
         } do
      provider = Fixtures.SSO.enable_scim(provider)

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "adopted-directory@acme.test"
        )

      oidc_first =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member,
          provider_identifier: "shared-directory-id",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })

      assert {:ok, %{identity: adopted}} =
               SSO.scim_provision_user(provider, %{
                 external_id: "shared-directory-id",
                 email: member.email,
                 full_name: "Adopted Directory Person"
               })

      assert adopted.id == oidc_first.id
      assert adopted.provisioned_via == :oidc_jit
      assert adopted.scim_external_id == "shared-directory-id"

      request =
        capture_request(provider, %{
          "sub" => "approved-after-adoption",
          "email" => member.email,
          "email_verified" => true
        })

      assert {:ok, %{identity: rebound}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert rebound.id == adopted.id
      assert rebound.provider_identifier == "approved-after-adoption"
      assert rebound.scim_external_id == "shared-directory-id"
      refute rebound.provider_identifier_retired_at

      assert {:ok, %SCIMUser{external_id: "shared-directory-id"}} =
               SSO.scim_fetch_user(provider, rebound.id)
    end

    test "rebinding a member's identity ends the sessions signed in through the old identifier and disconnects them after commit",
         %{account: account, subject: subject, provider: provider} do
      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email: "rebound-sessions@acme.test"
        )

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member,
          provider_identifier: "okta|before-rotation"
        })

      old_session =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      email_session = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      expected_topic = Auth.live_socket_topic(Crypto.hash(old_session))
      assert {:ok, %UserToken{}} = Auth.fetch_session_by_token(old_session, account.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|after-rotation",
          "email" => member.email,
          "email_verified" => true
        })

      assert request.matched_membership_id == member.id

      Emisar.Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      Emisar.Config.put_override(:emisar, :scim_delete_disconnect_test_pid, self())

      assert {:ok, %{identity: rebound}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert rebound.id == identity.id
      assert rebound.provider_identifier == "okta|after-rotation"

      assert Auth.fetch_session_by_token(old_session, account.id) == {:error, :not_found}
      refute Repo.exists?(UserToken.Query.by_identity_ids([identity.id]))
      assert_receive {:scim_delete_disconnect, [^expected_topic], false}
      refute_receive {:scim_delete_disconnect, _topics, _in_transaction?}

      # Only the credential that changed ends: the Member's email-code session stays.
      assert {:ok, %UserToken{}} = Auth.fetch_session_by_token(email_session, account.id)
    end

    test "a directory adopting an OIDC-first identity's externalId keeps its sessions", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      provider = Fixtures.SSO.enable_scim(provider)

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "adopted-sessions@acme.test"
        )

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member,
          provider_identifier: "okta|adopted-sessions"
        })

      session =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      assert SSO.scim_provision_user(provider, %{
               external_id: "directory|adopted-sessions",
               email: member.email,
               full_name: "Directory Name"
             }) == {:error, :identity_pending_approval}

      assert [%LinkRequest{source: :scim} = request] = link_requests(provider.id)
      assert request.matched_membership_id == member.id

      Emisar.Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      Emisar.Config.put_override(:emisar, :scim_delete_disconnect_test_pid, self())

      assert {:ok, %{identity: adopted}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert adopted.id == identity.id
      assert adopted.provider_identifier == "okta|adopted-sessions"
      assert adopted.scim_external_id == "directory|adopted-sessions"
      assert {:ok, %UserToken{}} = Auth.fetch_session_by_token(session, account.id)
      refute_receive {:scim_delete_disconnect, _topics, _in_transaction?}
    end

    test "the database refuses a second live identity for one member", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, _first} =
        account.id
        |> SSO.UserIdentity.Changeset.create(
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "first",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )
        |> Repo.insert()

      second =
        SSO.UserIdentity.Changeset.create(
          account.id,
          provider.id,
          Repo.reload!(member),
          %{
            provider_identifier: "second",
            created_by: :provider,
            provisioned_via: :oidc_jit
          }
        )

      assert {:error, changeset} = Repo.insert(second)
      assert "already has an identity for this connection" in errors_on(changeset).membership_id
    end

    test "provisions a new Member + consumes the request", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      request =
        capture_request(provider, %{
          "sub" => "okta|approve",
          "email" => "approve@acme.test",
          "email_verified" => true,
          "name" => "Approve Me"
        })

      {:ok, access} = RunnerAccess.restricted(["production"], [])

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.approve_link_request(request, access, subject)

      assert membership.display_name == "Approve Me"
      assert membership.email == "approve@acme.test"
      # The approver vouched for the address; nobody proved the inbox.
      refute membership.email_verified_at
      assert identity.provider_identifier == "okta|approve"
      assert identity.created_by == :admin
      assert identity.provisioned_via == :manual
      assert identity.membership_id == membership.id
      assert membership.role == :operator
      assert Accounts.runner_access_for_membership(account.id, membership.id) == access
      assert link_requests(provider.id) == []

      # The bound sub now signs in normally, as the provisioned Member.
      claims = %{
        "sub" => "okta|approve",
        "email" => "approve@acme.test",
        "email_verified" => true
      }

      assert {:ok, %{membership: signed_in}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert signed_in.id == membership.id
    end

    test "broadcasts to the waiting pending page on approval", %{
      subject: subject,
      provider: provider
    } do
      request =
        capture_request(provider, %{"sub" => "okta|notify", "email" => "notify@acme.test"})

      :ok = SSO.subscribe_link_request(request.id)

      assert {:ok, _} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert_receive {:sso_link_request, :approved, %{id: id, provider_id: provider_id}}
      assert id == request.id
      assert provider_id == provider.id
    end

    test "a matched request links the identity to the EXISTING member — no dup, role kept", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      # An existing :admin member whose email the IdP asserts.
      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: :admin,
          email: "member@acme.test"
        )

      {:ok, existing_access} = RunnerAccess.restricted(["database"], [])
      Fixtures.Memberships.force_runner_access(membership, existing_access)

      request =
        capture_request(provider, %{
          "sub" => "okta|m",
          "email" => "  MEMBER@ACME.TEST  ",
          "email_verified" => "true",
          "name" => "Member"
        })

      assert request.matched_membership_id == membership.id

      assert {:ok, %{membership: linked, identity: identity}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      # Bound to the EXISTING member. OIDC owns only the login identifier; the
      # directory column stays available for a later SCIM assertion.
      assert linked.id == membership.id
      assert identity.membership_id == membership.id
      assert identity.provider_identifier == "okta|m"
      refute identity.scim_external_id
      # The member's existing role is untouched (not downgraded to :operator).
      membership = Repo.reload!(membership)
      assert membership.role == :admin

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               existing_access

      assert link_requests(provider.id) == []
    end

    test "a match to a Member links the identity to that Member", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "unlinked-match@acme.test",
          role: "viewer"
        )

      claims = %{
        "sub" => "okta|unlinked-match",
        "email" => "unlinked-match@acme.test",
        "email_verified" => true
      }

      request = capture_request(provider, claims)
      assert request.matched_membership_id == member.id

      assert {:ok, %{membership: linked, identity: identity}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert linked.id == member.id
      assert linked.role == :viewer
      assert identity.membership_id == member.id
      assert identity.provider_identifier == "okta|unlinked-match"
      assert link_requests(provider.id) == []

      assert {:ok, %{membership: signed_in}} =
               SSO.complete_auth(provider, callback(claims), %{}, %RequestContext{})

      assert signed_in.id == member.id
    end

    test "a legacy unverified OIDC match cannot be approved", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: :viewer,
          email: "legacy-unverified@acme.test"
        )

      request =
        Fixtures.SSO.create_link_request(
          provider: provider,
          provider_identifier: "okta|legacy-unverified",
          source: :oidc,
          email: membership.email,
          claims: %{"sub" => "okta|legacy-unverified", "email" => membership.email},
          matched_membership_id: membership.id
        )

      audit_count = Repo.aggregate(Audit.Event, :count)

      assert SSO.approve_link_request(request, RunnerAccess.none(), subject) ==
               {:error, :unverified_email}

      assert Repo.reload(request)
      assert Repo.reload(membership).email == membership.email
      refute Repo.exists?(UserIdentity.Query.not_deleted())
      assert Repo.aggregate(Audit.Event, :count) == audit_count
    end

    test "a Member elsewhere with the address is never the target (H1)", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      existing = Fixtures.Memberships.create_membership(email: "taken@acme.test")

      request =
        capture_request(provider, %{
          "sub" => "okta|dup",
          "email" => "taken@acme.test",
          "email_verified" => true
        })

      assert is_nil(request.matched_membership_id)

      assert {:ok, %{membership: membership}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert membership.account_id == account.id
      assert membership.id != existing.id
      assert is_nil(Accounts.peek_sync_membership_by_id(account.id, existing.id))
    end

    test "denies a viewer and leaves the request pending", %{account: account, provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|v", "email" => "v@acme.test"})

      assert SSO.approve_link_request(request, RunnerAccess.none(), viewer_in(account)) ==
               {:error, :unauthorized}

      assert [_still_pending] = link_requests(provider.id)
    end

    test "denies a free plan (:sso_not_available)", %{provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|ne", "email" => "ne@acme.test"})

      # The plan gate (`ensure_can_configure_sso`) is the first check — before the
      # request is even fetched — so a free-plan owner is denied outright.
      {_owner, _free_account, free_subject} = Fixtures.Subjects.owner_subject(%{})

      assert SSO.approve_link_request(request, RunnerAccess.none(), free_subject) ==
               {:error, :sso_not_available}

      assert [_still_pending] = link_requests(provider.id)
    end

    test "is account-scoped — B cannot approve A's request", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|x", "email" => "x@acme.test"})

      assert SSO.approve_link_request(request, RunnerAccess.none(), sb) ==
               {:error, :not_found}

      assert [_still_pending] = link_requests(provider.id)
    end

    test "a SCIM push matching an existing member parks a request; approve heals the next push",
         %{
           account: account,
           subject: subject,
           provider: provider
         } do
      provider = Fixtures.SSO.enable_scim(provider)

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: :admin,
          email: "member@acme.test"
        )

      attrs = %{external_id: "okta|scim", email: "member@acme.test", full_name: "Member"}

      # The address names the member's workspace contact (the controller renders
      # 409), and a matched request is parked.
      assert SSO.scim_provision_user(provider, attrs) == {:error, :identity_pending_approval}
      assert [request] = link_requests(provider.id)
      assert request.matched_membership_id == membership.id

      # Admin approves → the identity is linked to the existing member.
      assert {:ok, %{membership: linked}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert linked.id == membership.id

      # The next SCIM push self-heals: the identity now resolves to the member.
      assert {:ok, %{membership: healed}} = SSO.scim_provision_user(provider, attrs)
      assert healed.id == membership.id
    end
  end

  # -- dismiss_link_request/2 ------------------------------------------

  describe "dismiss_link_request/2" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      %{account: account, subject: subject, provider: provider}
    end

    test "deletes the request without provisioning", %{subject: subject, provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|d", "email" => "d@acme.test"})

      assert {:ok, %LinkRequest{}} = SSO.dismiss_link_request(request, subject)
      assert link_requests(provider.id) == []
      assert UserIdentity.Query.not_deleted() |> Repo.all() == []
    end

    test "denies a viewer", %{account: account, provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|dv", "email" => "dv@acme.test"})

      assert SSO.dismiss_link_request(request, viewer_in(account)) == {:error, :unauthorized}
      assert [_still_pending] = link_requests(provider.id)
    end

    test "is account-scoped — B cannot dismiss A's request", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|dx", "email" => "dx@acme.test"})

      assert SSO.dismiss_link_request(request, sb) == {:error, :not_found}
      assert [_still_pending] = link_requests(provider.id)
    end
  end

  # -- subscribe_link_request/1 ---------------------------------------

  describe "subscribe_link_request/1" do
    test "the subscriber receives the request's dismiss broadcast" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      request = capture_request(provider, %{"sub" => "okta|sub", "email" => "sub@acme.test"})

      :ok = SSO.subscribe_link_request(request.id)
      assert {:ok, _} = SSO.dismiss_link_request(request, subject)

      assert_receive {:sso_link_request, :dismissed, %{id: id}}
      assert id == request.id
    end
  end

  describe "subscribe_account_link_requests/1" do
    test "the subscriber receives pending and resolved count changes" do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      :ok = SSO.subscribe_account_link_requests(account.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|account-topic",
          "email" => "account-topic@acme.test"
        })

      assert_receive {:sso_link_requests_changed, account_id}
      assert account_id == account.id

      assert {:ok, _request} = SSO.dismiss_link_request(request, subject)
      assert_receive {:sso_link_requests_changed, ^account_id}
    end
  end

  describe "identity_provider_kinds/0" do
    test "carries every supported provider kind" do
      assert SSO.identity_provider_kinds() ==
               [:google_workspace, :okta, :entra, :jumpcloud, :keycloak, :openid_connect]
    end
  end

  describe "provider_fixed_issuer/1" do
    test "only Google Workspace serves one issuer for every customer" do
      assert SSO.provider_fixed_issuer(:google_workspace) == "https://accounts.google.com"
      assert SSO.provider_fixed_issuer(:jumpcloud) == nil
      assert SSO.provider_fixed_issuer(:okta) == nil
      assert SSO.provider_fixed_issuer(:entra) == nil
      assert SSO.provider_fixed_issuer(:keycloak) == nil
      assert SSO.provider_fixed_issuer(:openid_connect) == nil
    end

    test "reads the string form the console posts, and nil for anything unknown" do
      assert SSO.provider_fixed_issuer("google_workspace") == "https://accounts.google.com"
      assert SSO.provider_fixed_issuer("jumpcloud") == nil
      assert SSO.provider_fixed_issuer("okta") == nil
      assert SSO.provider_fixed_issuer("not_a_provider") == nil
      assert SSO.provider_fixed_issuer(:not_a_provider) == nil
      assert SSO.provider_fixed_issuer("") == nil
      assert SSO.provider_fixed_issuer(nil) == nil
    end
  end

  describe "provider_issuer_regions/1" do
    test "returns exact JumpCloud regions for atom and form values" do
      expected = [
        {"United States", "https://oauth.id.jumpcloud.com/"},
        {"Europe", "https://oauth.id.eu.jumpcloud.com/"},
        {"India", "https://oauth.id.in.jumpcloud.com/"}
      ]

      assert SSO.provider_issuer_regions(:jumpcloud) == expected
      assert SSO.provider_issuer_regions("jumpcloud") == expected

      for kind <- [:google_workspace, "okta", "not_a_provider", nil] do
        assert SSO.provider_issuer_regions(kind) == []
      end
    end
  end

  describe "provider_identifier_claim/1" do
    test "Entra joins on oid; every other kind on the OIDC-standard sub" do
      assert SSO.provider_identifier_claim(:entra) == :oid
      assert SSO.provider_identifier_claim(:google_workspace) == :sub
      assert SSO.provider_identifier_claim(:okta) == :sub
      assert SSO.provider_identifier_claim(:jumpcloud) == :sub
      assert SSO.provider_identifier_claim(:keycloak) == :sub
      assert SSO.provider_identifier_claim(:openid_connect) == :sub
    end

    test "reads the string form the console posts, and nil for anything unknown" do
      assert SSO.provider_identifier_claim("entra") == :oid
      assert SSO.provider_identifier_claim("not_a_provider") == nil
      assert SSO.provider_identifier_claim(:not_a_provider) == nil
      assert SSO.provider_identifier_claim("") == nil
      assert SSO.provider_identifier_claim(nil) == nil
    end
  end

  describe "supports_scim?/1" do
    test "Google Workspace has no inbound SCIM; the other kinds do" do
      refute SSO.supports_scim?(:google_workspace)
      assert SSO.supports_scim?(:okta)
      assert SSO.supports_scim?(:entra)
      assert SSO.supports_scim?(:jumpcloud)
      assert SSO.supports_scim?(:keycloak)
      assert SSO.supports_scim?(:openid_connect)
    end

    test "an unknown kind fails closed" do
      refute SSO.supports_scim?("not_a_provider")
      refute SSO.supports_scim?(:not_a_provider)
      refute SSO.supports_scim?(nil)
    end
  end

  # -- subject_can_configure_sso?/1 ------------------------------------

  describe "subject_can_manage_sso?/1" do
    test "permission-only: true for an admin even on a plan without SSO" do
      account = Fixtures.Accounts.create_account()

      admin =
        Fixtures.Subjects.subject_for(
          Fixtures.Memberships.create_membership(account_id: account.id, role: :admin)
        )

      viewer =
        Fixtures.Subjects.subject_for(
          Fixtures.Memberships.create_membership(account_id: account.id, role: :viewer)
        )

      # Free plan: the permission half holds; the plan half (configure_sso?) doesn't.
      assert SSO.subject_can_manage_sso?(admin)
      refute SSO.subject_can_configure_sso?(admin)
      refute SSO.subject_can_manage_sso?(viewer)
    end
  end

  describe "subject_can_configure_sso?/1" do
    test "true for an enterprise owner (manage_sso + SSO plan)" do
      {_owner, _account, subject} = enterprise_owner()
      assert SSO.subject_can_configure_sso?(subject)
    end

    test "true for a Team owner — SSO is Team and up" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      assert SSO.subject_can_configure_sso?(subject)
    end

    test "false for a free plan (no SSO plan)" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject(%{})
      refute SSO.subject_can_configure_sso?(subject)
    end

    test "false for a viewer (no manage_sso) even on enterprise" do
      {_owner, account, _owner_subject} = enterprise_owner()
      refute SSO.subject_can_configure_sso?(viewer_in(account))
    end
  end

  # -- subject_can_configure_directory_sync?/1 -------------------------

  describe "subject_can_configure_directory_sync?/1" do
    test "true for an enterprise owner (manage_sso + Enterprise plan)" do
      {_owner, _account, subject} = enterprise_owner()
      assert SSO.subject_can_configure_directory_sync?(subject)
    end

    test "false for a Team owner — directory sync is Enterprise-only" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      refute SSO.subject_can_configure_directory_sync?(subject)
    end

    test "false for a viewer (no manage_sso) even on enterprise" do
      {_owner, account, _owner_subject} = enterprise_owner()
      refute SSO.subject_can_configure_directory_sync?(viewer_in(account))
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp record_session_effects do
    marker = make_ref()
    handler = {__MODULE__, self(), marker}

    :ok =
      :telemetry.attach(
        handler,
        [:emisar, :repo, :query],
        fn _event, _measurements, metadata, {owner, reference} ->
          if self() == owner and metadata.source == "auth_user_tokens" and
               String.starts_with?(metadata.query, "DELETE") do
            send(owner, {reference, Repo.in_transaction?()})
          end
        end,
        {self(), marker}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Emisar.Config.put_override(
      :emisar,
      :session_disconnect_handler,
      {:emisar, RecordingSessionDisconnector}
    )

    Emisar.Config.put_override(:emisar, :scim_delete_disconnect_test_pid, self())
    marker
  end

  # A workspace whose plan includes SSO and one enabled connection of it.
  defp mfa_enrollment_route do
    account = Fixtures.Accounts.create_account(plan: "enterprise")
    {account, provider_fixture(account)}
  end

  # A Member signed in through SSO at `provider`, with no authenticator yet and
  # no verified address: the Member the IdP enrollment proof exists for.
  defp mfa_enrollment_sso_fixture({account, provider} \\ mfa_enrollment_route()) do
    member =
      Fixtures.Memberships.create_membership(account_id: account.id, email_verified?: false)

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        membership: member
      })

    raw =
      Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

    %{
      account: account,
      provider: provider,
      member: member,
      identity: identity,
      session_digest: Crypto.hash(raw),
      subject: Fixtures.Subjects.subject_for(member, session: raw)
    }
  end

  defp mfa_enrollment_reauthentication(enrollment) do
    %{
      provider_id: enrollment.provider.id,
      identity_id: enrollment.identity.id,
      provider_identifier: enrollment.identity.provider_identifier,
      namespace: namespace(enrollment.provider),
      auth_time: System.system_time(:second),
      session_digest: enrollment.session_digest
    }
  end

  # An invitee in a workspace that refuses email sign-in, holding the proof the
  # code step handed over: the invited inbox proved its code and
  # `Auth.complete_magic_link_sign_in/4` answered `{:ok, :sso_required, …}`
  # without accepting, consuming or minting anything.
  defp invitation_sso_fixture do
    {owner, account, subject} = enterprise_owner()
    provider = provider_fixture(account)
    email = "invitee-#{System.unique_integer([:positive])}@acme.test"

    {:ok, %{membership: invitation, invitation_token: invitation_token}} =
      Accounts.invite_user_to_account(
        Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
        subject
      )

    # Once the workspace requires SSO, its administrators act through the IdP
    # too: the owner's email-code session holds no authority any more.
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
    subject = provider_subject(owner, provider)

    {:ok, ^email, intent} =
      Accounts.prepare_invitation_acceptance(invitation_token, %{"display_name" => "Invited Name"})

    {:ok, %{token_id: code_id, nonce: nonce}} =
      Auth.request_invitation_code(intent, %RequestContext{})

    assert_received {:email, sent}
    [_, ^code_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
    invitation_id = invitation.id
    {:ok, ^invitation_id} = Auth.verify_magic_link(code_id, secret, nonce)
    browser_id = Crypto.random_secret()

    {:ok, :sso_required, %{proof: proof}} =
      Auth.complete_magic_link_sign_in(invitation.id, code_id, browser_id, %RequestContext{})

    %{
      account: account,
      subject: subject,
      provider: provider,
      invitation: invitation,
      invitation_token: invitation_token,
      email: email,
      code_id: code_id,
      browser_id: browser_id,
      proof: proof
    }
  end

  defp begin_invitation_sso(fixture) do
    SSO.begin_invitation_sso_sign_in(
      fixture.proof,
      fixture.provider.id,
      @redirect_uri,
      fixture.browser_id
    )
  end

  defp accept_through_sso(fixture, sub) do
    {:ok, begun} = begin_invitation_sso(fixture)

    {:ok, _raw, accepted} =
      SSO.complete_invitation_sso_sign_in(
        callback(invitee_claims(fixture, sub)),
        begun,
        fixture.proof,
        fixture.browser_id,
        %RequestContext{}
      )

    accepted
  end

  defp invitee_claims(fixture, sub) do
    %{
      "sub" => sub,
      "email" => fixture.email,
      "email_verified" => true,
      "auth_time" => System.system_time(:second)
    }
  end

  defp put_auth_time(claims, nil), do: Map.delete(claims, "auth_time")
  defp put_auth_time(claims, auth_time), do: Map.put(claims, "auth_time", auth_time)

  # The step accepted, consumed and minted nothing for this invitation.
  defp assert_invitation_untouched(fixture) do
    invitation = Repo.reload!(fixture.invitation)
    assert is_nil(invitation.invitation_accepted_at)
    refute invitation.email_verified_at
    assert Repo.get!(UserToken, fixture.code_id).context == "magic_link_verified"
    assert member_identities(invitation) == []
    assert session_count(invitation) == 0
  end

  defp member_mfa_reset_sso_fixture do
    {actor, account, _subject} = enterprise_owner()
    provider = provider_fixture(account, %{enabled: true, satisfies_mfa: true})

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        membership: actor,
        provider_identifier: "reset-actor-sub"
      })

    actor_session_token =
      Fixtures.Auth.create_session_token!(actor, :sso, DateTime.utc_now(), %{},
        user_identity_id: identity.id
      )

    target_membership =
      Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      |> Fixtures.Memberships.set_mfa_state(
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now()
      )

    %{
      account: account,
      actor: actor,
      actor_session_token: actor_session_token,
      actor_session_token_digest: Crypto.hash(actor_session_token),
      identity: identity,
      provider: provider,
      subject: Fixtures.Subjects.subject_for(actor, session: actor_session_token),
      target: target_membership,
      target_membership: target_membership
    }
  end

  defp member_mfa_reset_stash(reset, begun) do
    Map.merge(begun, %{
      target_membership_id: reset.target_membership.id,
      target_mfa_enabled_at: reset.target.mfa_enabled_at,
      target_updated_at: reset.target.updated_at
    })
  end

  defp member_mfa_reset_reauthentication(reset) do
    %{
      provider_id: reset.provider.id,
      identity_id: reset.identity.id,
      provider_identifier: reset.identity.provider_identifier,
      namespace:
        {reset.provider.issuer, reset.provider.client_id, reset.provider.identifier_claim},
      auth_time: System.system_time(:second)
    }
  end

  defp demote_other_owners(account_id, except: keep_membership_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_role(:owner)
    |> Repo.all()
    |> Enum.reject(&(&1.id == keep_membership_id))
    |> Enum.each(&Fixtures.Memberships.force_role(&1, "admin"))
  end

  # Moves the refusal recorded for `resource` back by `hours`, as if the
  # provider had sent it then.
  defp backdate_refusal(account_id, resource, hours: hours) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account_id)
    |> Emisar.Audit.Event.Query.by_event_type("directory_sync.change_refused")
    |> Emisar.Audit.Event.Query.by_payload_values(%{resource: resource})
    |> Repo.update_all(set: [occurred_at: DateTime.add(DateTime.utc_now(), -hours, :hour)])
  end
end
