defmodule EmisarWeb.AccountSlugAuthzTest do
  @moduledoc """
  The account slug in `/app/:account_id_or_slug/...` is a cross-account authz
  input. Every authenticated mount resolves + authorizes it from the URL (the
  conn plug for the dead render, the `:ensure_account_slug` on_mount for the live
  view): a non-member or unknown slug 404s — indistinguishable, so a URL never
  confirms a tenant exists (404, never 403, no leak). Bare `/app` forwards to the
  user's account; a member's deep link opens.
  """
  use EmisarWeb.ConnCase, async: true

  describe "slug-scoped tenant routes" do
    test "a member reaches their own account's slugged pages", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
      # The slug also resolves by the account id (the API/SSO/redirect form).
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account.id}/runners")
    end

    test "a non-member's slug 404s — same as an unknown slug, so neither leaks", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)

      # A real, populated account the logged-in user has no membership in.
      other = Emisar.Fixtures.account_fixture()

      assert_error_sent 404, fn -> get(conn, ~p"/app/#{other}/runners") end
      assert_error_sent 404, fn -> get(conn, ~p"/app/no-such-team/runners") end
      # A deep link is no different — the gate runs on every mount, not just the index.
      assert_error_sent 404, fn -> get(conn, ~p"/app/#{other}/audit/#{Ecto.UUID.generate()}") end
    end

    test "a signed-out mount of a slug LV redirects to sign-in BEFORE slug resolution", %{
      conn: conn
    } do
      # closes AUTH-021-T06 — `:ensure_account_slug` is composed AFTER
      # `:ensure_authenticated`, so a signed-out visitor is bounced to /sign_in (with
      # a return_to) before the slug is ever resolved. The result is a sign-in
      # redirect, NOT the 404 a signed-in non-member would get — the gate order
      # means an anonymous user never reaches the tenant-existence check.
      account = Emisar.Fixtures.account_fixture()

      assert {:error, {:redirect, %{to: "/sign_in"}}} =
               live(conn, ~p"/app/#{account}/runners")
    end

    test "a member of account A cannot reach account B's slug (cross-account)", %{conn: conn} do
      {conn, _user, _account_a} = register_and_log_in(conn)

      # B belongs to someone else; A's member is not in it.
      {_conn_b, _user_b, account_b} = register_and_log_in(build_conn())

      assert_error_sent 404, fn -> get(conn, ~p"/app/#{account_b}/runs") end
    end

    test "bare /app forwards to the user's account slug", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      assert redirected_to(get(conn, ~p"/app")) == ~p"/app/#{account}"
    end

    test "a cross-slug live_patch 404s — the mounted subject can't drift tenants", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      # B belongs to someone else; A's member is not in it.
      {_conn_b, _user_b, account_b} = register_and_log_in(build_conn())

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners")

      # A same-account patch (e.g. a filter change) is unaffected by the guard.
      assert render_patch(lv, ~p"/app/#{account}/runners") =~ "Runners"

      # A patch swapping the URL's account ref without a remount keeps the
      # account-A subject — the handle_params guard raises NotFoundError (a 404),
      # crashing the view, rather than serve B's path under A's authorization.
      Process.flag(:trap_exit, true)

      assert {{%EmisarWeb.NotFoundError{}, _stacktrace}, _call} =
               catch_exit(render_patch(lv, ~p"/app/#{account_b}/runners"))
    end

    test "a same-account live_patch by the id form continues — the alternate ref matches", %{
      conn: conn
    } do
      # closes AUTH-032-T01 (id branch) — `ensure_slug_unchanged` accepts the ref
      # whether it's the account slug OR its id (`ref == account.id or
      # account.slug`). Mount by slug, patch to the id form of the SAME account:
      # the guard's `account.id` branch matches, so the patch continues, no 404.
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners")

      assert render_patch(lv, ~p"/app/#{account.id}/runners") =~ "Runners"
    end

    test "the subject is re-scoped to the URL account, not the session-pinned one", %{conn: conn} do
      # closes AUTH-021-T04 — the slug gate re-resolves the tenant from the URL on
      # every mount and OVERWRITES the session-pinned account/subject. A session
      # pinned to A but a URL for held B mounts under B; the URL is the tenant key,
      # the session pin is never trusted as authorization.
      {conn, user, account_a} = register_and_log_in(conn)

      account_b = Emisar.Fixtures.account_fixture(%{name: "Bravo Distinct Team"})
      _ = Emisar.Fixtures.membership_fixture(account_id: account_b.id, user_id: user.id)

      # Pin the session to A, then request B's slugged page.
      conn = put_session(conn, :current_account_id, account_a.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account_b}/runners")

      # current_account drives every slugged nav link, so the active tenant is B
      # (URL), not A (session pin): B's slug threads the sidebar nav, A's slug is
      # nowhere. (A surfaces in the workspace switcher by NAME + id, but never as
      # an /app/<slug> href — that's a POST switch, so its slug can't leak here.)
      assert html =~ "/app/#{account_b.slug}/"
      refute html =~ "/app/#{account_a.slug}/"
    end

    test "a suspended membership on the URL slug 404s", %{conn: conn} do
      # closes AUTH-021-T05 — `fetch_membership_by_account_id_or_slug` requires a
      # non-suspended membership (`not_disabled`), so once the member is suspended
      # their own slug 404s just like a stranger's: no redirect, no leak.
      {conn, user, account} = register_and_log_in(conn)

      {1, _} =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, user.id)
        |> Emisar.Repo.update_all(set: [disabled_at: DateTime.utc_now()])

      assert_error_sent 404, fn -> get(conn, ~p"/app/#{account}/runners") end
    end

    test "slug refs are re-authorized every request — revoking access mid-session 404s", %{
      conn: conn
    } do
      # closes AUTH-019-T10 — the gate runs on every request, not once at sign-in.
      # The first request to the member's own slug succeeds; after their
      # membership is revoked the very next request to the same URL 404s.
      {conn, user, account} = register_and_log_in(conn)

      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")

      # Revoke (soft-delete) the membership between the two requests.
      {1, _} =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, user.id)
        |> Emisar.Repo.update_all(set: [deleted_at: DateTime.utc_now()])

      # The session token still authenticates the user, but the slug gate
      # re-resolves membership on this request and finds none → 404.
      assert_error_sent 404, fn -> get(conn, ~p"/app/#{account}/runners") end
    end
  end

  describe "require_authenticated_user plug (non-slug branches)" do
    test "a no-membership user is redirected to onboarding (not locked out)", %{conn: conn} do
      # closes AUTH-019-T06 — the controller plug for the bare `/app` route, where
      # the ref is nil: a user with no membership at all isn't a 404 and isn't
      # logged out — they're steered to /onboarding to create their first
      # workspace. (The on_mount counterpart is covered in dashboard_live_test.)
      conn = log_in_user(conn, Emisar.Fixtures.user_fixture())

      conn = get(conn, ~p"/app")

      assert redirected_to(conn) == ~p"/onboarding"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "don't belong to any account"
    end

    test "a user whose every membership is suspended is force-logged-out", %{conn: conn} do
      # closes AUTH-019-T07 — when the ref is nil AND every membership is
      # suspended, the plug logs the session out with a flash rather than send the
      # user to onboarding (their access was revoked, not never-granted). (The
      # on_mount counterpart is covered in dashboard_live_test.)
      {conn, user, _account} = register_and_log_in(conn)

      {1, _} =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_user_id(user.id)
        |> Emisar.Repo.update_all(set: [disabled_at: DateTime.utc_now()])

      conn = get(conn, ~p"/app")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "suspended"
      refute get_session(conn, :user_token)
    end

    test "a session pinned to a now-suspended account is silently refreshed to the live primary",
         %{conn: conn} do
      # closes AUTH-019-T08 — the session caches the active account id. If that
      # membership is suspended out-of-band, `fetch_membership_for_session` falls
      # back to the user's latest live membership and `maybe_refresh_account_session`
      # OVERWRITES the dead session pointer with the resolved one — so subsequent
      # requests stop re-resolving against the corpse. The user isn't bounced; they
      # just land on the live account.
      {conn, user, suspended_account} = register_and_log_in(conn)

      # A second, later-joined account that stays live — the fallback target.
      live_account = Emisar.Fixtures.account_fixture(%{name: "Live Fallback Team"})
      _ = Emisar.Fixtures.membership_fixture(account_id: live_account.id, user_id: user.id)

      # Pin the session to the first account, then suspend that membership.
      conn = put_session(conn, :current_account_id, suspended_account.id)

      {1, _} =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(suspended_account.id, user.id)
        |> Emisar.Repo.update_all(set: [disabled_at: DateTime.utc_now()])

      conn = get(conn, ~p"/app")

      # Forwarded to the live account, and the stale pointer is rewritten to it.
      assert redirected_to(conn) == ~p"/app/#{live_account}"
      assert get_session(conn, :current_account_id) == live_account.id
    end
  end
end
