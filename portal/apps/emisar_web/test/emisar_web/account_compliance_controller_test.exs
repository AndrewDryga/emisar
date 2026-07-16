defmodule EmisarWeb.AccountComplianceControllerTest do
  @moduledoc """
  `require_sso` / `require_mfa` are account-level controls the LiveView
  `on_mount` hooks enforce — hooks that do NOT run for `get`/`post` controller
  routes nested in the same `live_session`. This covers the two controller
  surfaces that ingest/act:

    * the audit CSV download — `EmisarWeb.Plugs.EnsureAccountCompliance` re-checks
      the resolved account before any data is read (BEFORE the plan gate);
    * the OAuth consent mint — the consent RENDER stays open (it mints nothing),
      and require_sso / require_mfa is enforced at the mint, on the CHOSEN account.

  The MFA exemption is ACCOUNT-SCOPED (a foreign-IdP SSO session earns none), and
  the sso_required shim a bounced session lands on stays reachable (no loop).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Fixtures, OAuth, Repo}
  alias Emisar.SSO.UserIdentity

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource EmisarWeb.Endpoint.url() <> "/api/mcp/rpc"

  defp enabled_provider(account),
    do: Fixtures.SSO.create_identity_provider(account_id: account.id)

  defp require_sso!(account),
    do: Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

  defp require_mfa!(account),
    do: Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

  # A real signed-in session whose token records SSO provenance for `identity`.
  defp sso_session(user, identity) do
    token =
      Emisar.Auth.create_session_token!(user, :sso, true, %{}, user_identity_id: identity.id)

    build_conn() |> init_test_session(%{}) |> put_session(:user_token, token)
  end

  defp identity_for(account, provider, user) do
    {:ok, identity} =
      Repo.insert(
        UserIdentity.Changeset.create(account.id, provider.id, user.id, %{
          provider_identifier: "okta|#{System.unique_integer([:positive])}",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
      )

    identity
  end

  defp register_client! do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => "Claude", "redirect_uris" => [@redirect]})

    client
  end

  defp code_challenge do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
  end

  defp authorize_params(client) do
    %{
      client_id: client.id,
      redirect_uri: @redirect,
      response_type: "code",
      code_challenge: code_challenge(),
      code_challenge_method: "S256",
      scope: "mcp offline_access",
      state: "xyz",
      resource: @resource
    }
  end

  describe "GET /app/:account/audit/download" do
    test "a magic-link session in a require_sso account is bounced, never handed the CSV", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      _ = enabled_provider(account)
      require_sso!(account)

      conn = get(conn, ~p"/app/#{account}/audit/download")

      # A 302 to the SSO step-up — BEFORE the Team-plan gate (no subscription
      # here), proving the compliance plug runs first; no CSV body is streamed.
      assert redirected_to(conn) == ~p"/app/#{account}/sso_required"
    end

    test "a non-enrolled member of a require_mfa account is funnelled to MFA setup", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      require_mfa!(account)

      conn = get(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) == ~p"/app/mfa_setup"
    end

    test "an SSO-compliant session for the account still downloads the CSV", %{conn: conn} do
      {_conn, user, account} = register_and_log_in(conn)
      provider = enabled_provider(account)
      require_sso!(account)
      identity = identity_for(account, provider, user)
      Fixtures.Accounts.create_subscription(account, "team")

      {:ok, _} =
        Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "alice")

      conn =
        get(
          sso_session(user, identity),
          ~p"/app/#{account}/audit/download?event_type=user.invited"
        )

      assert response_content_type(conn, :csv)
      assert response(conn, 200) =~ "alice"
    end

    test "a session SSO-authed via ANOTHER account's IdP is NOT MFA-exempt here", %{conn: conn} do
      # The MFA exemption is account-scoped: an SSO session whose provider
      # satisfies MFA but belongs to a DIFFERENT account earns no exemption for
      # THIS one — it never proved a second factor here. So a foreign-IdP session
      # on a require_mfa account is funnelled to enrollment, not waved through.
      {_conn, user, account} = register_and_log_in(conn)
      require_mfa!(account)

      other = Fixtures.Accounts.create_account()
      other_provider = enabled_provider(other)
      foreign_identity = identity_for(other, other_provider, user)

      conn = get(sso_session(user, foreign_identity), ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) == ~p"/app/mfa_setup"
    end

    test "an SSO session whose provider satisfies MFA FOR THIS account stays exempt", %{
      conn: conn
    } do
      # The account-scoped positive: an MFA-satisfying SSO identity that DOES
      # belong to this account keeps its exemption — the fix narrows the hole
      # without breaking the legitimate case.
      {_conn, user, account} = register_and_log_in(conn)
      require_mfa!(account)
      provider = enabled_provider(account)
      identity = identity_for(account, provider, user)
      Fixtures.Accounts.create_subscription(account, "team")

      {:ok, _} =
        Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "alice")

      conn =
        get(
          sso_session(user, identity),
          ~p"/app/#{account}/audit/download?event_type=user.invited"
        )

      assert response_content_type(conn, :csv)
    end
  end

  describe "GET /oauth/authorize — the consent RENDER is not compliance-gated (the mint is)" do
    test "a magic-link session in a require_sso account still reaches the consent screen", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      _ = enabled_provider(account)
      require_sso!(account)

      # Rendering consent mints nothing, so it is NOT gated on the session account
      # (gating it would also block granting a DIFFERENT, compliant account). The
      # require_sso / require_mfa gate lives at the mint (POST), on the CHOSEN one.
      html =
        conn
        |> get(~p"/oauth/authorize?#{authorize_params(register_client!())}")
        |> html_response(200)

      assert html =~ "Authorize"
    end
  end

  describe "POST /oauth/authorize (mint) — require_sso/require_mfa gates the CHOSEN account" do
    test "approving a require_sso account from a non-SSO session mints nothing", %{conn: conn} do
      {conn, user, session_account} = register_and_log_in(conn)

      chosen = Fixtures.Accounts.create_account()
      _ = enabled_provider(chosen)
      require_sso!(chosen)

      # Owner in the chosen account — so WITHOUT the compliance guard the mint
      # would succeed (key-issue permission is present); the guard is what blocks.
      Fixtures.Memberships.create_membership(
        account_id: chosen.id,
        user_id: user.id,
        role: "owner"
      )

      conn = put_session(conn, :current_account_id, session_account.id)
      client = register_client!()

      conn =
        post(conn, ~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "scope" => "mcp offline_access",
          "state" => "xyz",
          "code_challenge" => code_challenge(),
          "code_challenge_method" => "S256",
          "resource" => @resource,
          "account_id" => chosen.id,
          "decision" => "approve"
        })

      assert html_response(conn, 400) =~ "single sign-on"
      refute Repo.one(Emisar.ApiKeys.ApiKey)
      refute Repo.one(OAuth.AuthorizationCode)
    end

    test "a session whose CURRENT account requires SSO can still grant a NON-enforcing account",
         %{conn: conn} do
      # Regression guard: enforcement is on the CHOSEN account, not the session
      # account. A magic-link session pinned to a require_sso account must still
      # grant a different, non-enforcing account it belongs to — the removed
      # session-account plug wrongly blocked this (and even blocked "deny").
      {conn, user, session_account} = register_and_log_in(conn)
      _ = enabled_provider(session_account)
      require_sso!(session_account)

      grantee = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: grantee.id,
        user_id: user.id,
        role: "owner"
      )

      conn = put_session(conn, :current_account_id, session_account.id)
      client = register_client!()

      conn =
        post(conn, ~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "scope" => "mcp offline_access",
          "state" => "xyz",
          "code_challenge" => code_challenge(),
          "code_challenge_method" => "S256",
          "resource" => @resource,
          "account_id" => grantee.id,
          "decision" => "approve"
        })

      assert redirected_to(conn, 302) =~ "code="
      assert Repo.one(Emisar.ApiKeys.ApiKey).account_id == grantee.id
    end
  end

  describe "the sso_required shim stays reachable (no redirect loop)" do
    test "a non-SSO session reaches the shim, which logs it out to the branded sign-in", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      _ = enabled_provider(account)
      require_sso!(account)

      # The shim carries NO compliance plug, so the bounced magic-link session
      # can reach it — it logs out and lands on the branded sign-in (no loop).
      conn = get(conn, ~p"/app/#{account}/sso_required")

      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
      refute get_session(conn, :user_token)
    end
  end
end
