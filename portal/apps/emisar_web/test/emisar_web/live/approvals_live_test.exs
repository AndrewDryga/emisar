defmodule EmisarWeb.ApprovalsLiveTest do
  @moduledoc """
  The approvals queue: pending requests, standing grants, and the
  revoke-grant control (decide-permission gated — a revoked grant means
  the next call needs fresh human approval).
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

  alias Emisar.Approvals
  alias Emisar.Runs

  defp pending_request!(account, requester_id, reason) do
    runner = runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.reboot",
        source: "operator",
        args: %{},
        # A real require-approval run is parked :pending_approval.
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, requester_id, reason)
    request
  end

  # Grants are per API key — they only mint for MCP-sourced runs, so the
  # grant tests need the MCP shape (api_key_id + args_sha256).
  defp pending_mcp_request!(account, user, reason) do
    runner = runner_fixture(account_id: account.id)
    {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.reboot",
        source: "mcp",
        api_key_id: key.id,
        args: %{},
        args_sha256: "abc123",
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, user.id, reason)
    request
  end

  test "lists the pending request with its reason", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = pending_request!(account, user.id, "reboot for kernel patch")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    assert html =~ "linux.reboot"
    assert html =~ "reboot for kernel patch"
  end

  test "a pending request shows its expiry, amber only when it's about to lapse", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request!(account, user.id, "kernel patch")

    # Default 24h TTL → expiry shown but muted (not urgent yet).
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")
    assert html =~ "expires"
    refute html =~ "text-amber-400"

    # Under two hours left → amber so an approver triages it ahead of fresher
    # but less-urgent requests.
    request
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), 1800, :second))
    |> Emisar.Repo.update!()

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")
    assert html =~ "text-amber-400"
  end

  test "an approval_updated broadcast reloads the queue", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals")
    refute html =~ "late-arriving request"

    _ = pending_request!(account, user.id, "late-arriving request")
    send(lv.pid, {:approval_updated, nil})

    assert render(lv) =~ "late-arriving request"
  end

  test "an expired request shows its Expired outcome in recent decisions", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request!(account, user.id, "lapsed without a decision")

    # Backdate its TTL and run the real expiry sweep — it lands in Recent
    # decisions as :expired with no decider; the status badge carries the outcome.
    request
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))
    |> Emisar.Repo.update!()

    assert Approvals.expire_overdue_requests() == 1

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    assert html =~ "expired"
  end

  test "revoke_grant retires a standing grant", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = subject_for(user, account)

    request = pending_mcp_request!(account, user, "grant me a day")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)

    {:ok, [grant], _meta} = Approvals.list_grants_for_account(subject)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals")
    assert html =~ "linux.reboot"

    html = render_click(lv, "revoke_grant", %{"id" => grant.id})
    assert html =~ "Grant revoked. New calls will require fresh approval."
  end

  test "a grant's expiry + last-used render through <.local_time>, with spacing kept", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)
    subject = subject_for(user, account)

    request = pending_mcp_request!(account, user, "grant me a day")
    # A one-day grant has an expiry → the "expires <time>" branch; minting it
    # also stamps last_used_at (uses_count starts at 1), so "last used" renders
    # a <time> too.
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    # Viewer-local <time> for both (same model as the rest of the app).
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
    # Mid-sentence spacing survives the formatter line-break (the {" "} guards):
    # "expires <time>" and "last used <time>" never abut their prefix.
    assert html =~ ~r/expires\s<time/
    refute html =~ ~r/expires<time/
    assert html =~ ~r/last used\s<time/
    refute html =~ ~r/last used<time/
  end

  test "revoking an unknown grant flashes not-found", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals")

    assert render_click(lv, "revoke_grant", %{"id" => Ecto.UUID.generate()}) =~
             "Grant not found."
  end

  test "a viewer cannot revoke a grant", %{conn: conn} do
    {_owner_conn, owner, account} = register_and_log_in(conn)
    subject = subject_for(owner, account)

    request = pending_mcp_request!(account, owner, "standing grant")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)
    {:ok, [grant], _meta} = Approvals.list_grants_for_account(subject)

    viewer = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")

    {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/approvals")

    html = render_click(lv, "revoke_grant", %{"id" => grant.id})

    assert html =~ "You don&#39;t have permission to do that."

    # The grant survived.
    {:ok, [%{revoked_at: nil}], _meta} = Approvals.list_grants_for_account(subject)
  end
end
