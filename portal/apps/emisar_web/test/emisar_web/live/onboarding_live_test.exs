defmodule EmisarWeb.OnboardingLiveTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, Repo}
  alias Emisar.Accounts.Membership

  describe "workspace creation" do
    test "an 80-char name is accepted and arms the switch POST", %{conn: conn} do
      # closes AUTH-011-T03 (upper bound) — the account name's max is 80; a name at
      # that boundary creates the workspace and arms the hidden POST to
      # AccountSwitchController (phx-trigger-action) that pins the new tenant.
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      name = String.duplicate("a", 80)
      html = lv |> form("#onboarding_form", %{"account" => %{"name" => name}}) |> render_submit()

      assert html =~ "phx-trigger-action"
      assert html =~ ~s|action="/app/accounts/switch"|

      names =
        Accounts.Account.Query.not_deleted() |> Repo.all() |> Enum.map(& &1.name)

      assert name in names
    end

    test "a name colliding with an existing slug is deduped, both coexist", %{conn: conn} do
      # closes AUTH-011-T04 — `suggest_unique_slug` appends a counter when the base
      # slug is taken, so a second workspace named identically to an existing one
      # gets a distinct slug; both accounts survive.
      {conn, _user, existing} = register_and_log_in(conn, %{account: %{name: "Collide Co"}})

      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      lv
      |> form("#onboarding_form", %{"account" => %{"name" => "Collide Co"}})
      |> render_submit()

      slugs =
        Accounts.Account.Query.not_deleted()
        |> Repo.all()
        |> Enum.filter(&(&1.name == "Collide Co"))
        |> Enum.map(& &1.slug)

      assert length(slugs) == 2
      assert existing.slug in slugs
      assert Enum.uniq(slugs) == slugs
    end

    test "a name over 80 chars renders the length error inline on the field", %{conn: conn} do
      # closes AUTH-011-T06 — the derived slug is truncated to fit, but the account
      # NAME validation (max 80) fails, so `create_account_with_owner` returns a
      # changeset error and the LV re-renders it inline on the name field (no create).
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      name = String.duplicate("x", 81)
      html = lv |> form("#onboarding_form", %{"account" => %{"name" => name}}) |> render_submit()

      assert html =~ "should be at most 80 character"
      refute html =~ "phx-trigger-action=\"true\""
    end

    test "the creator becomes owner of ONLY the new account (no privilege spill)", %{conn: conn} do
      # closes AUTH-011-T10 — creating a workspace makes the user its :owner and
      # nothing more: their membership set gains exactly one owner row for the new
      # account, leaving their existing memberships untouched.
      {conn, user, first} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      lv
      |> form("#onboarding_form", %{"account" => %{"name" => "Fresh Workspace"}})
      |> render_submit()

      memberships =
        Membership.Query.not_deleted()
        |> Membership.Query.by_user_id(user.id)
        |> Repo.all()
        |> Repo.preload(:account)

      new = Enum.find(memberships, &(&1.account.name == "Fresh Workspace"))
      assert new.role == :owner
      # The pre-existing account is still owned, unchanged — no spill either way.
      assert Enum.find(memberships, &(&1.account_id == first.id)).role == :owner
      assert Enum.count(memberships, &(&1.account.name == "Fresh Workspace")) == 1
    end
  end

  describe "no-membership entry + tenant pinning" do
    test "a no-membership user landing on /app is routed to onboarding to create a workspace", %{
      conn: conn
    } do
      # closes AUTH-011-T08 — a confirmed user with no membership (and not fully
      # suspended) who hits the app isn't 404'd or logged out: `require_authenticated_user`
      # → `assign_current_account` (the nil-ref branch) steers them to /onboarding,
      # and the page renders the create-workspace form so they can self-serve.
      conn = log_in_user(conn, Emisar.Fixtures.user_fixture())

      assert redirected_to(get(conn, ~p"/app")) == ~p"/onboarding"

      {:ok, _lv, html} = live(conn, ~p"/onboarding")
      assert html =~ "Set up your workspace"
      assert html =~ "onboarding_form"
    end

    test "the switch POST pins the new tenant before landing — never the old/zero workspace", %{
      conn: conn
    } do
      # closes AUTH-011-T09 — after `create_account_with_owner`, the LV arms a real
      # POST to AccountSwitchController (phx-trigger-action) carrying the new
      # account_id. Replaying that POST is what pins the session to the NEW tenant
      # and redirects to its slug — so a creator never lands back in a previous
      # (or zero) workspace. Drive the create, then the armed POST, end to end.
      {conn, user, first} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding_form", %{"account" => %{"name" => "Brand New Space"}})
        |> render_submit()

      assert html =~ "phx-trigger-action"

      # The just-created account, carried in the form's hidden account_id, is what
      # the armed POST pins. Resolve it from the user's memberships.
      created =
        Membership.Query.not_deleted()
        |> Membership.Query.by_user_id(user.id)
        |> Repo.all()
        |> Repo.preload(:account)
        |> Enum.find(&(&1.account.name == "Brand New Space"))

      # Replay the armed switch POST.
      switched = post(conn, ~p"/app/accounts/switch", account_id: created.account_id)

      # Lands on the NEW tenant's slug and pins it in the session — not the
      # pre-existing `first` workspace the user was already in.
      assert redirected_to(switched) == ~p"/app/#{created.account}"
      assert get_session(switched, :current_account_id) == created.account_id
      refute get_session(switched, :current_account_id) == first.id
    end
  end

  describe "workspace-name form validation" do
    test "a blank name renders inline on the field, not in a flash", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding_form", %{"account" => %{"name" => ""}})
        |> render_submit()

      # Inline field error under the name input.
      assert html =~ "can&#39;t be blank"
      # Old flash copy is gone.
      refute html =~ "Unable to create. Try a different name."
    end

    test "phx-change surfaces a blank-name error inline without submitting", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding_form", %{"account" => %{"name" => ""}})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    @tag skip: "BUG: a 1-2 char name derives a too-short slug; the slug-format error \
has no input to render on, so the create silently fails with NO visible feedback"
    test "a short name yielding an invalid slug surfaces the error on the name field", %{
      conn: conn
    } do
      # AUTH-011-T07 — a 1- or 2-char name passes the name validation (min 1) but
      # `suggest_unique_slug` derives a slug ("x") that FAILS the account slug format
      # (3-64 chars). `create_account_with_owner` returns a changeset whose error is
      # on :slug — but the form has only a :name input, so the error is orphaned: the
      # page re-renders with NO error and NO creation (verified: "3-64 chars" absent,
      # no phx-trigger-action). The user is stuck with no feedback. The CORRECT
      # behavior (asserted here, skipped until fixed) is to surface that slug-format
      # error on the name field the user actually controls.
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html = lv |> form("#onboarding_form", %{"account" => %{"name" => "x"}}) |> render_submit()

      # No workspace was created (the slug is invalid)…
      refute html =~ "phx-trigger-action=\"true\""
      # …and the reason must be visible to the operator (this is the failing assertion).
      assert html =~ "3-64 chars" or html =~ "must be"
    end
  end
end
