defmodule EmisarWeb.RunsLiveTest do
  @moduledoc """
  The runs list names the accountable HUMAN of each run — the requesting
  operator, or an MCP/LLM key's owner — with an origin icon and no redundant
  channel prose.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Repo, Runs}
  alias Emisar.Runners.Runner

  test "shows only the accountable person's name beside the source icon", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    owner = Fixtures.Users.create_user(full_name: "Jordan Vale", email: "jordan@example.test")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        name: "Claude Code",
        created_by_id: owner.id
      )

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    {:ok, _run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        api_key_id: key.id,
        args: %{}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs")

    # The source icon already says how the run arrived; the cell only names the
    # accountable person and does not spend width repeating the API key.
    assert html =~ ~s(title="Jordan Vale")
    assert html =~ "hero-bolt"
    assert html =~ ~s(aria-label="Dispatched via MCP")
    refute html =~ owner.email
    refute html =~ "via Claude Code"
    # Secondary columns (Source/Duration) collapse below lg so the table fits
    # a phone in an incident.
    assert html =~ "hidden lg:table-cell"
    # The "When" timestamp renders as a hook-driven <time> (viewer-local),
    # consistent with the rest of the app — not a raw server-UTC string.
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
  end

  test "falls back to the accountable person's email when no name exists", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    owner = Fixtures.Users.create_user(full_name: nil, email: "owner@example.test")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        name: "Claude Code",
        created_by_id: owner.id
      )

    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    {:ok, _run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        api_key_id: key.id,
        args: %{}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs")

    assert html =~ ~s(title="#{owner.email}")
    refute html =~ "via Claude Code"
  end

  test "a deep-linked api_key_id scopes runs to that agent and reads active in the Agent filter",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, name: "Claude Code")

    {_raw2, other_key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, name: "Other Agent")

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    base = %{account_id: account.id, runner_id: runner.id, source: "mcp", args: %{}}

    {:ok, _} =
      Runs.create_run(Map.merge(base, %{action_id: "ci.deploy_canary", api_key_id: key.id}))

    {:ok, _} =
      Runs.create_run(Map.merge(base, %{action_id: "linux.uptime", api_key_id: other_key.id}))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs?#{[source: "mcp", api_key_id: key.id]}")

    # Scoped to this agent's run; the other agent is excluded.
    assert html =~ "ci.deploy_canary"
    refute html =~ "linux.uptime"
    # No pivot chip — the Agent filter itself carries the selection: its hidden
    # input holds the key's id, and the combobox label shows its name.
    refute html =~ "Agent:"
    assert html =~ ~s(name="api_key_id" value="#{key.id}")
    assert html =~ "Claude Code"

    # The bare value deep-link (no source) still applies AND stays visible —
    # a filter must never narrow the feed from a hidden control.
    {:ok, _lv, bare} = live(conn, ~p"/app/#{account}/runs?#{[api_key_id: key.id]}")
    assert bare =~ "ci.deploy_canary"
    refute bare =~ "linux.uptime"
    assert bare =~ ~s(name="api_key_id" value="#{key.id}")
  end

  test "'Dispatched by' reveals its WHO picker; hidden children stay out of the bar",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    {:ok, _} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    # No kind picked → none of the three children render.
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs")
    refute html =~ ~s(name="api_key_id")
    refute html =~ ~s(name="requested_by_id")
    refute html =~ ~s(name="runbook_id")

    # LLM agent picked → the Agent picker appears (and only it).
    {:ok, _lv, mcp} = live(conn, ~p"/app/#{account}/runs?source=mcp")
    assert mcp =~ ~s(name="api_key_id")
    refute mcp =~ ~s(name="requested_by_id")

    # Operator picked → the Operator picker appears (and only it).
    {:ok, _lv, operator} = live(conn, ~p"/app/#{account}/runs?source=operator")
    assert operator =~ ~s(name="requested_by_id")
    refute operator =~ ~s(name="api_key_id")
  end

  test "a deep-linked runner_id scopes runs to that runner and reads active in the Runner filter",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, runner_a} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "web-iad-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    {:ok, runner_b} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "db-iad-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.13"
      })
      |> Repo.insert()

    {:ok, _} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner_a.id,
        action_id: "ci.deploy_canary",
        source: "operator",
        args: %{}
      })

    {:ok, _} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner_b.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs?#{[runner_id: runner_a.id]}")

    # Scoped to runner_a's run; runner_b's is excluded.
    assert html =~ "ci.deploy_canary"
    refute html =~ "linux.uptime"
    # No pivot chip — the Runner filter itself carries the selection: its hidden
    # input holds runner_a's id, and the combobox label shows its name.
    refute html =~ "Runner:"
    assert html =~ ~s(name="runner_id" value="#{runner_a.id}")
    assert html =~ "web-iad-1"
  end

  test "redirects anonymous users", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/runs")
  end

  test "the connected empty render shows the onboarding pitch", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs")
    assert html =~ "No runs yet"
  end

  test "the filter bar hides at account-empty, stays live once a filter is active", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)

    # No runs + no active filter → dead controls would just push the pitch
    # down — the bar doesn't render at all.
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs")
    refute has_element?(lv, "#runs-filter")

    # An active filter (even though it matches nothing) keeps the controls live,
    # so the operator can always clear back to the full set.
    {:ok, lv2, _html} = live(conn, ~p"/app/#{account}/runs?status=success")
    assert has_element?(lv2, "#runs-filter")
    refute has_element?(lv2, "#runs-filter select[disabled]")
  end

  test "the dead/pre-connect empty render shows a loading placeholder, not the pitch",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    # A plain GET is the disconnected render — connected?/1 is false, so the
    # onboarding pitch is deferred behind a loading placeholder rather than
    # flashed before the live socket confirms the list is really empty.
    html = conn |> get(~p"/app/#{account}/runs") |> html_response(200)
    assert html =~ "Loading"
    refute html =~ "No runs yet"
  end

  test "an account-runs broadcast reloads the current page", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs")
    refute html =~ "linux.late_run"

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.late_run",
        source: "operator",
        args: %{}
      })

    send(lv.pid, {:run_created, run})
    assert render(lv) =~ "linux.late_run"

    # The badge hooks forward unrelated account-topic broadcasts — any
    # other message shape is ignored, never a crash.
    send(lv.pid, :totally_unrelated)
    assert render(lv) =~ "linux.late_run"
  end

  test "a bad cursor in the URL falls back to the first page", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs?page=garbage-cursor")
    assert html =~ "Runs"
  end

  # the `filter` event is pure URL reshaping
  # (`LiveTable.apply_filter` push_patches the chosen filter into the query
  # string); it performs no mutation and so needs no authz gate. Selecting a
  # status patches the URL to `?status=…` and re-renders from the patched
  # params, with no denial flash.
  test "the filter event reshapes the URL with no authz (no mutation)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    {:ok, _run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs")

    # Picking a status drives the real dropdown path (phx-change "filter").
    html =
      lv
      |> form("#runs-filter", %{"status" => "success"})
      |> render_change()

    # The URL was reshaped to carry the filter (no mutation, no gate)…
    assert_patched(lv, ~p"/app/#{account}/runs?status=success")
    # …and there was no permission denial — it's an ungated read reshape.
    refute html =~ "You don&#39;t have permission to do that."
  end

  # the feed is scoped to the caller's account via
  # `for_subject/2`: A's operator sees A's runs and never B's, even though both
  # accounts have runs. (The foreign-account slug 404 lives in
  # account_slug_authz_test; this is the in-account data scoping.)
  test "cross-account — A's operator sees only A's runs, never B's", %{conn: conn} do
    {conn, _user, account_a} = register_and_log_in(conn)
    runner_a = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: false)

    {:ok, _} =
      Runs.create_run(%{
        account_id: account_a.id,
        runner_id: runner_a.id,
        action_id: "linux.alpha_run",
        source: "operator",
        args: %{}
      })

    account_b = Fixtures.Accounts.create_account()
    runner_b = Fixtures.Runners.create_runner(account_id: account_b.id, connected?: false)

    {:ok, _} =
      Runs.create_run(%{
        account_id: account_b.id,
        runner_id: runner_b.id,
        action_id: "linux.bravo_run",
        source: "operator",
        args: %{}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account_a}/runs")

    assert html =~ "linux.alpha_run"
    refute html =~ "linux.bravo_run"
  end

  describe "no-LLM onboarding banner" do
    test "the page-wide banner is GONE — the nav dot is the one nudge signal", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs")

      # Three signals for one fact (banner + nav dot + dashboard pillar) was
      # noise; the banner strip died. No agents AND no runners → not even the
      # dot: the first job is a runner, so the agents nudge waits its turn.
      refute html =~ "No LLM connected yet"
    end

    test "still no banner once an MCP key exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs")

      refute html =~ "No LLM connected yet"
    end

    test "is suppressed on the agents page itself (where the operator would act)", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/agents")

      refute html =~ "No LLM connected yet"
    end
  end
end
