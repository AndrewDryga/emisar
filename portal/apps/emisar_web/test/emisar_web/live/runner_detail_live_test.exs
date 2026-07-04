defmodule EmisarWeb.RunnerDetailLiveTest do
  @moduledoc """
  The runner detail page: presence-backed status, the enable/disable/
  delete lifecycle, and the two no-existence-leak paths — cross-account
  and per-user runner scope both read as "not found", never 403.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runners

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    %{conn: conn, user: user, account: account, runner: runner}
  end

  test "renders the runner with its actions and recent runs", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert html =~ runner.name
    assert html =~ runner.hostname
  end

  # a runner that has reported no catalog renders the
  # "No actions yet" empty state in the advertised-actions card.
  test "a runner with no advertised actions shows the empty catalog state", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert html =~ "No actions yet"
    assert html =~ "hasn&#39;t reported a catalog yet"
  end

  # a runner never dispatched to renders the "No runs yet"
  # empty state in the recent-runs sidebar.
  test "a runner with no recent runs shows the empty recent-runs state", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert html =~ "No runs yet"
    assert html =~ "Nothing dispatched to this runner yet"
  end

  test "a bad cursor in the URL falls back to the first page, not a crash", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    # A hand-edited page/filter cursor makes the actions read return {:error, …};
    # the LV must retry clean (first page), never raise the MatchError H2 fixed.
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}?page=garbage-cursor")

    assert html =~ runner.name
  end

  test "an offline runner's Run affordance is aria-disabled with a non-color cue",
       %{conn: conn, account: account, runner: runner} do
    # setup's runner is offline, so the action row renders the disabled span.
    Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert html =~ ~s(aria-disabled="true")
    # The signal-slash icon is the non-color cue (not the dimmed text alone).
    assert html =~ "hero-signal-slash"
  end

  test "an enforcing runner shows the signed-only notice and disables Run", %{
    conn: conn,
    account: account
  } do
    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        enforce_signatures: true,
        connected?: true
      )

    Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert html =~ "Signed dispatch only"
    # Points operators at the concrete provisioning tool.
    assert html =~ "emisar signing init"
    # The Run affordance is the disabled lock variant (not color alone), and is
    # NOT a dispatch link — the portal can't run on this host.
    assert html =~ "hero-lock-closed"
    refute html =~ "/runs/new/#{runner.id}/linux.uptime"
  end

  test "an online non-enforcing runner offers the Run link (no signed-only gating)", %{
    conn: conn,
    account: account
  } do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
    Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert html =~ "/runs/new/#{runner.id}/linux.uptime"
    refute html =~ "Signed dispatch only"
  end

  test "an unknown id bounces to the index as not-found", %{conn: conn, account: account} do
    dest = ~p"/app/#{account}/runners"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runners/#{Ecto.UUID.generate()}")

    assert flash["error"] == "Runner not found."
  end

  test "a cross-account runner reads as not-found", %{conn: conn, account: account} do
    foreign_runner = Fixtures.Runners.create_runner()

    dest = ~p"/app/#{account}/runners"

    assert {:error, {:live_redirect, %{to: ^dest}}} =
             live(conn, ~p"/app/#{account}/runners/#{foreign_runner.id}")
  end

  test "an out-of-scope runner reads as not-found, not 403", %{
    conn: _conn,
    user: owner,
    account: account,
    runner: runner
  } do
    in_scope_runner = Fixtures.Runners.create_runner(account_id: account.id)

    operator = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, :ok} =
      Runners.replace_runner_scopes(
        membership,
        [{"runner", in_scope_runner.id}],
        Fixtures.Subjects.subject_for(owner, account)
      )

    operator_conn = build_conn() |> log_in_user(operator)

    # The scoped runner works; the unscoped one doesn't exist for them.
    assert {:ok, _lv, _html} =
             live(operator_conn, ~p"/app/#{account}/runners/#{in_scope_runner.id}")

    dest = ~p"/app/#{account}/runners"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             live(build_conn() |> log_in_user(operator), ~p"/app/#{account}/runners/#{runner.id}")

    assert flash["error"] == "Runner not found."
  end

  test "disable / enable round-trip", %{conn: conn, account: account, runner: runner} do
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert render_click(lv, "disable", %{}) =~ "Runner disabled."
    assert Emisar.Repo.reload!(runner).disabled_at

    assert render_click(lv, "enable", %{}) =~ "Runner enabled."
    refute Emisar.Repo.reload!(runner).disabled_at
  end

  # disabling an ONLINE runner is allowed (a soft "stop",
  # distinct from delete which requires the runner be offline first).
  test "disabling a connected runner is allowed (soft-stop)", %{conn: conn, account: account} do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert render_click(lv, "disable", %{}) =~ "Runner disabled."
    assert Emisar.Repo.reload!(runner).disabled_at
  end

  # a connected runner's Delete zone (and its typed-confirm
  # modal) are not rendered; you must disable it first. Disable + Enable zones
  # gate on disabled_at, not online state, so the Disable zone still shows.
  test "the delete zone is hidden while the runner is online", %{conn: conn, account: account} do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    # Owner can manage, but delete is gated behind `not online?`.
    refute html =~ "Delete this runner"
    # The soft-stop Disable zone is still available for an online runner.
    assert html =~ "Disable this runner"
  end

  test "enable at the plan's runner limit flashes instead of enabling", %{
    conn: conn,
    user: user,
    account: account,
    runner: runner
  } do
    # The fixture account is on "free" (limit 3): disable the target, then
    # fill the remaining slots so re-enabling would exceed the plan.
    subject = Fixtures.Subjects.subject_for(user, account)
    {:ok, _disabled} = Runners.disable_runner(runner, subject)
    for _ <- 1..3, do: Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    assert render_click(lv, "enable", %{}) =~ "you&#39;re at your runner limit (3)"
    assert Emisar.Repo.reload!(runner).disabled_at
  end

  test "a viewer cannot disable — gated flash, runner untouched", %{
    account: account,
    runner: runner
  } do
    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, lv, _html} =
      build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runners/#{runner.id}")

    assert render_click(lv, "disable", %{}) =~ "You don&#39;t have permission to do that."
    refute Emisar.Repo.reload!(runner).disabled_at
  end

  # `delete` is manage-gated; an operator (view-only on
  # runners) who forces the event past the hidden danger zone gets the gated
  # flash and the runner is NOT soft-deleted. (, a cross-account
  # delete, is already unreachable: mount redirects "Runner not found." before
  # any event — see "a cross-account runner reads as not-found" above.)
  test "an operator cannot delete — forced event gated, runner untouched", %{
    account: account,
    runner: runner
  } do
    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, lv, _html} =
      build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/runners/#{runner.id}")

    assert render_click(lv, "delete", %{}) =~ "You don&#39;t have permission to do that."
    refute Emisar.Repo.reload!(runner).deleted_at
  end

  test "delete soft-deletes and navigates back to the index via the typed-confirm dialog", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    # Drive the dialog: type the runner's name, then Confirm.
    type_confirm_token(lv, "delete-runner", runner.name)
    confirm_dialog(lv, "delete-runner", "Delete runner")
    assert_redirect(lv, ~p"/app/#{account}/runners")
    assert Emisar.Repo.reload!(runner).deleted_at
  end

  test "delete's typed-confirm: Confirm won't fire until the runner name matches", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    # Empty + wrong token → Confirm disabled, `delete` never dispatched.
    assert_raise ArgumentError, ~r/disabled/, fn ->
      confirm_dialog(lv, "delete-runner", "Delete runner")
    end

    type_confirm_token(lv, "delete-runner", "not-the-runner-name")

    assert_raise ArgumentError, ~r/disabled/, fn ->
      confirm_dialog(lv, "delete-runner", "Delete runner")
    end

    # The runner is untouched — no bypassing event fired.
    refute Emisar.Repo.reload!(runner).deleted_at
  end

  test "a presence_diff broadcast refreshes the status badge", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    connected_badge = ~r/>\s*connected\s*</

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")
    refute render(lv) =~ connected_badge

    # The runner connects elsewhere; the page hears the diff and re-reads.
    Runners.connect_runner(runner)
    send(lv.pid, %{event: "presence_diff"})

    assert render(lv) =~ connected_badge
  end

  # an operator (view-only on runners) opens the detail
  # page: it renders, but `subject_can_manage_runners?` is false so none of the
  # lifecycle zones (disable / enable / delete) are present. The danger surface
  # is admin+ only.
  test "an operator sees the detail but no disable/enable/delete zones", %{
    account: account,
    runner: runner
  } do
    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, _lv, html} =
      build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/runners/#{runner.id}")

    # The page loads (operator holds view_runners)…
    assert html =~ runner.name
    # …but every manage-only zone is gone.
    refute html =~ "Disable this runner"
    refute html =~ "Enable this runner"
    refute html =~ "Delete this runner"
  end

  # once a runner is disabled the Disable zone is replaced
  # by the Enable zone (the two gate on `disabled_at`, not online state), so the
  # UI is idempotent: you can't disable an already-disabled runner.
  test "the disable zone is hidden once the runner is disabled (enable zone shows)", %{
    conn: conn,
    user: user,
    account: account,
    runner: runner
  } do
    {:ok, _disabled} =
      Runners.disable_runner(runner, Fixtures.Subjects.subject_for(user, account))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    refute html =~ "Disable this runner"
    assert html =~ "Enable this runner"
  end

  # the inverse: an enabled runner shows no Enable zone
  # (it's the disabled-only restore affordance). setup's runner is enabled.
  test "the enable zone is hidden while the runner is enabled", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    refute html =~ "Enable this runner"
    assert html =~ "Disable this runner"
  end

  # `enable` is manage-gated; an operator who forces the
  # event (the zone is hidden for them) gets the gated flash and the runner stays
  # disabled.
  test "an operator cannot enable — forced event gated, runner stays disabled", %{
    user: owner,
    account: account,
    runner: runner
  } do
    {:ok, _disabled} =
      Runners.disable_runner(runner, Fixtures.Subjects.subject_for(owner, account))

    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, lv, _html} =
      build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/runners/#{runner.id}")

    assert render_click(lv, "enable", %{}) =~ "You don&#39;t have permission to do that."
    assert Emisar.Repo.reload!(runner).disabled_at
  end

  # a non-limit enable failure flashes the generic
  # "Could not enable runner." A disabled runner (under the plan limit) is
  # soft-deleted out from under the page after mount; `enable_runner`'s gates
  # pass on the stale struct, but the locked re-read (`not_deleted`) misses →
  # {:error, :not_found} → the generic failure branch (not the over-limit one).
  test "a non-limit enable failure flashes 'Could not enable runner.'", %{
    conn: conn,
    user: user,
    account: account,
    runner: runner
  } do
    {:ok, _disabled} =
      Runners.disable_runner(runner, Fixtures.Subjects.subject_for(user, account))

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/#{runner.id}")

    # The runner vanishes between render and the Enable click.
    {:ok, _} = runner |> Runners.Runner.Changeset.delete() |> Emisar.Repo.update()

    assert render_click(lv, "enable", %{}) =~ "Could not enable runner."
  end
end
