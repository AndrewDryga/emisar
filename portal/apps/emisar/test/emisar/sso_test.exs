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
  alias Emisar.{Accounts, Repo, SSO}
  alias Emisar.Fixtures
  alias Emisar.SSO.{GroupRoleMapping, IdentityProvider, LinkRequest, UserIdentity}

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
    Application.put_env(:emisar, :sso_oidc_impl, StubOIDC)
    on_exit(fn -> Application.delete_env(:emisar, :sso_oidc_impl) end)
    :ok
  end

  defp enterprise_owner do
    Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
  end

  defp provider_fixture(account, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          kind: :okta,
          name: "Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true,
          default_role: :viewer
        },
        Map.new(attrs)
      )

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account.id, attrs))
    provider
  end

  defp callback(claims), do: %{"_claims" => claims}

  defp link_requests(provider_id) do
    LinkRequest.Query.all()
    |> LinkRequest.Query.by_provider_id(provider_id)
    |> Repo.all()
  end

  # Drive a manual-provider sign-in for an unknown sub → the captured request.
  defp capture_request(provider, claims) do
    {:error, :identity_pending_approval} = SSO.complete_auth(provider, callback(claims), %{})
    hd(link_requests(provider.id))
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

    test "a free plan is denied (:sso_not_available)" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{})

      assert {:error, :sso_not_available} = SSO.list_providers_for_account(subject)
    end

    test "is account-scoped — B never sees A's providers" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      _provider = provider_fixture(account_a)

      assert {:ok, [], _meta} = SSO.list_providers_for_account(sb)
    end
  end

  # -- list_identities_for_users/2 -------------------------------------

  describe "list_identities_for_users/2" do
    test "returns the given users' SSO/SCIM identities, provider preloaded" do
      %{provider: provider, subject: subject} = scim_provider()
      %{identity: identity} = provision(provider, "okta|alice")

      assert {:ok, [found]} = SSO.list_identities_for_users([identity.user_id], subject)
      assert found.id == identity.id
      assert found.provisioned_via == :scim
      assert found.provider.id == provider.id
      assert found.provider.name == provider.name
    end

    test "a viewer (no manage_sso) is denied" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|bob")

      assert {:error, :unauthorized} =
               SSO.list_identities_for_users([identity.user_id], viewer_in(account))
    end

    test "is account-scoped — B never sees A's synced members" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|carol")
      {_ub, _account_b, sb} = enterprise_owner()

      assert {:ok, []} = SSO.list_identities_for_users([identity.user_id], sb)
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

  # -- change_provider/2 -----------------------------------------------

  describe "change_provider/2" do
    test "builds a provider config changeset from attrs (the phx-change form)" do
      changeset = SSO.change_provider(%IdentityProvider{}, %{kind: :okta, name: "Okta"})

      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_change(changeset, :kind) == :okta
      assert Ecto.Changeset.get_change(changeset, :name) == "Okta"
    end

    test "defaults to an empty provider + no attrs" do
      assert %Ecto.Changeset{data: %IdentityProvider{}} = SSO.change_provider()
    end

    test "surfaces validation errors (a non-https issuer) for inline display" do
      changeset = SSO.change_provider(%IdentityProvider{}, %{issuer: "http://idp.test"})

      assert "must be an https URL" in errors_on(changeset).issuer
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

  # -- configure_provider/2 --------------------------------------------

  describe "configure_provider/2 gating" do
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
      assert provider.satisfies_mfa
    end

    test "JumpCloud is an accepted provider kind" do
      {_user, _account, subject} = enterprise_owner()

      assert :jumpcloud in IdentityProvider.kinds()

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
      assert Repo.reload!(provider).issuer == "https://idp.test"
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

      # The LV strips a blank secret from the params before it reaches the
      # context, so the changeset never casts client_secret — the stored value
      # survives an otherwise-unrelated edit.
      assert {:ok, _} = SSO.update_provider(provider, %{name: "Renamed"}, subject)

      reloaded = Repo.reload!(provider)
      assert reloaded.name == "Renamed"
      assert reloaded.client_secret == "keep-this-secret"
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

  # -- delete_provider/3 -----------------------------------------------

  describe "delete_provider/3" do
    test "soft-deletes a provider for an enterprise admin" do
      {_user, account, subject} = enterprise_owner()
      # A second enabled provider so require_sso (unset here anyway) can't bite.
      provider = provider_fixture(account)

      assert {:ok, %IdentityProvider{} = deleted} = SSO.delete_provider(provider, subject)
      assert deleted.deleted_at
      assert {:error, :not_found} = SSO.fetch_provider_by_id(provider.id, subject)
    end

    test "a free plan is denied on delete (:sso_not_available)" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{})
      provider = provider_fixture(account)

      assert {:error, :sso_not_available} = SSO.delete_provider(provider, subject)
      refute Repo.reload!(provider).deleted_at
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
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, default_role: :operator)

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

      assert {:error, :identity_pending_approval} =
               SSO.complete_auth(provider, callback(claims), %{})

      # The real sub + claims are captured for the admin; no user/identity yet.
      assert [%LinkRequest{} = request] = link_requests(provider.id)
      assert request.provider_identifier == "okta|unknown"
      assert request.email == "u@acme.test"
      assert request.claims["sub"] == "okta|unknown"
      assert UserIdentity.Query.not_deleted() |> Repo.all() == []
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

      assert {:error, :identity_pending_approval} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert [request] = link_requests(provider.id)
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

  describe "scim_provision_user/2" do
    setup do
      scim_provider()
    end

    test "creates a user_identity (created_by :provider, provisioned_via :scim) + membership at default_role" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
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
      refute membership.disabled_at
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
      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|readd")
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # Some IdPs re-POST rather than PATCH active:true — the re-POST restores
      # access (reinstate the membership + scim_active), never staying suspended.
      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      refute membership.disabled_at
      assert identity.scim_active
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

  # -- scim_deactivate_user/2 (provider-scoped) ------------------------

  describe "scim_deactivate_user/2" do
    test "suspends the membership (disabled_at) + flips scim_active, never deleting the user" do
      %{provider: provider} = scim_provider(%{default_role: :admin})
      attrs = scim_attrs(%{external_id: "okta|deprov", email: "deprov@acme.test"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      assert {:ok, %{membership: membership, identity: deactivated}} =
               SSO.scim_deactivate_user(provider, "okta|deprov")

      assert membership.disabled_at
      refute deactivated.scim_active

      # The user + identity survive (audit preservation) — only access is cut.
      assert {:ok, _user} = Emisar.Users.fetch_user_by_id(user.id)
      assert {:ok, _identity} = SSO.scim_fetch_user(provider, identity.scim_external_id)
    end

    test "deactivating the last active owner is refused (:last_owner), flag left untouched" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :viewer})
      attrs = scim_attrs(%{external_id: "okta|owner"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      # Promote the lone provisioned member to the account's only owner.
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      assert {:error, :last_owner} = SSO.scim_deactivate_user(provider, "okta|owner")

      # The membership stays active and the SCIM flag is left untouched.
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
      assert {:ok, unchanged} = SSO.scim_fetch_user(provider, identity.scim_external_id)
      assert unchanged.scim_active
    end

    test "returns :not_found when no identity matches the externalId" do
      %{provider: provider} = scim_provider()
      assert {:error, :not_found} = SSO.scim_deactivate_user(provider, "okta|nobody")
    end
  end

  # -- scim_reactivate_user/2 (provider-scoped) ------------------------

  describe "scim_reactivate_user/2" do
    test "clears disabled_at on a suspended membership + flips scim_active back on" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|react", email: "react@acme.test"})

      {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|react")
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.scim_reactivate_user(provider, "okta|react")

      refute membership.disabled_at
      assert identity.scim_active
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end

    test "returns :not_found when no identity matches the externalId" do
      %{provider: provider} = scim_provider()
      assert {:error, :not_found} = SSO.scim_reactivate_user(provider, "okta|nobody")
    end
  end

  # -- scim_fetch_user/2 (provider-scoped) -----------------------------

  describe "scim_fetch_user/2" do
    test "resolves the identity for (provider, externalId) — the IdP's pre-create probe" do
      %{provider: provider} = scim_provider()
      %{identity: identity} = provision(provider, "okta|fetch")

      assert {:ok, fetched} = SSO.scim_fetch_user(provider, "okta|fetch")
      assert fetched.id == identity.id
      assert fetched.scim_external_id == "okta|fetch"
    end

    test "an unknown externalId is :not_found" do
      %{provider: provider} = scim_provider()
      assert {:error, :not_found} = SSO.scim_fetch_user(provider, "okta|nobody")
    end

    test "is provider-scoped — provider B can't fetch provider A's identity" do
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

    test "lists the provider's directory identities, paginated", %{provider: provider} do
      _ = provision(provider, "okta|l1")
      _ = provision(provider, "okta|l2")

      assert {:ok, identities, _meta} = SSO.scim_list_users(provider)
      assert length(identities) == 2
    end

    test "a :scim_filter by external_id matches anywhere in the directory (past the page)", %{
      provider: provider
    } do
      _ = provision(provider, "okta|needle")
      _ = provision(provider, "okta|hay")

      assert {:ok, [identity], _meta} =
               SSO.scim_list_users(provider, scim_filter: {:external_id, "okta|needle"})

      assert identity.scim_external_id == "okta|needle"
    end

    test "is provider-scoped — provider B's list never includes provider A's identities" do
      %{provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()
      _ = provision(provider_a, "okta|onlyA")

      assert {:ok, [], _meta} = SSO.scim_list_users(provider_b)
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

  # -- scim_patch_group_members/4 (provider-scoped) --------------------

  describe "scim_patch_group_members/4" do
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

    test "returns the distinct external group ids seen via SCIM", %{
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
      assert Enum.sort(groups) == ["grp-adm", "grp-ops"]
    end

    test "denies a non-Enterprise plan (:directory_sync_not_available)" do
      {_u, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account)

      assert {:error, :directory_sync_not_available} = SSO.list_synced_groups(provider, subject)
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

    test "denies a Team plan (:directory_sync_not_available)", %{provider: provider} do
      {_u, _team_account, team_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      assert {:error, :directory_sync_not_available} =
               SSO.list_group_mappings(provider, team_subject)
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

  # -- delete_group_mapping/3 ------------------------------------------

  describe "delete_group_mapping/3" do
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

  describe "list_pending_link_requests_for_account/1" do
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

  # -- approve_link_request/2 ------------------------------------------

  describe "approve_link_request/2" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      %{account: account, subject: subject, provider: provider}
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

      assert {:ok, %{user: user, identity: identity}} = SSO.approve_link_request(request, subject)

      assert user.email == "approve@acme.test"
      assert identity.provider_identifier == "okta|approve"
      assert identity.created_by == :admin
      assert identity.provisioned_via == :manual
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).role == :operator
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

    test "a matched request links the identity to the EXISTING user — no dup, role kept", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      # An existing :admin member whose email the IdP asserts.
      member = Fixtures.Users.create_user(%{email: "member@acme.test"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: :admin
        )

      request =
        capture_request(provider, %{
          "sub" => "okta|m",
          "email" => "member@acme.test",
          "name" => "Member"
        })

      assert request.matched_user_id == member.id
      assert {:ok, %{user: user, identity: identity}} = SSO.approve_link_request(request, subject)

      # Bound to the EXISTING user; the sub is stored as both ids.
      assert user.id == member.id
      assert identity.provider_identifier == "okta|m"
      assert identity.scim_external_id == "okta|m"
      # The member's existing role is untouched (not downgraded to :operator).
      assert Fixtures.Memberships.fetch_membership(account.id, member.id).role == :admin
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

      assert {:error, :email_taken} = SSO.approve_link_request(request, subject)
      # The request survives so an admin can resolve it another way.
      assert [_still_pending] = link_requests(provider.id)
    end

    test "denies a viewer and leaves the request pending", %{account: account, provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|v", "email" => "v@acme.test"})

      assert {:error, :unauthorized} = SSO.approve_link_request(request, viewer_in(account))
      assert [_still_pending] = link_requests(provider.id)
    end

    test "denies a free plan (:sso_not_available)", %{provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|ne", "email" => "ne@acme.test"})

      # The plan gate (`ensure_can_configure_sso`) is the first check — before the
      # request is even fetched — so a free-plan owner is denied outright.
      {_u, _free_account, free_subject} = Fixtures.Subjects.owner_subject(%{})

      assert {:error, :sso_not_available} = SSO.approve_link_request(request, free_subject)
      assert [_still_pending] = link_requests(provider.id)
    end

    test "is account-scoped — B cannot approve A's request", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|x", "email" => "x@acme.test"})

      assert {:error, :not_found} = SSO.approve_link_request(request, sb)
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
      assert {:ok, %{user: user}} = SSO.approve_link_request(request, subject)
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
