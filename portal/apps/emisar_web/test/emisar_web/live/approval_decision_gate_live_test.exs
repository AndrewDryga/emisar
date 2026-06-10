defmodule EmisarWeb.ApprovalDecisionGateLiveTest do
  @moduledoc """
  Authorization coverage for the approve/deny decision on
  `EmisarWeb.ApprovalDetailLive` (`/app/approvals/:id`) — the money-
  adjacent gate where a wrong-role decision would let an unauthorized
  user release a gated infrastructure action.

  `approval_detail_live_test.exs` covers the rendering + crash
  regressions; this file covers the actual state transitions and the
  role gate:

    * an owner approving a pending request flips it to "approved" in the
      DB (and denying flips it to "denied"),
    * a viewer sees neither control and a *crafted* approve/deny event
      (bypassing the hidden UI — IL-15) is refused with a flash, leaving
      the request pending.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Approvals, Repo, Runs}
  alias Emisar.Approvals.Request
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
        action_id: "cassandra.repair",
        source: "operator",
        reason: "needs review",
        args: %{}
      })

    {:ok, req} = Approvals.create_request(run, requested_by.id, "please approve")
    req
  end

  defp reload_status(req_id) do
    Request.Query.all()
    |> Request.Query.by_id(req_id)
    |> Repo.fetch!(Request.Query)
    |> Map.fetch!(:status)
  end

  # Downgrade the logged-in owner to a viewer (same move team_live_test
  # uses). `register_and_log_in` always creates an owner.
  defp downgrade_to_viewer(user) do
    {:ok, m} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Emisar.Fixtures.force_membership_role(m, "viewer")
  end

  describe "owner decisions transition state" do
    test "approving a pending request flips it to approved", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      req = pending_request(account, user)

      {:ok, lv, _html} = live(conn, ~p"/app/approvals/#{req.id}")

      # Duration defaults to "once" (the form's first option) → no grant,
      # one-shot approval.
      html =
        lv
        |> element("form[phx-submit='approve']")
        |> render_submit(%{"reason" => "ok"})

      assert html =~ "Approved for this call only."
      assert reload_status(req.id) == :approved
    end

    test "denying a pending request flips it to denied", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      req = pending_request(account, user)

      {:ok, lv, _html} = live(conn, ~p"/app/approvals/#{req.id}")

      html =
        lv
        |> element("form[phx-submit='deny']")
        |> render_submit()

      assert html =~ "Denied."
      assert reload_status(req.id) == :denied
    end
  end

  describe "viewer is gated" do
    test "no approve/deny controls render for a viewer", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      req = pending_request(account, user)
      downgrade_to_viewer(user)

      {:ok, _lv, html} = live(conn, ~p"/app/approvals/#{req.id}")

      assert html =~ "Viewers can&#39;t decide approvals." or
               html =~ "Viewers can't decide approvals."

      refute html =~ "Approve and send"
      refute html =~ "phx-submit=\"deny\""
    end

    test "a crafted approve event is refused — flash, request stays pending", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      req = pending_request(account, user)
      downgrade_to_viewer(user)

      {:ok, lv, _html} = live(conn, ~p"/app/approvals/#{req.id}")

      # Push the event directly, as a hand-rolled client would — the
      # rendered UI never offers it to a viewer, so the handler itself
      # must deny it (IL-15).
      html = render_hook(lv, "approve", %{"reason" => "let me in"})

      assert html =~ "Viewers can&#39;t decide approvals."
      assert reload_status(req.id) == :pending
    end

    test "a crafted deny event is refused — request stays pending", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      req = pending_request(account, user)
      downgrade_to_viewer(user)

      {:ok, lv, _html} = live(conn, ~p"/app/approvals/#{req.id}")

      html = render_hook(lv, "deny", %{"reason" => "nope"})

      assert html =~ "Viewers can&#39;t decide approvals."
      assert reload_status(req.id) == :pending
    end
  end
end
