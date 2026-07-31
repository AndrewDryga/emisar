defmodule EmisarWeb.RunbooksLiveTest do
  @moduledoc """
  The runbooks index: lists the account's runbooks, gates the New
  button on manage permission, links published rows to the Run form,
  and live-refreshes on the account's runbook feed.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Repo, Runbooks}
  alias Emisar.Runbooks.RunbookExecution

  defp create_runbook!(user, account, title, opts \\ []) do
    subject = owner_subject(user, account)

    {:ok, runbook} =
      Runbooks.create_runbook(
        %{
          "title" => title,
          "name" => title,
          "slug" => String.downcase(String.replace(title, " ", "-")),
          "definition" => Emisar.Fixtures.Runbooks.default_definition()
        },
        subject
      )

    if opts[:published?] do
      {:ok, runbook} = Runbooks.publish(runbook, subject)
      runbook
    else
      runbook
    end
  end

  defp create_execution!(user, account, runbook, reason) do
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

    RunbookExecution.Changeset.create(%{
      id: Ecto.UUID.generate(),
      account_id: account.id,
      runbook_id: runbook.id,
      initiating_membership_id: membership.id,
      requested_by_id: user.id,
      reason: reason,
      frozen_plan: %{"schema_version" => 1, "stages" => []},
      inputs_raw: "{}",
      inputs_sha256: String.duplicate("0", 64),
      status: :succeeded
    })
    |> Repo.insert!()
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

    # No drafts exist, but a status filter is active. The operator must still
    # see the filter bar to clear it — not the "No runbooks yet" create-CTA,
    # which would trap them on a dead empty state with no way back.
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks?status=draft")

    assert html =~ "No runbooks match these filters"
    refute html =~ "No runbooks yet"
    # The status filter control is still rendered so they can clear it.
    assert html =~ ~s(name="status")
  end

  test "lists runbooks; published rows get a Run link, drafts don't", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    published = create_runbook!(user, account, "Deploy check", published?: true)
    draft = create_runbook!(user, account, "Half baked")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert html =~ "Deploy check"
    assert html =~ "Half baked"
    assert html =~ ~p"/app/#{account}/runbooks/#{published.id}/run"
    refute html =~ ~p"/app/#{account}/runbooks/#{draft.id}/run"
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
    _ = create_runbook!(user, account, "Risky deploy", published?: true)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks")

    assert html =~ "Risky deploy"
    assert html =~ "high"
    assert html =~ "ring-rose-500/30"
  end

  test "a runbook whose action isn't in the catalog shows no risk pill", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    # No Fixtures.Catalog.create_action for linux.uptime — the catalog hasn't observed it, so the
    # row renders without a risk pill (never a false-low) rather than guessing.
    # A draft (not published) so the emerald "published" status badge — which
    # shares the low-risk pill's ring color — can't be mistaken for a pill.
    _ = create_runbook!(user, account, "Unobserved")

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

  test "a hand-edited bogus status filter is dropped, not crashed on", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    published = create_runbook!(user, account, "Deploy check", published?: true)

    # A status the whitelist doesn't know (never String.to_atom — IL-14). The
    # filter is dropped on a clean retry rather than raising, so the list still
    # renders the account's runbooks instead of a 500.
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks?status=bogus")

    assert html =~ "Deploy check"
    assert html =~ ~p"/app/#{account}/runbooks/#{published.id}/run"
  end
end
