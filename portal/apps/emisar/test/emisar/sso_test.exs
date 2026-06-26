defmodule Emisar.SSOTest do
  @moduledoc """
  The SSO authorization boundary: enterprise+permission-gated provider config,
  and the relying-party login core — identity resolution strictly by
  `(provider, sub)` (never email), JIT provisioning, the verified-email rule
  (§9 C2/R6), the domain gate (H1), and the per-provider MFA toggle (N2).

  The `oidcc` protocol layer is stubbed (`StubOIDC`) so these exercise the real
  resolution/JIT/gate logic with canned claims and no live IdP.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Accounts, Repo, SSO}
  alias Emisar.SSO.{IdentityProvider, LinkRequest, UserIdentity}

  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts),
      do:
        {:ok,
         %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}

    # The test supplies the validated claims via `params["_claims"]`.
    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, params, _stashed) do
      claims = params["_claims"] || %{}
      {:ok, %{identifier: claims["sub"], claims: claims}}
    end
  end

  setup do
    Application.put_env(:emisar, :sso_oidc_impl, StubOIDC)
    on_exit(fn -> Application.delete_env(:emisar, :sso_oidc_impl) end)
    :ok
  end

  defp enterprise_owner do
    owner_subject_fixture(%{plan: "enterprise"})
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
    viewer = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: :viewer)
    subject_for(viewer, account, role: :viewer)
  end

  # -- Config gating ---------------------------------------------------

  describe "configure_provider/2 gating" do
    test "a free account cannot configure SSO" do
      {_user, _account, subject} = owner_subject_fixture(%{})

      assert {:error, :sso_not_available} =
               SSO.configure_provider(%{kind: :okta, name: "Okta"}, subject)
    end

    test "a Team account can configure an OIDC provider — SSO is Team and up" do
      {_user, _account, subject} = owner_subject_fixture(%{plan: "team"})

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
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: :viewer)
      viewer_subject = subject_for(viewer, account, role: :viewer)

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
  end

  describe "config cross-account isolation" do
    test "account A's provider cannot be fetched or updated by account B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert {:error, :not_found} = SSO.fetch_provider_by_id(provider.id, sb)
      assert {:error, :not_found} = SSO.update_provider(provider, %{name: "Hijacked"}, sb)
      assert {:error, :not_found} = SSO.delete_provider(provider, sb)
    end
  end

  describe "require_sso lock-out guard on provider removal" do
    setup do
      {_user, account, subject} = enterprise_owner()
      account = account |> Ecto.Changeset.change(require_sso: true) |> Repo.update!()
      %{account: account, subject: subject}
    end

    test "cannot delete the last enabled connection", %{account: account, subject: subject} do
      provider = provider_fixture(account)

      assert {:error, :require_sso_last_provider} = SSO.delete_provider(provider, subject)
      refute Repo.reload!(provider).deleted_at
    end

    test "cannot disable the last enabled connection", %{account: account, subject: subject} do
      provider = provider_fixture(account)

      assert {:error, :require_sso_last_provider} =
               SSO.update_provider(provider, %{enabled: false}, subject)

      assert Repo.reload!(provider).enabled
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
      account |> Ecto.Changeset.change(require_sso: false) |> Repo.update!()
      provider = provider_fixture(account)

      assert {:ok, _} = SSO.delete_provider(provider, subject)
    end
  end

  describe "update_provider/3 edit-path validation + gating" do
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

    test "disabling one of two enabled providers is allowed (not the last)" do
      {_user, account, subject} = enterprise_owner()
      account |> Ecto.Changeset.change(require_sso: true) |> Repo.update!()

      _keep = provider_fixture(account, %{name: "Keep", kind: :okta, enabled: true})
      extra = provider_fixture(account, %{name: "Extra", kind: :keycloak, enabled: true})

      # Even under require_sso, disabling a provider while another enabled one
      # remains is fine — the last-provider guard only fires on the final one.
      assert {:ok, %IdentityProvider{enabled: false}} =
               SSO.update_provider(extra, %{enabled: false}, subject)
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
      {_user, account, subject} = owner_subject_fixture(%{})
      provider = provider_fixture(account)

      assert {:error, :sso_not_available} =
               SSO.update_provider(provider, %{name: "Renamed"}, subject)

      assert Repo.reload!(provider).name == "Okta"
    end
  end

  describe "delete_provider/3 gating" do
    test "a free plan is denied on delete (:sso_not_available)" do
      {_user, account, subject} = owner_subject_fixture(%{})
      provider = provider_fixture(account)

      assert {:error, :sso_not_available} = SSO.delete_provider(provider, subject)
      refute Repo.reload!(provider).deleted_at
    end
  end

  describe "enable_scim/2 gating" do
    # SCIM is Enterprise-only, even though OIDC is Team+.
    test "a Team plan can configure OIDC but is denied SCIM enable (:directory_sync_not_available)" do
      {_user, account, subject} = owner_subject_fixture(%{plan: "team"})
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
  end

  # -- Login resolution + JIT ------------------------------------------

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

      membership = fetch_membership(account.id, user.id)
      assert membership.role == :operator
    end

    test "an existing same-email user is NEVER matched — a colliding email fails :email_taken" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      existing = user_fixture(%{email: "taken@acme.test"})

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

    test "provisioning into account A's provider never lands in account B" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, account_b, _sb} = enterprise_owner()
      provider = provider_fixture(account_a)
      claims = %{"sub" => "okta|scoped", "email" => "scoped@acme.test", "email_verified" => true}

      assert {:ok, %{user: user}} = SSO.complete_auth(provider, callback(claims), %{})

      assert fetch_membership(account_a.id, user.id)
      refute fetch_membership(account_b.id, user.id)
    end
  end

  # -- Manual link requests --------------------------------------------

  describe "manual link requests" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      %{account: account, subject: subject, provider: provider}
    end

    test "a re-attempt upserts — one request per (provider, sub), claims refreshed", %{
      provider: provider
    } do
      _ =
        capture_request(provider, %{"sub" => "okta|u", "email" => "old@a.test", "name" => "Old"})

      _ =
        capture_request(provider, %{"sub" => "okta|u", "email" => "new@a.test", "name" => "New"})

      assert [request] = link_requests(provider.id)
      assert request.email == "new@a.test"
      assert request.full_name == "New"
    end

    test "list_link_requests returns the account's pending requests", %{
      subject: subject,
      provider: provider
    } do
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})

      assert {:ok, [%LinkRequest{provider_identifier: "okta|a"}], _meta} =
               SSO.list_link_requests(provider, subject)
    end

    test "list_link_requests denies a viewer (no manage_sso)", %{
      account: account,
      provider: provider
    } do
      assert {:error, :unauthorized} = SSO.list_link_requests(provider, viewer_in(account))
    end

    test "list_link_requests is account-scoped — B cannot see A's requests", %{provider: provider} do
      {_ub, _account_b, sb} = enterprise_owner()
      _ = capture_request(provider, %{"sub" => "okta|a", "email" => "a@acme.test"})

      assert {:ok, [], _meta} = SSO.list_link_requests(provider, sb)
    end

    test "approve_link_request provisions the captured identity + consumes the request", %{
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
      assert fetch_membership(account.id, user.id).role == :operator
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

    test "approve_link_request denies a viewer and leaves the request pending", %{
      account: account,
      provider: provider
    } do
      request = capture_request(provider, %{"sub" => "okta|v", "email" => "v@acme.test"})

      assert {:error, :unauthorized} = SSO.approve_link_request(request, viewer_in(account))
      assert [_still_pending] = link_requests(provider.id)
    end

    test "approve_link_request is account-scoped — B cannot approve A's request", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|x", "email" => "x@acme.test"})

      assert {:error, :not_found} = SSO.approve_link_request(request, sb)
      assert [_still_pending] = link_requests(provider.id)
    end

    test "approve_link_request denies a free plan (:sso_not_available)", %{
      provider: provider
    } do
      request = capture_request(provider, %{"sub" => "okta|ne", "email" => "ne@acme.test"})

      # The plan gate (`ensure_can_configure_sso`) is the first check — before the
      # request is even fetched — so a free-plan owner is denied outright.
      {_u, _free_account, free_subject} = owner_subject_fixture(%{})

      assert {:error, :sso_not_available} = SSO.approve_link_request(request, free_subject)
      assert [_still_pending] = link_requests(provider.id)
    end

    test "approve_link_request refuses when the email already belongs to a user (H1)", %{
      subject: subject,
      provider: provider
    } do
      _existing = user_fixture(%{email: "taken@acme.test"})

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

    test "dismiss_link_request deletes the request without provisioning", %{
      subject: subject,
      provider: provider
    } do
      request = capture_request(provider, %{"sub" => "okta|d", "email" => "d@acme.test"})

      assert {:ok, %LinkRequest{}} = SSO.dismiss_link_request(request, subject)
      assert link_requests(provider.id) == []
      assert UserIdentity.Query.not_deleted() |> Repo.all() == []
    end

    test "dismiss_link_request denies a viewer", %{account: account, provider: provider} do
      request = capture_request(provider, %{"sub" => "okta|dv", "email" => "dv@acme.test"})

      assert {:error, :unauthorized} = SSO.dismiss_link_request(request, viewer_in(account))
      assert [_still_pending] = link_requests(provider.id)
    end

    test "dismiss_link_request is account-scoped — B cannot dismiss A's request", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|dx", "email" => "dx@acme.test"})

      assert {:error, :not_found} = SSO.dismiss_link_request(request, sb)
      assert [_still_pending] = link_requests(provider.id)
    end
  end

  describe "linking an existing member" do
    setup do
      {_owner, account, subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :manual, default_role: :operator)
      # An existing member whose email the IdP asserts. Role :admin so we can
      # prove a link never downgrades them to the provider's :operator default.
      member = user_fixture(%{email: "member@acme.test"})
      _ = membership_fixture(account_id: account.id, user_id: member.id, role: :admin)
      %{account: account, subject: subject, provider: provider, member: member}
    end

    test "a capture whose email matches an existing member records the matched user", %{
      provider: provider,
      member: member
    } do
      request =
        capture_request(provider, %{
          "sub" => "okta|m",
          "email" => "member@acme.test",
          "name" => "Member"
        })

      assert request.matched_user_id == member.id
    end

    test "a :jit login matching an existing member is parked for approval (not auto-merged)" do
      {_owner, account, _subject} = enterprise_owner()
      provider = provider_fixture(account, provisioner: :jit)
      member = user_fixture(%{email: "jit@acme.test"})
      _ = membership_fixture(account_id: account.id, user_id: member.id, role: :viewer)
      claims = %{"sub" => "okta|jit", "email" => "jit@acme.test", "email_verified" => true}

      assert {:error, :identity_pending_approval} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert [request] = link_requests(provider.id)
      assert request.matched_user_id == member.id
    end

    test "approving a matched request links the identity to the EXISTING user — no dup, role kept",
         %{account: account, subject: subject, provider: provider, member: member} do
      request =
        capture_request(provider, %{
          "sub" => "okta|m",
          "email" => "member@acme.test",
          "name" => "Member"
        })

      assert request.matched_user_id == member.id
      assert {:ok, %{user: user, identity: identity}} = SSO.approve_link_request(request, subject)

      # Bound to the EXISTING user (not a fresh one); the sub is stored as both ids.
      assert user.id == member.id
      assert identity.user_id == member.id
      assert identity.provider_identifier == "okta|m"
      assert identity.scim_external_id == "okta|m"
      assert identity.created_by == :admin
      assert link_requests(provider.id) == []

      # The member's existing role is untouched (not downgraded to :operator).
      assert fetch_membership(account.id, member.id).role == :admin

      # The bound sub now signs in AS the existing user.
      claims = %{"sub" => "okta|m", "email" => "member@acme.test", "email_verified" => true}
      assert {:ok, %{user: signed_in}} = SSO.complete_auth(provider, callback(claims), %{})
      assert signed_in.id == member.id
    end

    test "approving a matched request denies a viewer (stays pending)", %{
      account: account,
      provider: provider
    } do
      request = capture_request(provider, %{"sub" => "okta|m", "email" => "member@acme.test"})

      assert {:error, :unauthorized} = SSO.approve_link_request(request, viewer_in(account))
      assert [_still_pending] = link_requests(provider.id)
    end

    test "approving a matched request is account-scoped — B cannot approve A's", %{
      provider: provider
    } do
      {_ub, _account_b, sb} = enterprise_owner()
      request = capture_request(provider, %{"sub" => "okta|m", "email" => "member@acme.test"})

      assert {:error, :not_found} = SSO.approve_link_request(request, sb)
      assert [_still_pending] = link_requests(provider.id)
    end

    test "a SCIM push matching an existing member parks a request + 409s; approve heals the next push",
         %{subject: subject, provider: provider, member: member} do
      attrs = %{external_id: "okta|scim", email: "member@acme.test", full_name: "Member"}

      # Collision → :email_taken (the controller renders 409), but a matched request is parked.
      assert {:error, :email_taken} = SSO.scim_provision_user(provider, attrs)
      assert [request] = link_requests(provider.id)
      assert request.matched_user_id == member.id
      assert request.provider_identifier == "okta|scim"

      # Admin approves → the identity is linked to the existing member.
      assert {:ok, %{user: user}} = SSO.approve_link_request(request, subject)
      assert user.id == member.id

      # The next SCIM push self-heals: the identity now resolves to the member.
      assert {:ok, %{user: healed}} = SSO.scim_provision_user(provider, attrs)
      assert healed.id == member.id
    end
  end

  # -- Domain gate (H1) ------------------------------------------------

  describe "complete_auth/3 — allowed_email_domain gate" do
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

  # -- MFA toggle (N2) -------------------------------------------------

  describe "provider_satisfies_mfa?/1" do
    test "reads the per-provider toggle" do
      assert SSO.provider_satisfies_mfa?(%IdentityProvider{satisfies_mfa: true})
      refute SSO.provider_satisfies_mfa?(%IdentityProvider{satisfies_mfa: false})
    end
  end

  # -- No owner-escalation via sync (code-review #1) -------------------

  describe "owner is never assignable via SSO/SCIM" do
    test "configure_provider rejects an :owner default_role" do
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

    test "provision_sso_membership refuses :owner (defense in depth)" do
      {_user, account, _subject} = enterprise_owner()
      user = user_fixture()

      assert {:error, :owner_not_assignable} =
               Accounts.provision_sso_membership(account.id, user.id, :owner)
    end
  end

  # -- email_verified string-vs-boolean (code-review #6) ---------------

  describe "verified-email claim parsing" do
    test "JIT trusts email_verified arriving as the string \"true\"" do
      {_user, account, _subject} = enterprise_owner()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|str", "email" => "str@acme.test", "email_verified" => "true"}

      assert {:ok, %{user: user}} = SSO.complete_auth(provider, callback(claims), %{})
      assert user.email == "str@acme.test"
    end
  end
end
