defmodule EmisarWeb.DashboardLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app")
    end

    test "logs out and redirects a fully-suspended user", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn)

      # Suspend the user's only membership: the session can no longer resolve
      # an account, and all-suspended means access is revoked (not onboarding),
      # so the auth pipeline signs them out with a flash.
      {1, _} =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_user_id(user.id)
        |> Emisar.Repo.update_all(set: [disabled_at: DateTime.utc_now()])

      assert {:error, {:redirect, %{to: "/sign_in", flash: %{"error" => message}}}} =
               live(conn, ~p"/app")

      assert message =~ "suspended"
    end

    test "redirects a logged-in user with no account to onboarding", %{conn: conn} do
      # A bare user (no membership at all) isn't locked out — they're sent to
      # onboarding to create their first account.
      conn = log_in_user(conn, Emisar.Fixtures.user_fixture())

      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, ~p"/app")
    end

    test "unconfirmed users see the verify-email banner and can resend", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn)
      # register_and_log_in confirms by default — simulate the unverified state.
      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: nil) |> Emisar.Repo.update()

      {:ok, lv, html} = live(conn, ~p"/app")
      assert html =~ "Verify your email"
      assert html =~ "Resend email"

      # The button is wired to the global :email_confirmation on_mount hook,
      # not to DashboardLive — clicking it still re-sends from any page.
      html = lv |> element("button", "Resend email") |> render_click()
      assert html =~ "Confirmation email sent"
    end

    test "confirmed users see no verify-email banner", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app")
      refute html =~ "Verify your email"
    end

    test "fresh accounts see the onboarding wizard with both checklist cards",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app")

      # Two onboarding cards — runner + LLM — sit at the top of the
      # dashboard as a wizard checklist. The runner card links to
      # /app/runners/install where the actual install command lives.
      assert html =~ "Connect a runner"
      assert html =~ "Connect an LLM"

      # No auto-minted install key — the dashboard doesn't mint
      # anymore. The runners/install page mints when the operator
      # navigates into it.
      assert Emisar.Repo.all(Emisar.Runners.AuthKey) == []
    end

    test "renders the populated dashboard once a runner exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _agent} =
        Emisar.Runners.create_runner(
          %{
            "name" => "runner-1",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app")
      assert html =~ "Runners online"
      assert html =~ "Recent runs"
      # The runner-onboarding card disappears once a runner exists.
      refute html =~ "Connect a runner"
      # LLM onboarding card still shows — no API key was minted in
      # this test.
      assert html =~ "Connect an LLM"
      # A runner with nothing dispatched yet gets the dispatch nudge.
      assert html =~ "Dispatch your first action"
      # No runs yet, so the rose failures panel stays hidden.
      refute html =~ "Recent failures"
    end

    test "the dispatch nudge appears with a runner-but-no-runs and clears after the first run",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app")
      assert html =~ "Dispatch your first action"
      # Deep-linked to the runner's own catalog, not the runners list.
      assert html =~ ~p"/app/runners/#{runner.id}"

      {:ok, _run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          args: %{},
          reason: "first run",
          source: "operator"
        })

      {:ok, _lv2, html2} = live(conn, ~p"/app")
      refute html2 =~ "Dispatch your first action"
    end

    test "a failed run surfaces the Recent failures panel linking to the run", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      Emisar.Fixtures.policy_fixture(account_id: account.id)

      {:ok, :running, run} =
        Emisar.Runs.dispatch_run(
          %{
            account_id: account.id,
            runner_id: runner.id,
            action_id: "linux.uptime",
            args: %{},
            reason: "test",
            source: "operator"
          },
          subject
        )

      {:ok, _} = Emisar.Runs.mark_finished(run, %{"status" => "failed", "duration_ms" => 5})

      {:ok, _lv, html} = live(conn, ~p"/app")

      # The rose failures panel only renders when there's a failed run — its
      # title + a deep link to the run prove the operator can act on it.
      assert html =~ "Recent failures"
      assert html =~ ~p"/app/runs/#{run.id}"
    end

    test "account broadcasts schedule a debounced stats reload", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, html} = live(conn, ~p"/app")
      assert html =~ "Connect a runner"

      # A runner registers elsewhere; the dashboard hears the account
      # broadcast (2-tuple) or a presence_diff and ARMS a debounced reload
      # rather than re-querying per message. The reload fires on the
      # :reload_dashboard timer — inject it directly to stand in for the timer.
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      send(lv.pid, {:runner_updated, runner})
      send(lv.pid, :reload_dashboard)
      refute render(lv) =~ "Connect a runner"

      send(lv.pid, %{event: "presence_diff"})
      send(lv.pid, :reload_dashboard)
      assert render(lv) =~ "Runners online"

      # Unrelated message shapes are ignored, never a crash.
      send(lv.pid, :stray_message)
      assert render(lv) =~ "Runners online"
    end
  end
end
