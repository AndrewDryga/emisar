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
  alias Emisar.{Accounts, Audit, Auth, Repo, SSO}
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Fixtures
  alias Emisar.SSO.{GroupRoleMapping, GroupRunnerAccessMapping}
  alias Emisar.SSO.{IdentityProvider, LinkRequest, SCIMUser, SCIMUserUpdate, UserIdentity}

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

  defp link_requests(provider_id) do
    LinkRequest.Query.all()
    |> LinkRequest.Query.by_provider_id(provider_id)
    |> Repo.all()
  end

  # Drive a manual-provider sign-in for an unknown sub → the captured request.
  defp capture_request(provider, claims) do
    {:pending, %LinkRequest{} = request} = SSO.complete_auth(provider, callback(claims), %{})
    request
  end

  defp viewer_in(account) do
    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: :viewer
      )

    Fixtures.Subjects.subject_for(viewer, account, role: :viewer)
  end

  # A SCIM-enabled enterprise provider + its owner subject + account.
  defp scim_provider(provider_attrs \\ %{}) do
    {_user, account, subject} = enterprise_owner()
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

  defp role_of(account_id, user_id),
    do: Fixtures.Memberships.fetch_membership(account_id, user_id).role

  defp map_group(provider, subject, external_group_id, role) do
    attrs = %{external_group_id: external_group_id, role: role}
    {:ok, mapping} = SSO.create_group_mapping(provider, attrs, subject)
    mapping
  end

  # One SCIM `members` PATCH operation over the given member externalIds.
  defp members_op(verb, external_ids),
    do: %{"op" => verb, "path" => "members", "value" => Enum.map(external_ids, &%{"value" => &1})}

  # -- list_providers_for_account/2 ------------------------------------

  describe "list_providers_for_account/2" do
    test "lists the account's providers, name-ordered, for an enterprise admin" do
      {_user, account, subject} = enterprise_owner()
      _b = provider_fixture(account, %{kind: :keycloak, name: "B-Keycloak"})
      _a = provider_fixture(account, %{kind: :okta, name: "A-Okta"})

      assert {:ok, providers, _meta} = SSO.list_providers_for_account(subject)
      assert Enum.map(providers, & &1.name) == ["A-Okta", "B-Keycloak"]
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      _provider = provider_fixture(account)

      assert {:error, :unauthorized} = SSO.list_providers_for_account(viewer_in(account))
    end

    test "a downgraded plan still lists what it has — you can't retire what you can't see" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{})
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
      {_user, account, subject} = enterprise_owner()
      _b = provider_fixture(account, %{kind: :keycloak, name: "B-Keycloak", enabled: false})
      _a = provider_fixture(account, %{kind: :okta, name: "A-Okta"})

      assert {:ok, [first, second], _meta} = SSO.list_provider_facts(subject)
      assert Enum.map([first, second], & &1.name) == ["A-Okta", "B-Keycloak"]
      assert first.enabled?
      refute second.enabled?

      assert Map.keys(first) |> Enum.sort() ==
               ~w[directory_sync? enabled? id last_synced_at name]a
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      _provider = provider_fixture(account)

      assert {:error, :unauthorized} = SSO.list_provider_facts(viewer_in(account))
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
    end

    test "an OIDC-only connection reports no directory sync" do
      {_user, account, _subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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

      assert {:error, :unauthorized} = SSO.list_provider_facts(viewer)
    end

    test "an API client holds no posture permission" do
      {_user, account, _subject} = enterprise_owner()

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

      assert {:ok, facts} = SSO.member_directory_facts([identity.user_id], subject)
      assert Map.keys(facts) == [identity.user_id]
      member = facts[identity.user_id]
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
        user_id: identity.user_id
      )

      assert {:ok, facts} = SSO.member_directory_facts([identity.user_id], subject)
      member = facts[identity.user_id]

      # A-Keycloak sorts first by name, but directory sync outranks the name.
      assert member.directory_managed?
      assert member.identity.provider_id == scim.id
    end

    test "turning directory sync off changes the answer for an already-read member" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|bob")

      assert {:ok, %{} = before} = SSO.member_directory_facts([identity.user_id], subject)
      assert before[identity.user_id].directory_managed?

      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert {:ok, %{} = after_disable} = SSO.member_directory_facts([identity.user_id], subject)
      refute after_disable[identity.user_id].directory_managed?
      assert after_disable[identity.user_id].identity.provider_id == provider.id
    end

    test "a deleted connection drops the attribution entirely" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|carol")

      assert {:ok, facts} = SSO.member_directory_facts([identity.user_id], subject)
      assert Map.has_key?(facts, identity.user_id)

      {:ok, _provider} = SSO.delete_provider(provider, subject)

      assert SSO.member_directory_facts([identity.user_id], subject) == {:ok, %{}}
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

      assert SSO.member_directory_facts([identity.user_id], subject) == {:ok, %{}}
      assert account.id != account_b.id
    end

    test "a viewer (no manage_sso) is denied" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|erin")

      assert {:error, :unauthorized} =
               SSO.member_directory_facts([identity.user_id], viewer_in(account))
    end

    test "is account-scoped — B never sees A's synced members" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|frank")
      {_ub, _account_b, sb} = enterprise_owner()

      assert SSO.member_directory_facts([identity.user_id], sb) == {:ok, %{}}
    end
  end

  # -- list_synced_users/2 --------------------------------------------

  describe "user_profile_directory_managed?/2" do
    test "true for a member synced under a SCIM-enabled provider" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|managed")

      assert SSO.user_profile_directory_managed?(account.id, identity.user_id)
    end

    test "false once directory sync is disabled — the lock lifts with SCIM" do
      %{provider: provider, account: account, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|unlocked")

      {:ok, _provider} = SSO.disable_scim(provider, subject)

      refute SSO.user_profile_directory_managed?(account.id, identity.user_id)
    end

    test "false for a member with no directory identity" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      refute SSO.user_profile_directory_managed?(account.id, user.id)
    end
  end

  describe "list_synced_users/2" do
    test "returns the provider's provisioned users with the user preloaded" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|alice")

      assert {:ok, [synced]} = SSO.list_synced_users(provider, subject)
      assert synced.id == identity.id
      assert synced.user.id == identity.user_id
    end

    test "a viewer (no manage_sso) is denied" do
      %{provider: provider, account: account} = scim_provider()

      assert {:error, :unauthorized} = SSO.list_synced_users(provider, viewer_in(account))
    end

    test "another account's subject can't read the provider (:not_found)" do
      %{provider: provider} = scim_provider()
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:error, :not_found} = SSO.list_synced_users(provider, sb)
    end
  end

  # -- provider_sync_stats/1 ------------------------------------------

  describe "provider_sync_stats/1" do
    test "counts synced users and distinct synced groups (NOT group→role mappings)" do
      %{provider: provider, subject: subject} = scim_provider()
      provision(provider, "okta|a")
      provision(provider, "okta|b")

      # The directory pushes TWO groups over SCIM...
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-ops", member_external_ids: ["okta|a"]})

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-eng",
          member_external_ids: ["okta|a", "okta|b"]
        })

      # ...and the admin maps only ONE of them. The tally counts the 2 groups the
      # directory synced, not the 1 group→role mapping configured.
      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, stats} = SSO.provider_sync_stats(subject)
      assert stats[provider.id] == %{users: 2, groups: 2}
    end

    test "a viewer (no manage_sso) is denied" do
      %{account: account} = scim_provider()

      assert {:error, :unauthorized} = SSO.provider_sync_stats(viewer_in(account))
    end

    test "is account-scoped — B's stats never include A's connection" do
      %{provider: provider} = scim_provider()
      provision(provider, "okta|a")
      # A synced group for A too — the group tally is account-scoped via the
      # DirectoryGroupMember for_subject clause, so B never sees A's group counts.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-a", member_external_ids: ["okta|a"]})

      {_ub, _account_b, sb} = enterprise_owner()

      assert {:ok, stats} = SSO.provider_sync_stats(sb)
      refute Map.has_key?(stats, provider.id)
    end
  end

  # -- fetch_provider_by_id/2 ------------------------------------------

  describe "fetch_provider_by_id/2" do
    test "resolves a provider in the subject's account" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{id: id}} = SSO.fetch_provider_by_id(provider.id, subject)
      assert id == provider.id
    end

    test "a malformed (non-UUID) id is :not_found, never a crash" do
      {_user, _account, subject} = enterprise_owner()

      assert {:error, :not_found} = SSO.fetch_provider_by_id("not-a-uuid", subject)
    end

    test "a viewer is denied (:unauthorized)" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, :unauthorized} = SSO.fetch_provider_by_id(provider.id, viewer_in(account))
    end

    test "cross-account: B cannot fetch A's provider (:not_found)" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert {:error, :not_found} = SSO.fetch_provider_by_id(provider.id, sb)
    end
  end

  # -- change_provider/3 -----------------------------------------------

  describe "change_provider/3" do
    setup do
      {_user, account, subject} = enterprise_owner()
      %{account: account, subject: subject}
    end

    test "builds a provider config changeset from attrs (the phx-change form)", %{
      subject: subject
    } do
      assert {:ok, changeset} =
               SSO.change_provider(%IdentityProvider{}, %{kind: :okta, name: "Okta"}, subject)

      assert Ecto.Changeset.get_change(changeset, :kind) == :okta
      assert Ecto.Changeset.get_change(changeset, :name) == "Okta"
    end

    test "defaults to an empty provider + no attrs", %{subject: subject} do
      assert {:ok, %Ecto.Changeset{data: %IdentityProvider{}}} = SSO.change_provider(subject)
    end

    test "a subject that can't manage single sign-on gets no form" do
      {_user, account, _subject} = enterprise_owner()
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
      assert Ecto.Changeset.get_field(jumpcloud, :issuer) == "https://oauth.id.jumpcloud.com/"
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

      assert Ecto.Changeset.get_change(typed, :client_secret) == "being-typed"
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
      assert Ecto.Changeset.get_change(changeset, :kind) == nil
      assert Ecto.Changeset.get_change(changeset, :issuer) == nil
      assert Ecto.Changeset.get_change(changeset, :name) == "Renamed"
    end

    test "an unrelated edit leaves a stored identifier claim alone", %{
      account: account,
      subject: subject
    } do
      provider = provider_fixture(account, %{kind: :keycloak, identifier_claim: :oid})

      assert {:ok, changeset} = SSO.change_provider(provider, %{"name" => "Renamed"}, subject)

      # Narrowing the claim list must not retype a connection people already
      # sign in through — the form tells the truth about what is stored.
      assert Ecto.Changeset.get_change(changeset, :identifier_claim) == nil
      assert Ecto.Changeset.get_field(changeset, :identifier_claim) == :oid
    end

    test "another account cannot build an existing provider's form", %{account: account} do
      provider = provider_fixture(account)
      {_user, _other_account, other_subject} = enterprise_owner()

      assert SSO.change_provider(provider, %{}, other_subject) == {:error, :not_found}
    end
  end

  # -- change_group_mapping/2 ------------------------------------------

  describe "change_group_mapping/2" do
    test "from a %IdentityProvider{} it's a CREATE changeset (account/provider from the provider)" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)

      changeset =
        SSO.change_group_mapping(provider, %{external_group_id: "grp-1", role: :operator})

      assert %Ecto.Changeset{data: %GroupRoleMapping{}} = changeset
      assert Ecto.Changeset.get_field(changeset, :account_id) == account.id
      assert Ecto.Changeset.get_field(changeset, :provider_id) == provider.id
      assert Ecto.Changeset.get_change(changeset, :role) == :operator
    end

    test "from a %GroupRoleMapping{} it's the inline EDIT changeset (only display + role)" do
      mapping = %GroupRoleMapping{external_group_id: "grp-1", role: :viewer}

      changeset = SSO.change_group_mapping(mapping, %{role: :admin})

      assert %Ecto.Changeset{data: %GroupRoleMapping{}} = changeset
      assert Ecto.Changeset.get_change(changeset, :role) == :admin
    end

    test "rejects an :owner role (sync can never grant owner — decision 7)" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)

      changeset = SSO.change_group_mapping(provider, %{external_group_id: "g", role: :owner})

      assert "directory sync cannot grant owner" in errors_on(changeset).role
    end
  end

  describe "change_group_runner_access_mapping/3" do
    setup do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      %{account: account, provider: provider, subject: subject}
    end

    test "builds explicit create and update changesets", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      create_attrs = %{
        external_group_id: "grp-db",
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

      assert Ecto.Changeset.get_change(update, :runner_access_mode) == :all
    end

    test "an injected persisted array never becomes the grant", %{
      provider: provider,
      subject: subject
    } do
      attrs = %{
        external_group_id: "grp-db",
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
      attrs = %{external_group_id: "grp-empty", runner_access_mode: :restricted}

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
      {_user, _other_account, other_subject} = enterprise_owner()
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
      {_user, account, _subject} = enterprise_owner()

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        default_runner_access_mode: :restricted,
        default_runner_scope: ["crafted"]
      }

      assert {:error, :unauthorized} = SSO.configure_provider(attrs, viewer_in(account))
    end

    test "a free account cannot configure SSO" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{})

      assert {:error, :sso_not_available} =
               SSO.configure_provider(%{kind: :okta, name: "Okta"}, subject)
    end

    test "a Team account can configure an OIDC provider — SSO is Team and up" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

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
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: :viewer
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               SSO.configure_provider(%{kind: :okta, name: "Okta"}, viewer_subject)
    end

    test "an enterprise admin configures a provider" do
      {_user, _account, subject} = enterprise_owner()

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
      # the account's 2FA requirement.
      refute provider.satisfies_mfa

      assert {:ok, [event], _meta} =
               Audit.list_events(subject, filter: [event_type: ["sso.provider_configured"]])

      assert event.payload["runner_access"] == %{
               "mode" => "none",
               "groups" => [],
               "runner_ids" => []
             }
    end

    test "rejects a default that names a runner in another account" do
      {_user, _account, subject} = enterprise_owner()
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

    test "an injected persisted scope array is ignored, so it never becomes the default" do
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, _subject} = enterprise_owner()
      {_other_user, _other_account, other_subject} = enterprise_owner()
      provider = provider_fixture(account)

      attrs = %{default_runner_access_mode: :restricted, default_runner_scope: ["crafted"]}

      assert {:error, :not_found} = SSO.update_provider(provider, attrs, other_subject)
    end

    test "a restricted admin cannot configure or update a broader provider default" do
      {_owner, account, owner_subject} = enterprise_owner()
      admin = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      assert {:ok, _membership} =
               Accounts.update_membership_runner_access(
                 membership,
                 db_access,
                 owner_subject
               )

      admin_subject = Fixtures.Subjects.membership_subject(membership)

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        default_runner_access_mode: :all
      }

      assert {:error, :runner_access_exceeds_subject} =
               SSO.configure_provider(attrs, admin_subject)

      provider = provider_fixture(account)

      assert {:error, :runner_access_exceeds_subject} =
               SSO.update_provider(
                 provider,
                 %{default_runner_access_mode: :all},
                 admin_subject
               )
    end

    test "JumpCloud is an accepted provider kind" do
      {_user, _account, subject} = enterprise_owner()

      assert :jumpcloud in SSO.identity_provider_kinds()

      assert {:ok, %IdentityProvider{kind: :jumpcloud}} =
               SSO.configure_provider(
                 %{
                   kind: :jumpcloud,
                   name: "JumpCloud",
                   issuer: "https://oauth.id.jumpcloud.com/",
                   client_id: "cid",
                   client_secret: "secret"
                 },
                 subject
               )
    end

    test "the issuer must be an https URL" do
      {_user, _account, subject} = enterprise_owner()

      assert {:error, changeset} =
               SSO.configure_provider(
                 %{kind: :okta, name: "Okta", issuer: "http://idp.test", client_id: "cid"},
                 subject
               )

      assert "must be an https URL" in errors_on(changeset).issuer
    end

    test "a fixed-issuer kind stores its own issuer, whatever was submitted" do
      {_user, _account, subject} = enterprise_owner()

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
      {_user, _account, subject} = enterprise_owner()

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
      {_user, _account, subject} = enterprise_owner()

      assert {:error, changeset} =
               SSO.configure_provider(
                 %{kind: :okta, name: "Okta", issuer: "https://", client_id: "cid"},
                 subject
               )

      assert "must be an https URL" in errors_on(changeset).issuer
    end

    test "allowed_email_domain is normalized — leading @ stripped, trimmed (casing kept for citext)" do
      {_user, _account, subject} = enterprise_owner()

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
      {_user, _account, subject} = enterprise_owner()

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

    test "a second ENABLED provider of the same kind hits the unique (account, kind) index" do
      {_user, account, subject} = enterprise_owner()
      _first = provider_fixture(account, %{kind: :okta, enabled: true})

      assert {:error, changeset} =
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

      # The partial unique index (one enabled provider per (account, kind)) maps
      # the violation onto the first constraint field, :account_id.
      assert "has already been taken" in errors_on(changeset).account_id
    end

    test "two ENABLED providers with the same allowed_email_domain hit the unique index" do
      {_user, account, subject} = enterprise_owner()
      _first = provider_fixture(account, %{kind: :okta, allowed_email_domain: "acme.test"})

      assert {:error, changeset} =
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

      assert errors_on(changeset).allowed_email_domain != []
    end

    test "omitting kind / name / issuer / client_id surfaces the required-field errors" do
      {_user, _account, subject} = enterprise_owner()

      assert {:error, changeset} = SSO.configure_provider(%{}, subject)

      errors = errors_on(changeset)
      assert "can't be blank" in errors.kind
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.issuer
      assert "can't be blank" in errors.client_id
    end

    test "a blank client_secret is not stored (an empty secret never persists)" do
      {_user, _account, subject} = enterprise_owner()

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
      {_user, _account, subject} = enterprise_owner()

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
      {_user, account, subject} = enterprise_owner()
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

      assert {:error, :client_secret_required} =
               SSO.update_provider(provider, %{"issuer" => "https://attacker.test"}, subject)

      unchanged = Repo.reload!(provider)
      assert unchanged.issuer == provider.issuer
      assert unchanged.client_secret == "the-customer-s-secret"
    end

    test "repointing the client id without the secret is refused too", %{
      account: account,
      subject: subject
    } do
      provider = provider_fixture(account, client_secret: "the-customer-s-secret")

      assert {:error, :client_secret_required} =
               SSO.update_provider(provider, %{"client_id" => "attacker-client"}, subject)
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

  describe "configure_provider/2 role coverage" do
    test "an admin can't stand up a connection defaulting to a role they can't grant" do
      # The changeset excludes only :owner, so creation was the one path that
      # never asked whether the caller may hand out the role it defaults to.
      {_owner, account, _owner_subject} = enterprise_owner()
      admin_user = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin_user.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.membership_subject(admin_membership)

      attrs = %{
        kind: :okta,
        name: "Okta",
        issuer: "https://idp.example.test",
        client_id: "cid",
        client_secret: "secret",
        default_role: :billing_manager
      }

      assert {:error, :role_exceeds_your_permissions} =
               SSO.configure_provider(attrs, admin)
    end
  end

  describe "update_provider/3" do
    test "account A's provider cannot be fetched or updated by account B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert {:error, :not_found} = SSO.fetch_provider_by_id(provider.id, sb)
      assert {:error, :not_found} = SSO.update_provider(provider, %{name: "Hijacked"}, sb)
      assert {:error, :not_found} = SSO.delete_provider(provider, sb)
    end

    test "changing the issuer to a non-https URL is rejected on update" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, changeset} =
               SSO.update_provider(provider, %{issuer: "http://idp.test"}, subject)

      assert "must be an https URL" in errors_on(changeset).issuer
      # The stored issuer is unchanged.
      assert Repo.reload!(provider).issuer == provider.issuer
    end

    test "setting :owner as the default_role is rejected on update" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, changeset} =
               SSO.update_provider(provider, %{default_role: :owner}, subject)

      assert "can't be owner" in errors_on(changeset).default_role
      assert Repo.reload!(provider).default_role == :viewer
    end

    test "a mutable identifier_claim (email) is rejected; oid is allowed — the (provider, sub) takeover guard" do
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "old-secret"})

      assert {:ok, _} = SSO.update_provider(provider, %{client_secret: "rotated-secret"}, subject)
      assert Repo.reload!(provider).client_secret == "rotated-secret"
    end

    test "an update with no client_secret key keeps the stored secret (never wiped)" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "keep-this-secret"})

      # A secret nobody can read back must survive an unrelated edit — the
      # context drops the key rather than casting a missing value over it.
      assert {:ok, _} = SSO.update_provider(provider, %{name: "Renamed"}, subject)

      reloaded = Repo.reload!(provider)
      assert reloaded.name == "Renamed"
      assert reloaded.client_secret == "keep-this-secret"
    end

    test "a blank or whitespace-only client_secret keeps the stored one" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{client_secret: "keep-this-secret"})

      # The form posts the empty field on every save, and a stray space is the
      # same "I didn't type one" — neither may clobber the credential.
      assert {:ok, _} = SSO.update_provider(provider, %{"client_secret" => ""}, subject)
      assert Repo.reload!(provider).client_secret == "keep-this-secret"

      assert {:ok, _} = SSO.update_provider(provider, %{"client_secret" => "   "}, subject)
      assert Repo.reload!(provider).client_secret == "keep-this-secret"
    end

    test "a rejected update returns a changeset holding no secret at all" do
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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
      {_user, account, subject} = enterprise_owner()
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
               "runner_ids" => []
             }

      assert event.payload["after"] == %{
               "mode" => "restricted",
               "groups" => ["database"],
               "runner_ids" => []
             }
    end

    test "a free plan is denied on update (:sso_not_available)" do
      # The row exists (built via the fixture, bypassing the gate), but the plan
      # gate (`ensure_can_configure_sso`) fires before any row touch.
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{})
      provider = provider_fixture(account)

      assert {:error, :sso_not_available} =
               SSO.update_provider(provider, %{name: "Renamed"}, subject)

      assert Repo.reload!(provider).name == "Okta"
    end

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, :unauthorized} =
               SSO.update_provider(provider, %{name: "Renamed"}, viewer_in(account))
    end

    test "disabling one of two enabled providers is allowed (not the last)" do
      {_user, account, subject} = enterprise_owner()
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      _keep = provider_fixture(account, %{name: "Keep", kind: :okta, enabled: true})
      extra = provider_fixture(account, %{name: "Extra", kind: :keycloak, enabled: true})

      # Even under require_sso, disabling a provider while another enabled one
      # remains is fine — the last-provider guard only fires on the final one.
      assert {:ok, %IdentityProvider{enabled: false}} =
               SSO.update_provider(extra, %{enabled: false}, subject)
    end

    test "cannot disable the last enabled connection when require_sso is on" do
      {_user, account, subject} = enterprise_owner()
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      provider = provider_fixture(account)

      assert {:error, :require_sso_last_provider} =
               SSO.update_provider(provider, %{enabled: false}, subject)

      assert Repo.reload!(provider).enabled
    end
  end

  # -- delete_provider/2 -----------------------------------------------

  describe "delete_provider/2" do
    test "soft-deletes a provider for an enterprise admin" do
      {_user, account, subject} = enterprise_owner()
      # A second enabled provider so require_sso (unset here anyway) can't bite.
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{} = deleted} = SSO.delete_provider(provider, subject)
      assert deleted.deleted_at
      assert {:error, :not_found} = SSO.fetch_provider_by_id(provider.id, subject)
    end

    test "a downgraded plan cannot delete a mapping, because deleting one can promote" do
      # A member left in no mapped group falls back to `default_role`. With the
      # provider defaulting to :admin and the group mapped to :viewer, deleting
      # the mapping RAISES everyone it touches — so it is not cleanup, and an
      # unentitled account does not get to do it.
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account, default_role: :admin)
      {:ok, provider, _raw} = SSO.enable_scim(provider, subject)

      {:ok, mapping} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp", role: :viewer}, subject)

      Fixtures.Accounts.create_subscription(account, "free")

      assert {:error, :directory_sync_not_available} =
               SSO.delete_group_mapping(mapping, subject)
    end

    test "a downgraded plan can still delete — the connection outlived the plan, not the risk" do
      # Downgrading does not stop an existing connection accepting sign-ins, so
      # refusing the delete left an owner holding a live credential they had no
      # way to retire.
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{})
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{}} = SSO.delete_provider(provider, subject)
      assert Repo.reload!(provider).deleted_at
    end

    test "dismisses the requests waiting on it, and tells the browsers holding them" do
      # Approval needs the provider, so a request that outlives it can never be
      # approved — it just sat in the admin's queue while someone's browser waited
      # on a page that would never resolve.
      {_user, account, subject} = enterprise_owner()
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

    test "a viewer (no manage_sso) is denied" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:error, :unauthorized} = SSO.delete_provider(provider, viewer_in(account))
      refute Repo.reload!(provider).deleted_at
    end
  end

  # -- require_sso lock-out guard on provider removal ------------------

  describe "require_sso lock-out guard on provider removal" do
    setup do
      {_user, account, subject} = enterprise_owner()
      account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      %{account: account, subject: subject}
    end

    test "cannot delete the last enabled connection", %{account: account, subject: subject} do
      provider = provider_fixture(account)

      assert {:error, :require_sso_last_provider} = SSO.delete_provider(provider, subject)
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

      assert {:error, :discovery_failed} = SSO.test_provider("https://unreachable.test", subject)
      refute Repo.one(IdentityProvider)
    end

    test "a non-https or malformed issuer is rejected before any fetch" do
      {_owner, _account, subject} = enterprise_owner()

      assert {:error, :invalid_issuer} = SSO.test_provider("http://idp.test", subject)
      assert {:error, :invalid_issuer} = SSO.test_provider("not a url", subject)
    end

    test "an SSRF issuer (private/loopback/metadata) is blocked before any fetch" do
      {_owner, _account, subject} = enterprise_owner()

      # Each is blocked even though the stub would happily "discover" it — proving
      # the SSRF guard runs ahead of the fetch, not after.
      assert {:error, :blocked_issuer} = SSO.test_provider("https://169.254.169.254", subject)
      assert {:error, :blocked_issuer} = SSO.test_provider("https://10.0.0.5", subject)
      assert {:error, :blocked_issuer} = SSO.test_provider("https://localhost:8443", subject)
    end

    test "a non-admin (no manage_sso) cannot test a connection" do
      {_owner, account, _owner_subject} = enterprise_owner()

      assert {:error, :unauthorized} = SSO.test_provider("https://idp.test", viewer_in(account))
    end

    test "a free account cannot test a connection (Team-and-up gate)" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{})

      assert {:error, :sso_not_available} = SSO.test_provider("https://idp.test", subject)
    end
  end

  # -- list_enabled_providers_for_account/1 (pre-Subject) --------------

  describe "list_enabled_providers_for_account/1" do
    test "returns an account's ENABLED providers, name-ordered (the sign-in page source)" do
      {_user, account, _subject} = enterprise_owner()
      _b = provider_fixture(account, %{kind: :keycloak, name: "B-Keycloak", enabled: true})
      _a = provider_fixture(account, %{kind: :okta, name: "A-Okta", enabled: true})
      _off = provider_fixture(account, %{kind: :jumpcloud, name: "Off", enabled: false})

      providers = SSO.list_enabled_providers_for_account(account.id)
      assert Enum.map(providers, & &1.name) == ["A-Okta", "B-Keycloak"]
    end

    test "an account with no enabled provider returns []" do
      {_user, account, _subject} = enterprise_owner()
      _off = provider_fixture(account, %{enabled: false})

      assert SSO.list_enabled_providers_for_account(account.id) == []
    end

    test "is scoped to the account — never another account's providers" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, account_b, _sb} = enterprise_owner()
      _a = provider_fixture(account_a, %{name: "A"})

      assert SSO.list_enabled_providers_for_account(account_b.id) == []
    end
  end

  # -- fetch_provider_for_sign_in/1 (pre-Subject) ----------------------

  describe "fetch_provider_for_sign_in/1" do
    test "resolves an ENABLED provider by id for the begin-auth redirect" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: true})

      assert {:ok, %IdentityProvider{id: id}} = SSO.fetch_provider_for_sign_in(provider.id)
      assert id == provider.id
    end

    test "a DISABLED provider is :not_found (sign-in only offers enabled ones)" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{enabled: false})

      assert {:error, :not_found} = SSO.fetch_provider_for_sign_in(provider.id)
    end

    test "an unknown or malformed id is :not_found, never a crash" do
      assert {:error, :not_found} = SSO.fetch_provider_for_sign_in(Ecto.UUID.generate())
      assert {:error, :not_found} = SSO.fetch_provider_for_sign_in("not-a-uuid")
    end
  end

  # -- begin_auth/2 (pre-Subject) --------------------------------------

  describe "begin_auth/2" do
    test "delegates to the OIDC wrapper, returning the authorize-url + stash secrets" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, %{authorize_url: url, state: state, nonce: nonce, pkce_verifier: verifier}} =
               SSO.begin_auth(provider, [])

      assert url == "https://idp.test/auth"
      assert is_binary(state)
      assert is_binary(nonce)
      assert is_binary(verifier)
    end
  end

  # -- complete_auth/3 -------------------------------------------------

  describe "complete_auth/3 — resolution + JIT" do
    test "first login JIT-provisions a fresh user + identity + membership at default_role" do
      {_user, account, subject} = enterprise_owner()

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

      assert {:ok, %{user: user, identity: identity, provider: ^provider, created?: true}} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert user.email == "new@acme.test"
      assert user.full_name == "New Operator"
      assert user.confirmed_at
      assert identity.provider_identifier == "okta|new-1"
      assert identity.created_by == :provider

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
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
               "runner_ids" => []
             }
    end

    test "an existing same-email user is NEVER matched — a colliding email fails :email_taken" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      existing = Fixtures.Users.create_user(%{email: "taken@acme.test"})

      claims = %{"sub" => "okta|other", "email" => "taken@acme.test", "email_verified" => true}

      assert {:error, :email_taken} = SSO.complete_auth(provider, callback(claims), %{})

      # The pre-existing user is untouched + no identity was bound to it.
      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_user_id(existing.id)
             |> Repo.all() == []
    end

    test "a repeated (provider, sub) login resolves to the SAME user — no duplicate" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|stable", "email" => "stable@acme.test", "email_verified" => true}

      # created?: true only on the FIRST login (the JIT registration) — the
      # returning login resolves the existing identity, so it's signed_in.
      assert {:ok, %{user: first, created?: true}} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert {:ok, %{user: second, created?: false}} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert first.id == second.id
    end

    test "a no-email IdP JIT-provisions a user with nil email (identified by sub)" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|nomail", "name" => "No Email"}

      assert {:ok, %{user: user, identity: identity}} =
               SSO.complete_auth(provider, callback(claims), %{})

      refute user.email
      assert identity.provider_identifier == "okta|nomail"
    end

    test "an unverified email claim is not trusted — users.email stays nil (R6)" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|unverified", "email" => "unverified@acme.test"}

      assert {:ok, %{user: user}} = SSO.complete_auth(provider, callback(claims), %{})
      refute user.email
    end

    test "JIT trusts email_verified arriving as the string \"true\"" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|str", "email" => "str@acme.test", "email_verified" => "true"}

      assert {:ok, %{user: user}} = SSO.complete_auth(provider, callback(claims), %{})
      assert user.email == "str@acme.test"
    end

    test "a string \"false\" email_verified is NOT trusted even with an hd claim (the email is dropped)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)

      # email_verified is the STRING "false" (some IdPs / the SCIM path send strings)
      # paired with a Google-style `hd` — a forged hd must not launder an unverified
      # email. The user still provisions (identity binds by sub), but with NO email.
      claims = %{
        "sub" => "okta|strfalse",
        "email" => "unverified@acme.test",
        "email_verified" => "false",
        "hd" => "acme.test"
      }

      assert {:ok, %{user: user}} = SSO.complete_auth(provider, callback(claims), %{})
      assert is_nil(user.email)
    end

    test "a :manual provisioner parks an unknown sub as a pending request, never auto-creating" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      claims = %{"sub" => "okta|unknown", "email" => "u@acme.test", "email_verified" => true}

      assert {:pending, %LinkRequest{} = request} =
               SSO.complete_auth(provider, callback(claims), %{})

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

      {:ok, %{user: directory_user}} =
        SSO.scim_provision_user(provider, %{external_id: "directory-123"})

      claims = %{"sub" => "oid-456"}

      assert {:pending, %LinkRequest{} = request} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert request.provider_identifier == "oid-456"

      # The directory's member is the only one, and still the only identity.
      identities =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_provider_id(provider.id)
        |> Repo.all()

      assert Enum.map(identities, & &1.provider_identifier) == ["directory-123"]

      assert Fixtures.Memberships.fetch_membership(account.id, directory_user.id)
    end

    test "a :jit login matching an existing member is parked for approval (not auto-merged)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)
      member = Fixtures.Users.create_user(%{email: "jit@acme.test"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: :viewer
        )

      claims = %{"sub" => "okta|jit", "email" => "jit@acme.test", "email_verified" => true}

      assert {:pending, request} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert request.matched_user_id == member.id
    end

    test "provisioning into account A's provider never lands in account B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, account_b, _sb} = enterprise_owner()
      provider = provider_fixture(account_a)
      claims = %{"sub" => "okta|scoped", "email" => "scoped@acme.test", "email_verified" => true}

      assert {:ok, %{user: user}} = SSO.complete_auth(provider, callback(claims), %{})

      assert Fixtures.Memberships.fetch_membership(account_a.id, user.id)
      refute Fixtures.Memberships.fetch_membership(account_b.id, user.id)
    end
  end

  describe "complete_auth/3 — a connection disabled mid-flight" do
    test "a first login cannot land through a door the account just closed" do
      # Disabling a connection is how an operator revokes a route in, and
      # end_sessions_signed_in_through runs in that disable's after_commit — so a
      # callback that completes afterwards is never swept. Under the same row lock
      # the disable takes, one of the two goes first and the other refuses.
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      {:ok, disabled} = SSO.update_provider(provider, %{enabled: false}, subject)

      claims = %{"sub" => "okta|mid-flight", "email" => "mf@acme.test", "email_verified" => true}

      assert {:error, :provider_disabled} =
               SSO.complete_auth(disabled, callback(claims), %{})
    end

    test "a returning member cannot either" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|returning", "email" => "ret@acme.test", "email_verified" => true}

      assert {:ok, _} = SSO.complete_auth(provider, callback(claims), %{})

      {:ok, disabled} = SSO.update_provider(provider, %{enabled: false}, subject)

      assert {:error, :provider_disabled} =
               SSO.complete_auth(disabled, callback(claims), %{})
    end
  end

  describe "complete_auth/3 — allowed_email_domain gate (H1)" do
    setup do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, allowed_email_domain: "acme.test")
      %{provider: provider}
    end

    test "a verified email in the allowed domain is admitted", %{provider: provider} do
      claims = %{"sub" => "okta|in", "email" => "ok@acme.test", "email_verified" => true}
      assert {:ok, %{user: _}} = SSO.complete_auth(provider, callback(claims), %{})
    end

    test "a verified email outside the allowed domain is refused", %{provider: provider} do
      claims = %{"sub" => "okta|out", "email" => "x@evil.test", "email_verified" => true}

      assert {:error, :email_domain_not_allowed} =
               SSO.complete_auth(provider, callback(claims), %{})
    end

    test "a Google hd claim matching the domain is admitted", %{provider: provider} do
      claims = %{"sub" => "g|hd", "email" => "x@acme.test", "hd" => "acme.test"}
      assert {:ok, %{user: _}} = SSO.complete_auth(provider, callback(claims), %{})
    end

    test "an explicit unverified-email claim cannot use hd to pass the domain gate", %{
      provider: provider
    } do
      claims = %{
        "sub" => "g|unverified-hd",
        "email" => "x@acme.test",
        "email_verified" => "false",
        "hd" => "acme.test"
      }

      assert {:error, :email_domain_not_allowed} =
               SSO.complete_auth(provider, callback(claims), %{})
    end

    test "no verified domain is refused when a domain is required", %{provider: provider} do
      claims = %{"sub" => "okta|nodomain"}

      assert {:error, :email_domain_not_allowed} =
               SSO.complete_auth(provider, callback(claims), %{})
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
      assert {:error, :unauthorized} = SSO.authenticate_scim_token("")
      assert {:error, :unauthorized} = SSO.authenticate_scim_token("ems-")
      assert {:error, :unauthorized} = SSO.authenticate_scim_token("ems-totally-wrong-secret")
      # A correct prefix but a tampered tail must still fail the hash compare.
      assert {:error, :unauthorized} = SSO.authenticate_scim_token(token <> "x")
    end

    test "a token whose provider has scim disabled is :unauthorized", %{
      provider: provider,
      token: token,
      subject: subject
    } do
      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert {:error, :unauthorized} = SSO.authenticate_scim_token(token)
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

    test "disabling revokes a linked member's sessions", %{provider: provider, subject: subject} do
      %{identity: identity} = provision(provider, "okta|live")
      {:ok, user} = Emisar.Users.fetch_user_by_id(identity.user_id)

      _token =
        Fixtures.Auth.create_session_token!(user, :sso, false, %{}, user_identity_id: identity.id)

      assert {:ok, _} = SSO.update_provider(provider, %{enabled: false}, subject)

      # Disabling used to stop only NEW sign-ins, leaving every session already
      # minted through the connection valid for its full lifetime.
      assert Repo.all(
               Emisar.Auth.UserToken.Query.by_user_id(Emisar.Auth.UserToken.Query.all(), user.id)
             ) == []
    end

    test "deleting revokes them too", %{provider: provider, subject: subject} do
      %{identity: identity} = provision(provider, "okta|gone")
      {:ok, user} = Emisar.Users.fetch_user_by_id(identity.user_id)

      _token =
        Fixtures.Auth.create_session_token!(user, :sso, false, %{}, user_identity_id: identity.id)

      assert {:ok, _} = SSO.delete_provider(provider, subject)

      assert Repo.all(
               Emisar.Auth.UserToken.Query.by_user_id(Emisar.Auth.UserToken.Query.all(), user.id)
             ) == []
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
        assert {:error, :identity_namespace_locked} =
                 SSO.update_provider(provider, attrs, subject),
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
      # scim_external_id. The directory reuses it here — and without stamping it,
      # every later GET/PATCH/DELETE /Users/{id} (which look up by
      # scim_external_id) 404s and the member can never be offboarded.
      user = Fixtures.Users.create_user()

      {:ok, oidc_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, user.id, %{
          provider_identifier: "shared-id",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
        |> Repo.insert()

      assert is_nil(oidc_identity.scim_external_id)

      %{identity: adopted} = provision(provider, "shared-id")
      assert adopted.id == oidc_identity.id
      assert adopted.scim_external_id == "shared-id"

      # …and the lifecycle endpoints can now find it.
      assert {:ok, %{identity: deactivated}} =
               SSO.scim_update_user(provider, "shared-id", %SCIMUserUpdate{active: false})

      refute deactivated.scim_active
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
      {:ok, %{user: alice}} =
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
      assert {:pending, %LinkRequest{}} = SSO.complete_auth(provider, callback(bob_claims), %{})

      # Alice herself still converges — same value, and the claims agree on who.
      alice_claims = %{
        "sub" => "shared-value",
        "email" => "alice@acme.test",
        "email_verified" => true
      }

      assert {:ok, %{user: signed_in}} =
               SSO.complete_auth(provider, callback(alice_claims), %{})

      assert signed_in.id == alice.id
      assert account.id
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
      first = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: first.id)

      second = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: second.id)

      # OIDC captures the identifier first.
      capture_request(provider, %{
        "sub" => "shared-identifier",
        "email" => first.email,
        "email_verified" => true
      })

      # The directory then presents the SAME identifier for someone else.
      assert {:error, :email_taken} =
               SSO.scim_provision_user(provider, %{
                 external_id: "shared-identifier",
                 email: second.email
               })

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
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      {:ok, identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, user.id, %{
          provider_identifier: "oidc-sub-S",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
        |> Repo.insert()

      # The directory pushes a DIFFERENT identifier for the same person; the email
      # collides, so it parks a link request rather than creating a second identity.
      assert {:error, :email_taken} =
               SSO.scim_provision_user(provider, %{
                 external_id: "directory-external-E",
                 email: user.email
               })

      request =
        SSO.LinkRequest.Query.all()
        |> SSO.LinkRequest.Query.by_provider_id(provider.id)
        |> Repo.one()

      assert request.source == :scim

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(owner_membership)

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
      user = Fixtures.Users.create_user()

      {:ok, oidc_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, user.id, %{
          provider_identifier: "sub-and-external-agree",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
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
                 email: user.email
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

      assert {:ok, %{user: user, identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      assert user.email == "prov@acme.test"
      assert user.confirmed_at

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
               "runner_ids" => []
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

      assert {:ok, %{user: first, identity: id1}} = SSO.scim_provision_user(provider, attrs)
      assert {:ok, %{user: second, identity: id2}} = SSO.scim_provision_user(provider, attrs)

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

      assert {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_update_user(provider, "okta|readd", %SCIMUserUpdate{active: false})
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

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
      assert {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)

      # An operator suspends them in the portal; the IdP still lists them active,
      # so scim_active stays true — this is NOT an IdP deprovision.
      membership = Accounts.peek_sync_membership(account.id, user.id)
      assert Fixtures.Memberships.suspend_membership(membership).disabled_at

      # A routine re-POST (an IdP that re-creates the still-active user) must NOT
      # lift the manual suspend.
      assert {:ok, %{membership: reprovisioned}} = SSO.scim_provision_user(provider, attrs)
      assert reprovisioned.disabled_at
    end

    test "a colliding email fails :email_taken — never merges onto the existing user", %{
      provider: provider
    } do
      existing = Fixtures.Users.create_user(%{email: "taken@acme.test"})
      attrs = scim_attrs(%{external_id: "okta|collide", email: "taken@acme.test"})

      assert {:error, :email_taken} = SSO.scim_provision_user(provider, attrs)

      # The pre-existing user is untouched + no identity was bound to it.
      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_user_id(existing.id)
             |> Repo.all() == []
    end

    test "a provider-A-scoped provision never lands in account B (cross-account)", %{
      provider: provider_a,
      account: account_a
    } do
      %{account: account_b} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|scoped", email: "scoped@acme.test"})

      assert {:ok, %{user: user}} = SSO.scim_provision_user(provider_a, attrs)

      assert Fixtures.Memberships.fetch_membership(account_a.id, user.id)
      refute Fixtures.Memberships.fetch_membership(account_b.id, user.id)
    end
  end

  # -- scim_update_user/3 (provider-scoped) ----------------------------

  describe "scim_update_user/3 tenancy" do
    test "a rename reaches the person's own name when this is their only workspace" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|solo")

      assert {:ok, _} =
               SSO.scim_update_user(provider, "okta|solo", %SCIMUserUpdate{
                 name: {:replace, "Solo Person"}
               })

      {:ok, user} = Emisar.Users.fetch_user_by_id(identity.user_id)
      assert user.full_name == "Solo Person"

      membership = Fixtures.Memberships.fetch_membership(account.id, identity.user_id)
      assert membership.directory_display_name == "Solo Person"
    end

    test "it stops at this account's membership when they belong elsewhere too" do
      # `users.full_name` is the person's own attribute and shows in every
      # workspace they are in — including their roster row, audit actor labels
      # and run attribution there. One account's directory does not get to write
      # what another account's operators read.
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|shared")
      {:ok, user} = Emisar.Users.fetch_user_by_id(identity.user_id)
      their_own_name = user.full_name

      other_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: identity.user_id,
        role: "operator"
      )

      assert {:ok, _} =
               SSO.scim_update_user(provider, "okta|shared", %SCIMUserUpdate{
                 name: {:replace, "Renamed By Acme"}
               })

      # This account sees the directory's name…
      membership = Fixtures.Memberships.fetch_membership(account.id, identity.user_id)
      assert membership.directory_display_name == "Renamed By Acme"

      # …and the other one still sees the person.
      assert Repo.reload!(user).full_name == their_own_name
    end

    test "the account's own label for a member is audited even when the person is not renamed" do
      # `directory_display_name` outranks `users.full_name` in every label this
      # account renders — the roster, run attribution, and the actor/target name
      # on EXISTING audit events. A directory that moves it relabels the audit
      # trail retroactively, so the move is itself an audit event; without one it
      # was silent for any member who belongs to a second workspace.
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|relabel")

      other_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: identity.user_id,
        role: "operator"
      )

      assert {:ok, _} =
               SSO.scim_update_user(provider, "okta|relabel", %SCIMUserUpdate{
                 name: {:replace, "Someone Else"}
               })

      assert event =
               Enum.find(
                 Repo.all(Emisar.Audit.Event),
                 &(&1.event_type == "membership.renamed_via_scim")
               )

      assert event.account_id == account.id
      assert event.actor_kind == "directory_sync"
      assert event.actor_id == provider.id
      assert event.target_id == identity.user_id
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
      alice = Fixtures.Users.create_user()

      {:ok, alices} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, alice.id, %{
          provider_identifier: "collides",
          scim_external_id: "alice-directory-id",
          created_by: :provider,
          provisioned_via: :scim
        })
        |> Repo.insert()

      # Refused, not absorbed. The identifier column is unique per connection and
      # Alice holds this value, so there is no row Bob can honestly occupy — the
      # directory is told, rather than handed someone else's identity.
      assert {:error, :identifier_taken} =
               SSO.scim_provision_user(provider, %{
                 external_id: "collides",
                 email: "bob@acme.test"
               })

      untouched = Repo.reload!(alices)
      assert untouched.scim_external_id == "alice-directory-id"
      assert untouched.user_id == alice.id
    end

    test "an unclaimed OIDC-first row is still adopted by a matching externalId" do
      # The fallback that makes OIDC-first convergence work must survive the fix.
      %{provider: provider, account: account} = scim_provider()
      user = Fixtures.Users.create_user()

      {:ok, oidc_first} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, user.id, %{
          provider_identifier: "unclaimed",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
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
      %{provider: provider, account: account, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|onlyowner")

      # Make the synced member the account's ONLY owner — the state the
      # last-active-owner guard exists for.
      membership = Fixtures.Memberships.fetch_membership(account.id, identity.user_id)
      owner = Fixtures.Memberships.force_role(membership, "owner")
      assert owner.role == :owner

      account.id
      |> Fixtures.Memberships.fetch_membership(subject.actor.id)
      |> Fixtures.Memberships.force_role("admin")

      update = %SCIMUserUpdate{name: {:replace, "Half Landed"}, active: false}
      assert {:error, :last_owner} = SSO.scim_update_user(provider, "okta|onlyowner", update)

      # Nothing landed: not the lifecycle, not the name, not the identity flag.
      unchanged = Fixtures.Memberships.fetch_membership(account.id, identity.user_id)
      refute unchanged.disabled_at
      refute unchanged.directory_display_name
      assert Repo.reload!(identity).scim_active
    end

    test "a rejected rename rolls the whole operation back" do
      # The rename's own changeset can refuse (a >255-char name); the operation
      # also carried the deactivation, and the directory is told the whole PATCH
      # failed — so no part of it may stay.
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|badname")

      update = %SCIMUserUpdate{
        name: {:replace, String.duplicate("x", 256)},
        active: false
      }

      assert {:error, %Ecto.Changeset{}} = SSO.scim_update_user(provider, "okta|badname", update)

      unchanged = Fixtures.Memberships.fetch_membership(account.id, identity.user_id)
      refute unchanged.disabled_at
      refute unchanged.directory_display_name
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
      refute Accounts.peek_sync_membership(account.id, identity.user_id)

      update = %SCIMUserUpdate{name: {:replace, "New Name"}, active: false}
      assert {:error, :not_found} = SSO.scim_update_user(provider, "okta|removed", update)
      assert Repo.reload!(identity).scim_active
    end
  end

  describe "scim_update_user/3" do
    test "ends only this account's sessions — the person stays signed in elsewhere" do
      # A session token is per-user, not per-account, so revoking them all let one
      # tenant's directory sign someone out of a workspace it has no authority
      # over. Only the credential this account minted is destroyed.
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|multi", email: "multi@acme.test"})
      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      other_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: user.id,
        role: "operator"
      )

      sso_session =
        Fixtures.Auth.create_session_token!(user, :sso, false, %{}, user_identity_id: identity.id)

      magic_link_session = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, _} =
               SSO.scim_update_user(provider, "okta|multi", %SCIMUserUpdate{active: false})

      # The connection's own session is gone…
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(sso_session)

      # …and the one that reaches the other workspace is untouched.
      assert {:ok, _user, _token} =
               Auth.fetch_user_and_token_by_session_token(magic_link_session)
    end

    test "suspends the membership (disabled_at) + flips scim_active, never deleting the user" do
      %{provider: provider} = scim_provider(%{default_role: :admin})
      attrs = scim_attrs(%{external_id: "okta|deprov", email: "deprov@acme.test"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{membership: membership, identity: deactivated}} =
               SSO.scim_update_user(provider, "okta|deprov", %SCIMUserUpdate{active: false})

      assert membership.disabled_at
      refute deactivated.scim_active

      # The user + identity survive (audit preservation) — only access is cut.
      assert {:ok, _user} = Emisar.Users.fetch_user_by_id(user.id)
      assert {:ok, _scim_user} = SSO.scim_fetch_user(provider, identity.scim_external_id)
    end

    test "marks the membership directory_suspended, so the DOMAIN refuses a manual reinstate" do
      %{provider: provider, subject: subject} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|dsusp", email: "dsusp@acme.test"})
      {:ok, _} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{membership: membership}} =
               SSO.scim_update_user(provider, "okta|dsusp", %SCIMUserUpdate{active: false})

      assert membership.directory_suspended

      # An operator can't lift an IdP deactivation — the guard is judged on the
      # locked row's own flag, so a stale UI / crafted event is refused too.
      assert Accounts.reinstate_membership(membership, subject) == {:error, :deactivated_in_idp}
      assert Repo.reload!(membership).disabled_at
    end

    test "deactivating the last active owner is refused (:last_owner), flag left untouched" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :viewer})
      attrs = scim_attrs(%{external_id: "okta|owner"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      # Promote the lone provisioned member to the account's only owner.
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      assert {:error, :last_owner} =
               SSO.scim_update_user(provider, "okta|owner", %SCIMUserUpdate{active: false})

      # The membership stays active and the SCIM flag is left untouched, so the
      # projection still answers active.
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
      assert {:ok, unchanged} = SSO.scim_fetch_user(provider, identity.scim_external_id)
      assert unchanged.active
    end

    test "returns :not_found when no identity matches the externalId" do
      %{provider: provider} = scim_provider()

      assert {:error, :not_found} =
               SSO.scim_update_user(provider, "okta|nobody", %SCIMUserUpdate{active: false})
    end
  end

  # -- scim_update_user/3 reactivate ----------------------------------

  describe "scim_update_user/3 reactivate" do
    test "clears disabled_at on a suspended membership + flips scim_active back on" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|react", email: "react@acme.test"})

      {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_update_user(provider, "okta|react", %SCIMUserUpdate{active: false})
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.scim_update_user(provider, "okta|react", %SCIMUserUpdate{active: true})

      refute membership.disabled_at
      assert identity.scim_active
      # The IdP reactivating clears the directory-suspended mark — an operator can
      # reinstate them again if suspended manually later.
      refute membership.directory_suspended
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end

    test "returns :not_found when no identity matches the externalId" do
      %{provider: provider} = scim_provider()

      assert {:error, :not_found} =
               SSO.scim_update_user(provider, "okta|nobody", %SCIMUserUpdate{active: true})
    end

    test "a manual break-glass suspension survives an IdP deactivate→reactivate cycle" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|held", email: "held@acme.test"})

      {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.suspend_membership(membership)

      {:ok, _} = SSO.scim_update_user(provider, "okta|held", %SCIMUserUpdate{active: false})

      assert {:ok, %{membership: returned}} =
               SSO.scim_update_user(provider, "okta|held", %SCIMUserUpdate{active: true})

      # The IdP never owned the suspension, so its reactivate can't lift it —
      # the member stays out until an operator reinstates locally.
      assert returned.disabled_at
      refute returned.directory_suspended
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end
  end

  # -- scim_update_user/3 rename --------------------------------------

  describe "scim_update_user/3 rename" do
    test "replaces the synced user's display name, audited to the directory" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|rename", full_name: "Old Name"})
      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{identity: %UserIdentity{} = returned}} =
               SSO.scim_update_user(provider, "okta|rename", %SCIMUserUpdate{
                 name: {:replace, "New Name"}
               })

      assert returned.id == identity.id
      assert Repo.reload!(user).full_name == "New Name"

      assert event =
               Enum.find(
                 Repo.all(Emisar.Audit.Event),
                 &(&1.event_type == "user.renamed_via_scim")
               )

      assert event.actor_kind == "directory_sync"
      assert event.payload["full_name"] == "New Name"
    end

    test "an unchanged name is a no-op — no audit row" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|same", full_name: "Keep Name"})
      {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{identity: %UserIdentity{}}} =
               SSO.scim_update_user(provider, "okta|same", %SCIMUserUpdate{
                 name: {:replace, "Keep Name"}
               })

      assert Repo.reload!(user).full_name == "Keep Name"

      refute Enum.any?(
               Repo.all(Emisar.Audit.Event),
               &(&1.event_type == "user.renamed_via_scim")
             )
    end

    test "an unknown externalId is :not_found" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_update_user(provider, "okta|nobody", %SCIMUserUpdate{
               name: {:replace, "Anyone"}
             }) == {:error, :not_found}
    end

    test "is provider-scoped — provider B can't rename provider A's user" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|scoped", full_name: "A Name"})
      {:ok, %{user: user}} = SSO.scim_provision_user(provider_a, attrs)

      assert SSO.scim_update_user(provider_b, "okta|scoped", %SCIMUserUpdate{
               name: {:replace, "Hijack"}
             }) == {:error, :not_found}

      assert Repo.reload!(user).full_name == "A Name"
    end
  end

  # -- scim_fetch_user/2 (provider-scoped) -----------------------------

  describe "scim_fetch_user/2" do
    test "returns the directory-user projection for (provider, externalId)" do
      %{provider: provider} = scim_provider()

      {:ok, _} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|fetch",
          email: "fetch@acme.test",
          full_name: "Fetch Person"
        })

      assert SSO.scim_fetch_user(provider, "okta|fetch") ==
               {:ok,
                %SCIMUser{
                  external_id: "okta|fetch",
                  user_name: "fetch@acme.test",
                  display_name: "Fetch Person",
                  active: true
                }}
    end

    test "a no-email directory user's userName falls back to the opaque externalId" do
      %{provider: provider} = scim_provider()
      _ = provision(provider, "okta|nomail", %{full_name: nil})

      assert {:ok, scim_user} = SSO.scim_fetch_user(provider, "okta|nomail")
      assert scim_user.user_name == "okta|nomail"
      refute scim_user.display_name
    end

    test "a deprovisioned (suspended) member reports inactive" do
      %{provider: provider} = scim_provider()
      _ = provision(provider, "okta|off")
      {:ok, _} = SSO.scim_update_user(provider, "okta|off", %SCIMUserUpdate{active: false})

      assert {:ok, scim_user} = SSO.scim_fetch_user(provider, "okta|off")
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
      assert {:ok, scim_user} = SSO.scim_fetch_user(provider, "okta|held")
      refute scim_user.active
    end

    test "an orphaned identity (membership removed by an operator) is found and reports inactive" do
      %{provider: provider} = scim_provider()
      %{membership: membership} = provision(provider, "okta|orphan")
      Fixtures.Memberships.mark_membership_as_deleted(membership)

      assert {:ok, scim_user} = SSO.scim_fetch_user(provider, "okta|orphan")
      refute scim_user.active
    end

    test "an unknown externalId is :not_found" do
      %{provider: provider} = scim_provider()
      assert {:error, :not_found} = SSO.scim_fetch_user(provider, "okta|nobody")
    end

    test "is provider-scoped — provider B can't fetch provider A's user" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      _ = provision(provider_a, "okta|onlyA")

      assert {:error, :not_found} = SSO.scim_fetch_user(provider_b, "okta|onlyA")
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
      {:ok, _} = SSO.scim_update_user(provider, "okta|gone", %SCIMUserUpdate{active: false})

      assert {:ok, scim_users, 2} = SSO.scim_list_users(provider)

      assert Map.new(scim_users, &{&1.external_id, &1.active}) ==
               %{"okta|on" => true, "okta|gone" => false}
    end

    test "another account's membership never decides a row's active state", %{
      provider: provider
    } do
      {:ok, %{user: user}} = SSO.scim_provision_user(provider, %{external_id: "okta|two-tenant"})

      # The same person is also a (suspended) member of an unrelated account —
      # only the provider's own account may decide what its directory is told.
      other_account = Fixtures.Accounts.create_account()

      other_membership =
        Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: user.id)

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

      assert {:ok, [], 0} = SSO.scim_list_users(provider_b)
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

    test "lists synced groups with mapped displays and member external ids", %{
      provider: provider,
      subject: subject
    } do
      _ = provision(provider, "okta|alice")
      _ = provision(provider, "okta|bob")

      {:ok, _mapping} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Operations",
          member_external_ids: ["okta|bob", "okta|alice"]
        })

      assert {:ok,
              [
                %{
                  external_group_id: "grp-ops",
                  display: "Operations",
                  member_external_ids: ["okta|alice", "okta|bob"]
                }
              ], 1} = SSO.scim_list_groups(provider)
    end

    test "filters by the display the directory pushed, mapped or not", %{
      provider: provider,
      subject: subject
    } do
      _ = provision(provider, "okta|member")

      {:ok, _mapping} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Operations",
          member_external_ids: ["okta|member"]
        })

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_external_ids: ["okta|member"]
        })

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-nameless",
          member_external_ids: ["okta|member"]
        })

      assert {:ok, [%{external_group_id: "grp-ops"}], 1} =
               SSO.scim_list_groups(provider, display_name: "Operations")

      assert {:ok, [%{external_group_id: "grp-unmapped"}], 1} =
               SSO.scim_list_groups(provider, display_name: "Security Review")

      # Only a group whose directory never sent a displayName answers on its id.
      assert {:ok, [%{external_group_id: "grp-nameless"}], 1} =
               SSO.scim_list_groups(provider, display_name: "grp-nameless")

      assert {:ok, [], 0} =
               SSO.scim_list_groups(provider, display_name: "grp-unmapped")
    end

    test "an unmapped group keeps the display its directory pushed", %{provider: provider} do
      _ = provision(provider, "okta|member")

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_external_ids: ["okta|member"]
        })

      assert {:ok,
              [
                %{
                  external_group_id: "grp-unmapped",
                  display: "Security Review",
                  member_external_ids: ["okta|member"]
                }
              ], 1} = SSO.scim_list_groups(provider)
    end

    test "a rename moves an unmapped group's display", %{provider: provider} do
      _ = provision(provider, "okta|member")

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_external_ids: ["okta|member"]
        })

      {:ok, _group} = SSO.scim_rename_group(provider, "grp-unmapped", "Security Council")

      assert {:ok, [%{display: "Security Council"}], 1} = SSO.scim_list_groups(provider)
    end

    test "a PATCH-added member does not erase the group's display", %{provider: provider} do
      _ = provision(provider, "okta|member")
      _ = provision(provider, "okta|joiner")

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-unmapped",
          display: "Security Review",
          member_external_ids: ["okta|member"]
        })

      {:ok, _group} =
        SSO.scim_patch_group_members(provider, "grp-unmapped", ["okta|joiner"], [])

      assert {:ok, [%{display: "Security Review", member_external_ids: members}], 1} =
               SSO.scim_list_groups(provider)

      assert members == ["okta|joiner", "okta|member"]
    end

    test "is provider-scoped", %{provider: provider_a} do
      %{provider: provider_b} = scim_provider()
      _ = provision(provider_a, "okta|only-a")

      {:ok, _group} =
        SSO.scim_upsert_group(provider_a, %{
          external_id: "grp-a",
          member_external_ids: ["okta|only-a"]
        })

      assert {:ok, [], 0} = SSO.scim_list_groups(provider_b)
    end
  end

  # -- scim_fetch_group/2 (provider-scoped) ----------------------------

  describe "scim_fetch_group/2" do
    test "returns one synced group with its member external ids" do
      %{provider: provider} = scim_provider()
      _ = provision(provider, "okta|member")

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-fetch",
          member_external_ids: ["okta|member"]
        })

      assert SSO.scim_fetch_group(provider, "grp-fetch") ==
               {:ok,
                %{
                  external_group_id: "grp-fetch",
                  display: nil,
                  member_external_ids: ["okta|member"]
                }}
    end

    test "returns :not_found for an unknown group" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_fetch_group(provider, "grp-missing") == {:error, :not_found}
    end

    test "is provider-scoped" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      _ = provision(provider_a, "okta|only-a")

      {:ok, _group} =
        SSO.scim_upsert_group(provider_a, %{
          external_id: "grp-a",
          member_external_ids: ["okta|only-a"]
        })

      assert SSO.scim_fetch_group(provider_b, "grp-a") == {:error, :not_found}
    end
  end

  # -- scim_upsert_group/2 (provider-scoped) ---------------------------

  describe "scim_upsert_group/2" do
    setup do
      scim_provider()
    end

    test "replaces the group's synced membership + recomputes roles to the mapped role", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|u1")
      assert role_of(account.id, identity.user_id) == :viewer

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{external_group_id: "grp-ops", display: "Operators", member_count: 1}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-ops",
                 display: "Operators",
                 member_external_ids: ["okta|u1"]
               })

      assert role_of(account.id, identity.user_id) == :operator
    end

    test "an unknown member external_id is ignored (not yet provisioned)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|known")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-mix", role: :admin}, subject)

      assert {:ok, %{member_count: 1}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-mix",
                 member_external_ids: ["okta|known", "okta|ghost-not-provisioned"]
               })

      assert role_of(account.id, identity.user_id) == :admin
    end

    test "removing a member from the group resets them to the provider default_role (#3)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|drop")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|drop"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Re-push the group with an empty member set → the member leaves it and
      # resets to the provider default (:viewer).
      assert {:ok, %{member_count: 0}} =
               SSO.scim_upsert_group(provider, %{external_id: "grp-adm", member_external_ids: []})

      assert role_of(account.id, identity.user_id) == :viewer
    end
  end

  # -- scim_rename_group/3 (provider-scoped) --------------------

  describe "scim_rename_group/3" do
    setup do
      scim_provider()
    end

    test "moves the display onto the mapping and keeps the id the IdP addresses", %{
      provider: provider,
      subject: subject
    } do
      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", external_group_display: "Ops", role: :operator},
          subject
        )

      assert {:ok, %{external_group_id: "grp-ops", display: "Platform"}} =
               SSO.scim_rename_group(provider, "grp-ops", "Platform")

      # The id is the IdP's handle on the group, so a rename must not move it —
      # only the human label the console shows changes.
      reloaded = Repo.reload!(mapping)
      assert reloaded.external_group_id == "grp-ops"
      assert reloaded.external_group_display == "Platform"
      assert reloaded.role == :operator
    end

    test "a group nobody has mapped is still renamable", %{provider: provider} do
      assert {:ok, %{external_group_id: "grp-unmapped", display: "Renamed"}} =
               SSO.scim_rename_group(provider, "grp-unmapped", "Renamed")
    end

    test "rejects a blank id, but takes a blank display", %{provider: provider} do
      assert {:error, :invalid_scim_group} = SSO.scim_rename_group(provider, "", "Platform")

      # displayName is optional in SCIM, so clearing it is a rename, not an error —
      # the group keeps answering on the id the IdP addresses it by.
      assert {:ok, %{external_group_id: "grp-ops", display: ""}} =
               SSO.scim_rename_group(provider, "grp-ops", "")
    end
  end

  # -- scim_patch_group_members/4 (provider-scoped) --------------------

  describe "ensure_identity_provider_enabled/2" do
    test "refuses a session for an identity whose connection has been disabled" do
      # Auth calls this INSIDE the session transaction, holding the provider lock
      # across the credential write. complete_auth checks the same thing, but its
      # lock is released when the identity transaction commits — so a disable could
      # commit, sweep no sessions, and the callback then insert one that survives.
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)
      %{identity: identity} = provision(provider, "okta|session-guard")

      assert SSO.ensure_identity_provider_enabled(Repo, identity.id) == :ok

      {:ok, _disabled} = SSO.update_provider(provider, %{enabled: false}, subject)

      assert SSO.ensure_identity_provider_enabled(Repo, identity.id) ==
               {:error, :provider_disabled}
    end

    test "a sign-in with no identity has no connection to check" do
      assert SSO.ensure_identity_provider_enabled(Repo, nil) == :ok
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

  describe "scim_patch_group_members/5" do
    setup do
      scim_provider()
    end

    test "adds members to a group and recomputes their role to the mapped role", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|add")

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{external_group_id: "grp-ops", added: 1, removed: 0}} =
               SSO.scim_patch_group_members(provider, "grp-ops", ["okta|add"], [])

      assert role_of(account.id, identity.user_id) == :operator
    end

    test "removing a member from their only mapped group resets them to default_role (#3)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|patch")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|patch"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      assert {:ok, %{added: 0, removed: 1}} =
               SSO.scim_patch_group_members(provider, "grp-adm", [], ["okta|patch"])

      assert role_of(account.id, identity.user_id) == :viewer
    end
  end

  # -- scim_patch_group/3 (provider-scoped) ----------------------------

  describe "scim_patch_group/3" do
    setup do
      scim_provider()
    end

    test "add then remove applies both in wire order", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: kept} = provision(provider, "okta|kept")
      %{identity: dropped} = provision(provider, "okta|dropped")
      map_group(provider, subject, "grp-ops", :operator)

      operations = [
        members_op("Add", ["okta|kept", "okta|dropped"]),
        members_op("remove", ["okta|dropped"])
      ]

      assert {:ok, %{external_group_id: "grp-ops", member_external_ids: ["okta|kept"]}} =
               SSO.scim_patch_group(provider, "grp-ops", operations)

      assert role_of(account.id, kept.user_id) == :operator
      assert role_of(account.id, dropped.user_id) == :viewer
    end

    test "a whole-set replace hands over the absolute set a later remove applies to", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: kept} = provision(provider, "okta|kept")
      %{identity: victim} = provision(provider, "okta|victim")
      map_group(provider, subject, "grp-adm", :admin)

      # An IdP rewriting a group and then offboarding in one request: the remove
      # applies to the replaced set, not to a set the batch already superseded.
      operations = [
        members_op("replace", ["okta|kept", "okta|victim"]),
        members_op("remove", ["okta|victim"])
      ]

      assert {:ok, %{member_external_ids: ["okta|kept"]}} =
               SSO.scim_patch_group(provider, "grp-adm", operations)

      assert role_of(account.id, kept.user_id) == :admin
      assert role_of(account.id, victim.user_id) == :viewer
    end

    test "Okta's filtered remove takes the named member out", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|filtered")
      map_group(provider, subject, "grp-adm", :admin)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|filtered"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      operations = [%{"op" => "remove", "path" => ~s(members[value eq "okta|filtered"])}]

      assert {:ok, _summary} = SSO.scim_patch_group(provider, "grp-adm", operations)
      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "Okta's pathless `{id, displayName}` settle renames the group it addresses", %{
      provider: provider,
      subject: subject
    } do
      mapping = map_group(provider, subject, "grp-ops", :operator)

      operations = [
        %{"op" => "replace", "value" => %{"id" => "grp-ops", "displayName" => "Platform"}}
      ]

      assert {:ok, %{external_group_id: "grp-ops", display: "Platform"}} =
               SSO.scim_patch_group(provider, "grp-ops", operations)

      assert Repo.reload!(mapping).external_group_display == "Platform"
    end

    test "an unacceptable rename takes the membership change batched with it", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|atomic")
      map_group(provider, subject, "grp-adm", :admin)

      operations = [
        %{"op" => "replace", "path" => "displayName", "value" => String.duplicate("n", 300)},
        members_op("add", ["okta|atomic"])
      ]

      assert SSO.scim_patch_group(provider, "grp-adm", operations) ==
               {:error, :invalid_scim_group}

      # The privilege change must not land under a rename we refuse.
      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "an operation list past the cap is refused before anything is applied", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|flood")
      map_group(provider, subject, "grp-adm", :admin)
      operations = List.duplicate(members_op("add", ["okta|flood"]), 101)

      assert SSO.scim_patch_group(provider, "grp-adm", operations) ==
               {:error, :invalid_scim_group}

      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "one pathless map cannot expand past the operation cap", %{provider: provider} do
      value = Map.new(1..101, &{"attribute#{&1}", &1})
      operations = [%{"op" => "replace", "value" => value}]

      assert SSO.scim_patch_group(provider, "grp-adm", operations) ==
               {:error, :invalid_scim_group}
    end

    test "member changes past the AGGREGATE cap are refused, not just one oversized op", %{
      provider: provider
    } do
      half = for n <- 1..2600, do: "okta|#{n}"
      rest = for n <- 2601..5200, do: "okta|#{n}"

      assert SSO.scim_patch_group(provider, "grp-adm", [
               members_op("add", half),
               members_op("add", rest)
             ]) == {:error, :invalid_scim_group}
    end

    test "an operation on an attribute we do not model is refused, not a silent no-op", %{
      provider: provider
    } do
      operations = [%{"op" => "replace", "path" => "description", "value" => "Ops team"}]

      assert SSO.scim_patch_group(provider, "grp-adm", operations) ==
               {:error, :unsupported_scim_patch}
    end

    test "an externalId settle alone answers with the group as it stands", %{provider: provider} do
      provision(provider, "okta|settled")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_external_ids: ["okta|settled"]
        })

      # Entra reads a group back and PATCHes `externalId` to the value it already
      # has; answering 400 stopped that group's sync dead.
      operations = [%{"op" => "replace", "path" => "externalId", "value" => "grp-ops"}]

      assert SSO.scim_patch_group(provider, "grp-ops", operations) ==
               {:ok,
                %{
                  external_group_id: "grp-ops",
                  display: "Ops",
                  member_external_ids: ["okta|settled"]
                }}
    end

    test "a member externalId belonging to another account is ignored, never reached", %{
      provider: provider_a,
      subject: subject_a
    } do
      %{provider: provider_b, subject: subject_b, account: account_b} = scim_provider()
      %{identity: identity_b} = provision(provider_b, "okta|b-only")
      map_group(provider_a, subject_a, "grp-adm", :admin)
      map_group(provider_b, subject_b, "grp-adm", :admin)

      operations = [members_op("add", ["okta|b-only"])]

      assert {:ok, _summary} = SSO.scim_patch_group(provider_a, "grp-adm", operations)
      assert role_of(account_b.id, identity_b.user_id) == :viewer
    end
  end

  # -- recompute_role_for_identity/2 (provider-scoped) -----------------

  describe "recompute_role_for_identity/2" do
    setup do
      scim_provider()
    end

    test "applies the HIGHEST mapped role over the identity's synced groups", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|hi")

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-op", role: :operator},
          subject
        )

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-op",
          member_external_ids: ["okta|hi"]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|hi"]
        })

      assert {:ok, %Accounts.Membership{role: :admin}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert role_of(account.id, identity.user_id) == :admin
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
      provider: provider,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|none")

      # No group mappings at all → reset to the provider default (:viewer).
      assert {:ok, %Accounts.Membership{role: :viewer}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "never re-roles a human owner (#3 — owners out of sync scope)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity, membership: membership} = provision(provider, "okta|ownerskip")
      Fixtures.Memberships.force_role(membership, "owner")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|ownerskip"]
        })

      # A mapped :admin group would otherwise demote owner→admin, but recompute
      # leaves a human owner untouched.
      assert {:ok, %Accounts.Membership{role: :owner}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert role_of(account.id, membership.user_id) == :owner
    end
  end

  # -- enable_scim/2 ---------------------------------------------------

  describe "enable_scim/2" do
    test "mints a bearer + flips scim_enabled, returning the raw token once" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{scim_enabled: true} = enabled, raw} =
               SSO.enable_scim(provider, subject)

      assert String.starts_with?(raw, "ems-")
      assert enabled.scim_token_prefix == String.slice(raw, 0, 12)
      # The minted bearer authenticates immediately.
      assert {:ok, _} = SSO.authenticate_scim_token(raw)
    end

    test "a Team plan can configure OIDC but is denied SCIM enable (:directory_sync_not_available)" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert {:error, :directory_sync_not_available} = SSO.enable_scim(provider, subject)
      refute Repo.reload!(provider).scim_enabled
    end

    test "the SCIM token prefix is unique across providers (partial index)" do
      {_user, account, subject} = enterprise_owner()
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
      assert {:error, :unauthorized} = SSO.enable_scim(provider, viewer_in(account))
      refute Repo.reload!(provider).scim_enabled
    end

    test "cross-account: account B cannot enable SCIM on account A's provider → :not_found" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert {:error, :not_found} = SSO.enable_scim(provider, sb)
    end

    test "a kind that can't push SCIM is refused, and keeps no token" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account, %{kind: :google_workspace})

      # Google has no inbound SCIM for a custom app, so a bearer minted here
      # could only ever authenticate a directory that cannot exist.
      assert {:error, :scim_not_supported} = SSO.enable_scim(provider, subject)

      reloaded = Repo.reload!(provider)
      refute reloaded.scim_enabled
      assert is_nil(reloaded.scim_token_prefix)
      assert is_nil(reloaded.scim_token_hash)
    end
  end

  # -- rotate_scim_token/2 ---------------------------------------------

  describe "rotate_scim_token/2" do
    setup do
      {_user, account, subject} = enterprise_owner()
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
      assert {:error, :unauthorized} = SSO.authenticate_scim_token(raw1)
      assert {:ok, _} = SSO.authenticate_scim_token(raw2)
    end

    test "a non-admin (no manage_sso) is denied → :unauthorized", %{
      account: account,
      provider: provider
    } do
      assert {:error, :unauthorized} = SSO.rotate_scim_token(provider, viewer_in(account))
    end

    test "a kind that can't push SCIM is refused", %{account: account, subject: subject} do
      google = provider_fixture(account, %{kind: :google_workspace, name: "Google"})

      assert {:error, :scim_not_supported} = SSO.rotate_scim_token(google, subject)
      assert is_nil(Repo.reload!(google).scim_token_prefix)
    end

    test "cross-account: account B cannot rotate account A's SCIM bearer → :not_found", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:error, :not_found} = SSO.rotate_scim_token(provider, sb)
    end
  end

  # -- disable_scim/2 --------------------------------------------------

  describe "disable_scim/2" do
    setup do
      {_user, account, subject} = enterprise_owner()
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
      assert {:error, :unauthorized} = SSO.authenticate_scim_token(raw)
    end

    test "discards the group snapshot, so re-enabling can't restore a revoked role", %{
      subject: subject,
      provider: provider,
      account: account
    } do
      # The group memberships are only true while the directory is pushing them.
      # Kept across a disable/re-enable, the first user to sync recomputed their
      # role from a stale snapshot — handing back an admin role the directory may
      # have revoked while sync was off, before any fresh push could correct it.
      {:ok, provider, _raw} = SSO.enable_scim(provider, subject)

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      %{identity: identity} = provision(provider, "okta|snapshot")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|snapshot"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      assert {:ok, disabled} = SSO.disable_scim(provider, subject)
      {:ok, reenabled, _raw} = SSO.enable_scim(disabled, subject)

      assert {:ok, []} = SSO.list_synced_groups(reenabled, subject)

      # SCIM does not order Users before Groups. Until the directory pushes
      # groups, there is no snapshot to reason from — so a user-first re-sync
      # leaves the membership alone rather than reading an absence as "in no
      # groups" and acting on it.
      %{identity: resynced} = provision(reenabled, "okta|snapshot")
      assert role_of(account.id, resynced.user_id) == :admin

      # Once groups DO arrive and this person is not among them, they drop to the
      # connection default — the old snapshot is not what restored anything.
      {:ok, _} =
        SSO.scim_upsert_group(reenabled, %{
          external_id: "grp-adm",
          member_external_ids: []
        })

      assert role_of(account.id, resynced.user_id) == :viewer
    end

    test "a downgraded plan can still retire the bearer", %{
      subject: subject,
      provider: provider,
      account: account
    } do
      # The token keeps authenticating after a downgrade, so an owner who cannot
      # disable it has a live directory credential and no way to revoke it. Only
      # buying the feature back was gated on the plan; giving it up never is.
      {:ok, _enabled, raw} = SSO.enable_scim(provider, subject)
      assert {:ok, _} = SSO.authenticate_scim_token(raw)

      Fixtures.Accounts.create_subscription(account, "free")

      assert {:ok, %IdentityProvider{scim_enabled: false}} = SSO.disable_scim(provider, subject)
      assert {:error, :unauthorized} = SSO.authenticate_scim_token(raw)
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
      assert {:error, :unauthorized} = SSO.disable_scim(provider, viewer_in(account))
    end

    test "cross-account: account B cannot disable account A's SCIM sync → :not_found", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:error, :not_found} = SSO.disable_scim(provider, sb)
    end
  end

  # -- list_synced_groups/2 --------------------------------------------

  describe "list_synced_groups/2" do
    setup do
      scim_provider()
    end

    test "returns each distinct external group seen via SCIM with its member count", %{
      provider: provider,
      subject: subject
    } do
      _ = provision(provider, "okta|u1")
      _ = provision(provider, "okta|u2")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_external_ids: ["okta|u1"]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          display: "Admins",
          member_external_ids: ["okta|u2"]
        })

      assert {:ok, groups} = SSO.list_synced_groups(provider, subject)

      assert groups == [
               %{external_group_id: "grp-adm", member_count: 1},
               %{external_group_id: "grp-ops", member_count: 1}
             ]
    end

    test "a downgraded plan still reads its synced groups" do
      {_u, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert {:ok, []} = SSO.list_synced_groups(provider, subject)
    end

    test "is account-scoped — another account's enterprise owner can't read it", %{
      provider: provider
    } do
      {_u, _account_b, subject_b} = enterprise_owner()

      assert {:error, :not_found} = SSO.list_synced_groups(provider, subject_b)
    end
  end

  # -- list_group_mappings/3 -------------------------------------------

  describe "list_group_mappings/3" do
    setup do
      scim_provider()
    end

    test "lists a provider's group→role mappings for an enterprise admin", %{
      provider: provider,
      subject: subject
    } do
      {:ok, mapping} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

      assert {:ok, [listed], _meta} = SSO.list_group_mappings(provider, subject)
      assert listed.id == mapping.id
    end

    test "denies a viewer (no manage_sso)", %{provider: provider, account: account} do
      assert {:error, :unauthorized} = SSO.list_group_mappings(provider, viewer_in(account))
    end

    test "a downgraded plan still reads its mappings — removing one needs no plan" do
      {_u, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, subject)
    end

    test "is account-scoped — B sees none of A's mappings", %{
      provider: provider,
      subject: subject
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-a", role: :admin}, subject)

      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, sb)
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
               SSO.create_group_mapping(
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
               SSO.create_group_mapping(
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
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "00g-dupe", role: :admin},
                 subject
               )

      assert {:error, changeset} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "00g-dupe", role: :operator},
                 subject
               )

      # The unique index on (provider_id, external_group_id) maps the violation
      # onto the first constraint field, :provider_id.
      assert "has already been taken" in errors_on(changeset).provider_id
    end

    test "denies a viewer (no manage_sso)", %{provider: provider, account: account} do
      assert {:error, :unauthorized} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-x", role: :admin},
                 viewer_in(account)
               )
    end

    test "denies a Team plan (:directory_sync_not_available)", %{provider: provider} do
      {_u, _team_account, team_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      assert {:error, :directory_sync_not_available} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-x", role: :admin},
                 team_subject
               )
    end

    test "cross-account: B can't create a mapping on A's provider (:not_found)", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:error, :not_found} =
               SSO.create_group_mapping(provider, %{external_group_id: "grp-x", role: :admin}, sb)
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
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

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
        SSO.create_group_runner_access_mapping(
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
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

      assert SSO.update_group_mapping(mapping, %{role: :viewer}, viewer_in(account)) ==
               {:error, :unauthorized}
    end

    test "rejects editing a mapping up to :owner", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

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
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

      assert {:error, :not_found} = SSO.update_group_mapping(mapping_a, %{role: :viewer}, sb)
    end
  end

  # -- delete_group_mapping/2 ------------------------------------------

  describe "delete_group_mapping/2" do
    setup do
      scim_provider()
    end

    test "soft-deletes a mapping for an enterprise admin", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

      assert {:ok, deleted} = SSO.delete_group_mapping(mapping, subject)
      assert deleted.deleted_at
      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, subject)
    end

    test "denies a viewer without manage_sso", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, mapping} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

      assert SSO.delete_group_mapping(mapping, viewer_in(account)) == {:error, :unauthorized}
    end

    test "cross-account: B can't delete A's mapping (:not_found)", %{
      provider: provider,
      subject: subject
    } do
      {_ub, _account_b, sb} = enterprise_owner()

      {:ok, mapping_a} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-1", role: :admin}, subject)

      assert {:error, :not_found} = SSO.delete_group_mapping(mapping_a, sb)
    end
  end

  describe "list_group_runner_access_mappings/3" do
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
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      assert {:ok, [listed], _meta} =
               SSO.list_group_runner_access_mappings(provider, subject)

      assert listed.id == mapping.id
    end

    test "is permission and account scoped", %{provider: provider, account: account} do
      assert {:error, :unauthorized} =
               SSO.list_group_runner_access_mappings(provider, viewer_in(account))

      {_user, _other_account, other_subject} = enterprise_owner()

      assert {:ok, [], _meta} =
               SSO.list_group_runner_access_mappings(provider, other_subject)
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
               SSO.create_group_runner_access_mapping(
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
                 SSO.create_group_runner_access_mapping(
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
               SSO.create_group_runner_access_mapping(
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
      admin = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(membership, db_access, owner_subject)

      assert {:error, :runner_access_exceeds_subject} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{
                   external_group_id: "grp-app",
                   runner_access_mode: :restricted,
                   scope: ["group:app"]
                 },
                 Fixtures.Subjects.membership_subject(membership)
               )
    end

    test "a malformed selection from another account is still not_found", %{provider: provider} do
      {_user, _other_account, other_subject} = enterprise_owner()

      assert {:error, :not_found} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{
                   external_group_id: "grp-x",
                   runner_access_mode: :restricted,
                   scope: ["not-a-selector"]
                 },
                 other_subject
               )
    end

    test "a malformed selection a viewer submits is still unauthorized", %{
      provider: provider,
      account: account
    } do
      assert {:error, :unauthorized} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{
                   external_group_id: "grp-x",
                   runner_access_mode: :restricted,
                   scope: ["not-a-selector"]
                 },
                 viewer_in(account)
               )
    end

    test "the database rejects an account/provider tenant mismatch", %{
      provider: provider
    } do
      {_user, other_account, _subject} = enterprise_owner()

      changeset =
        Emisar.SSO.GroupRunnerAccessMapping.Changeset.create(
          other_account.id,
          provider.id,
          %{external_group_id: "grp-cross-tenant", runner_access_mode: :all}
        )

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).provider_id
    end

    test "refuses a grant broader than the configuring admin currently has", %{
      account: account,
      provider: provider,
      subject: owner_subject
    } do
      admin = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(membership, db_access, owner_subject)

      admin_subject = Fixtures.Subjects.membership_subject(membership)

      assert {:error, :runner_access_exceeds_subject} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{external_group_id: "grp-all", runner_access_mode: :all},
                 admin_subject
               )
    end

    test "denies a viewer (no manage_sso)", %{provider: provider, account: account} do
      assert {:error, :unauthorized} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{external_group_id: "grp-x", runner_access_mode: :all},
                 viewer_in(account)
               )
    end

    test "is account scoped", %{provider: provider} do
      {_user, _other_account, other_subject} = enterprise_owner()

      assert {:error, :not_found} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{external_group_id: "grp-x", runner_access_mode: :all},
                 other_subject
               )
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
        SSO.create_group_runner_access_mapping(
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
        SSO.create_group_runner_access_mapping(
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
        SSO.create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      {_user, _other_account, other_subject} = enterprise_owner()

      assert {:error, :not_found} =
               SSO.update_group_runner_access_mapping(
                 mapping,
                 %{runner_access_mode: :all},
                 other_subject
               )
    end
  end

  describe "delete_group_runner_access_mapping/2" do
    setup do
      scim_provider()
    end

    test "soft-deletes the independent grant", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      assert {:ok, deleted} = SSO.delete_group_runner_access_mapping(mapping, subject)
      assert deleted.deleted_at
      assert {:ok, [], _meta} = SSO.list_group_runner_access_mappings(provider, subject)
    end

    test "denies a viewer without manage_sso", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      assert SSO.delete_group_runner_access_mapping(mapping, viewer_in(account)) ==
               {:error, :unauthorized}
    end

    test "another account cannot delete it", %{provider: provider, subject: subject} do
      {:ok, mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-db", runner_access_mode: :all},
          subject
        )

      {_user, _other_account, other_subject} = enterprise_owner()

      assert {:error, :not_found} =
               SSO.delete_group_runner_access_mapping(mapping, other_subject)
    end
  end

  # -- list_link_requests/3 --------------------------------------------

  describe "list_link_requests/3" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      %{account: account, subject: subject, provider: provider}
    end

    test "returns the account's pending requests", %{subject: subject, provider: provider} do
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})

      assert {:ok, [%LinkRequest{provider_identifier: "okta|a"}], _meta} =
               SSO.list_link_requests(provider, subject)
    end

    test "denies a viewer (no manage_sso)", %{account: account, provider: provider} do
      assert {:error, :unauthorized} = SSO.list_link_requests(provider, viewer_in(account))
    end

    test "is account-scoped — B cannot see A's requests", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})

      assert {:ok, [], _meta} = SSO.list_link_requests(provider, sb)
    end
  end

  describe "list_pending_link_requests_for_account/2" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      %{account: account, subject: subject}
    end

    test "returns pending requests across ALL the account's connections", %{
      account: account,
      subject: subject
    } do
      okta = provider_fixture(account, kind: :okta, name: "Okta", provisioner: :manual)

      keycloak =
        provider_fixture(account, kind: :keycloak, name: "Keycloak", provisioner: :manual)

      _ = capture_request(okta, %{"sub" => "okta|a", "email" => "a@acme.test"})
      _ = capture_request(keycloak, %{"sub" => "kc|b", "email" => "b@acme.test"})

      assert {:ok, requests, _meta} = SSO.list_pending_link_requests_for_account(subject)
      assert MapSet.new(requests, & &1.provider_identifier) == MapSet.new(["okta|a", "kc|b"])
    end

    test "denies a viewer (no manage_sso)", %{account: account} do
      assert {:error, :unauthorized} =
               SSO.list_pending_link_requests_for_account(viewer_in(account))
    end

    test "is account-scoped — B never sees A's pending", %{account: account} do
      provider = provider_fixture(account, provisioner: :manual)
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:ok, [], _meta} = SSO.list_pending_link_requests_for_account(sb)
    end
  end

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
      assert {:error, :unauthorized} = SSO.list_pending_link_request_facts(viewer_in(account))
    end

    test "is account-scoped — B never sees A's pending", %{account: account} do
      provider = provider_fixture(account, provisioner: :manual)
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:ok, [], _meta} = SSO.list_pending_link_request_facts(sb)
    end
  end

  # -- fetch_pending_link_request/1 -----------------------------------

  describe "fetch_pending_link_request/1" do
    test "loads a captured request by id (no subject), account preloaded" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      request = capture_request(provider, %{"sub" => "okta|pending", "email" => "p@acme.test"})

      assert {:ok, loaded} = SSO.fetch_pending_link_request(request.id)
      assert loaded.id == request.id
      assert loaded.account.id == account.id
    end

    test "an unknown or malformed id is :not_found (approved/dismissed requests are gone)" do
      assert {:error, :not_found} = SSO.fetch_pending_link_request(Ecto.UUID.generate())
      assert {:error, :not_found} = SSO.fetch_pending_link_request("not-a-uuid")
    end
  end

  # -- approve_link_request/3 ------------------------------------------

  describe "granting a role through SSO can't exceed the granter's own" do
    setup do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account, default_role: :operator)

      admin_user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin_user.id,
          role: "admin"
        )

      %{
        account: account,
        provider: provider,
        admin: Fixtures.Subjects.membership_subject(membership)
      }
    end

    test "an admin can't make billing_manager the connection default", %{
      provider: provider,
      admin: admin
    } do
      # An admin holds no manage_billing, so handing the finance seat to whoever
      # the directory sends is an escalation by proxy. Rejecting only :owner
      # missed it.
      assert {:error, :role_exceeds_your_permissions} =
               SSO.update_provider(provider, %{default_role: :billing_manager}, admin)
    end

    test "an admin can't map a group to billing_manager", %{provider: provider, admin: admin} do
      assert {:error, :role_exceeds_your_permissions} =
               SSO.create_group_mapping(
                 provider,
                 %{"external_group_id" => "grp-finance", "role" => "billing_manager"},
                 admin
               )
    end

    test "an admin can still grant the roles they hold", %{provider: provider, admin: admin} do
      assert {:ok, _mapping} =
               SSO.create_group_mapping(
                 provider,
                 %{"external_group_id" => "grp-ops", "role" => "operator"},
                 admin
               )

      assert {:ok, updated} = SSO.update_provider(provider, %{default_role: :viewer}, admin)
      assert updated.default_role == :viewer
    end
  end

  describe "approve_link_request/3" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      %{account: account, subject: subject, provider: provider}
    end

    test "an admin can't link an identity onto an owner", %{
      account: account,
      provider: provider
    } do
      # The approver also configured the IdP, so without this they could assert
      # the owner's email under a subject they control, approve their own
      # request, and thereafter sign in as the owner.
      owner_user = Fixtures.Users.create_user(email: "owner@acme.test")

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner_user.id,
        role: "owner"
      )

      admin_user = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin_user.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.membership_subject(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|impersonator",
          "email" => "owner@acme.test",
          "email_verified" => true
        })

      assert {:error, :link_target_outranks_approver} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 admin
               )
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
      target_user = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: target_user.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|inserted-after-the-sweep",
          "email" => target_user.email,
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

      assert {:error, :identity_namespace_changed} =
               SSO.approve_link_request(
                 late,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 subject
               )

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
      target_user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(account_id: account.id, user_id: target_user.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|captured-before-repoint",
          "email" => target_user.email,
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

      assert {:error, :not_found} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 subject
               )

      refute Repo.one(SSO.UserIdentity)
    end

    test "a binding stops working once its person joins a second account", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      # Approval is allowed only when the target belongs to no OTHER account —
      # otherwise the approver reaches an account they have no authority over. That
      # check is made once and cannot see forward, so the moment a second
      # membership exists the reason the binding was permitted has stopped being
      # true. The binding goes with it.
      target = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: target.id)

      request =
        capture_request(provider, %{
          "sub" => "okta|single-account-only",
          "email" => target.email,
          "email_verified" => true
        })

      assert {:ok, %{identity: identity}} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 subject
               )

      assert identity.created_by == :admin
      refute Repo.reload!(identity).deleted_at

      # Someone else's account now invites them.
      elsewhere = Fixtures.Accounts.create_account()

      other_subject =
        Fixtures.Subjects.membership_subject(
          Fixtures.Memberships.create_membership(
            account_id: elsewhere.id,
            user_id: Fixtures.Users.create_user().id,
            role: "owner"
          )
        )

      assert {:ok, _invite} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: target.email, role: "operator"),
                 other_subject
               )

      # The credential the first account's admin approved no longer resolves.
      assert Repo.reload!(identity).deleted_at

      assert {:pending, %LinkRequest{}} =
               SSO.complete_auth(
                 provider,
                 callback(%{
                   "sub" => "okta|single-account-only",
                   "email" => target.email,
                   "email_verified" => true
                 }),
                 %{}
               )
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
          user_id: Fixtures.Users.create_user().id,
          role: "admin"
        )

      admin = Fixtures.Subjects.membership_subject(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|nobody-here-yet",
          "email" => "brand-new@acme.test",
          "email_verified" => true
        })

      Fixtures.Memberships.force_role(admin_membership, "viewer")

      assert {:error, :unauthorized} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 admin
               )

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
      owner_user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner_user.id,
        role: "owner"
      )

      approver_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      approver = Fixtures.Subjects.membership_subject(approver_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|owner-target",
          "email" => owner_user.email,
          "email_verified" => true
        })

      Fixtures.Memberships.force_role(approver_membership, "admin")

      assert {:error, :link_target_outranks_approver} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 approver
               )
    end

    test "an approver demoted while their page sat open is refused", %{
      account: account,
      provider: provider
    } do
      # %Subject{}.permissions is a snapshot taken when the session was built. An
      # admin demoted (or suspended) while the approval page sat open still carried
      # the permissions it loaded with — one last credential binding after the
      # authority for it was taken away.
      target_user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: target_user.id,
        role: "operator"
      )

      admin_user = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin_user.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.membership_subject(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|stale-approver",
          "email" => target_user.email,
          "email_verified" => true
        })

      # The subject in hand still says admin; the row no longer does.
      Fixtures.Memberships.force_role(admin_membership, "viewer")

      assert {:error, :unauthorized} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 admin
               )

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
      target_user = Fixtures.Users.create_user()

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      admin_user = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin_user.id,
          role: "admin"
        )

      admin = Fixtures.Subjects.membership_subject(admin_membership)

      request =
        capture_request(provider, %{
          "sub" => "okta|late-promotion",
          "email" => target_user.email,
          "email_verified" => true
        })

      Fixtures.Memberships.force_role(target_membership, "owner")

      assert {:error, :link_target_outranks_approver} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 admin
               )

      # Nothing was bound.
      refute Repo.one(SSO.UserIdentity)
    end

    test "refuses to link someone who also belongs to another workspace", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      # A session can switch accounts, so binding a credential to a multi-account
      # person hands this workspace's admin reach into workspaces they have no
      # authority over.
      shared = Fixtures.Users.create_user(email: "shared@acme.test")

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: shared.id,
        role: "operator"
      )

      other = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other.id,
        user_id: shared.id,
        role: "viewer"
      )

      request =
        capture_request(provider, %{
          "sub" => "okta|shared",
          "email" => "shared@acme.test",
          "email_verified" => true
        })

      assert {:error, :link_target_in_other_accounts} =
               SSO.approve_link_request(
                 request,
                 %RunnerAccess{mode: :none, groups: [], runner_ids: []},
                 subject
               )
    end

    test "rebinds the member's existing identity instead of giving them a second", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      # Role and runner access are recomputed per identity onto the one
      # membership, so a second identity made the member's privileges depend on
      # iteration order — and the reconcile job's single-row read raised outright.
      member = Fixtures.Users.create_user(email: "member@acme.test")

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      {:ok, directory_identity} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, member.id, %{
          provider_identifier: "directory-123",
          scim_external_id: "directory-123",
          created_by: :provider,
          provisioned_via: :scim
        })
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

      # The directory still addresses them by the id it knows — overwriting this
      # would strand every later GET/PATCH/DELETE /Users/{id}.
      assert identity.scim_external_id == "directory-123"

      live =
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_user_id(member.id)
        |> Repo.all()

      assert Enum.map(live, & &1.id) == [directory_identity.id]
    end

    test "the database refuses a second live identity for one person", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Users.create_user()

      {:ok, _first} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, member.id, %{
          provider_identifier: "first",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
        |> Repo.insert()

      second =
        SSO.UserIdentity.Changeset.create(account.id, provider.id, member.id, %{
          provider_identifier: "second",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })

      assert {:error, changeset} = Repo.insert(second)
      assert "already has an identity for this connection" in errors_on(changeset).user_id
    end

    test "provisions the captured identity + consumes the request", %{
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

      assert {:ok, %{user: user, identity: identity}} =
               SSO.approve_link_request(request, access, subject)

      assert user.email == "approve@acme.test"
      assert identity.provider_identifier == "okta|approve"
      assert identity.created_by == :admin
      assert identity.provisioned_via == :manual
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      assert membership.role == :operator
      assert Accounts.runner_access_for_membership(account.id, membership.id) == access
      assert link_requests(provider.id) == []

      # The bound sub now signs in normally, resolving to the provisioned user.
      claims = %{
        "sub" => "okta|approve",
        "email" => "approve@acme.test",
        "email_verified" => true
      }

      assert {:ok, %{user: signed_in}} = SSO.complete_auth(provider, callback(claims), %{})
      assert signed_in.id == user.id
    end

    test "broadcasts to the waiting pending page on approval", %{
      subject: subject,
      provider: provider
    } do
      request =
        capture_request(provider, %{"sub" => "okta|notify", "email" => "notify@acme.test"})

      :ok = SSO.subscribe_link_request(request.id)

      assert {:ok, _} = SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert_receive {:sso_link_request, :approved, %{id: id, provider_id: provider_id}}
      assert id == request.id
      assert provider_id == provider.id
    end

    test "a matched request links the identity to the EXISTING user — no dup, role kept", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      # An existing :admin member whose email the IdP asserts.
      member = Fixtures.Users.create_user(%{email: "member@acme.test"})

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: :admin
        )

      {:ok, existing_access} = RunnerAccess.restricted(["database"], [])
      Fixtures.Memberships.force_runner_access(membership, existing_access)

      request =
        capture_request(provider, %{
          "sub" => "okta|m",
          "email" => "member@acme.test",
          "name" => "Member"
        })

      assert request.matched_user_id == member.id

      assert {:ok, %{user: user, identity: identity}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      # Bound to the EXISTING user; the sub is stored as both ids.
      assert user.id == member.id
      assert identity.provider_identifier == "okta|m"
      assert identity.scim_external_id == "okta|m"
      # The member's existing role is untouched (not downgraded to :operator).
      membership = Fixtures.Memberships.fetch_membership(account.id, member.id)
      assert membership.role == :admin

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               existing_access

      assert link_requests(provider.id) == []
    end

    test "refuses when the email already belongs to a non-member user (H1)", %{
      subject: subject,
      provider: provider
    } do
      _existing = Fixtures.Users.create_user(%{email: "taken@acme.test"})

      request =
        capture_request(provider, %{
          "sub" => "okta|dup",
          "email" => "taken@acme.test",
          "email_verified" => true
        })

      assert {:error, :email_taken} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      # The request survives so an admin can resolve it another way.
      assert [_still_pending] = link_requests(provider.id)
    end

    test "denies a viewer and leaves the request pending", %{account: account, provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|v", "email" => "v@acme.test"})

      assert {:error, :unauthorized} =
               SSO.approve_link_request(request, RunnerAccess.none(), viewer_in(account))

      assert [_still_pending] = link_requests(provider.id)
    end

    test "denies a free plan (:sso_not_available)", %{provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|ne", "email" => "ne@acme.test"})

      # The plan gate (`ensure_can_configure_sso`) is the first check — before the
      # request is even fetched — so a free-plan owner is denied outright.
      {_u, _free_account, free_subject} = Fixtures.Subjects.owner_subject(%{})

      assert {:error, :sso_not_available} =
               SSO.approve_link_request(request, RunnerAccess.none(), free_subject)

      assert [_still_pending] = link_requests(provider.id)
    end

    test "is account-scoped — B cannot approve A's request", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|x", "email" => "x@acme.test"})

      assert {:error, :not_found} =
               SSO.approve_link_request(request, RunnerAccess.none(), sb)

      assert [_still_pending] = link_requests(provider.id)
    end

    test "a SCIM push matching an existing member parks a request; approve heals the next push",
         %{
           account: account,
           subject: subject,
           provider: provider
         } do
      member = Fixtures.Users.create_user(%{email: "member@acme.test"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: :admin
        )

      attrs = %{external_id: "okta|scim", email: "member@acme.test", full_name: "Member"}

      # Collision → :email_taken (the controller renders 409), but a matched request is parked.
      assert {:error, :email_taken} = SSO.scim_provision_user(provider, attrs)
      assert [request] = link_requests(provider.id)
      assert request.matched_user_id == member.id

      # Admin approves → the identity is linked to the existing member.
      assert {:ok, %{user: user}} =
               SSO.approve_link_request(request, RunnerAccess.none(), subject)

      assert user.id == member.id

      # The next SCIM push self-heals: the identity now resolves to the member.
      assert {:ok, %{user: healed}} = SSO.scim_provision_user(provider, attrs)
      assert healed.id == member.id
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

      assert {:error, :unauthorized} = SSO.dismiss_link_request(request, viewer_in(account))
      assert [_still_pending] = link_requests(provider.id)
    end

    test "is account-scoped — B cannot dismiss A's request", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|dx", "email" => "dx@acme.test"})

      assert {:error, :not_found} = SSO.dismiss_link_request(request, sb)
      assert [_still_pending] = link_requests(provider.id)
    end
  end

  # -- subscribe_link_request/1 ---------------------------------------

  describe "retire_admin_approved_identities/2" do
    test "retires only the bindings an admin approved, and revokes their sessions" do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      user = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      {:ok, admin_approved} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, user.id, %{
          provider_identifier: "approved-by-an-admin",
          created_by: :admin,
          provisioned_via: :manual
        })
        |> Repo.insert()

      assert {:ok, 1} = SSO.retire_admin_approved_identities(user, Repo)
      assert Repo.reload!(admin_approved).deleted_at
    end

    test "leaves what the directory itself asserted alone" do
      # Those were never an emisar-side decision about whose credential this is.
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      user = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      {:ok, from_the_directory} =
        account.id
        |> SSO.UserIdentity.Changeset.create(provider.id, user.id, %{
          provider_identifier: "asserted-by-the-idp",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
        |> Repo.insert()

      assert {:ok, 0} = SSO.retire_admin_approved_identities(user, Repo)
      refute Repo.reload!(from_the_directory).deleted_at
    end
  end

  describe "subscribe_link_request/1" do
    test "the subscriber receives the request's dismiss broadcast" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual)
      request = capture_request(provider, %{"sub" => "okta|sub", "email" => "sub@acme.test"})

      :ok = SSO.subscribe_link_request(request.id)
      assert {:ok, _} = SSO.dismiss_link_request(request, subject)

      assert_receive {:sso_link_request, :dismissed, %{id: id}}
      assert id == request.id
    end
  end

  describe "identity_provider_kinds/0" do
    test "carries every supported provider kind" do
      assert SSO.identity_provider_kinds() ==
               [:google_workspace, :okta, :entra, :jumpcloud, :keycloak, :openid_connect]
    end
  end

  describe "provider_fixed_issuer/1" do
    test "only Google Workspace and JumpCloud serve one issuer for every customer" do
      assert SSO.provider_fixed_issuer(:google_workspace) == "https://accounts.google.com"
      assert SSO.provider_fixed_issuer(:jumpcloud) == "https://oauth.id.jumpcloud.com/"
      assert SSO.provider_fixed_issuer(:okta) == nil
      assert SSO.provider_fixed_issuer(:entra) == nil
      assert SSO.provider_fixed_issuer(:keycloak) == nil
      assert SSO.provider_fixed_issuer(:openid_connect) == nil
    end

    test "reads the string form the console posts, and nil for anything unknown" do
      assert SSO.provider_fixed_issuer("jumpcloud") == "https://oauth.id.jumpcloud.com/"
      assert SSO.provider_fixed_issuer("okta") == nil
      assert SSO.provider_fixed_issuer("not_a_provider") == nil
      assert SSO.provider_fixed_issuer(:not_a_provider) == nil
      assert SSO.provider_fixed_issuer("") == nil
      assert SSO.provider_fixed_issuer(nil) == nil
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

  describe "provider_sync_recent?/2" do
    test "true for enabled directory sync on a capable connection within the day" do
      now = ~U[2026-08-03 12:00:00.000000Z]
      provider = %IdentityProvider{kind: :okta, scim_enabled: true, scim_last_seen_at: now}

      assert SSO.provider_sync_recent?(provider, now)

      assert SSO.provider_sync_recent?(
               %{provider | scim_last_seen_at: DateTime.add(now, -86_399)},
               now
             )

      # The one-arity form reads the current time.
      assert SSO.provider_sync_recent?(%{provider | scim_last_seen_at: DateTime.utc_now()})
    end

    test "false when the connection never synced, is off, or can't sync at all" do
      now = ~U[2026-08-03 12:00:00.000000Z]
      provider = %IdentityProvider{kind: :okta, scim_enabled: true, scim_last_seen_at: now}

      refute SSO.provider_sync_recent?(%{provider | scim_last_seen_at: nil}, now)
      refute SSO.provider_sync_recent?(%{provider | scim_enabled: false}, now)
      refute SSO.provider_sync_recent?(%{provider | kind: :google_workspace}, now)
    end

    test "false at exactly a day old, past it, and for a stamp in the future" do
      now = ~U[2026-08-03 12:00:00.000000Z]
      provider = %IdentityProvider{kind: :okta, scim_enabled: true}

      a_day_ago = %{provider | scim_last_seen_at: DateTime.add(now, -86_400)}
      last_week = %{provider | scim_last_seen_at: DateTime.add(now, -7 * 86_400)}
      ahead_of_us = %{provider | scim_last_seen_at: DateTime.add(now, 60)}
      barely_ahead = %{provider | scim_last_seen_at: DateTime.add(now, 1, :microsecond)}

      # A clock-skewed IdP must not read as freshly synced — the window is
      # "between now and a day ago", both ends closed against nonsense.
      refute SSO.provider_sync_recent?(a_day_ago, now)
      refute SSO.provider_sync_recent?(last_week, now)
      refute SSO.provider_sync_recent?(ahead_of_us, now)
      refute SSO.provider_sync_recent?(barely_ahead, now)
    end
  end

  # -- provider_satisfies_mfa?/1 ---------------------------------------

  describe "provider_satisfies_mfa?/1" do
    test "reads the per-provider toggle" do
      assert SSO.provider_satisfies_mfa?(%IdentityProvider{satisfies_mfa: true})
      refute SSO.provider_satisfies_mfa?(%IdentityProvider{satisfies_mfa: false})
    end
  end

  # -- identity_satisfies_mfa?/1 (pre-Subject) -------------------------

  describe "identity_satisfies_mfa?/1" do
    test "true when the identity's provider has satisfies_mfa set" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{satisfies_mfa: true})
      claims = %{"sub" => "okta|mfa-yes", "email" => "y@acme.test", "email_verified" => true}
      {:ok, %{identity: identity}} = SSO.complete_auth(provider, callback(claims), %{})

      assert SSO.identity_satisfies_mfa?(identity.id)
    end

    test "false when the identity's provider has satisfies_mfa cleared" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, %{satisfies_mfa: false})
      claims = %{"sub" => "okta|mfa-no", "email" => "n@acme.test", "email_verified" => true}
      {:ok, %{identity: identity}} = SSO.complete_auth(provider, callback(claims), %{})

      refute SSO.identity_satisfies_mfa?(identity.id)
    end

    test "false for a nil / unknown identity (fail closed)" do
      refute SSO.identity_satisfies_mfa?(nil)
      refute SSO.identity_satisfies_mfa?(Ecto.UUID.generate())
    end
  end

  # -- identity_belongs_to_account?/2 (pre-Subject) --------------------

  describe "identity_belongs_to_account?/2" do
    setup do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|belong", "email" => "b@acme.test", "email_verified" => true}
      {:ok, %{identity: identity}} = SSO.complete_auth(provider, callback(claims), %{})
      %{account: account, identity: identity}
    end

    test "true when the identity's account_id matches", %{account: account, identity: identity} do
      assert SSO.identity_belongs_to_account?(identity.id, account.id)
    end

    test "false for another account's id", %{identity: identity} do
      {_ub, account_b, _sb} = enterprise_owner()
      refute SSO.identity_belongs_to_account?(identity.id, account_b.id)
    end

    test "false for a nil / unknown identity (fail closed)", %{account: account} do
      refute SSO.identity_belongs_to_account?(nil, account.id)
      refute SSO.identity_belongs_to_account?(Ecto.UUID.generate(), account.id)
    end
  end

  # -- subject_can_configure_sso?/1 ------------------------------------

  describe "subject_can_manage_sso?/1" do
    test "permission-only: true for an admin even on a plan without SSO" do
      account = Fixtures.Accounts.create_account()
      admin = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :admin)
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      # Free plan: the permission half holds; the plan half (configure_sso?) doesn't.
      assert SSO.subject_can_manage_sso?(admin)
      refute SSO.subject_can_configure_sso?(admin)
      refute SSO.subject_can_manage_sso?(viewer)
    end
  end

  describe "subject_can_configure_sso?/1" do
    test "true for an enterprise owner (manage_sso + SSO plan)" do
      {_user, _account, subject} = enterprise_owner()
      assert SSO.subject_can_configure_sso?(subject)
    end

    test "true for a Team owner — SSO is Team and up" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      assert SSO.subject_can_configure_sso?(subject)
    end

    test "false for a free plan (no SSO plan)" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{})
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
      {_user, _account, subject} = enterprise_owner()
      assert SSO.subject_can_configure_directory_sync?(subject)
    end

    test "false for a Team owner — directory sync is Enterprise-only" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      refute SSO.subject_can_configure_directory_sync?(subject)
    end

    test "false for a viewer (no manage_sso) even on enterprise" do
      {_owner, account, _owner_subject} = enterprise_owner()
      refute SSO.subject_can_configure_directory_sync?(viewer_in(account))
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp demote_other_owners(account_id, except: keep_user_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_role(:owner)
    |> Repo.all()
    |> Enum.reject(&(&1.user_id == keep_user_id))
    |> Enum.each(&Fixtures.Memberships.force_role(&1, "admin"))
  end
end
