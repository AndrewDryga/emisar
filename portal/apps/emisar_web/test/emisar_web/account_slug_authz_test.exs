defmodule EmisarWeb.AccountSlugAuthzTest do
  @moduledoc """
  The workspace in `/app/:account_id_or_slug/...` comes from the URL, and only
  this browser's session for that workspace authenticates it (the plug for the
  dead render, the `:ensure_authenticated` on_mount for the live view). An
  unknown slug 404s; a real workspace without a live session here goes to that
  workspace's sign-in — never to another workspace's data. Bare `/app` picks
  among the signed-in workspaces.
  """
  use EmisarWeb.ConnCase, async: true

  describe "slug-scoped workspace routes" do
    test "a Member reaches its own workspace's pages, by slug or id", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)

      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
      # The slug also resolves by the workspace id (the API/SSO/redirect form).
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account.id}/runners")
    end

    test "shared workspace topics have one subscription per live socket", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      for path <- [
            ~p"/app/#{account}",
            ~p"/app/#{account}/approvals",
            ~p"/app/#{account}/runners",
            ~p"/app/#{account}/runners/install",
            ~p"/app/#{account}/settings/team",
            ~p"/app/#{account}/runners/#{runner.id}"
          ] do
        assert {:ok, view, _html} = live(conn, path)

        duplicates =
          Emisar.PubSub.Server
          |> Registry.keys(view.pid)
          |> Enum.frequencies()
          |> Enum.filter(fn {_topic, count} -> count > 1 end)

        assert duplicates == []
        assert "account:#{account.id}:team" in Registry.keys(Emisar.PubSub.Server, view.pid)
      end
    end

    for change <- [:role, :directory_pending, :removed] do
      test "a scope event remounts instead of accepting a #{change} Member", %{conn: conn} do
        {conn, owner, account} = register_and_log_in(conn)
        Fixtures.Memberships.force_role(owner, "admin")
        {:ok, view, _html} = live(conn, ~p"/app/#{account}/runs")

        case unquote(change) do
          :role ->
            Fixtures.Memberships.force_role(owner, "viewer")

          :directory_pending ->
            Fixtures.Memberships.mark_directory_authorization_pending(owner, 1)

          :removed ->
            Fixtures.Memberships.mark_membership_as_deleted(owner)
            # A new seat for the same address is another Member, not this one.
            Fixtures.Memberships.create_membership(
              account_id: account.id,
              email: owner.email,
              role: "admin"
            )
        end

        send(view.pid, {:list_changed, :team, "membership.runner_access_changed", owner.id})
        assert_redirect(view, ~p"/app/#{account}")
      end
    end

    test "a workspace without a session here goes to its sign-in; an unknown slug 404s", %{
      conn: conn
    } do
      {conn, _owner, _account} = register_and_log_in(conn)
      # A real, populated workspace this browser has no session for.
      {_conn_b, _owner_b, other} = register_and_log_in(build_conn())

      for path <- [
            ~p"/app/#{other}/runners",
            ~p"/app/#{other}/runs",
            # A deep link is no different: the gate runs on every request.
            ~p"/app/#{other}/audit/#{Ecto.UUID.generate()}"
          ] do
        refused = get(conn, path)
        assert redirected_to(refused) == ~p"/app/#{other}/sign_in"
      end

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{other}/runners")
      assert to == ~p"/app/#{other}/sign_in"

      assert_error_sent 404, fn -> get(conn, ~p"/app/no-such-team/runners") end
    end

    test "the same person's Member elsewhere needs its own sign-in there", %{conn: conn} do
      {conn, owner, _account} = register_and_log_in(conn)
      later = Fixtures.Accounts.create_account()

      later_member =
        Fixtures.Memberships.create_membership(account_id: later.id, email: owner.email)

      assert redirected_to(get(conn, ~p"/app/#{later}/runners")) == ~p"/app/#{later}/sign_in"

      assert {:ok, _lv, _html} =
               conn |> log_in_member(later_member) |> live(~p"/app/#{later}/runners")
    end

    test "an anonymous mount of a workspace page goes to that workspace's sign-in", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/runners")
      assert to == ~p"/app/#{account}/sign_in"
    end

    test "bare /app forwards to the only signed-in workspace", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)

      assert redirected_to(get(conn, ~p"/app")) == ~p"/app/#{account}"
    end

    test "a cross-slug live_patch 404s — the mounted subject can't drift workspaces", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)
      # B is signed in from the same browser, so only the guard stands between.
      {conn, _owner_b, account_b} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners")
      assert render_patch(lv, ~p"/app/#{account}/runners") =~ "Runners"

      # A patch swapping the URL's workspace without a remount keeps the A
      # subject — the handle_params guard raises NotFoundError (a 404), crashing
      # the view, rather than serve B's path under A's authorization.
      Process.flag(:trap_exit, true)

      assert {{%EmisarWeb.NotFoundError{}, _stacktrace}, _call} =
               catch_exit(render_patch(lv, ~p"/app/#{account_b}/runners"))
    end

    test "a same-workspace live_patch by the id form continues", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners")

      assert render_patch(lv, ~p"/app/#{account.id}/runners") =~ "Runners"
    end

    test "with two workspaces in the cookie, the URL picks the session and the subject", %{
      conn: conn
    } do
      {conn, owner_a, account_a} = register_and_log_in(conn)
      {conn, owner_b, account_b} = register_and_log_in(conn, %{account: %{name: "Bravo"}})

      {:ok, lv, html} = live(conn, ~p"/app/#{account_b}/runners")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_membership.id == owner_b.id
      assert assigns.current_subject.membership_id == owner_b.id
      refute assigns.current_membership.id == owner_a.id
      # Every workspace-scoped nav link is B's.
      assert html =~ "/app/#{account_b.slug}/"
      refute html =~ "/app/#{account_a.slug}/"
    end

    test "a suspended or removed Member's own slug goes back to sign-in on the next request",
         %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
      Fixtures.Memberships.suspend_membership(owner)

      assert redirected_to(get(conn, ~p"/app/#{account}/runners")) == ~p"/app/#{account}/sign_in"

      {conn, removed, removed_account} = register_and_log_in(build_conn())
      Fixtures.Memberships.mark_membership_as_deleted(removed)

      assert redirected_to(get(conn, ~p"/app/#{removed_account}/runners")) ==
               ~p"/app/#{removed_account}/sign_in"
    end
  end

  describe "slugless pages" do
    test "with no session they go to /sign_in and remember a GET destination", %{conn: conn} do
      conn = get(conn, ~p"/app")

      assert redirected_to(conn) == ~p"/sign_in"
      assert get_session(conn, :user_return_to) == ~p"/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "You must sign in"
    end

    test "a dead entry among several is pruned and /app forwards to the workspace left", %{
      conn: conn
    } do
      {conn, suspended, _suspended_account} = register_and_log_in(conn)
      {conn, _owner, live_account} = register_and_log_in(conn)
      Fixtures.Memberships.suspend_membership(suspended)

      conn = get(conn, ~p"/app")

      assert redirected_to(conn) == ~p"/app/#{live_account}"
      assert [{account_id, _token}] = get_session(conn, :sessions)
      assert account_id == live_account.id
    end
  end
end
