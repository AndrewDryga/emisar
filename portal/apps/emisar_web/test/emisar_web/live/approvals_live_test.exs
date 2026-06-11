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
        args: %{}
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
        args_sha256: "abc123"
      })

    {:ok, request} = Approvals.create_request(run, user.id, reason)
    request
  end

  test "lists the pending request with its reason", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = pending_request!(account, user.id, "reboot for kernel patch")

    {:ok, _lv, html} = live(conn, ~p"/app/approvals")

    assert html =~ "linux.reboot"
    assert html =~ "reboot for kernel patch"
  end

  test "an approval_updated broadcast reloads the queue", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    {:ok, lv, html} = live(conn, ~p"/app/approvals")
    refute html =~ "late-arriving request"

    _ = pending_request!(account, user.id, "late-arriving request")
    send(lv.pid, {:approval_updated, nil})

    assert render(lv) =~ "late-arriving request"
  end

  test "revoke_grant retires a standing grant", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = subject_for(user, account)

    request = pending_mcp_request!(account, user, "grant me a day")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)

    {:ok, [grant], _meta} = Approvals.list_grants_for_account(subject)

    {:ok, lv, html} = live(conn, ~p"/app/approvals")
    assert html =~ "linux.reboot"

    html = render_click(lv, "revoke_grant", %{"id" => grant.id})
    assert html =~ "Grant revoked. New calls will require fresh approval."
  end

  test "revoking an unknown grant flashes not-found", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/approvals")

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

    {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/approvals")

    html = render_click(lv, "revoke_grant", %{"id" => grant.id})

    assert html =~ "You don&#39;t have permission to do that."

    # The grant survived.
    {:ok, [%{revoked_at: nil}], _meta} = Approvals.list_grants_for_account(subject)
  end
end
