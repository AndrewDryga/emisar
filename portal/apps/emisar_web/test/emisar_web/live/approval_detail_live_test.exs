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

    {:ok, _lv, html} = live(conn, ~p"/app/approvals/#{request.id}")

    # The panel renders the approve form (owner can decide) — this is the
    # exact path that raised KeyError on `@grant_duration` in production.
    assert html =~ "Decide"
    assert html =~ "Approve and send"
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

    # The Deny form is a bare button — it submits no `reason`, which used
    # to raise FunctionClauseError in handle_event/3.
    html =
      lv
      |> element("form[phx-submit='deny']")
      |> render_submit()

    assert html =~ "Denied."
  end
end
