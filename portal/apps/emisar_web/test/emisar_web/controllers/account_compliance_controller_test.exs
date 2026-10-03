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

  A session belongs to one workspace, so another workspace's SSO session earns
  nothing here, and a session `require_sso` no longer accepts is dropped and
  sent to the workspace's sign-in (no loop).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Auth, Fixtures, OAuth, Repo}

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource EmisarWeb.Endpoint.url() <> "/api/mcp/rpc"

  # `satisfies_mfa` is opt-in — trusting someone else's second factor is a claim
  # the operator makes deliberately — so these MFA-exemption cases say so.
  defp enabled_provider(account),
    do: Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)

  defp require_sso!(account),
    do: Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

  defp require_mfa!(account),
    do: Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

  # A browser signed in to `member`'s workspace through `identity`'s provider.
  defp sso_session(member, identity) do
    log_in_member(build_conn(), member,
      auth_method: :sso,
      user_identity_id: identity.id,
      mfa: true
    )
  end

  defp identity_for(provider, member),
    do: Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: member)

  defp register_client! do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => "Claude", "redirect_uris" => [@redirect]})

    client
  end

  defp code_challenge do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
  end

  defp authorize_params(client, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => code_challenge(),
        "code_challenge_method" => "S256",
        "scope" => "mcp offline_access",
        "state" => "xyz",
        "resource" => @resource
      },
      overrides
    )
  end

  describe "GET /app/:account/audit/download" do
    test "a magic-link session in a require_sso account is bounced, never handed the CSV", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      _ = enabled_provider(account)
      require_sso!(account)

      token = session_token(conn, account)
      conn = get(conn, ~p"/app/#{account}/audit/download")

      # The workspace gate drops the session the policy refuses and sends the
      # browser to the workspace's sign-in; no CSV body is streamed.
      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
      refute get_session(conn, :sessions)
      assert Auth.fetch_session_by_token(token, account.id) == {:error, :not_found}
    end

    test "a non-enrolled member of a require_mfa account is funnelled to MFA setup", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)
      require_mfa!(account)

      conn = get(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) == ~p"/app/#{account}/mfa_setup"
    end

    test "an SSO-compliant session for the account still downloads the CSV", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = enabled_provider(account)
      require_sso!(account)
      identity = identity_for(provider, owner)

      {:ok, _} =
        Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "alice")

      conn =
        get(
          sso_session(owner, identity),
          ~p"/app/#{account}/audit/download?event_type=user.invited"
        )

      assert response_content_type(conn, :csv)
      assert response(conn, 200) =~ "alice"
    end

    test "another workspace's SSO session earns nothing here", %{conn: conn} do
      # A session is authority only inside its own workspace: the same person's
      # SSO session in another workspace never reaches THIS workspace's page, and
      # its token presented under this workspace is refused.
      {_conn, owner, account} = register_and_log_in(conn)
      require_mfa!(account)

      other = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(other, "team")
      other_provider = enabled_provider(other)

      other_member =
        Fixtures.Memberships.create_membership(account_id: other.id, email: owner.email)

      foreign = sso_session(other_member, identity_for(other_provider, other_member))

      refused = get(foreign, ~p"/app/#{account}/audit/download")
      assert redirected_to(refused) == ~p"/app/#{account}/sign_in"

      forged =
        build_conn()
        |> init_test_session(%{sessions: [{account.id, session_token(foreign, other)}]})
        |> get(~p"/app/#{account}/audit/download")

      assert redirected_to(forged) == ~p"/app/#{account}/sign_in"
    end

    test "an SSO session whose provider satisfies MFA FOR THIS account stays exempt", %{
      conn: conn
    } do
      # The account-scoped positive: an MFA-satisfying SSO identity that DOES
      # belong to this account keeps its exemption — the fix narrows the hole
      # without breaking the legitimate case.
      {_conn, owner, account} = register_and_log_in(conn)
      require_mfa!(account)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = enabled_provider(account)
      identity = identity_for(provider, owner)

      {:ok, _} =
        Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "alice")

      conn =
        get(
          sso_session(owner, identity),
          ~p"/app/#{account}/audit/download?event_type=user.invited"
        )

      assert response_content_type(conn, :csv)
    end
  end

  describe "GET /oauth/authorize — the consent RENDER is not compliance-gated (the mint is)" do
    test "a magic-link session in a require_sso account still reaches the consent screen", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
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
      {conn, owner, session_account} = register_and_log_in(conn)

      chosen = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(chosen, "team")
      _ = enabled_provider(chosen)
      require_sso!(chosen)

      # Owner in the chosen workspace, signed in there by email — so WITHOUT the
      # compliance guard the mint would succeed; the guard is what blocks.
      chosen_owner =
        Fixtures.Memberships.create_membership(
          account_id: chosen.id,
          email: owner.email,
          role: "owner"
        )

      conn = log_in_member(conn, chosen_owner)
      assert session_token(conn, session_account)
      client = register_client!()

      params = authorize_params(client, %{"account_id" => chosen.id, "decision" => "approve"})
      conn = post(conn, ~p"/oauth/authorize", params)

      assert html_response(conn, 400) =~ "single sign-on"
      refute Repo.one(Emisar.ApiKeys.ApiKey)
      refute Repo.one(OAuth.AuthorizationCode)
    end

    test "approving a require_mfa account without an enrolled factor mints nothing", %{conn: conn} do
      {conn, owner, session_account} = register_and_log_in(conn)

      chosen = Fixtures.Accounts.create_account()
      require_mfa!(chosen)

      chosen_owner =
        Fixtures.Memberships.create_membership(
          account_id: chosen.id,
          email: owner.email,
          role: "owner"
        )

      conn = log_in_member(conn, chosen_owner)
      assert session_token(conn, session_account)
      client = register_client!()

      params = authorize_params(client, %{"account_id" => chosen.id, "decision" => "approve"})
      conn = post(conn, ~p"/oauth/authorize", params)

      html = html_response(conn, 400)
      assert html =~ "multi-factor authentication"
      assert html =~ "set up or verify MFA for this browser"
      refute Repo.one(Emisar.ApiKeys.ApiKey)
      refute Repo.one(OAuth.AuthorizationCode)
    end

    test "a browser also signed in to a require_sso workspace can still grant a NON-enforcing one",
         %{conn: conn} do
      # Regression guard: enforcement is on the CHOSEN workspace, not on any other
      # session in the browser.
      {conn, owner, session_account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(session_account, "team")
      _ = enabled_provider(session_account)
      require_sso!(session_account)

      grantee = Fixtures.Accounts.create_account()

      grantee_owner =
        Fixtures.Memberships.create_membership(
          account_id: grantee.id,
          email: owner.email,
          role: "owner"
        )

      conn = log_in_member(conn, grantee_owner)
      client = register_client!()

      params = authorize_params(client, %{"account_id" => grantee.id, "decision" => "approve"})
      conn = post(conn, ~p"/oauth/authorize", params)

      assert redirected_to(conn, 302) =~ "code="
      assert Repo.one(Emisar.ApiKeys.ApiKey).account_id == grantee.id
    end
  end

  describe "a session require_sso no longer accepts" do
    test "is dropped once and lands on the workspace sign-in, which renders (no loop)", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = enabled_provider(account)
      require_sso!(account)
      token = session_token(conn, account)

      dropped = get(conn, ~p"/app/#{account}")
      assert redirected_to(dropped) == ~p"/app/#{account}/sign_in"
      refute get_session(dropped, :sessions)
      assert Auth.fetch_session_by_token(token, account.id) == {:error, :not_found}

      page = dropped |> recycle() |> get(~p"/app/#{account}/sign_in")
      assert html_response(page, 200) =~ ~p"/sign_in/sso/#{provider.id}"
    end
  end
end
