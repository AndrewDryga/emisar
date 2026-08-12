defmodule EmisarWeb.RunbooksLiveTest do
  @moduledoc """
  The runbooks index: one row per runbook chipped with its live release and any
  unpublished change, gates the New button on manage permission, links runnable
  runbooks to the Run form, and live-refreshes on the account's runbook feed.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runbooks

  defp create_runbook!(user, account, title, opts \\ []) do
    runbook =
      Fixtures.Runbooks.create_runbook(
        account_id: account.id,
        created_by_id: user.id,
        title: title,
        slug: String.downcase(String.replace(title, " ", "-"))
      )

    if opts[:published?] do
      Fixtures.Runbooks.publish_runbook(runbook)
    else
      runbook
    end
  end

  defp create_execution!(user, account, runbook, reason) do
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

    Fixtures.Runbooks.create_execution(
      account_id: account.id,
      runbook: runbook,
      initiating_membership_id: membership.id,
      reason: reason
    )
  end

  test "renders the empty state with new and import actions for an owner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert html =~ "Runbooks"
    assert has_element?(lv, "a[href='#{~p"/app/#{account}/runbooks/new"}']", "New runbook")

    assert has_element?(
             lv,
             "a[href='#{~p"/app/#{account}/runbooks/import"}']",
             "Import runbook"
           )
  end

  test "an empty *filtered* result keeps the filter bar, not the create-CTA", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    # Nothing has unpublished changes, but that filter is active. The operator
    # must still see the filter bar to clear it — not the "No runbooks yet"
    # create-CTA, which would trap them on a dead empty state with no way back.
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks?state=draft")

    assert html =~ "No runbooks match these filters"
    refute html =~ "No runbooks yet"
    # The state filter control is still rendered so they can clear it.
    assert html =~ ~s(name="state")
    assert html =~ "Unpublished changes"
  end

  test "the live release rides the Run label; only never-published earns a chip", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    published = create_runbook!(user, account, "Deploy check", published?: true)
    never_published = create_runbook!(user, account, "Half baked")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert html =~ "Deploy check"
    assert html =~ "Half baked"
    refute has_element?(lv, "span", "Live v1")
    assert has_element?(lv, "span", "Never published")

    # Only the live release runs, and the button names it — a runbook without
    # one offers no Run and no draft dot (it is ALL unpublished).
    assert has_element?(
             lv,
             "a[href='#{~p"/app/#{account}/runbooks/#{published.id}/run"}']",
             "Run v1"
           )

    refute html =~ ~p"/app/#{account}/runbooks/#{never_published.id}/run"
    refute has_element?(lv, "[id^='runbook-'][id$='-draft-tip']")

    # One row per runbook — the editor is reached by id, never by version.
    assert html =~ ~p"/app/#{account}/runbooks/#{published.id}/edit"

    assert has_element?(
             lv,
             ~s(a[href="/app/#{account.slug}/audit?target_kind=runbook&target_id=#{published.id}"]),
             "View activity"
           )

    refute html =~ "/versions"
  end

  test "a runbook with unpublished changes still runs its live release", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    runbook = create_runbook!(user, account, "Deploy check", published?: true)
    base_sha = Runbooks.definition_digest(runbook.definition)
    attrs = %{"title" => "Deploy check", "draft_definition" => runbook.definition}

    assert {:ok, _runbook} = Runbooks.save_draft(runbook, attrs, base_sha, subject)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks")

    # Waiting changes are a quiet amber dot whose tooltip explains itself on
    # keyboard and touch, never a labeled chip shouting beside the title.
    assert has_element?(lv, "#runbook-#{runbook.id}-draft-tip[role='tooltip']")
    assert render(lv) =~ "Unpublished changes — open the runbook to review and publish them."
    refute has_element?(lv, "span", "Live v1")

    # The Run button dispatches — and names — the live release, unchanged by
    # the waiting draft.
    assert has_element?(
             lv,
             "a[href='#{~p"/app/#{account}/runbooks/#{runbook.id}/run"}']",
             "Run v1"
           )
  end

  test "moves guidance and account-scoped recent runs into the reading rail", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runbook = create_runbook!(user, account, "Deploy check", published?: true)
    execution = create_execution!(user, account, runbook, "Deploy during change window")

    {other_user, other_account, _other_subject} = Fixtures.Subjects.owner_subject()
    other_runbook = create_runbook!(other_user, other_account, "Other account")
    hidden = create_execution!(other_user, other_account, other_runbook, "Must stay hidden")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert has_element?(lv, "#runbooks-docs-rail a[href='/docs/runbooks']")
    assert has_element?(lv, "#runbooks-reading-rail:not([class*='border-l'])")

    assert has_element?(
             lv,
             "#runbooks-docs-rail",
             "Every action in a stage must succeed before the next stage starts"
           )

    refute html =~ "Runbooks turn an ordered procedure"
    refute has_element?(lv, "#runbooks-primary a[href='/docs/runbooks']")
    assert has_element?(lv, "#recent-runbook-runs a[href$='/runs/#{execution.id}']")
    assert html =~ "Deploy during change window"
    refute html =~ hidden.reason
  end

  test "a viewer gets the list but no New action", %{conn: conn} do
    {_owner_conn, user, account} = register_and_log_in(conn)
    runbook = create_runbook!(user, account, "Visible to all")

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, _lv, html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/app/#{account}/runbooks")

    assert html =~ "Visible to all"
    assert html =~ ~p"/app/#{account}/runbooks/#{runbook.id}/edit"
    refute html =~ ~p"/app/#{account}/runbooks/new"
    refute html =~ ~p"/app/#{account}/runbooks/import"
  end

  test "a runbook row shows its most-severe step risk so it's visible before opening", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)

    # The runbook's lone step is linux.uptime — advertise it as high-risk so its
    # list row carries a high (rose) risk pill, the headline cue before opening.
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")
    create_runbook!(user, account, "Risky deploy", published?: true)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert html =~ "Risky deploy"
    assert html =~ "high"
    assert html =~ "ring-rose-500/30"
  end

  test "a runbook whose action isn't in the catalog shows no risk pill", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    # No Fixtures.Catalog.create_action for linux.uptime — the catalog hasn't observed it, so the
    # row renders without a risk pill (never a false-low) rather than guessing.
    create_runbook!(user, account, "Unobserved")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert html =~ "Unobserved"
    refute html =~ "ring-rose-500/30"
    refute html =~ "ring-brand-500/30"
  end

  test "refreshes when the account's runbook feed broadcasts", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks")
    refute html =~ "Late arrival"

    late = create_runbook!(user, account, "Late arrival")
    send(lv.pid, {:list_changed, :runbook, "runbook.created", late.id})

    assert render(lv) =~ "Late arrival"
  end

  test "a hand-edited bogus state filter is dropped, not crashed on", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    published = create_runbook!(user, account, "Deploy check", published?: true)

    # A state the whitelist doesn't know (never String.to_atom — IL-14). The
    # filter is dropped on a clean retry rather than raising, so the list still
    # renders the account's runbooks instead of a 500.
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks?state=bogus")

    assert html =~ "Deploy check"
    assert html =~ ~p"/app/#{account}/runbooks/#{published.id}/run"
  end
end
