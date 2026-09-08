defmodule EmisarWeb.ConsoleRefreshPerformanceTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Accounts

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    %{conn: conn, user: user, account: account, runner: runner}
  end

  test "new runbook defers catalog work until connected and loads the fleet once", %{
    conn: conn,
    account: account
  } do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

    queries =
      capture_queries(self(), fn ->
        html = conn |> get(~p"/app/#{account}/runbooks/new") |> html_response(200)
        assert html =~ "Loading"
      end)

    refute Enum.any?(queries, &(&1 =~ ~r/FROM "(?:runners|runner_actions|pack_versions)"/))

    # Mount directly with a connected socket to isolate editor reads from the
    # shared authentication/navigation hooks; existing editor tests drive the
    # complete connected form, saving and trust-denial paths.
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}

    {:ok, view, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.loaded?
    assert Enum.any?(assigns.catalog.targets, &(&1.id == runner.id))

    socket =
      Phoenix.Component.assign(socket,
        current_subject: assigns.current_subject,
        live_action: :new
      )

    queries =
      capture_queries(self(), fn ->
        assert {:ok, _socket} = EmisarWeb.RunbookEditorLive.mount(%{}, %{}, socket)
      end)

    assert Enum.count(queries, &(&1 =~ ~r/SELECT r0\."id".*FROM "runners"/s)) == 1
  end

  test "a large Runs refresh estimates totals without scanning history", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    Emisar.Config.put_override(:emisar, :exact_count_ceiling, -1)
    run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id)
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/runs")

    queries =
      capture_queries(view.pid, fn ->
        send(view.pid, {:run_updated, run.id})
        send(view.pid, :reload_runs)
        render(view)
      end)

    assert :sys.get_state(view.pid).socket.assigns.metadata.count_kind == :estimated
    assert Enum.any?(queries, &String.starts_with?(&1, "EXPLAIN"))
    refute Enum.any?(queries, &(&1 =~ ~r/SELECT count\(.*action_runs/is))
  end

  test "own and unrelated heartbeats project connection state without SQL", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    for id <- [Ecto.UUID.generate(), runner.id] do
      assert capture_queries(view.pid, fn ->
               send(view.pid, heartbeat(id, 3))
               render(view)
             end) == []
    end

    projected = :sys.get_state(view.pid).socket.assigns.runner
    assert projected.online?
    assert projected.action_load == 3
    assert projected.last_heartbeat_at
  end

  test "badge bursts do no immediate SQL and refresh each family once", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/runs")
    run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id)
    request = Fixtures.Approvals.create_request(account_id: account.id, run_id: run.id)

    assert capture_queries(view.pid, fn ->
             for _ <- 1..20 do
               send(view.pid, {:approval_updated, request.id})
               send(view.pid, {:pack_trust_changed, account.id})
               send(view.pid, {:sso_link_requests_changed, account.id})
             end

             render(view)
           end) == []

    assert :sys.get_state(view.pid).socket.assigns.shell_chrome.pending_approvals_count == 0

    queries =
      capture_queries(view.pid, fn ->
        for badge <- [:approvals, :packs, :access_requests],
            do: send(view.pid, {:recompute_nav_badge, badge})

        render(view)
      end)

    assert Enum.count(queries, &(&1 =~ ~r/SELECT count\(.*approval_requests/is)) == 1
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.shell_chrome.pending_approvals_count == 1
    assert assigns.shell_chrome.pending_packs_count == 0
    assert assigns.shell_chrome.pending_access_requests_count == 0
    assert MapSet.size(assigns.pending_badge_recomputes) == 0
  end

  test "a queued badge refresh honors runner access revoked after the broadcast", %{
    conn: conn,
    user: user,
    account: account,
    runner: runner
  } do
    account.id
    |> Fixtures.Memberships.fetch_membership(user.id)
    |> Fixtures.Memberships.force_role("admin")

    run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id)
    request = Fixtures.Approvals.create_request(account_id: account.id, run_id: run.id)
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/runs")
    assert :sys.get_state(view.pid).socket.assigns.shell_chrome.pending_approvals_count == 1

    send(view.pid, {:approval_updated, request.id})
    render(view)

    {:ok, access} = Accounts.RunnerAccess.restricted(["inaccessible"], [])

    account.id
    |> Fixtures.Memberships.fetch_membership(user.id)
    |> Fixtures.Memberships.force_runner_access(access)

    send(view.pid, {:recompute_nav_badge, :approvals})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.shell_chrome.pending_approvals_count == 0
  end

  test "scope events refresh the exact member once without broadening the subject", %{
    conn: conn,
    user: user,
    account: account
  } do
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    Fixtures.Memberships.force_role(membership, "admin")
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/runs?source=operator")
    permission = Emisar.Runs.Authorizer.dispatch_run_permission()

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.current_subject.permissions, &MapSet.delete(&1, permission))
    end)

    original = :sys.get_state(view.pid).socket.assigns
    Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())

    assert capture_queries(view.pid, fn ->
             send(
               view.pid,
               {:list_changed, :team, "membership.runner_access_changed", Ecto.UUID.generate()}
             )

             render(view)
           end) == []

    queries =
      capture_queries(view.pid, fn ->
        Emisar.PubSub.broadcast(
          "account:#{account.id}:team",
          {:list_changed, :team, "membership.runner_access_changed", user.id}
        )

        render(view)
      end)

    assert length(queries) == 1
    refreshed = :sys.get_state(view.pid).socket.assigns
    assert refreshed.current_subject == original.current_subject
    assert refreshed.current_membership.runner_access_mode == :none
    assert refreshed.filter_params == original.filter_params
    assert MapSet.member?(refreshed.pending_badge_recomputes, :approvals)
  end

  defp heartbeat(id, load) do
    %{
      event: "presence_diff",
      payload: %{
        joins: %{id => %{metas: [%{action_load: load, last_heartbeat_at: 1_700_000_000}]}},
        leaves: %{id => %{metas: [%{}]}}
      }
    }
  end

  defp capture_queries(pid, fun) do
    owner = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:emisar, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == pid, do: send(owner, {ref, metadata.query})
        end,
        nil
      )

    try do
      fun.()
      drain_queries(ref)
    after
      :telemetry.detach(ref)
    end
  end

  defp drain_queries(ref) do
    receive do
      {^ref, query} -> [query | drain_queries(ref)]
    after
      0 -> []
    end
  end
end
