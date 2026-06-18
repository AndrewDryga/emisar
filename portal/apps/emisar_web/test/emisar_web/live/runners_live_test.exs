defmodule EmisarWeb.RunnersLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runners" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/runners")
    end

    test "shows the empty state when no runners are registered", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")
      assert html =~ "No runners yet"
      assert html =~ "Open install wizard"
    end

    test "the dead/pre-connect empty render shows a loading placeholder, not the pitch",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # A plain GET is the disconnected render — connected?/1 is false, so the
      # onboarding pitch is deferred behind a loading placeholder.
      html = conn |> get(~p"/app/#{account}/runners") |> html_response(200)
      assert html =~ "Loading"
      refute html =~ "No runners yet"
    end

    test "lists runners grouped by their `group` field", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _} =
        Emisar.Runners.create_runner(%{"name" => "a1", "group" => "cassandra-us-east1"}, subject)

      {:ok, _} =
        Emisar.Runners.create_runner(%{"name" => "a2", "group" => "cassandra-us-east1"}, subject)

      {:ok, _} =
        Emisar.Runners.create_runner(%{"name" => "b1", "group" => "postgres-eu-west1"}, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")
      assert html =~ "cassandra-us-east1"
      assert html =~ "postgres-eu-west1"
      assert html =~ "a1"
      assert html =~ "b1"
    end

    test "an enforcing runner shows a Signed-only chip on the index", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      Emisar.Fixtures.runner_fixture(
        account_id: account.id,
        name: "hardened",
        enforce_signatures: true
      )

      Emisar.Fixtures.runner_fixture(account_id: account.id, name: "plain")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      assert html =~ "Signed-only"
      assert html =~ "hardened"
      assert html =~ "plain"
    end

    test "an offline runner's 'last seen' heartbeat renders through <.local_time>", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # An offline runner with connect history → the "last seen <time>" branch
      # (not "just connected", which needs live presence). Stamping the column
      # without tracking presence keeps it offline.
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: false)

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

    test "the fleet health strip summarizes the whole account's runner states", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: true)
      disabled = Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: true)
      {:ok, _} = Emisar.Runners.disable_runner(disabled, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      # The strip names each state (Offline always shows, even at 0). The
      # whole-account total is NOT repeated here — it lives in the group
      # header(s) below, so it's not duplicated above and below the table.
      assert html =~ "Online"
      assert html =~ "Offline"
      assert html =~ "Disabled"
    end
  end

  describe "GET /app/runners/install" do
    test "always renders the install wizard with a pre-minted command",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      # Pre-existing runner shouldn't bypass the wizard — the user can
      # add a second runner the same way as the first.
      {:ok, _} =
        Emisar.Runners.create_runner(
          %{
            "name" => "existing",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")
      assert html =~ "Install a runner"
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
    end

    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} =
               live(conn, ~p"/app/anon/runners/install")
    end
  end

  describe "GET /app/runners/:id" do
    test "404-redirects when the runner does not belong to the account", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      dest = ~p"/app/#{account}/runners"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/runners/#{Ecto.UUID.generate()}")
    end

    test "renders the runner detail page", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, runner} =
        Emisar.Runners.create_runner(
          %{
            "name" => "my-runner",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")
      assert html =~ "my-runner"
      assert html =~ "Advertised actions"
    end
  end

  describe "fleet-offline nav alert (Option B)" do
    test "shows the 'All runners offline' nav alert when the whole fleet is offline", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      _runner = Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: false)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      # The runners page has no all-offline banner, so this text is the nav badge.
      assert html =~ "All runners offline"
    end

    test "no nav alert when at least one runner is online", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      _runner = Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: true)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners")

      refute html =~ "All runners offline"
    end
  end
end
