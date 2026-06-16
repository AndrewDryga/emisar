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
    test "a non-enterprise account cannot configure SSO" do
      {_user, _account, subject} = owner_subject_fixture(%{plan: "team"})

      assert {:error, :sso_not_available} =
               SSO.configure_provider(%{kind: :okta, name: "Okta"}, subject)
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

    test "the issuer must be an https URL" do
      {_user, _account, subject} = enterprise_owner()

      assert {:error, changeset} =
               SSO.configure_provider(
                 %{kind: :okta, name: "Okta", issuer: "http://idp.test", client_id: "cid"},
                 subject
               )

      assert "must be an https URL" in errors_on(changeset).issuer
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

      assert {:ok, %{user: user, identity: identity, provider: ^provider}} =
               SSO.complete_auth(provider, callback(claims), %{})

      assert user.email == "new@acme.test"
      assert user.full_name == "New Operator"
      assert user.confirmed_at
      refute user.hashed_password
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

      assert {:ok, %{user: first}} = SSO.complete_auth(provider, callback(claims), %{})
      assert {:ok, %{user: second}} = SSO.complete_auth(provider, callback(claims), %{})

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
