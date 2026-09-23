defmodule EmisarWeb.OnboardingLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Repo}
  alias Emisar.Accounts.Membership
  alias EmisarWeb.BillingIntent

  describe "workspace creation" do
    test "creation requires the rendered CSRF token", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      shown = get(conn, ~p"/onboarding")

      [csrf] =
        shown.resp_body
        |> LazyHTML.from_document()
        |> LazyHTML.query("meta[name='csrf-token']")
        |> LazyHTML.attribute("content")

      assert_error_sent(403, fn ->
        conn
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/onboarding", account: %{name: "Forged Create"})
      end)

      assert Repo.aggregate(Accounts.Account, :count) == 1

      created =
        shown
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/onboarding", account: %{name: "Proved Create"}, _csrf_token: csrf)

      assert redirected_to(created) == ~p"/app/proved-create"
    end

    test "an 80-char name arms HTTP submission without creating anything in the socket", %{
      conn: conn
    } do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")
      name = String.duplicate("a", 80)
      html = lv |> form("#onboarding_form", account: %{name: name}) |> render_submit()

      assert html =~ "phx-trigger-action"
      assert html =~ ~s(action="/onboarding")
      assert Repo.aggregate(Accounts.Account, :count) == 1

      created = post(conn, ~p"/onboarding", account: %{name: name})
      assert redirected_to(created) =~ "/app/"
      assert html_response(get(created, redirected_to(created)), 200) =~ name
    end

    test "SSO without personal proof reaches recovery without creating a workspace", %{conn: conn} do
      {_conn, user, account} = register_and_log_in(conn)
      Fixtures.Accounts.maybe_seed_plan(account, "team")
      provider = Fixtures.SSO.create_identity_provider(%{account_id: account.id, name: "Okta"})

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        })

      token =
        Fixtures.Auth.create_session_token!(user, :sso, DateTime.utc_now(), %{},
          user_identity_id: identity.id
        )

      sso_conn = build_conn() |> init_test_session(%{}) |> put_session(:user_token, token)
      before = Repo.aggregate(Accounts.Account, :count)

      assert redirected_to(get(sso_conn, ~p"/onboarding")) ==
               ~p"/session/recover?reason=personal_required"

      refused = post(sso_conn, ~p"/onboarding", account: %{name: "Second Workspace"})

      assert redirected_to(refused) == ~p"/session/recover?reason=personal_required"
      recovery = refused |> get(redirected_to(refused)) |> html_response(200)
      assert recovery =~ "Sign out and sign in by email to create a workspace"
      refute recovery =~ "Something went wrong"
      assert Repo.aggregate(Accounts.Account, :count) == before
      assert {:ok, _, _} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "anonymous and revoked browsers cannot create a workspace", %{conn: conn} do
      assert redirected_to(post(conn, ~p"/onboarding", account: %{name: "Anonymous"})) ==
               ~p"/sign_in"

      refute Repo.exists?(Accounts.Account)

      {conn, _user, _account} = register_and_log_in(build_conn())
      Auth.delete_session_token(get_session(conn, :user_token))

      assert redirected_to(post(conn, ~p"/onboarding", account: %{name: "Revoked"})) ==
               ~p"/sign_in"

      assert Repo.aggregate(Accounts.Account, :count) == 1
    end

    test "expired personal proof cannot create a workspace while its bearer survives", %{
      conn: conn
    } do
      {conn, _user, _account} = register_and_log_in(conn)
      raw = get_session(conn, :user_token)
      Fixtures.Auth.expire_session_independent_proofs!(raw)

      assert redirected_to(get(conn, ~p"/onboarding")) ==
               ~p"/session/recover?reason=personal_required"

      refused = post(conn, ~p"/onboarding", account: %{name: "Expired"})

      assert redirected_to(refused) == ~p"/session/recover?reason=personal_required"
      assert Repo.aggregate(Accounts.Account, :count) == 1
      assert {:ok, _, _} = Auth.fetch_user_and_token_by_session_token(raw)
    end

    test "a colliding slug is deduped and both workspaces coexist", %{conn: conn} do
      {conn, _user, existing} =
        register_and_log_in(conn, %{account: %{name: "Collide Co", slug: "collide-co"}})

      created = post(conn, ~p"/onboarding", account: %{name: "Collide Co"})
      assert redirected_to(created) =~ "/app/"

      slugs = Accounts.Account.Query.not_deleted() |> Repo.all() |> Enum.map(& &1.slug)
      assert length(slugs) == 2
      assert existing.slug in slugs
      assert Enum.uniq(slugs) == slugs
    end

    test "a transaction failure retains the name and plan with no partial account", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn)
      user |> Ecto.Changeset.change(email: "invalid-fixture-address") |> Repo.update!()
      token = BillingIntent.sign("team", :year)

      failed =
        post(conn, ~p"/onboarding", account: %{name: "Unsaved Workspace"}, billing_intent: token)

      html = html_response(failed, 422)

      assert html =~ "Couldn&#39;t create this workspace. Try again."
      assert html =~ ~s(value="Unsaved Workspace")
      assert html =~ ~s(name="billing_intent" value="#{token}")
      assert Repo.aggregate(Accounts.Account, :count) == 1
    end

    test "creates only the new owner seat and audits its switch, ignoring a supplied account", %{
      conn: conn
    } do
      {conn, user, first} = register_and_log_in(conn)
      foreign = Fixtures.Accounts.create_account()

      created =
        post(conn, ~p"/onboarding", account: %{name: "Fresh Workspace"}, account_id: foreign.id)

      memberships =
        Membership.Query.not_deleted()
        |> Membership.Query.by_user_id(user.id)
        |> Repo.all()
        |> Repo.preload(:account)

      new = Enum.find(memberships, &(&1.account.name == "Fresh Workspace"))
      assert new.role == :owner
      assert Enum.find(memberships, &(&1.account_id == first.id)).role == :owner
      assert length(memberships) == 2
      assert get_session(created, :current_account_id) == new.account_id
      assert redirected_to(created) == ~p"/app/#{new.account}"

      [event] =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_account_id(new.account_id)
        |> Repo.all()
        |> Enum.filter(&(&1.event_type == "session.account_switched"))

      assert {event.actor_kind, event.actor_id} == {"membership", new.id}
    end
  end

  describe "memberless entry and billing choice" do
    test "a memberless user can sign out without creating a workspace", %{conn: conn} do
      conn = log_in_user(conn, Fixtures.Users.create_user(confirmed?: false))
      token = get_session(conn, :user_token)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")
      assert has_element?(lv, "a[href='/sign_out'][data-method=delete]", "Sign out")

      signed_out = delete(conn, ~p"/sign_out")
      assert redirected_to(signed_out) == "/"
      refute get_session(signed_out, :user_token)
      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
      refute Repo.exists?(Membership)
    end

    test "a memberless browser reaches onboarding and opens its new workspace", %{conn: conn} do
      conn = log_in_user(conn, Fixtures.Users.create_user())
      assert redirected_to(get(conn, ~p"/app")) == ~p"/onboarding"
      {:ok, _lv, html} = live(conn, ~p"/onboarding")
      assert html =~ "Create your workspace"

      created = post(conn, ~p"/onboarding", account: %{name: "First Workspace"})
      assert redirected_to(created) == ~p"/app/first-workspace"
      assert html_response(get(created, redirected_to(created)), 200) =~ "First Workspace"
    end

    test "a Team choice survives creation and routes to the new workspace's Billing page", %{
      conn: conn
    } do
      token = BillingIntent.sign("team", :year)

      conn =
        conn |> log_in_user(Fixtures.Users.create_user()) |> put_session(:billing_intent, token)

      {:ok, _lv, html} = live(conn, ~p"/onboarding")
      assert html =~ "Selected plan"
      assert html =~ "Annual"
      assert html =~ ~s(name="billing_intent" value="#{token}")

      created =
        post(conn, ~p"/onboarding", account: %{name: "Annual Team Space"}, billing_intent: token)

      assert redirected_to(created) ==
               ~p"/app/annual-team-space/settings/billing?billing_intent=#{token}"

      assert get_session(created, :current_account_id)
      refute get_session(created, :billing_intent)
    end

    test "an invalid Team choice degrades to ordinary Free onboarding", %{conn: conn} do
      conn =
        conn
        |> log_in_user(Fixtures.Users.create_user())
        |> put_session(:billing_intent, "forged")

      {:ok, _lv, html} = live(conn, ~p"/onboarding")
      assert html =~ "Starts on the Free plan"
      refute html =~ "Selected plan"
      refute html =~ ~s(name="billing_intent")

      created =
        post(conn, ~p"/onboarding", account: %{name: "Free Workspace"}, billing_intent: "forged")

      assert redirected_to(created) == ~p"/app/free-workspace"
    end
  end

  describe "workspace-name validation" do
    setup %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      %{conn: conn}
    end

    test "HTTP rejection retains blank, short and long names and their field errors", %{
      conn: conn
    } do
      for {name, error} <- [
            {"", "can&#39;t be blank"},
            {"x", "3-64 chars"},
            {String.duplicate("x", 81), "should be at most 80 character"}
          ] do
        html = conn |> post(~p"/onboarding", account: %{name: name}) |> html_response(422)
        assert html =~ error
        assert html =~ ~s(value="#{name}")
        refute html =~ ~s(phx-trigger-action="true")
        assert Repo.aggregate(Accounts.Account, :count) == 1
      end
    end

    test "malformed form input is rejected without creating anything", %{conn: conn} do
      for params <- [%{}, %{"account" => "wrong"}, %{"account" => %{"name" => []}}] do
        assert html_response(post(conn, ~p"/onboarding", params), 422) =~ "can&#39;t be blank"
      end

      assert Repo.aggregate(Accounts.Account, :count) == 1
    end

    test "live change and submit show errors without writing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/onboarding")
      form = form(lv, "#onboarding_form", account: %{name: ""})
      assert render_change(form, %{"_target" => ["account", "name"]}) =~ "can&#39;t be blank"
      html = render_submit(form)
      assert html =~ "can&#39;t be blank"
      refute html =~ ~s(phx-trigger-action="true")
      assert Repo.aggregate(Accounts.Account, :count) == 1
    end
  end
end
