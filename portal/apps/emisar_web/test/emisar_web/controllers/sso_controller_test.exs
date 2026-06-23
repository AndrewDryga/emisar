defmodule EmisarWeb.SSOControllerTest do
  @moduledoc """
  The OIDC relying-party login endpoints. The `oidcc` protocol layer is stubbed
  (`StubOIDC`, exactly as `Emisar.SSOTest` does it) so these exercise the real
  begin/stash + callback/login plumbing with canned claims and no live IdP.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Fixtures, Repo}
  alias Emisar.SSO.IdentityProvider

  # The session key the controller stashes the OIDC transaction secrets under.
  @stash_key "sso_login"

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

  # A stub whose callback verification fails with an UNMAPPED reason — to exercise
  # the controller's generic fallback copy (every concrete error has friendlier copy).
  defmodule FailingOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts),
      do:
        {:ok,
         %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, _params, _stashed), do: {:error, :token_endpoint_unreachable}
  end

  # A stub whose BEGIN step fails — a misconfigured provider whose discovery
  # document can't be fetched. Drives the `begin/2` controller's `with` else.
  defmodule FailingBeginOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts), do: {:error, :discovery_failed}

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, _params, _stashed), do: {:error, :unreachable}
  end

  setup do
    Application.put_env(:emisar, :sso_oidc_impl, StubOIDC)
    on_exit(fn -> Application.delete_env(:emisar, :sso_oidc_impl) end)
    :ok
  end

  defp enterprise_account do
    {_user, account, _subject} = Fixtures.owner_subject_fixture(%{plan: "enterprise"})
    account
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

  describe "GET /sign_in/sso/:provider_id (begin)" do
    test "redirects to the IdP and stashes the login state", %{conn: conn} do
      provider = provider_fixture(enterprise_account())

      conn = get(conn, ~p"/sign_in/sso/#{provider.id}")

      assert redirected_to(conn) == "https://idp.test/auth"

      stash = get_session(conn, @stash_key)
      assert stash.provider_id == provider.id
      assert stash.state == "s"
      assert stash.nonce == "n"
      assert stash.pkce_verifier == "v"
    end

    test "a disabled provider flashes and redirects to /sign_in", %{conn: conn} do
      provider = provider_fixture(enterprise_account(), enabled: false)

      conn = get(conn, ~p"/sign_in/sso/#{provider.id}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      refute get_session(conn, @stash_key)
    end

    test "an unknown provider flashes and redirects to /sign_in", %{conn: conn} do
      conn = get(conn, ~p"/sign_in/sso/#{Ecto.UUID.generate()}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
    end

    test "the stashed redirect_uri is the fixed registered callback, not an attacker-supplied one",
         %{conn: conn} do
      # closes AUTH-025-T05 — `begin/2` always computes `redirect_uri` as
      # `url(~p"/sign_in/sso/callback")`; it is NOT read from the request. A query
      # param trying to inject a phishing callback is ignored — the stash (which the
      # callback later trusts) carries the fixed registered URI, so there is no
      # open-redirect / token-exfiltration surface at begin.
      provider = provider_fixture(enterprise_account())

      conn =
        get(conn, ~p"/sign_in/sso/#{provider.id}", %{"redirect_uri" => "https://evil.test/steal"})

      stash = get_session(conn, @stash_key)
      assert stash.redirect_uri == url(~p"/sign_in/sso/callback")
      refute stash.redirect_uri =~ "evil.test"
    end

    test "begin emits no sign-in audit — the user isn't authenticated yet", %{conn: conn} do
      # closes AUTH-025-T08 — begin only redirects to the IdP and stashes the
      # transaction secrets; authentication happens at the callback. So no
      # `user.signed_in` (or other sign-in) audit row is written on the provider's
      # account at this step — attribution waits until an identity is actually proven.
      account = enterprise_account()
      provider = provider_fixture(account)

      _conn = get(conn, ~p"/sign_in/sso/#{provider.id}")

      signed_in =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Event.Query.by_account_id(account.id)
        |> Emisar.Audit.Event.Query.by_event_type("user.signed_in")
        |> Repo.all()

      assert signed_in == []
    end

    test "a provider whose begin_auth fails (misconfig) gets the same generic error, no stash",
         %{conn: conn} do
      # closes AUTH-025-T03 — the provider is real and enabled, but `begin_auth`
      # fails (e.g. its IdP discovery document is unreachable). The `with` else maps
      # ANY such failure to the one generic "no longer available" copy — never the
      # raw reason — redirects to /sign_in, and leaves no half-built login stash
      # behind. Same copy as an unknown provider: a misconfig isn't a different
      # signal an attacker can read.
      Application.put_env(:emisar, :sso_oidc_impl, FailingBeginOIDC)
      provider = provider_fixture(enterprise_account())

      conn = get(conn, ~p"/sign_in/sso/#{provider.id}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      refute get_session(conn, @stash_key)
    end
  end

  describe "GET /sign_in/sso/callback" do
    test "a valid stash + verified claims logs the user in with :sso provenance", %{conn: conn} do
      account = enterprise_account()
      provider = provider_fixture(account)
      # Claims ride the callback as query params, so booleans would arrive as
      # strings ("email_verified" => "true"); use the all-string `hd` path,
      # which the verified-email rule honors and which survives the round-trip.
      claims = %{"sub" => "okta|cb-1", "email" => "cb@acme.test", "hd" => "acme.test"}

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(@stash_key, %{
          provider_id: provider.id,
          state: "s",
          nonce: "n",
          pkce_verifier: "v",
          redirect_uri: "https://emisar.test/sign_in/sso/callback"
        })
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      # SSO lands on the account whose IdP this is (its slug), not bare /app.
      assert redirected_to(conn) == ~p"/app/#{account}"
      # …and the account is remembered for the SSO landing page (signed cookie).
      assert Map.has_key?(conn.resp_cookies, "emisar_recent_accounts")

      # The session carries a real token, the stash is cleared, and the
      # persisted token row records the SSO sign-in method.
      token = get_session(conn, :user_token)
      assert token
      refute get_session(conn, @stash_key)

      assert {:ok, user, auth} = Emisar.Auth.fetch_user_and_token_by_session_token(token)
      assert user.email == "cb@acme.test"
      assert auth.auth_method == :sso
      assert auth.user_identity_id
    end

    test "a successful callback records the user.signed_in audit with method sso", %{conn: conn} do
      # closes AUTH-026-T02 — the callback calls `record_sign_in(user, "sso", …)`
      # before `log_in_user` renews the session, so the sign-in is attributable to
      # the freshly-provisioned user with the SSO method. The observable contract: a
      # `user.signed_in` audit row on the provider's account naming the user, carrying
      # `method: "sso"`.
      account = enterprise_account()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|audit-1", "email" => "audit@acme.test", "hd" => "acme.test"}

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(@stash_key, %{
          provider_id: provider.id,
          state: "s",
          nonce: "n",
          pkce_verifier: "v",
          redirect_uri: "https://emisar.test/sign_in/sso/callback"
        })
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      token = get_session(conn, :user_token)
      {:ok, user, _auth} = Emisar.Auth.fetch_user_and_token_by_session_token(token)

      [event] =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Event.Query.by_account_id(account.id)
        |> Emisar.Audit.Event.Query.by_event_type("user.signed_in")
        |> Emisar.Audit.Event.Query.by_subject_id(user.id)
        |> Repo.all()

      assert event.payload["method"] == "sso"
    end

    test "an SSO session is exempt from the account's require_mfa (decision 4)", %{conn: conn} do
      account = enterprise_account()
      {:ok, account} = account |> Ecto.Changeset.change(require_mfa: true) |> Repo.update()
      provider = provider_fixture(account)
      claims = %{"sub" => "okta|mfa-exempt", "email" => "exempt@acme.test", "hd" => "acme.test"}

      logged_in =
        conn
        |> init_test_session(%{})
        |> put_session(@stash_key, %{
          provider_id: provider.id,
          state: "s",
          nonce: "n",
          pkce_verifier: "v",
          redirect_uri: "https://emisar.test/sign_in/sso/callback"
        })
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      # Follow the session into an authenticated LiveView: the SSO session
      # satisfies MFA, so a require_mfa account does NOT funnel it to setup.
      authed = logged_in |> recycle() |> get(~p"/app")
      refute authed.status == 302 and redirected_to(authed) =~ "/mfa_setup"
    end

    test "a satisfies_mfa:false provider's SSO session is NOT exempt from require_mfa", %{
      conn: conn
    } do
      account = enterprise_account()
      {:ok, account} = account |> Ecto.Changeset.change(require_mfa: true) |> Repo.update()
      provider = provider_fixture(account, satisfies_mfa: false)
      claims = %{"sub" => "okta|nomfa", "email" => "nomfa@acme.test", "hd" => "acme.test"}

      logged_in =
        conn
        |> init_test_session(%{})
        |> put_session(@stash_key, %{
          provider_id: provider.id,
          state: "s",
          nonce: "n",
          pkce_verifier: "v",
          redirect_uri: "https://emisar.test/sign_in/sso/callback"
        })
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      # The provider does NOT satisfy MFA, so require_mfa still funnels this
      # SSO user into TOTP setup (the satisfies_mfa flag is enforced). Bare
      # /app forwards to the account slug; the slugged dashboard's
      # :ensure_mfa_compliant on_mount is what redirects to /app/mfa_setup.
      authed = logged_in |> recycle() |> get(~p"/app")
      assert authed.status == 302
      slugged = authed |> recycle() |> get(redirected_to(authed))
      assert slugged.status == 302
      assert redirected_to(slugged) =~ "/mfa_setup"
    end

    test "no stash flashes 'expired' and redirects to /sign_in", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> get(~p"/sign_in/sso/callback", %{"_claims" => %{"sub" => "x"}})

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
      refute get_session(conn, :user_token)
    end

    test "an unmapped complete_auth error gets the generic fallback copy", %{conn: conn} do
      # closes AUTH-026-T07 — every recognised failure (`:email_taken`,
      # `:identity_pending_approval`, `:email_domain_not_allowed`, missing stash)
      # has tailored copy; anything else (here an IdP/transport failure surfaced by
      # `complete_auth`) falls to one generic "try again, or contact your admin"
      # message rather than leaking the raw reason or 500-ing. No session is created.
      Application.put_env(:emisar, :sso_oidc_impl, FailingOIDC)
      account = enterprise_account()
      provider = provider_fixture(account)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(@stash_key, %{
          provider_id: provider.id,
          state: "s",
          nonce: "n",
          pkce_verifier: "v",
          redirect_uri: "https://emisar.test/sign_in/sso/callback"
        })
        |> get(~p"/sign_in/sso/callback", %{"_claims" => %{"sub" => "okta|boom"}})

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Single sign-on failed"
      refute get_session(conn, :user_token)
    end
  end
end
