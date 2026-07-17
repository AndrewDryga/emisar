defmodule EmisarWeb.RunnersLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runners

  describe "GET /app/runners" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/runners")
    end

    test "an empty fleet drops straight into the inline install wizard", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runners")

      # No runners yet → the empty state IS the installer, one-liner pre-minted,
      # so a first-time operator connects a host with no detour to a separate page.
      assert html =~ "Run this on the host"
      assert html =~ "curl -sSL"
      assert html =~ "EMISAR_AUTH_KEY=emkey-auth-"
      assert has_element?(lv, "#runner-install-command")
      assert html =~ "min-h-9"
      refute html =~ "overflow-x-auto"
      # The redundant "Connect a runner" header button is dropped while the wizard shows.
      refute has_element?(lv, "a", "Connect a runner")
    end

    test "the fleet's sub-features ride the title row — Enrollment keys next to Connect a runner",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      assert html =~ "Connect a runner"
      assert html =~ ~p"/app/#{account}/runners/keys"
    end

    test "the dead/pre-connect empty render shows a loading placeholder, not the wizard",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # A plain GET is the disconnected render — connected?/1 is false, so the
      # installer (and the live credential it mints) is deferred behind a loading
      # placeholder; nothing is minted until the socket confirms an empty fleet.
      html = conn |> get(~p"/app/#{account}/runners") |> html_response(200)
      assert html =~ "Loading"
      refute html =~ "curl -sSL"
    end

    test "lists runners grouped by their `group` field", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "a1",
        group: "cassandra-us-east1"
      )

      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "a2",
        group: "cassandra-us-east1"
      )

      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "b1",
        group: "postgres-eu-west1"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")
      assert html =~ "cassandra-us-east1"
      assert html =~ "postgres-eu-west1"
      assert html =~ "a1"
      assert html =~ "b1"
    end

    test "an enforcing runner shows a Signed-only chip on the index", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "hardened",
        enforce_signatures: true
      )

      Fixtures.Runners.create_runner(account_id: account.id, name: "plain")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      assert html =~ "signed-only"
      assert html =~ "hardened"
      assert html =~ "plain"
      # A mixed fleet (one unsigned) must NOT show the all-fleet notice.
      refute html =~ "Fleet is signed-only"
    end

    test "shows the fleet signed-only notice when every active runner enforces", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id, name: "a", enforce_signatures: true)
      Fixtures.Runners.create_runner(account_id: account.id, name: "b", enforce_signatures: true)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")
      assert html =~ "Fleet is signed-only"
    end

    test "an offline runner's 'last seen' heartbeat renders through <.local_time>", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # An offline runner with connect history → the "last seen <time>" branch
      # (not "just connected", which needs live presence). Stamping the column
      # without tracking presence keeps it offline.
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      runner
      |> Ecto.Changeset.change(last_connected_at: DateTime.utc_now())
      |> Emisar.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      # Hook-driven, viewer-local <time> like the rest of the app…
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-format="relative")
      # …and the mid-sentence space survives (the {" "} guards): "last seen
      # <time>" never abuts, and the "·" separator keeps its space before the
      # composed status ("· last seen", not "·last seen").
      assert html =~ ~r/last seen\s<time/
      refute html =~ ~r/last seen<time/
      assert html =~ ~r/·\slast seen/
    end

    # the list is scoped to the caller's account via
    # `for_subject/2`: account A's operator sees A's runners and never B's, even
    # though both exist. (The slug gate's foreign-account 404 is covered in
    # account_slug_authz_test; this asserts the in-account data scoping.)
    test "cross-account — A's operator sees only A's runners, never B's", %{conn: conn} do
      {conn, _user, account_a} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account_a.id, name: "alpha-runner")

      account_b = Fixtures.Accounts.create_account()
      Fixtures.Runners.create_runner(account_id: account_b.id, name: "bravo-runner")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account_a}/runners")

      assert html =~ "alpha-runner"
      refute html =~ "bravo-runner"
    end

    # a viewer holds `view_runners`, so the list page
    # renders for them (it's not manage-gated). The "Connect a runner" affordance
    # is a plain link to the install wizard, present on the page header.
    test "a viewer can view the runners list; install affordances are issue-tier", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id, name: "viewable-runner")

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runners")

      assert html =~ "viewable-runner"
      # "Connect a runner" points at a mint the viewer can't perform — hidden
      # (§4), like the Enrollment keys door.
      refute has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/runners/install"}']",
               "Connect a runner"
             )
    end

    # a hand-edited page cursor makes the runner list read
    # return {:error, …} with non-empty params; `load/1` retries once with clean
    # params (first page) rather than recursing forever or rendering the
    # load-error/empty state. With a runner present, the retry shows it.
    test "a bad cursor in the URL falls back to the first page, not a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id, name: "still-listed")

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/runners?page=garbage-cursor")

      assert html =~ "still-listed"
      # The retry rendered the real list, not the danger load-error state.
      refute html =~ "Couldn't load your fleet"
    end

    # the list ROWS are scope-filtered to a
    # per-membership runner ACL (operators may have one): an operator scoped to one
    # runner sees only that row and never the out-of-scope runner (T12). But the
    # group sidebar + fleet-health strip are deliberately NOT scope-filtered —
    # they're whole-account source-of-truth, so their counts include both runners
    # and can exceed the visible rows (T09 — `list_group_summaries` takes only the
    # subject, no `membership_id`).
    test "operator scope filters list rows but not the group/fleet counts", %{conn: conn} do
      {_owner_conn, owner, account} = register_and_log_in(conn)

      in_scope =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "in-scope-runner",
          group: "shared-group"
        )

      _out_of_scope =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "out-of-scope-runner",
          group: "shared-group"
        )

      operator = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      # Scope the operator to just the in-scope runner.
      {:ok, :ok} =
        Emisar.Runners.replace_runner_scopes(
          membership,
          [{"runner", in_scope.id}],
          Fixtures.Subjects.subject_for(owner, account)
        )

      {:ok, _lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/runners")

      # Only the in-scope runner appears as a list row…
      assert html =~ "in-scope-runner"
      refute html =~ "out-of-scope-runner"
      # …but the group header count is whole-account (both runners), so it can
      # exceed the one visible row — intentional source-of-truth behaviour.
      assert html =~ "2 runners total"
    end

    test "the fleet health strip summarizes the whole account's runner states", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      disabled = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, _} = Emisar.Runners.disable_runner(disabled, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      # The naked posture line counts each state; healthy-at-zero states are
      # ABSENT (offline/pending/disabled only render when > 0 — silence is the
      # confirmation). The whole-account total is NOT repeated here — it lives
      # in the group header(s) below.
      assert html =~ "1 connected"
      refute html =~ "offline"
      assert html =~ "1 disabled"
    end
  end

  describe "GET /app/runners/install" do
    test "always renders the install wizard with a pre-minted command",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Pre-existing runner shouldn't bypass the wizard — the user can
      # add a second runner the same way as the first.
      Fixtures.Runners.create_runner(account_id: account.id, name: "existing")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")
      assert html =~ "Connect a runner"
      assert html =~ "Connect a runner"
      assert html =~ "curl -sSL"
      assert html =~ "EMISAR_AUTH_KEY=emkey-auth-"

      # The command embeds a live root-capable credential — the wizard must
      # say so (won't reshow, treat like a password) and let the operator
      # read the script before running it, not just on the marketing page.
      assert html =~ "Live credential"
      assert html =~ "Treat it like a password"
      assert html =~ "read it first"
      assert html =~ ~s(href="/install.sh")
    end

    test "reveals a troubleshooting checklist if no runner joins in time", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runners/install")
      # Hidden during the grace period — only the "waiting" pulse shows.
      refute html =~ "Not seeing it yet?"

      # The real watchdog is a ~35s Process.send_after; fire its message
      # directly so the operator isn't left staring at an animated dot when
      # the key, the firewall, or a non-systemd host is the problem.
      send(lv.pid, :reveal_troubleshooting)
      html = render(lv)
      assert html =~ "Not seeing it yet?"
      assert html =~ "truncated on paste"
      assert html =~ "journalctl -u emisar -f"
      # The overdue escalation is the ONE amber state on the page.
      assert html =~ "bg-amber-300/40"
    end

    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} =
               live(conn, ~p"/app/anon/runners/install")
    end
  end

  describe "GET /app/runners/:id" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "404-redirects when the runner does not belong to the account", %{
      conn: conn,
      account: account
    } do
      dest = ~p"/app/#{account}/runners"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/runners/#{Ecto.UUID.generate()}")
    end

    test "renders the runner detail page", %{conn: conn, account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "my-runner")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")
      assert html =~ "my-runner"
      assert html =~ "Advertised actions"
    end
  end

  describe "fleet-offline nav alert (Option B)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "shows the 'All runners offline' nav alert when the whole fleet is offline", %{
      conn: conn,
      account: account
    } do
      _runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      # The runners page has no all-offline banner, so this text is the nav badge.
      assert html =~ "All runners offline"
    end

    test "no nav alert when at least one runner is online", %{conn: conn, account: account} do
      _runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      refute html =~ "All runners offline"
    end
  end

  # test.exs policy: < 0.0.1 unsupported, [0.0.1, 0.1.0) outdated, >= 0.1.0 supported.
  describe "stale-version chip" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "a below-minimum runner shows an 'unsupported' chip", %{conn: conn, account: account} do
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "old",
        runner_version: "0.0.0"
      )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runners")
      assert html =~ "unsupported"
      assert html =~ "Runner update required"
      assert html =~ "/install.sh | sudo bash"
      assert has_element?(lv, "#runner-upgrade-command + button", "Copy")
      assert has_element?(lv, "#fleet-attention.mb-10.space-y-6")
      assert text_position(html, "Runner update required") < text_position(html, "1 connected")
    end

    test "a below-recommended runner shows an 'outdated' chip", %{conn: conn, account: account} do
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "stale",
        runner_version: "0.0.5"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")
      assert html =~ "outdated"
      assert html =~ "Runner update available"
      assert html =~ "/install.sh | sudo bash"
    end

    test "a current runner shows no staleness chip", %{conn: conn, account: account} do
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "fresh",
        runner_version: "1.0.0"
      )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runners")
      refute html =~ "unsupported"
      refute html =~ "outdated"
      refute html =~ "/install.sh | sudo bash"
      refute has_element?(lv, "#fleet-attention")
    end

    test "the same runner clears its upgrade prompt after reconnecting on the current binary",
         %{conn: conn, account: account} do
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "upgrading",
          runner_version: "0.0.0"
        )

      {:ok, _lv, stale_html} = live(conn, ~p"/app/#{account}/runners")
      assert stale_html =~ "Runner update required"

      assert {:ok, _runner} = Runners.apply_state(runner, %{"version" => "1.0.0"})

      {:ok, _lv, current_html} = live(conn, ~p"/app/#{account}/runners")
      refute current_html =~ "Runner update required"
      refute current_html =~ "outdated"
      refute current_html =~ "unsupported"
    end
  end

  defp text_position(html, text) do
    {position, _length} = :binary.match(html, text)
    position
  end
end
