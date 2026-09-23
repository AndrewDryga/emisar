defmodule EmisarWeb.SSOSessionStepUpControllerTest do
  @moduledoc "Real session/controller transactions with canned, not live-verified, OIDC claims."
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Config, Repo, SSO}

  defmodule RecordingOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl true
    def begin_authorization(_provider, opts) do
      send(self(), {:oidc_begin, opts})
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    @impl true
    def verify_callback(_provider, params, stash) do
      send(self(), {:oidc_callback, stash})

      if params["error"],
        do: {:error, :access_denied},
        else: {:ok, %{identifier: params["sub"], claims: %{"sub" => params["sub"]}}}
    end
  end

  setup %{conn: conn} do
    Config.put_override(:emisar, :sso_oidc_impl, RecordingOIDC)
    account = Fixtures.Accounts.create_account(plan: "enterprise")
    sibling = Fixtures.Accounts.create_account(name: "Independent workspace")
    user = Fixtures.Users.create_user()

    member =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: :viewer
      )

    Fixtures.Memberships.create_membership(
      account_id: sibling.id,
      user_id: user.id,
      role: :viewer
    )

    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id
      )

    conn = log_in_user(conn, user)
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

    %{
      conn: conn,
      account: account,
      sibling: sibling,
      user: user,
      member: member,
      provider: provider,
      identity: identity
    }
  end

  test "GET offers the linked provider with CSRF and never replaces the bearer", %{
    conn: conn,
    account: account,
    provider: provider
  } do
    raw = get_session(conn, :user_token)
    shown = get(conn, ~p"/app/#{account}/sso_required")
    html = html_response(shown, 200)
    assert html =~ "Continue with #{provider.name}"
    assert html =~ ~s|value="#{provider.id}"|
    assert html =~ "_csrf_token"
    assert html =~ ~s|action="/session/recover"|
    assert get_session(shown, :user_token) == raw
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)
    refute_received {:oidc_begin, _}
  end

  test "callback installs the one committed replacement and pins its destination", %{
    conn: conn,
    account: account,
    sibling: sibling,
    provider: provider,
    user: user,
    identity: identity
  } do
    raw = get_session(conn, :user_token)
    {:ok, donor} = Auth.fetch_session_by_token(raw)
    other = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    old_csrf = Plug.CSRFProtection.get_csrf_token()

    begun =
      conn
      |> put_session(:current_account_id, sibling.id)
      |> put_session(:user_return_to, ~p"/app/#{sibling}/settings/profile")
      |> put_session(:billing_intent, "stale-intent")
      |> put_session(:sso_login, %{provider_id: provider.id})
      |> put_session(:member_mfa_reset_sso, %{purpose: :reset})
      |> put_session(:sso_identity_link, %{purpose: :link})
      |> post(~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})

    assert redirected_to(begun) == "https://idp.test/auth"
    assert_received {:oidc_begin, options}
    assert options[:redirect_uri] == EmisarWeb.Endpoint.url() <> "/sign_in/sso/callback"
    refute get_session(begun, :sso_login)
    refute get_session(begun, :member_mfa_reset_sso)
    refute get_session(begun, :sso_identity_link)
    stash = get_session(begun, :sso_session_step_up)
    assert stash.redirect_uri == options[:redirect_uri]
    assert get_session(begun, :user_token) == raw

    completed = get(begun, ~p"/sign_in/sso/callback", %{"sub" => identity.provider_identifier})
    assert redirected_to(completed) == ~p"/app/#{account}"
    assert get_session(completed, :current_account_id) == account.id
    replacement_raw = get_session(completed, :user_token)
    refute replacement_raw == raw
    assert {:ok, replacement} = Auth.fetch_session_by_token(replacement_raw)
    assert replacement.personal_proved_at == donor.personal_proved_at
    assert replacement.personal_expires_at == donor.personal_expires_at

    assert {:ok, _} =
             Accounts.fetch_membership_by_account_id_or_slug(sibling.id, replacement)

    assert Auth.fetch_session_by_token(raw) == {:error, :not_found}
    assert {:ok, _session} = Auth.fetch_session_by_token(other)
    assert Repo.aggregate(Auth.UserToken.Query.by_context("session"), :count) == 2
    assert Plug.CSRFProtection.get_csrf_token() != old_csrf
    refute get_session(completed, :user_return_to)
    refute get_session(completed, :billing_intent)
    refute get_session(completed, :sso_session_step_up)

    assert get_session(completed, :live_socket_id) ==
             Auth.live_socket_topic_for_session(replacement_raw)

    assert html_response(get(completed, ~p"/app/#{account}"), 200) =~ account.name

    replay = get(begun, ~p"/sign_in/sso/callback", %{"sub" => identity.provider_identifier})
    assert redirected_to(replay) == ~p"/session/recover?reason=sso_incomplete"
    assert Repo.aggregate(Auth.UserToken.Query.by_context("session"), :count) == 2
  end

  @tag :step_up_review
  test "a late failed callback cannot overwrite the successful browser's replacement cookie", %{
    conn: conn,
    account: account,
    provider: provider,
    identity: identity
  } do
    begun = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    params = %{"sub" => identity.provider_identifier}
    winner = get(begun, ~p"/sign_in/sso/callback", params)
    replacement = get_session(winner, :user_token)
    loser = get(begun, ~p"/sign_in/sso/callback", params)

    # Apply only the late response's cookies, exactly as a browser does. Recycling
    # the loser would also copy its stale request cookies and hide the distinction.
    browser =
      Enum.reduce(get_resp_cookies(loser), recycle(winner), fn {key, %{value: value}}, acc ->
        Plug.Test.put_req_cookie(acc, key, value)
      end)

    reached = get(browser, ~p"/app/#{account}")
    assert html_response(reached, 200) =~ account.name
    assert get_session(reached, :user_token) == replacement
    refute Map.has_key?(get_resp_cookies(loser), "_emisar_web_key")
  end

  @tag :onboarding_grant
  test "retained personal proof creates and switches workspace while retiring its admin-approved SSO origin",
       %{
         conn: conn,
         user: user,
         account: account,
         sibling: sibling,
         provider: provider,
         identity: identity
       } do
    Accounts.Membership.Query.all()
    |> Accounts.Membership.Query.by_account_id(sibling.id)
    |> Accounts.Membership.Query.by_user_id(user.id)
    |> Repo.delete_all()

    identity |> Ecto.Changeset.change(created_by: :admin) |> Repo.update!()
    begun = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    completed = get(begun, ~p"/sign_in/sso/callback", %{"sub" => identity.provider_identifier})
    raw = get_session(completed, :user_token)
    {:ok, session} = Auth.fetch_session_by_token(raw)
    assert session.auth_method == :sso
    assert get_session(completed, :live_socket_id) == Auth.live_socket_topic_for_session(raw)

    {:ok, view, _html} = live(completed, ~p"/onboarding")

    submitted =
      view
      |> form("#onboarding_form", account: %{name: "Independent Personal Workspace"})
      |> render_submit()

    assert submitted =~ "phx-trigger-action"

    assert Auth.session_grant_account_ids(session.id) == [account.id]
    topic = Auth.live_socket_topic_for_session(raw)
    EmisarWeb.Endpoint.subscribe(topic)

    switched =
      post(completed, ~p"/onboarding", account: %{name: "Independent Personal Workspace"})

    assert [created_id] = Auth.session_grant_account_ids(session.id) -- [account.id]
    assert get_session(switched, :current_account_id) == created_id
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}

    assert html_response(get(switched, redirected_to(switched)), 200) =~
             "Independent Personal Workspace"

    assert Repo.reload!(identity).deleted_at
    assert {:ok, retained} = Auth.fetch_session_by_token(raw)
    assert retained.personal_expires_at == session.personal_expires_at
  end

  test "provider cancellation preserves the donor and reaches a renderable recovery page", %{
    conn: conn,
    account: account,
    provider: provider
  } do
    raw = get_session(conn, :user_token)
    begun = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    cancelled = get(begun, ~p"/sign_in/sso/callback", %{"error" => "access_denied"})
    assert redirected_to(cancelled) == ~p"/session/recover?reason=sso_incomplete"
    assert get_session(cancelled, :user_token) == raw
    refute Map.has_key?(get_resp_cookies(cancelled), "_emisar_web_key")
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)
    html = html_response(get(cancelled, redirected_to(cancelled)), 200)
    assert html =~ "Choose how to continue"
    assert html =~ "Single sign-on was not completed"
    assert html =~ account.name
  end

  test "wrong identifier fails without linking or provisioning another person", %{
    conn: conn,
    account: account,
    provider: provider
  } do
    raw = get_session(conn, :user_token)
    begun = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    rejected = get(begun, ~p"/sign_in/sso/callback", %{"sub" => "another-person"})
    assert redirected_to(rejected) == ~p"/session/recover?reason=sso_incomplete"
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)
    assert Repo.aggregate(SSO.UserIdentity, :count) == 1
    assert Repo.aggregate(SSO.LinkRequest, :count) == 0
  end

  test "a foreign provider is rejected before provider work and leaves the browser intact", %{
    conn: conn,
    account: account
  } do
    foreign = Fixtures.SSO.create_identity_provider()
    raw = get_session(conn, :user_token)
    rejected = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => foreign.id})
    assert redirected_to(rejected) == ~p"/app/#{account}/sso_required"
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)
    refute_received {:oidc_begin, _}
    html = html_response(get(rejected, ~p"/app/#{account}/sso_required"), 200)
    assert html |> LazyHTML.from_document() |> LazyHTML.text() =~ "Couldn't start"
  end

  test "target revocation during the trip cannot recreate workspace access", %{
    conn: conn,
    account: account,
    provider: provider,
    member: member,
    identity: identity
  } do
    raw = get_session(conn, :user_token)
    begun = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

    owner_identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        user_id: owner.actor.id
      )

    owner =
      Fixtures.Subjects.subject_for(owner.actor, account,
        auth_method: :sso,
        user_identity_id: owner_identity.id
      )

    assert Accounts.end_all_sessions_for(member, owner) == :ok
    rejected = get(begun, ~p"/sign_in/sso/callback", %{"sub" => identity.provider_identifier})
    assert redirected_to(rejected) == ~p"/session/recover?reason=sso_incomplete"
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)
    refute_received {:oidc_callback, _}
    assert html_response(get(rejected, ~p"/session/recover"), 200) =~ "Independent workspace"
  end

  test "another browser cannot finish the initiating browser's stash", %{
    conn: conn,
    account: account,
    provider: provider,
    identity: identity,
    user: user
  } do
    begun = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})

    rejected =
      build_conn()
      |> log_in_user(user)
      |> put_session(:sso_session_step_up, get_session(begun, :sso_session_step_up))
      |> get(~p"/sign_in/sso/callback", %{"sub" => identity.provider_identifier})

    assert redirected_to(rejected) == ~p"/session/recover?reason=sso_incomplete"
    refute_received {:oidc_callback, _}

    assert {:ok, _} =
             Auth.fetch_session_by_token(get_session(begun, :user_token))

    assert {:ok, _} =
             Auth.fetch_session_by_token(get_session(rejected, :user_token))
  end

  for stash <- ["malformed", %{}, %{account_id: "not-a-uuid", purpose: :workspace_sso}] do
    @stash stash
    test "present invalid step-up #{inspect(stash)} never falls through to anonymous login", %{
      provider: provider
    } do
      rejected =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:sso_session_step_up, @stash)
        |> put_session(:sso_login, %{provider_id: provider.id})
        |> get(~p"/sign_in/sso/callback", %{"sub" => "would-be-jit-person"})

      assert redirected_to(rejected) == ~p"/session/recover?reason=sso_incomplete"
      refute Map.has_key?(get_resp_cookies(rejected), "_emisar_web_key")
      refute_received {:oidc_callback, _}
      assert html_response(get(rejected, ~p"/session/recover"), 200) =~ "Your session has ended"
    end
  end

  test "starting SSO requires CSRF even though it does not consume the current session", %{
    conn: conn,
    account: account,
    provider: provider
  } do
    conn = put_private(conn, :plug_skip_csrf_protection, false)

    assert_error_sent(403, fn ->
      post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    end)

    refute_received {:oidc_begin, _}
  end
end
