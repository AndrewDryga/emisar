defmodule EmisarWeb.ApprovalDetailLiveTest do
  @moduledoc """
  The approval detail page + its decision panel. Regression coverage for
  two production crashes: a KeyError where the `decision_panel` component
  read `@grant_duration` but the call site only passed `can_decide?`, and
  a FunctionClauseError where clicking Deny submitted no `reason` but the
  handler head required `%{"reason" => reason}`.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Approvals, Repo, Runs}
  alias Emisar.Runners.Runner

  defp pending_request(account, requested_by) do
    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        reason: "needs review",
        args: %{}
      })

    {:ok, request} = Approvals.create_request(run, requested_by.id, "please approve")
    request
  end

  test "renders the decision panel for a decider without crashing", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/approvals/#{request.id}")

    # The panel renders the approve form (owner can decide) — this is the
    # exact path that raised KeyError on `@grant_duration` in production.
    assert html =~ "Decide"
    assert html =~ "Approve and send"
    # A held request shows when it auto-cancels so the decider can triage.
    assert html =~ "Expires"
    assert html =~ "expires"
    # Both decision buttons guard the most consequential click against a
    # double-submit.
    assert has_element?(lv, "button[phx-disable-with]", "Approve and send")
    assert has_element?(lv, "button[phx-disable-with]", "Deny")
  end

  test "choosing a reuse window reveals the grant scope fields", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/approvals/#{request.id}")

    # Defaults to "once" (no grant) → Match / Limit-to fields hidden.
    refute html =~ "Same arguments only"

    # Pick a real duration → grant_duration threads back into the panel.
    changed =
      lv
      |> element("form[phx-change='grant_form_changed']")
      |> render_change(%{"duration" => "one_day"})

    assert changed =~ "Same arguments only"
  end

  test "denying does not crash when the form carries no reason", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/approvals/#{request.id}")

    # The reason textarea is optional — an empty submit still denies (this
    # path once raised FunctionClauseError on the missing `reason`).
    html =
      lv
      |> element("form[phx-submit='deny']")
      |> render_submit()

    assert html =~ "Denied."
  end

  test "denying captures the reason in the decision history", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/approvals/#{request.id}")

    html =
      lv
      |> form("form[phx-submit='deny']", %{"reason" => "duplicate of an earlier run"})
      |> render_submit()

    assert html =~ "Denied."
    assert html =~ "duplicate of an earlier run"
    assert Repo.reload!(request).decision_reason == "duplicate of an earlier run"
  end

  test "a decision that lost a race to expiry re-fetches and flips the panel", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/approvals/#{request.id}")
    assert html =~ "Approve and send"

    # The request expires out from under the open page — its live broadcast
    # hasn't arrived yet, so simulate by expiring the row directly, then
    # deciding (approve and deny share the decision_failed defense).
    request
    |> Ecto.Changeset.change(
      status: :expired,
      expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )
    |> Repo.update!()

    html =
      lv
      |> form("form[phx-submit='deny']", %{"reason" => ""})
      |> render_submit()

    assert html =~ "expired before your decision landed"
    # The form flipped to decision-history — no interactive decision left.
    refute html =~ "Approve and send"
  end
end
