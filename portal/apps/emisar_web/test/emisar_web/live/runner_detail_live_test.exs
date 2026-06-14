defmodule EmisarWeb.RunnerDetailLiveTest do
  @moduledoc """
  The runner detail page: presence-backed status, the enable/disable/
  delete lifecycle, and the two no-existence-leak paths — cross-account
  and per-user runner scope both read as "not found", never 403.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Fixtures
  alias Emisar.Runners

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.runner_fixture(account_id: account.id, connected?: false)
    %{conn: conn, user: user, account: account, runner: runner}
  end

  test "renders the runner with its actions and recent runs", %{conn: conn, runner: runner} do
    {:ok, _lv, html} = live(conn, ~p"/app/runners/#{runner.id}")

    assert html =~ runner.name
    assert html =~ runner.hostname
  end

  test "an offline runner's Run affordance is aria-disabled with a non-color cue",
       %{conn: conn, runner: runner} do
    # setup's runner is offline, so the action row renders the disabled span.
    Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")

    {:ok, _lv, html} = live(conn, ~p"/app/runners/#{runner.id}")

    assert html =~ ~s(aria-disabled="true")
    # The signal-slash icon is the non-color cue (not the dimmed text alone).
    assert html =~ "hero-signal-slash"
  end

  test "an unknown id bounces to the index as not-found", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/app/runners", flash: flash}}} =
             live(conn, ~p"/app/runners/#{Ecto.UUID.generate()}")

    assert flash["error"] == "Runner not found."
  end

  test "a cross-account runner reads as not-found", %{conn: conn} do
    foreign_runner = Fixtures.runner_fixture()

    assert {:error, {:live_redirect, %{to: "/app/runners"}}} =
             live(conn, ~p"/app/runners/#{foreign_runner.id}")
  end

  test "an out-of-scope runner reads as not-found, not 403", %{
    conn: _conn,
    user: owner,
    account: account,
    runner: runner
  } do
    in_scope_runner = Fixtures.runner_fixture(account_id: account.id)

    operator = Fixtures.user_fixture()

    membership =
      Fixtures.membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")

    {:ok, :ok} =
      Runners.replace_runner_scopes(
        membership,
        [{"runner", in_scope_runner.id}],
        Fixtures.subject_for(owner, account)
      )

    operator_conn = build_conn() |> log_in_user(operator)

    # The scoped runner works; the unscoped one doesn't exist for them.
    assert {:ok, _lv, _html} = live(operator_conn, ~p"/app/runners/#{in_scope_runner.id}")

    assert {:error, {:live_redirect, %{to: "/app/runners", flash: flash}}} =
             live(build_conn() |> log_in_user(operator), ~p"/app/runners/#{runner.id}")

    assert flash["error"] == "Runner not found."
  end

  test "disable / enable round-trip", %{conn: conn, runner: runner} do
    {:ok, lv, _html} = live(conn, ~p"/app/runners/#{runner.id}")

    assert render_click(lv, "disable", %{}) =~ "Runner disabled."
    assert Emisar.Repo.reload!(runner).disabled_at

    assert render_click(lv, "enable", %{}) =~ "Runner enabled."
    refute Emisar.Repo.reload!(runner).disabled_at
  end

  test "enable at the plan's runner limit flashes instead of enabling", %{
    conn: conn,
    user: user,
    account: account,
    runner: runner
  } do
    # The fixture account is on "free" (limit 3): disable the target, then
    # fill the remaining slots so re-enabling would exceed the plan.
    subject = Fixtures.subject_for(user, account)
    {:ok, _disabled} = Runners.disable_runner(runner, subject)
    for _ <- 1..3, do: Fixtures.runner_fixture(account_id: account.id)

    {:ok, lv, _html} = live(conn, ~p"/app/runners/#{runner.id}")

    assert render_click(lv, "enable", %{}) =~ "you&#39;re at your runner limit (3)"
    assert Emisar.Repo.reload!(runner).disabled_at
  end

  test "a viewer cannot disable — gated flash, runner untouched", %{
    account: account,
    runner: runner
  } do
    viewer = Fixtures.user_fixture()
    _ = Fixtures.membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")

    {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/runners/#{runner.id}")

    assert render_click(lv, "disable", %{}) =~ "You don&#39;t have permission to do that."
    refute Emisar.Repo.reload!(runner).disabled_at
  end

  test "delete soft-deletes and navigates back to the index", %{conn: conn, runner: runner} do
    {:ok, lv, _html} = live(conn, ~p"/app/runners/#{runner.id}")

    render_click(lv, "delete", %{})
    assert_redirect(lv, "/app/runners")
    assert Emisar.Repo.reload!(runner).deleted_at
  end

  test "a presence_diff broadcast refreshes the status badge", %{conn: conn, runner: runner} do
    # Word-anchored: the offline badge text is "disconnected", which
    # contains "connected" as a bare substring.
    connected_badge = ~r/>\s*connected\s*</

    {:ok, lv, _html} = live(conn, ~p"/app/runners/#{runner.id}")
    refute render(lv) =~ connected_badge

    # The runner connects elsewhere; the page hears the diff and re-reads.
    Runners.connect_runner(runner)
    send(lv.pid, %{event: "presence_diff"})

    assert render(lv) =~ connected_badge
  end
end
