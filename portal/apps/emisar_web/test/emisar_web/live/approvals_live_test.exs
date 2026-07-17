defmodule EmisarWeb.ApprovalsLiveTest do
  @moduledoc """
  The approvals queue: pending requests, standing grants, and the
  revoke-grant control (decide-permission gated — a revoked grant means
  the next call needs fresh human approval).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Approvals
  alias Emisar.Runs

  defp pending_request!(account, requester_id, reason) do
    runner = Fixtures.Runners.create_runner(account_id: account.id)

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
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

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
    subject = Fixtures.Subjects.subject_for(user, account)

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
    subject = Fixtures.Subjects.subject_for(user, account)

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
    subject = Fixtures.Subjects.subject_for(owner, account)

    request = pending_mcp_request!(account, owner, "standing grant")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)
    {:ok, [grant], _meta} = Approvals.list_grants_for_account(subject)

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/approvals")

    html = render_click(lv, "revoke_grant", %{"id" => grant.id})

    assert html =~ "You don&#39;t have permission to do that."

    # The grant survived.
    {:ok, [%{revoked_at: nil}], _meta} = Approvals.list_grants_for_account(subject)
  end

  test "recent decisions list the decided requests but not the still-pending one", %{conn: conn} do
    # "Recent decisions" = all_recent minus the rows already
    # shown in Pending, so a decided request appears there while a pending one
    # shows only at the top, never duplicated below.
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    decided = pending_request!(account, user.id, "decided-and-denied")
    {:ok, _} = Approvals.deny_request(decided, subject, "not now")

    _pending = pending_request!(account, user.id, "still-waiting")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    # The denied request carries its outcome badge in Recent; the pending one is
    # the amber card up top, with the reassuring "Nothing waiting" copy absent.
    assert html =~ "denied"
    assert html =~ "still-waiting"
    refute html =~ "Nothing waiting"
  end

  test "a viewer sees pending + recent but no standing-grants rows", %{conn: conn} do
    # a viewer holds `view` (pending + recent render) but not
    # `manage_grants`, so `list_grants_for_account` errors → collapsed to [] → the
    # grants section shows its empty-state, never a grant row or a Revoke button.
    {_owner_conn, owner, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(owner, account)

    # A real standing grant exists in the account…
    request = pending_mcp_request!(account, owner, "owner-minted grant")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)
    _pending = pending_request!(account, owner.id, "viewer can see this")

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, _lv, html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/approvals")

    # …but it doesn't render for the viewer (no manage_grants).
    assert html =~ "viewer can see this"
    assert html =~ "No active grants."
    refute html =~ "Revoke"
  end

  test "an operator sees no standing-grants rows either (manage_grants is admin+)", %{conn: conn} do
    # operator holds `decide` (so the Revoke button's UI
    # predicate would pass) but NOT `manage_grants`, and grant rows only load with
    # manage_grants. The list errors → [], so the section is empty regardless of
    # the predicate (the GOV-005 visibility/context split never collides).
    {_owner_conn, owner, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(owner, account)

    request = pending_mcp_request!(account, owner, "owner-minted grant")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)

    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, _lv, html} =
      build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/approvals")

    assert html =~ "No active grants."
    refute html =~ "Revoke"
  end

  test "another account's pending requests and grants never leak onto the page", %{conn: conn} do
    # `for_subject` scopes pending / grants / decided to the
    # subject's account, so a foreign account's held action and standing grant are
    # invisible here even though they exist in the same DB.
    {conn, _user, account} = register_and_log_in(conn)

    {_b_conn, b_user, b_account} = register_and_log_in(build_conn())
    b_subject = Fixtures.Subjects.subject_for(b_user, b_account)

    # B has a pending request AND a standing grant.
    _b_pending = pending_request!(b_account, b_user.id, "account-B secret reboot")
    b_grant_request = pending_mcp_request!(b_account, b_user, "account-B grant")
    {:ok, _} = Approvals.approve_request(b_grant_request, b_subject, "ok", duration: :one_day)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    refute html =~ "account-B secret reboot"
    refute html =~ "account-B grant"
    # A's own page reads as genuinely empty, not as B's data.
    assert html =~ "Nothing waiting."
  end

  test "a pending-load error renders the danger empty-state, not 'Nothing waiting'", %{conn: conn} do
    # a crafted `?pending_after=` cursor makes
    # `list_pending_approval_requests` → `Repo.list` return {:error,:invalid_cursor}.
    # That collapses to [] but sets `pending_error?`, so the section must warn "a
    # held action may be waiting", NOT reassure with "Nothing waiting".
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} =
      live(conn, ~p"/app/#{account}/approvals?pending_after=not-a-real-cursor")

    assert html =~ "Couldn&#39;t load pending approvals."
    assert html =~ "a held action may be waiting"
    refute html =~ "Nothing waiting."
  end

  test "an empty queue shows the reassuring empty-state linking to policies", %{conn: conn} do
    # zero pending and no load error: the Pending section
    # renders the reassuring "Nothing waiting." empty-state (not the danger one),
    # with the link to /policies that explains where approvals come from.
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    assert html =~ "Nothing waiting."
    refute html =~ "Couldn&#39;t load pending approvals."
    # The empty-state points the operator at the policy that gates runs.
    assert html =~ ~p"/app/#{account}/policies"
  end

  test "empty grants and empty decided sections each show their explanatory empty-state", %{
    conn: conn
  } do
    # an owner (holds manage_grants, so grants DO load) with
    # zero grants and zero decided requests sees the explanatory empty-state for
    # each secondary section, not a blank gap.
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals")

    assert html =~ "No active grants."
    assert html =~ "No decided approvals yet."
  end

  test "grants and decided load errors collapse to empty silently — no danger banner", %{
    conn: conn
  } do
    # crafted `grants_after`/`decided_after` cursors make
    # both reads return {:error,_}. Unlike Pending, these historical sections run
    # through `list_or_empty/1`, so they render their normal empty-states with NO
    # danger banner (a stale grant/decision isn't the held-action hazard pending is).
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/app/#{account}/approvals?grants_after=not-a-cursor&decided_after=also-not"
      )

    assert html =~ "No active grants."
    assert html =~ "No decided approvals yet."
    # Only Pending escalates a load failure to a danger banner.
    refute html =~ "Couldn&#39;t load pending approvals."
  end

  test "an operator's crafted revoke_grant is denied gracefully", %{conn: conn} do
    # BUG. The Revoke button's UI predicate is
    # `subject_can_decide_approval?` (operator+), but `fetch_grant_by_id` requires
    # `manage_grants` (admin+) and returns {:error,:unauthorized} for an operator.
    # `ApprovalsLive.handle_event("revoke_grant", …)` only matches {:error,:not_found}
    # and {:ok, grant}, so the :unauthorized return raises CaseClauseError
    # (approvals_live.ex:42) instead of flashing a denial. A crafted event must be
    # refused, not crash the view.
    {_owner_conn, owner, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(owner, account)

    request = pending_mcp_request!(account, owner, "standing grant")
    {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)
    {:ok, [grant], _meta} = Approvals.list_grants_for_account(subject)

    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, lv, _html} =
      build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/approvals")

    html = render_click(lv, "revoke_grant", %{"id" => grant.id})

    assert html =~ "You don&#39;t have permission to do that."
    {:ok, [%{revoked_at: nil}], _meta} = Approvals.list_grants_for_account(subject)
  end

  describe "pagination" do
    setup %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "the decided table pages at 15 rows with a live pager", %{
      conn: conn,
      account: account
    } do
      for _ <- 1..16 do
        Fixtures.Approvals.create_request(account_id: account.id, status: :approved)
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals")

      # 15 of 16 render; the pager offers the next cursor page.
      assert has_element?(lv, "#decided-pager", "15 / 16")
      assert has_element?(lv, ~s(a[href*="decided_after="]))
    end
  end

  describe "max grant-lifetime cap" do
    setup %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "an owner sets the cap", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals")

      assert render_change(lv, "set_max_grant_lifetime", %{"seconds" => "86400"}) =~
               "Grant-lifetime cap updated."

      assert Emisar.Repo.reload!(account).settings.max_grant_lifetime_seconds == 86_400
    end

    test "an owner disables standing grants (cap 0) — active grants are swept, the page flips",
         %{conn: conn, account: account} do
      # A live grant, minted the real way (approve with a window).
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, account)
      request = pending_mcp_request!(account, user, "grant me a day")
      {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :one_day)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals")
      assert html =~ "linux.reboot"
      # Uncapped default — the Guardrails select shows it as the selected option.
      assert has_element?(lv, ~s(#approvals-grant-cap option[value=""][selected]))

      html = render_change(lv, "set_max_grant_lifetime", %{"seconds" => "0"})

      # The sweep revoked the grant (flash counts it), the setting stuck, and
      # the section speaks the disabled state everywhere the operator looks.
      assert html =~ "Standing grants disabled — 1 active grant revoked"
      assert Emisar.Repo.reload!(account).settings.max_grant_lifetime_seconds == 0
      assert html =~ "Standing grants are disabled."
      assert html =~ "Disabled for this account — every approval is single-use."
      assert {:ok, [], _} = Approvals.list_grants_for_account(subject)
    end

    test "an owner removes the cap", %{conn: conn, account: account} do
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 3600})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals")

      assert render_change(lv, "set_max_grant_lifetime", %{"seconds" => ""}) =~
               "Grant-lifetime cap removed"

      refute Emisar.Repo.reload!(account).settings.max_grant_lifetime_seconds
    end

    test "an operator is refused at the event level (IL-15 — owners + admins only)", %{
      account: account
    } do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/approvals")

      html = render_change(lv, "set_max_grant_lifetime", %{"seconds" => "86400"})

      assert html =~ "Only owners and admins can change this setting."
      refute Emisar.Repo.reload!(account).settings.max_grant_lifetime_seconds
    end
  end
end
