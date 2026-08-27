defmodule EmisarWeb.SSOControllerTest do
  @moduledoc """
  The OIDC relying-party login endpoints. The `oidcc` protocol layer is stubbed
  (`StubOIDC`, exactly as `Emisar.SSOTest` does it) so these exercise the real
  begin/stash + callback/login plumbing with canned claims and no live IdP.
  """
  use EmisarWeb.ConnCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.{Auth, Crypto, Fixtures, Repo}
  alias Emisar.SSO.IdentityProvider
  alias EmisarWeb.OIDCIdentityHandoff

  # The session key the controller stashes the OIDC transaction secrets under.
  @stash_key "sso_login"
  @member_mfa_reset_stash_key "member_mfa_reset_sso"
  @identity_link_stash_key "sso_identity_link"

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
      claims = normalize_numeric_auth_time(claims)
      {:ok, %{identifier: claims["sub"], claims: claims}}
    end

    # ConnTest query-encodes the canned claims, while a real decoded ID token
    # preserves JSON numbers. Restore that one protocol type so the stub models
    # oidcc's verified claim map instead of Plug's query-string representation.
    defp normalize_numeric_auth_time(%{"auth_time" => auth_time} = claims)
         when is_binary(auth_time) do
      case Integer.parse(auth_time) do
        {value, ""} -> Map.put(claims, "auth_time", value)
        _other -> claims
      end
    end

    defp normalize_numeric_auth_time(claims), do: claims
  end

  # A stub whose callback failure has no tailored operator copy — the log still
  # classifies the transport boundary without exposing the dependency value.
  defmodule FailingOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts) do
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

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

  defmodule SensitiveBeginOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts) do
      send(self(), :sensitive_begin_oidc_called)

      {:error,
       {:failed_connect,
        [
          {:to_address, {{203, 0, 113, 10}, 443}},
          {:inet,
           [
             cacerts: ["TLS_CA_SENTINEL"],
             client_secret: "CLIENT_SECRET_SENTINEL"
           ], {:tls_alert, "RAW_IDP_BODY_SENTINEL"}}
        ]}}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, _params, _stashed), do: {:error, :unreachable}
  end

  defmodule SensitiveCallbackOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts) do
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, _params, _stashed) do
      send(self(), :sensitive_callback_oidc_called)

      {:error,
       {:http_error, 401,
        %{
          "id_token" => "ID_TOKEN_SENTINEL",
          "access_token" => "ACCESS_TOKEN_SENTINEL",
          "refresh_token" => "REFRESH_TOKEN_SENTINEL",
          "claims" => %{"email" => "CLAIMS_SENTINEL"},
          "client_secret" => "CLIENT_SECRET_SENTINEL",
          "body" => "RAW_IDP_BODY_SENTINEL",
          "tls" => ["TLS_CA_SENTINEL"]
        }}}
    end
  end

  defmodule SensitiveFallbackOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts), do: {:error, :not_used}

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, _params, _stashed) do
      send(self(), :sensitive_fallback_oidc_called)

      {:error,
       {:unexpected_dependency_failure,
        %{
          id_token: "ID_TOKEN_SENTINEL",
          claims: %{"sub" => "CLAIMS_SENTINEL"},
          detail: "RAW_IDP_BODY_SENTINEL\nforged_event reason=ok FORGED_LOG_LINE_SENTINEL"
        }}}
    end
  end

  defmodule RecordingOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(provider, _opts) do
      send(self(), {:oidc_begin, provider.id})
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(provider, _params, _stashed) do
      send(self(), {:oidc_callback, provider.id})
      {:error, :token_endpoint_unreachable}
    end
  end

  defmodule UnsafeAuthorizeOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts) do
      {:ok,
       %{
         authorize_url: "javascript:alert('unsafe')",
         state: "s",
         nonce: "n",
         pkce_verifier: "v"
       }}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, _params, _stashed), do: {:error, :not_used}
  end

  setup do
    Emisar.Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
    :ok
  end

  defp enterprise_account do
    Fixtures.Accounts.create_account(plan: "enterprise")
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

  defp stash_callback(conn, provider) do
    conn
    |> init_test_session(%{})
    |> put_session(@stash_key, %{
      provider_id: provider.id,
      state: "s",
      nonce: "n",
      pkce_verifier: "v",
      redirect_uri: "https://emisar.test/sign_in/sso/callback"
    })
  end

  defp conn_from(index) do
    build_conn()
    |> put_req_header("x-forwarded-for", "198.51.100.#{index}, 8.233.97.247")
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

    test "a provider on a disabled account cannot begin sign-in", %{conn: conn} do
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
      provider = provider_fixture(account)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

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
      # `begin/2` always computes `redirect_uri` as
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
      # begin only redirects to the IdP and stashes the
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
      # the provider is real and enabled, but `begin_auth`
      # fails (e.g. its IdP discovery document is unreachable). The `with` else maps
      # ANY such failure to the one generic "no longer available" copy — never the
      # raw reason — redirects to /sign_in, and leaves no half-built login stash
      # behind. Same copy as an unknown provider: a misconfig isn't a different
      # signal an attacker can read.
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, FailingBeginOIDC)
      provider = provider_fixture(enterprise_account())

      conn = get(conn, ~p"/sign_in/sso/#{provider.id}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      refute get_session(conn, @stash_key)
    end

    test "begin logs one bounded reason without dependency secrets or TLS payloads", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, SensitiveBeginOIDC)
      provider = provider_fixture(enterprise_account())

      log =
        capture_log(fn ->
          failed = get(conn, ~p"/sign_in/sso/#{provider.id}")
          assert redirected_to(failed) == ~p"/sign_in"
        end)

      assert log =~ "sso_begin_failed reason=idp_unreachable"
      assert_receive :sensitive_begin_oidc_called
      refute_sensitive_log(log)
    end

    test "one IP cannot rotate unknown provider ids past the public work cap" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for _attempt <- 1..20 do
        response = get(conn_from(201), ~p"/sign_in/sso/#{Ecto.UUID.generate()}")
        assert redirected_to(response) == ~p"/sign_in"
      end

      rejected = get(conn_from(201), ~p"/sign_in/sso/#{Ecto.UUID.generate()}")
      assert rejected.status == 429
      assert get_resp_header(rejected, "retry-after") == ["60"]

      allowed = get(conn_from(202), ~p"/sign_in/sso/#{Ecto.UUID.generate()}")
      assert redirected_to(allowed) == ~p"/sign_in"
    end

    test "provider work uses the canonical id across UUID casing and leaves another provider free" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingOIDC)
      provider = provider_fixture(enterprise_account())
      provider_id = provider.id

      for attempt <- 1..20 do
        path_id = if rem(attempt, 2) == 0, do: String.upcase(provider_id), else: provider_id
        response = get(conn_from(attempt), "/sign_in/sso/#{path_id}")
        assert redirected_to(response) == "https://idp.test/auth"
        assert_receive {:oidc_begin, ^provider_id}
      end

      rejected = get(conn_from(21), ~p"/sign_in/sso/#{provider_id}")
      assert rejected.status == 429
      refute_receive {:oidc_begin, ^provider_id}

      other = provider_fixture(enterprise_account())
      other_id = other.id
      allowed = get(conn_from(22), ~p"/sign_in/sso/#{other.id}")
      assert redirected_to(allowed) == "https://idp.test/auth"
      assert_receive {:oidc_begin, ^other_id}
    end
  end

  describe "POST /app/:account/settings/team/:membership/reset_mfa/sso" do
    test "an authenticated SSO owner begins a dedicated reset reauthentication", %{conn: conn} do
      reset = member_mfa_reset_controller_fixture(conn)

      conn =
        post(
          reset.conn,
          ~p"/app/#{reset.account}/settings/team/#{reset.target_membership.id}/reset_mfa/sso"
        )

      assert redirected_to(conn) == "https://idp.test/auth"

      stash = get_session(conn, @member_mfa_reset_stash_key)
      assert stash.actor_id == reset.actor.id
      assert stash.actor_membership_id == reset.actor_membership.id
      assert stash.account_id == reset.account.id
      assert stash.identity_id == reset.identity.id
      assert stash.provider_identifier == reset.identity.provider_identifier
      assert stash.target_membership_id == reset.target_membership.id
      assert stash.target_user_id == reset.target.id
      assert stash.target_mfa_enabled_at == reset.target.mfa_enabled_at
      assert stash.target_updated_at == reset.target.updated_at
      assert is_integer(stash.started_at)
      refute get_session(conn, @stash_key)

      assert {:ok, %Emisar.Users.User{id: actor_id}, _session} =
               Emisar.Auth.fetch_user_and_token_by_session_token(reset.session_token)

      assert actor_id == reset.actor.id
    end

    test "GET is not routed and POST requires the browser CSRF token", %{conn: conn} do
      reset = member_mfa_reset_controller_fixture(conn)

      path =
        ~p"/app/#{reset.account}/settings/team/#{reset.target_membership.id}/reset_mfa/sso"

      assert get(reset.conn, path).status == 404

      show_conn = get(reset.conn, ~p"/app/#{reset.account}/settings/team")
      csrf_token = Plug.CSRFProtection.get_csrf_token()

      assert_error_sent(403, fn ->
        reset.conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(path, %{})
      end)

      allowed =
        show_conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(path, %{"_csrf_token" => csrf_token})

      assert redirected_to(allowed) == "https://idp.test/auth"
    end

    test "the callback resets the target without replacing or re-minting the actor session", %{
      conn: conn
    } do
      reset = member_mfa_reset_controller_fixture(conn)

      begun =
        post(
          reset.conn,
          ~p"/app/#{reset.account}/settings/team/#{reset.target_membership.id}/reset_mfa/sso"
        )

      before_tokens =
        Emisar.Auth.UserToken.Query.by_user_id(reset.actor.id) |> Repo.aggregate(:count)

      completed =
        begun
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => reset.identity.provider_identifier,
            "auth_time" => System.system_time(:second)
          }
        })

      assert redirected_to(completed) == ~p"/app/#{reset.account}/settings/team"
      refute get_session(completed, @member_mfa_reset_stash_key)
      assert get_session(completed, :user_token) == reset.session_token
      assert is_nil(Repo.reload!(reset.target).mfa_enabled_at)

      assert {:ok, %Emisar.Users.User{id: actor_id}, actor_session} =
               Emisar.Auth.fetch_user_and_token_by_session_token(reset.session_token)

      assert actor_id == reset.actor.id
      assert actor_session.auth_method == :sso
      assert actor_session.user_identity_id == reset.identity.id

      assert Emisar.Auth.UserToken.Query.by_user_id(reset.actor.id) |> Repo.aggregate(:count) ==
               before_tokens

      refute Emisar.Audit.Event.Query.all()
             |> Emisar.Audit.Event.Query.by_event_type("user.signed_in")
             |> Repo.exists?()
    end

    test "a wrong subject or revoked provider trust has no provisioning or reset side effects", %{
      conn: conn
    } do
      for revoke_trust? <- [false, true] do
        reset = member_mfa_reset_controller_fixture(conn)

        begun =
          post(
            reset.conn,
            ~p"/app/#{reset.account}/settings/team/#{reset.target_membership.id}/reset_mfa/sso"
          )

        if revoke_trust? do
          reset.provider
          |> Ecto.Changeset.change(satisfies_mfa: false)
          |> Repo.update!()
        end

        users_before = Repo.aggregate(Emisar.Users.User, :count)
        identities_before = Repo.aggregate(Emisar.SSO.UserIdentity, :count)
        links_before = Repo.aggregate(Emisar.SSO.LinkRequest, :count)

        subject = if revoke_trust?, do: reset.identity.provider_identifier, else: "wrong-subject"

        completed =
          begun
          |> recycle()
          |> get(~p"/sign_in/sso/callback", %{
            "_claims" => %{
              "sub" => subject,
              "auth_time" => System.system_time(:second)
            }
          })

        assert redirected_to(completed) == ~p"/app/#{reset.account.id}/settings/team"
        assert Phoenix.Flash.get(completed.assigns.flash, :error) =~ "reauthentication failed"
        refute is_nil(Repo.reload!(reset.target).mfa_enabled_at)
        assert Repo.aggregate(Emisar.Users.User, :count) == users_before
        assert Repo.aggregate(Emisar.SSO.UserIdentity, :count) == identities_before
        assert Repo.aggregate(Emisar.SSO.LinkRequest, :count) == links_before

        assert {:ok, %Emisar.Users.User{}, _session} =
                 Emisar.Auth.fetch_user_and_token_by_session_token(reset.session_token)
      end
    end

    test "a target re-enrollment during the IdP round trip is not reset", %{conn: conn} do
      reset = member_mfa_reset_controller_fixture(conn)

      begun =
        post(
          reset.conn,
          ~p"/app/#{reset.account}/settings/team/#{reset.target_membership.id}/reset_mfa/sso"
        )

      new_epoch = DateTime.add(reset.target.mfa_enabled_at, 1, :second)

      re_enrolled =
        Fixtures.Users.set_mfa_state(reset.target,
          mfa_secret: Emisar.Auth.generate_mfa_secret(),
          mfa_enabled_at: new_epoch,
          mfa_recovery_codes: ["new-recovery-digest"]
        )

      target_session = Fixtures.Auth.create_session_token!(re_enrolled, :magic_link, nil)

      completed =
        begun
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => reset.identity.provider_identifier,
            "auth_time" => System.system_time(:second)
          }
        })

      assert redirected_to(completed) == ~p"/app/#{reset.account.id}/settings/team"
      assert Repo.reload!(reset.target).mfa_enabled_at == new_epoch

      assert {:ok, _target, _session} =
               Emisar.Auth.fetch_user_and_token_by_session_token(target_session)
    end

    test "a revoked actor session takes the controlled failure path", %{conn: conn} do
      reset = member_mfa_reset_controller_fixture(conn)

      begun =
        post(
          reset.conn,
          ~p"/app/#{reset.account}/settings/team/#{reset.target_membership.id}/reset_mfa/sso"
        )

      :ok = Emisar.Auth.delete_session_token(reset.session_token)

      completed =
        begun
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => reset.identity.provider_identifier,
            "auth_time" => System.system_time(:second)
          }
        })

      assert redirected_to(completed) == ~p"/app/#{reset.account.id}/settings/team"
      refute get_session(completed, @member_mfa_reset_stash_key)
      assert Phoenix.Flash.get(completed.assigns.flash, :error) =~ "reauthentication failed"
      refute is_nil(Repo.reload!(reset.target).mfa_enabled_at)
    end
  end

  describe "POST /app/:account/settings/sso/identity/link" do
    test "starts the signed identity-link ceremony and binds its session stash", %{conn: conn} do
      link = identity_link_controller_fixture(conn)

      begun =
        post(link.conn, ~p"/app/#{link.account}/settings/sso/identity/link", %{
          "handoff" => link.handoff
        })

      body = html_response(begun, 200)
      assert body =~ ~s(data-authorize-url="https://idp.test/auth")
      assert body =~ "window.location.replace(target)"
      assert get_resp_header(begun, "location") == []
      assert get_resp_header(begun, "cache-control") == ["no-store"]

      assert [csp] = get_resp_header(begun, "content-security-policy")
      assert csp =~ "form-action 'self'"
      assert [nonce] = Regex.run(~r/'nonce-([^']+)'/, csp, capture: :all_but_first)
      assert body =~ ~s(<script nonce="#{nonce}">)

      stash = get_session(begun, @identity_link_stash_key)
      assert stash.actor_id == link.user.id
      assert stash.actor_membership_id == link.membership.id
      assert stash.actor_session_token_digest == link.session_digest
      assert stash.account_id == link.account.id
      assert stash.provider_id == link.provider.id
      assert stash.purpose == :link
      assert stash.return_path == ~p"/app/#{link.account}/settings/profile"
      assert is_integer(stash.started_at)
      refute get_session(begun, @stash_key)
      refute get_session(begun, @member_mfa_reset_stash_key)
      assert get_session(begun, :user_token) == link.session_token
    end

    test "refuses a non-HTTPS authorization target before rendering browser navigation", %{
      conn: conn
    } do
      link = identity_link_controller_fixture(conn)
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, UnsafeAuthorizeOIDC)

      failed =
        post(link.conn, ~p"/app/#{link.account}/settings/sso/identity/link", %{
          "handoff" => link.handoff
        })

      assert redirected_to(failed) == ~p"/app/#{link.account}/settings/profile"
      assert Phoenix.Flash.get(failed.assigns.flash, :error) =~ "Couldn't start provider sign-in"
      refute get_session(failed, @identity_link_stash_key)
    end

    test "the callback links the identity without replacing the current session", %{conn: conn} do
      link = identity_link_controller_fixture(conn)

      begun =
        post(link.conn, ~p"/app/#{link.account}/settings/sso/identity/link", %{
          "handoff" => link.handoff
        })

      token_count_before = Auth.UserToken.Query.by_user_id(link.user.id) |> Repo.aggregate(:count)

      completed =
        begun
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => "workforce|linked-user",
            "email" => link.user.email,
            "email_verified" => "true",
            "auth_time" => System.system_time(:second)
          }
        })

      assert redirected_to(completed) == ~p"/app/#{link.account.id}/settings/profile"
      assert Phoenix.Flash.get(completed.assigns.flash, :info) =~ "linked to your profile"
      refute get_session(completed, @identity_link_stash_key)
      assert get_session(completed, :user_token) == link.session_token

      assert {:ok, _user, %Auth.UserToken{auth_method: :magic_link, user_identity_id: nil}} =
               Auth.fetch_user_and_token_by_session_token(link.session_token)

      assert Auth.UserToken.Query.by_user_id(link.user.id) |> Repo.aggregate(:count) ==
               token_count_before

      identity =
        Emisar.SSO.UserIdentity.Query.not_deleted()
        |> Emisar.SSO.UserIdentity.Query.by_provider_id(link.provider.id)
        |> Emisar.SSO.UserIdentity.Query.by_user_id(link.user.id)
        |> Repo.one!()

      assert identity.provider_identifier == "workforce|linked-user"
      assert identity.created_by == :user
    end

    test "a copied handoff cannot cross accounts or sessions", %{conn: conn} do
      link = identity_link_controller_fixture(conn)
      other_account = Fixtures.Accounts.create_account(plan: "enterprise")

      _other_membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: link.user.id,
          role: "owner"
        )

      wrong_account =
        post(link.conn, ~p"/app/#{other_account}/settings/sso/identity/link", %{
          "handoff" => link.handoff
        })

      assert redirected_to(wrong_account) == ~p"/app/#{other_account}/settings/profile"
      refute get_session(wrong_account, @identity_link_stash_key)

      replacement_session = Fixtures.Auth.create_session_token!(link.user, :magic_link, nil)

      wrong_session =
        link.conn
        |> put_session(:user_token, replacement_session)
        |> post(~p"/app/#{link.account}/settings/sso/identity/link", %{
          "handoff" => link.handoff
        })

      assert redirected_to(wrong_session) == ~p"/app/#{link.account}/settings/profile"
      refute get_session(wrong_session, @identity_link_stash_key)
    end

    test "an invalid handoff fails closed without beginning provider work", %{conn: conn} do
      link = identity_link_controller_fixture(conn)
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingOIDC)

      failed =
        post(link.conn, ~p"/app/#{link.account}/settings/sso/identity/link", %{
          "handoff" => "not-signed"
        })

      assert redirected_to(failed) == ~p"/app/#{link.account}/settings/profile"
      assert Phoenix.Flash.get(failed.assigns.flash, :error) =~ "Confirm your code"
      refute get_session(failed, @identity_link_stash_key)
      refute_receive {:oidc_begin, _provider_id}
    end

    test "verifies a disabled saved provider without enabling it or replacing the session", %{
      conn: conn
    } do
      verification =
        identity_link_controller_fixture(conn, purpose: :verify_provider, enabled: false)

      begun =
        post(
          verification.conn,
          ~p"/app/#{verification.account}/settings/sso/identity/link",
          %{"handoff" => verification.handoff}
        )

      completed =
        begun
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => "workforce|verifying-admin",
            "email" => verification.user.email,
            "email_verified" => "true",
            "auth_time" => System.system_time(:second)
          }
        })

      assert redirected_to(completed) ==
               ~p"/app/#{verification.account.id}/settings/sso/#{verification.provider.id}"

      assert Phoenix.Flash.get(completed.assigns.flash, :info) =~ "sign-in verified"
      assert get_session(completed, :user_token) == verification.session_token

      reloaded = Repo.reload!(verification.provider)
      assert reloaded.enabled == false
      assert %DateTime{} = reloaded.sign_in_verified_at
      assert reloaded.sign_in_verified_by_user_id == verification.user.id
      assert is_binary(reloaded.sign_in_verified_identity_id)
    end
  end

  describe "GET /sign_in/sso/callback" do
    test "a saved callback cookie cannot replay provider work past the shared cap" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, RecordingOIDC)
      provider = provider_fixture(enterprise_account())
      provider_id = provider.id

      begun = get(conn_from(31), ~p"/sign_in/sso/#{provider.id}")
      assert_receive {:oidc_begin, ^provider_id}

      _log =
        capture_log(fn ->
          for attempt <- 32..50 do
            response =
              begun
              |> recycle()
              |> put_req_header("x-forwarded-for", "198.51.100.#{attempt}, 8.233.97.247")
              |> get(~p"/sign_in/sso/callback", %{"state" => "s", "code" => "code"})

            assert redirected_to(response) == ~p"/sign_in"
            assert_receive {:oidc_callback, ^provider_id}
          end

          rejected =
            begun
            |> recycle()
            |> put_req_header("x-forwarded-for", "198.51.100.51, 8.233.97.247")
            |> get(~p"/sign_in/sso/callback", %{"state" => "s", "code" => "code"})

          assert redirected_to(rejected) == ~p"/sign_in"
          refute_receive {:oidc_callback, ^provider_id}
        end)

      other = provider_fixture(enterprise_account())
      other_id = other.id
      allowed = get(conn_from(52), ~p"/sign_in/sso/#{other.id}")
      assert redirected_to(allowed) == "https://idp.test/auth"
      assert_receive {:oidc_begin, ^other_id}
    end

    test "the callback route is independently capped by client IP" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for _attempt <- 1..20 do
        response = get(conn_from(101), ~p"/sign_in/sso/callback")
        assert redirected_to(response) == ~p"/sign_in"
      end

      rejected = get(conn_from(101), ~p"/sign_in/sso/callback")
      assert rejected.status == 429

      allowed = get(conn_from(102), ~p"/sign_in/sso/callback")
      assert redirected_to(allowed) == ~p"/sign_in"
    end

    test "a normal sign-in callback cannot replace an authenticated session", %{conn: conn} do
      {conn, actor, _actor_account} = register_and_log_in(conn)
      actor_token = get_session(conn, :user_token)
      provider = provider_fixture(enterprise_account())

      conn =
        conn
        |> put_session(@stash_key, %{
          provider_id: provider.id,
          state: "s",
          nonce: "n",
          pkce_verifier: "v",
          redirect_uri: "https://emisar.test/sign_in/sso/callback"
        })
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => "replacement-sub",
            "email" => "replacement@example.test",
            "email_verified" => "true"
          }
        })

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token) == actor_token
      refute get_session(conn, @stash_key)
      assert Emisar.Users.fetch_user_by_email("replacement@example.test") == {:error, :not_found}

      assert {:ok, %Emisar.Users.User{id: actor_id}, _auth} =
               Emisar.Auth.fetch_user_and_token_by_session_token(actor_token)

      assert actor_id == actor.id
    end

    test "a valid stash + verified claims logs the user in with :sso provenance", %{conn: conn} do
      account = enterprise_account()
      provider = provider_fixture(account)
      # Claims ride the callback as query params, so the provider's boolean
      # email-verification claim arrives as the string "true".
      claims = %{
        "sub" => "okta|cb-1",
        "email" => "cb@acme.test",
        "email_verified" => "true"
      }

      conn =
        conn
        |> stash_callback(provider)
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

    test "account disable between begin and callback prevents JIT side effects", %{conn: conn} do
      {_user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
      provider = provider_fixture(account)

      claims = %{
        "sub" => "okta|disabled",
        "email" => "disabled@acme.test",
        "email_verified" => "true"
      }

      conn = conn |> init_test_session(%{}) |> get(~p"/sign_in/sso/#{provider.id}")

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      conn = conn |> recycle() |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in"
      assert Emisar.Users.fetch_user_by_email("disabled@acme.test") == {:error, :not_found}
    end

    test "a protected OAuth request resumes after SSO sign-in", %{conn: conn} do
      account = enterprise_account()
      provider = provider_fixture(account)

      claims = %{
        "sub" => "okta|oauth",
        "email" => "oauth@acme.test",
        "email_verified" => "true"
      }

      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

      {:ok, client} =
        Emisar.OAuth.register_client(%{
          "client_name" => "Cloud LLM",
          "redirect_uris" => ["https://llm.example/oauth/callback"]
        })

      params = %{
        client_id: client.id,
        redirect_uri: "https://llm.example/oauth/callback",
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: "mcp offline_access",
        state: "resume-sso",
        resource: EmisarWeb.Endpoint.url() <> "/api/mcp/rpc"
      }

      authorize_path = ~p"/oauth/authorize?#{params}"
      conn = get(conn, authorize_path)
      assert redirected_to(conn) == ~p"/sign_in"

      conn = conn |> recycle() |> get(~p"/sign_in/sso/#{provider.id}")

      conn =
        conn
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      assert redirected_to(conn) == authorize_path

      html = conn |> recycle() |> get(authorize_path) |> html_response(200)
      assert html =~ "Authorize"
    end

    test "a successful callback records the user.signed_in audit with method sso", %{conn: conn} do
      account = enterprise_account()
      provider = provider_fixture(account)

      claims = %{
        "sub" => "okta|audit-1",
        "email" => "audit@acme.test",
        "email_verified" => "true"
      }

      conn =
        conn
        |> stash_callback(provider)
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      token = get_session(conn, :user_token)
      {:ok, user, _auth} = Emisar.Auth.fetch_user_and_token_by_session_token(token)

      [event] =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Event.Query.by_account_id(account.id)
        |> Emisar.Audit.Event.Query.by_event_type("user.signed_in")
        |> Emisar.Audit.Event.Query.by_target_id(user.id)
        |> Repo.all()

      assert event.payload["method"] == "sso"
    end

    test "an SSO session is exempt from the account's require_mfa (decision 4)", %{conn: conn} do
      account = enterprise_account()
      account = Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      provider = provider_fixture(account, satisfies_mfa: true)

      claims = %{
        "sub" => "okta|mfa-exempt",
        "email" => "exempt@acme.test",
        "email_verified" => "true"
      }

      logged_in =
        conn
        |> stash_callback(provider)
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      token = get_session(logged_in, :user_token)

      assert {:ok, _user, %Emisar.Auth.UserToken{mfa_verified_at: %DateTime{}}} =
               Emisar.Auth.fetch_user_and_token_by_session_token(token)

      # Follow both redirects into the protected account dashboard. Merely
      # reaching `/app` does not exercise the account compliance hook.
      authed = logged_in |> recycle() |> get(~p"/app")
      assert authed.status == 302
      slugged = authed |> recycle() |> get(redirected_to(authed))
      assert html_response(slugged, 200)
    end

    test "a satisfies_mfa:false provider's SSO session is NOT exempt from require_mfa", %{
      conn: conn
    } do
      account = enterprise_account()
      account = Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      provider = provider_fixture(account, satisfies_mfa: false)

      claims = %{
        "sub" => "okta|nomfa",
        "email" => "nomfa@acme.test",
        "email_verified" => "true"
      }

      logged_in =
        conn
        |> stash_callback(provider)
        |> get(~p"/sign_in/sso/callback", %{"_claims" => claims})

      # The provider does NOT satisfy MFA, so require_mfa still funnels this
      # SSO user into TOTP setup (the satisfies_mfa flag is enforced). Bare
      # /app forwards to the account slug; the slugged dashboard's
      # :ensure_account_compliant on_mount is what redirects to /app/mfa_setup.
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
      # every recognised failure (`:email_taken`,
      # `:identity_pending_approval`, `:email_domain_not_allowed`, missing stash)
      # has tailored copy; anything else (here an IdP/transport failure surfaced by
      # `complete_auth`) falls to one generic "try again, or contact your admin"
      # message rather than leaking the raw reason or 500-ing. No session is created.
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, FailingOIDC)
      account = enterprise_account()
      provider = provider_fixture(account)

      conn =
        conn
        |> stash_callback(provider)
        |> get(~p"/sign_in/sso/callback", %{"_claims" => %{"sub" => "okta|boom"}})

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Single sign-on failed"
      refute get_session(conn, :user_token)
    end

    test "callback logs one bounded reason without tokens, claims, body, or TLS material", %{
      conn: conn
    } do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, SensitiveCallbackOIDC)
      provider = provider_fixture(enterprise_account())

      log =
        capture_log(fn ->
          failed =
            conn
            |> stash_callback(provider)
            |> get(~p"/sign_in/sso/callback", %{"code" => "AUTH_CODE_SENTINEL"})

          assert redirected_to(failed) == ~p"/sign_in"
          refute get_session(failed, :user_token)
        end)

      assert log =~ "sso_callback_failed reason=idp_request_rejected"
      assert_receive :sensitive_callback_oidc_called
      refute_sensitive_log(log)
      refute log =~ "AUTH_CODE_SENTINEL"
    end

    test "an unknown nested callback failure uses the redacted fallback without log injection", %{
      conn: conn
    } do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, SensitiveFallbackOIDC)
      provider = provider_fixture(enterprise_account())

      log =
        capture_log(fn ->
          failed =
            conn
            |> stash_callback(provider)
            |> get(~p"/sign_in/sso/callback", %{"code" => "AUTH_CODE_SENTINEL"})

          assert redirected_to(failed) == ~p"/sign_in"
          refute get_session(failed, :user_token)
        end)

      assert log =~ "sso_callback_failed reason=redacted_failure"
      assert_receive :sensitive_fallback_oidc_called
      refute_sensitive_log(log)
      refute log =~ "AUTH_CODE_SENTINEL"
      refute log =~ "forged_event reason=ok"
    end
  end

  defp refute_sensitive_log(log) do
    for sentinel <- [
          "ID_TOKEN_SENTINEL",
          "ACCESS_TOKEN_SENTINEL",
          "REFRESH_TOKEN_SENTINEL",
          "CLAIMS_SENTINEL",
          "CLIENT_SECRET_SENTINEL",
          "RAW_IDP_BODY_SENTINEL",
          "TLS_CA_SENTINEL",
          "FORGED_LOG_LINE_SENTINEL"
        ] do
      refute log =~ sentinel
    end
  end

  defp member_mfa_reset_controller_fixture(conn) do
    {actor, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    actor_membership = Fixtures.Memberships.fetch_membership(account.id, actor.id)
    provider = provider_fixture(account, satisfies_mfa: true)

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: actor.id,
        provider_identifier: "reset-controller-sub"
      })

    session_token =
      Fixtures.Auth.create_session_token!(actor, :sso, DateTime.utc_now(), %{},
        user_identity_id: identity.id
      )

    conn = conn |> init_test_session(%{}) |> put_session(:user_token, session_token)

    target =
      Fixtures.Users.create_user()
      |> Fixtures.Users.set_mfa_state(
        mfa_secret: Emisar.Auth.generate_mfa_secret(),
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: []
      )

    target_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: target.id,
        role: "operator"
      )

    %{
      account: account,
      actor: actor,
      actor_membership: actor_membership,
      conn: conn,
      identity: identity,
      provider: provider,
      session_token: session_token,
      target: target,
      target_membership: target_membership
    }
  end

  defp identity_link_controller_fixture(conn, opts \\ []) do
    {user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    purpose = Keyword.get(opts, :purpose, :link)
    provider = provider_fixture(account, enabled: Keyword.get(opts, :enabled, true))
    session_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    session_digest = Crypto.hash(session_token)

    assert {:ok, :email} =
             Auth.begin_oidc_identity_step_up(provider.id, provider.name, purpose, subject)

    assert_received {:email, email}

    assert {:ok, proof} =
             Auth.confirm_oidc_identity_step_up(
               provider.id,
               purpose,
               Fixtures.Auth.code_from_email(email),
               subject
             )

    handoff =
      OIDCIdentityHandoff.sign(%{
        actor_id: user.id,
        actor_membership_id: membership.id,
        actor_session_token_digest: session_digest,
        account_id: account.id,
        provider_id: provider.id,
        purpose: purpose,
        proof: proof
      })

    %{
      account: account,
      conn: conn |> init_test_session(%{}) |> put_session(:user_token, session_token),
      handoff: handoff,
      membership: membership,
      provider: provider,
      session_digest: session_digest,
      session_token: session_token,
      user: user
    }
  end
end
