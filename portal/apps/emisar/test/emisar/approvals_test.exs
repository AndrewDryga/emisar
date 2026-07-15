defmodule Emisar.ApprovalsTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Approvals, Audit, Repo, Runs}
  alias Emisar.Approvals.{Decision, Grant, Request}
  alias Emisar.Fixtures
  alias Emisar.Runs.ActionRun

  defp run_fixture(opts \\ []) do
    account =
      Keyword.get(opts, :account) || Fixtures.Accounts.create_account()

    runner = Keyword.get(opts, :runner) || Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        # A real require-approval run is parked :pending_approval — the approval
        # finalizer only dispatches a run still in that state, so the fixture
        # must reflect the invariant (not the :pending default).
        status: :pending_approval
      })

    {account, run}
  end

  defp operator_subject(account) do
    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "owner"
      )

    Fixtures.Subjects.subject_for(operator, account, role: :owner)
  end

  # Drain the Swoosh test mailbox (notify runs inline under
  # :notify_approvers_async? false) and collect recipient addresses.
  defp notified_recipients(acc \\ []) do
    receive do
      {:email, email} ->
        notified_recipients(Enum.map(email.to, fn {_name, addr} -> addr end) ++ acc)
    after
      0 -> acc
    end
  end

  # Drain the Swoosh test mailbox and collect the email structs, so a test
  # can assert on both recipients and body (e.g. the approval deep link).
  defp notified_emails(acc \\ []) do
    receive do
      {:email, email} -> notified_emails([email | acc])
    after
      0 -> acc
    end
  end

  # -- Grants ---------------------------------------------------------

  defp insert_grant(account, key, opts) do
    Grant.Changeset.create(
      Map.merge(
        %{
          account_id: account.id,
          api_key_id: key.id,
          action_id: "linux.uptime",
          granted_by_id: opts[:granted_by_id] || Fixtures.Users.create_user().id,
          granted_at: DateTime.utc_now()
        },
        Map.new(opts)
      )
    )
    |> Repo.insert!()
  end

  # An MCP-sourced run (carries api_key_id) parked behind a pending
  # request — the shape approve_request needs to mint a durable grant.
  defp approvable_mcp_run do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        api_key_id: key.id,
        args: %{},
        args_sha256: "abc123",
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, user.id, "x")
    {subject, key, request}
  end

  # -- Configurable approval gate (GitHub-style) -----------------------

  # A fresh operator (owner) in the account, distinct from any other.
  defp distinct_operator(account) do
    user = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    Fixtures.Subjects.subject_for(user, account, role: :owner)
  end

  # Count of distinct approve votes recorded on a request.
  defp approved_count(request_id) do
    Repo.one(Decision.Query.approved_distinct_decider_count(request_id))
  end

  defp approval_gated_mcp_dispatch_setup do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    operator_subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
    mcp_subject = Emisar.Auth.Subject.for_api_key(key, account)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")

    _ =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        rules: %{
          "schema_version" => 2,
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "require_approval",
            "critical" => "deny"
          },
          "overrides" => []
        }
      )

    attrs = %{
      runner_id: runner.id,
      action_id: "linux.uptime",
      args: %{},
      reason: "deploy",
      source: "mcp",
      api_key_id: key.id,
      idempotency_key: "idem-#{System.unique_integer([:positive])}"
    }

    %{attrs: attrs, mcp_subject: mcp_subject, operator_subject: operator_subject}
  end

  defp request_notification_fixture do
    account = Fixtures.Accounts.create_account()
    decider = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: decider.id,
      role: "owner"
    )

    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        status: :pending_approval
      })

    %{account: account, run: run, decider: decider}
  end

  # Account + an online (subscribed) runner + a parked request snapshotting
  # `opts` (min_approvals / allow_self_approval). The requester is a separate
  # user so self-approval is opt-in per test.
  defp gated_request(opts \\ []) do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Emisar.Runners.subscribe_runner_transport(runner)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        # A real require-approval run is parked :pending_approval; the finalizer
        # only dispatches a run still in that state.
        status: :pending_approval
      })

    requester = Keyword.get(opts, :requested_by_id, Fixtures.Users.create_user().id)

    {:ok, request} =
      Approvals.create_request(run, requester, "needs review",
        min_approvals: Keyword.get(opts, :min_approvals, 1),
        allow_self_approval: Keyword.get(opts, :allow_self_approval, true)
      )

    %{account: account, runner: runner, run: run, request: request, requester_id: requester}
  end

  describe "list_pending_approval_requests/2" do
    test "only returns pending requests" do
      {account, run1} = run_fixture()
      {_, run2} = run_fixture(account: account)
      subject = operator_subject(account)

      {:ok, req_pending} = Approvals.create_request(run1, Fixtures.Users.create_user().id, nil)
      {:ok, req_to_deny} = Approvals.create_request(run2, Fixtures.Users.create_user().id, nil)
      {:ok, _} = Approvals.deny_request(req_to_deny, subject, "nope")

      {:ok, pending, _} = Approvals.list_pending_approval_requests(subject)
      ids = pending |> Enum.map(& &1.id)
      assert ids == [req_pending.id]
    end

    test "a multi-page walk returns pending requests oldest-first, once each" do
      {account, _} = run_fixture()
      subject = operator_subject(account)

      # Created oldest-first; the queue lists oldest-first. A cursor that
      # disagreed with the ORDER BY (the bug: ASC pipeline vs DESC cursor)
      # would skip/duplicate or reverse rows across pages.
      requests =
        for _ <- 1..6 do
          {_, run} = run_fixture(account: account)
          {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, nil)
          request
        end

      {:ok, all, _} = Approvals.list_pending_approval_requests(subject)
      assert Enum.map(all, & &1.id) == Enum.map(requests, & &1.id)

      walked = walk_pages(&Approvals.list_pending_approval_requests(subject, &1), 2)
      assert Enum.map(walked, & &1.id) == Enum.map(requests, & &1.id)
    end
  end

  describe "count_pending_approval_requests/1" do
    test "returns the count of pending rows (decided rows excluded)" do
      {account, run1} = run_fixture()
      {_, run2} = run_fixture(account: account)
      {_, run3} = run_fixture(account: account)
      subject = operator_subject(account)

      {:ok, _} = Approvals.create_request(run1, Fixtures.Users.create_user().id, nil)
      {:ok, _} = Approvals.create_request(run2, Fixtures.Users.create_user().id, nil)
      {:ok, to_deny} = Approvals.create_request(run3, Fixtures.Users.create_user().id, nil)
      {:ok, _} = Approvals.deny_request(to_deny, subject, "no")

      assert Approvals.count_pending_approval_requests(subject) == 2
    end

    test "returns 0 when there are no pending requests" do
      {account, _} = run_fixture()
      assert Approvals.count_pending_approval_requests(operator_subject(account)) == 0
    end

    test "is scoped to the subject's account (cross-account isolation)" do
      {account_a, run_a} = run_fixture()
      {account_b, _} = run_fixture()
      {:ok, _} = Approvals.create_request(run_a, Fixtures.Users.create_user().id, nil)

      # Account B has zero requests; the helper must not leak A's count.
      assert Approvals.count_pending_approval_requests(operator_subject(account_a)) == 1
      assert Approvals.count_pending_approval_requests(operator_subject(account_b)) == 0
    end

    test "returns 0 without raising when the subject lacks view permission" do
      # Contract: `count_*` is safe to call from the sidebar — never
      # raises, returns 0 for unauthorized callers so the badge silently
      # disappears rather than crashing the LV mount.
      {account, _} = run_fixture()

      # To test the rejection branch we craft an empty-permissions
      # subject directly.
      no_perms = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert Approvals.count_pending_approval_requests(no_perms) == 0
    end
  end

  describe "report_request_stats/3" do
    test "tallies window requested/approved/denied plus current pending" do
      account = Fixtures.Accounts.create_account()
      from = ~U[2026-06-01 00:00:00.000000Z]
      to = ~U[2026-07-01 00:00:00.000000Z]
      in_window = ~U[2026-06-15 12:00:00.000000Z]

      Fixtures.Approvals.create_request(
        account_id: account.id,
        status: :approved,
        requested_at: in_window
      )

      Fixtures.Approvals.create_request(
        account_id: account.id,
        status: :approved,
        requested_at: in_window
      )

      Fixtures.Approvals.create_request(
        account_id: account.id,
        status: :denied,
        requested_at: in_window
      )

      # A still-pending request in the window (counts toward requested + pending).
      Fixtures.Approvals.create_request(account_id: account.id, requested_at: in_window)

      # Requested at the exclusive upper bound — outside the window.
      Fixtures.Approvals.create_request(
        account_id: account.id,
        status: :approved,
        requested_at: to
      )

      stats = Approvals.report_request_stats(account.id, from, to)
      assert stats.requested == 4
      assert stats.approved == 2
      assert stats.denied == 1
      assert stats.pending == 1
    end

    test "excludes another account's requests (cross-account isolation)" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      from = ~U[2026-06-01 00:00:00.000000Z]
      to = ~U[2026-07-01 00:00:00.000000Z]
      at = ~U[2026-06-15 12:00:00.000000Z]

      Fixtures.Approvals.create_request(
        account_id: account.id,
        status: :approved,
        requested_at: at
      )

      Fixtures.Approvals.create_request(
        account_id: other_account.id,
        status: :approved,
        requested_at: at
      )

      stats = Approvals.report_request_stats(account.id, from, to)
      assert stats.requested == 1
      assert stats.approved == 1
      assert stats.pending == 0
    end
  end

  describe "pending_queue_stats/0 (fleet-wide telemetry sampler)" do
    test "an empty queue reports zero count and zero age" do
      assert %{count: 0, oldest_age_seconds: 0} = Approvals.pending_queue_stats()
    end

    test "counts unresolved requests across ALL accounts (fleet-wide, no subject)" do
      {_account_a, run_a} = run_fixture()
      {_account_b, run_b} = run_fixture()
      {:ok, _} = Approvals.create_request(run_a, Fixtures.Users.create_user().id, "a")
      {:ok, _} = Approvals.create_request(run_b, Fixtures.Users.create_user().id, "b")

      assert %{count: 2} = Approvals.pending_queue_stats()
    end

    test "oldest_age_seconds reflects the longest-waiting request" do
      {_account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

      # Backdate the request 90s into the past so the age is deterministic.
      query = Request.Query.all() |> Request.Query.by_id(request.id)
      Repo.update_all(query, set: [inserted_at: DateTime.add(DateTime.utc_now(), -90, :second)])

      assert %{count: 1, oldest_age_seconds: age} = Approvals.pending_queue_stats()
      assert age >= 90
    end

    test "a resolved (decided) request no longer counts" do
      {account, run} = run_fixture()
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(operator, account, role: :owner)
      {:ok, request} = Approvals.create_request(run, operator.id, "x")

      assert %{count: 1} = Approvals.pending_queue_stats()

      {:ok, _} = Approvals.deny_request(request, subject, "no")

      assert %{count: 0, oldest_age_seconds: 0} = Approvals.pending_queue_stats()
    end
  end

  describe "list_approval_requests_for_account/2" do
    test "lists pending requests with no filter, narrows by status, scopes to the account" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      subject = operator_subject(account)

      # No :status filter — the pending request is returned.
      assert {:ok, requests, _meta} = Approvals.list_approval_requests_for_account(subject)
      assert Enum.any?(requests, &(&1.id == request.id))

      # A non-matching status filter narrows it out.
      assert {:ok, approved_only, _meta} =
               Approvals.list_approval_requests_for_account(subject, status: :approved)

      refute Enum.any?(approved_only, &(&1.id == request.id))

      # Another account never sees it.
      {other_account, _run} = run_fixture()

      assert {:ok, theirs, _meta} =
               Approvals.list_approval_requests_for_account(operator_subject(other_account))

      refute Enum.any?(theirs, &(&1.id == request.id))
    end

    test "filters by status (a decided request shows under :denied, not :pending)" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      subject = operator_subject(account)
      {:ok, _} = Approvals.deny_request(request, subject, "no")

      assert {:ok, [%Request{status: :denied}], _} =
               Approvals.list_approval_requests_for_account(subject, status: "denied")

      assert {:ok, [], _} =
               Approvals.list_approval_requests_for_account(subject, status: "pending")
    end
  end

  describe "fetch_approval_request_by_id/3" do
    test "returns the request inside the subject's account; cross-account is :not_found" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      subject = operator_subject(account)

      assert {:ok, %Request{id: id}} = Approvals.fetch_approval_request_by_id(request.id, subject)
      assert id == request.id

      {other_account, _run} = run_fixture()
      other_subject = operator_subject(other_account)

      assert {:error, :not_found} =
               Approvals.fetch_approval_request_by_id(request.id, other_subject)

      assert {:error, :not_found} = Approvals.fetch_approval_request_by_id("not-a-uuid", subject)
    end
  end

  describe "fetch_approval_request_by_run_id/2" do
    setup do
      {account, run} = run_fixture()
      operator = Fixtures.Users.create_user()
      {:ok, request} = Approvals.create_request(run, operator.id, "x")
      subject = operator_subject(account)
      %{account: account, run: run, operator: operator, request: request, subject: subject}
    end

    test "finds the run's single request, account-scoped", %{
      run: run,
      request: request,
      subject: subject
    } do
      assert {:ok, %Request{id: id}} = Approvals.fetch_approval_request_by_run_id(run.id, subject)
      assert id == request.id

      {other_account, _run_b} = run_fixture()
      other_subject = operator_subject(other_account)

      assert {:error, :not_found} =
               Approvals.fetch_approval_request_by_run_id(run.id, other_subject)
    end

    test "a viewer (no view_approvals) is refused with :unauthorized", %{
      account: account,
      run: run
    } do
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      _viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      # view_approvals is granted to viewers, so they CAN read — instead pin the
      # rejection with a crafted empty-permission subject.
      no_perms = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert {:error, :unauthorized} =
               Approvals.fetch_approval_request_by_run_id(run.id, no_perms)
    end

    test "still returns a DENIED request — the decision record persists", %{
      run: run,
      request: request,
      subject: subject
    } do
      {:ok, _} = Approvals.deny_request(request, subject, "not during the change freeze")

      # Denying UPDATES status (no delete, no soft-delete) and the fetch is
      # status-agnostic (`all()`), so a denied request stays fetchable — the
      # run_detail banner, approval-detail page, and "Review approval" links all
      # depend on it. (2026-06-14 investigation: the dev-time {:ok}→:not_found
      # flake was a sandbox/broadcast artifact, NOT a worker removing denied
      # requests — the expiry sweeper is pending-only. This test guards the
      # conclusion against a future status filter that would re-break it.)
      assert {:ok, %Request{id: id, status: :denied}} =
               Approvals.fetch_approval_request_by_run_id(run.id, subject)

      assert id == request.id
    end
  end

  describe "fetch_request_for_visible_run/2" do
    test "lets an API client read only the approval attached to its visible account run" do
      {account, run} = run_fixture()
      owner = operator_subject(account)

      {:ok, request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "review required")

      {:ok, _raw, key} = Emisar.ApiKeys.create_key(%{name: "approval observer"}, owner)
      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, fetched} = Approvals.fetch_request_for_visible_run(run, subject)
      assert fetched.id == request.id

      {_other_account, foreign_run} = run_fixture()

      assert {:error, :not_found} =
               Approvals.fetch_request_for_visible_run(foreign_run, subject)
    end

    test "still requires run-view permission" do
      {account, run} = run_fixture()

      no_permissions = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert {:error, :unauthorized} =
               Approvals.fetch_request_for_visible_run(run, no_permissions)
    end
  end

  describe "list_decisions_for_request/2" do
    setup do
      %{account: account, request: request} = gated_request(min_approvals: 3)
      %{account: account, request: request}
    end

    test "returns the recorded votes oldest-first with the decider preloaded", %{
      account: account,
      request: request
    } do
      a = distinct_operator(account)
      b = distinct_operator(account)

      {:ok, _} = Approvals.approve_request(request, a, "lgtm-1")
      {:ok, _} = Approvals.deny_request(request, b, "changed my mind")

      assert {:ok, decisions} = Approvals.list_decisions_for_request(request, a)
      # Oldest-first: a's approve, then b's deny.
      assert Enum.map(decisions, & &1.decision) == [:approve, :deny]
      # The decider is preloaded for the UI tally (not an unloaded assoc).
      assert Enum.map(decisions, & &1.decider.id) == [a.actor.id, b.actor.id]
    end

    test "a viewer (no view_approvals) is refused with :unauthorized", %{
      account: account,
      request: request
    } do
      no_perms = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert {:error, :unauthorized} = Approvals.list_decisions_for_request(request, no_perms)
    end

    test "an owner of another account can't read this request's decisions (cross-account)", %{
      request: request
    } do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # `Subject.ensure_in_account` refuses the cross-account read.
      assert {:error, :not_found} = Approvals.list_decisions_for_request(request, subject_b)
    end
  end

  describe "approved_count_for_request/2" do
    setup do
      %{account: account, request: request} = gated_request(min_approvals: 3)
      %{account: account, request: request}
    end

    test "tallies distinct approvers, counting a deny as zero", %{
      account: account,
      request: request
    } do
      a = distinct_operator(account)
      b = distinct_operator(account)

      assert {:ok, 0} = Approvals.approved_count_for_request(request, a)

      {:ok, _} = Approvals.approve_request(request, a, "yes")
      assert {:ok, 1} = Approvals.approved_count_for_request(request, a)

      # A deny doesn't add to the approver tally.
      {:ok, _} = Approvals.deny_request(request, b, "no")
      assert {:ok, 1} = Approvals.approved_count_for_request(request, a)
    end

    test "a viewer (no view_approvals) is refused with :unauthorized", %{
      account: account,
      request: request
    } do
      no_perms = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert {:error, :unauthorized} = Approvals.approved_count_for_request(request, no_perms)
    end

    test "an owner of another account can't read this request's count (cross-account)", %{
      request: request
    } do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :not_found} = Approvals.approved_count_for_request(request, subject_b)
    end
  end

  describe "create_request/4" do
    test "creates an approval request in :pending status" do
      {_account, run} = run_fixture()
      operator = Fixtures.Users.create_user()

      assert {:ok, %Request{status: :pending, run_id: run_id}} =
               Approvals.create_request(run, operator.id, "high-risk action")

      assert run_id == run.id
    end

    test "sets expires_at 24h from now by default" do
      {_account, run} = run_fixture()
      user = Fixtures.Users.create_user()
      {:ok, request} = Approvals.create_request(run, user.id, "x")

      assert request.expires_at != nil
      assert DateTime.diff(request.expires_at, DateTime.utc_now(), :hour) in 23..24
    end

    test "a duplicate request for the same run is rejected by the unique constraint" do
      {_account, run} = run_fixture()
      {:ok, _} = Approvals.create_request(run, Fixtures.Users.create_user().id, "first")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Approvals.create_request(run, Fixtures.Users.create_user().id, "second")

      assert "has already been taken" in errors_on(changeset).run_id
    end
  end

  describe "create_request/4 approver notifications" do
    setup do
      account = Fixtures.Accounts.create_account()

      members =
        for role <- ~w(owner admin operator viewer), into: %{} do
          user = Fixtures.Users.create_user()

          _ =
            Fixtures.Memberships.create_membership(
              account_id: account.id,
              user_id: user.id,
              role: role
            )

          {role, user}
        end

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      %{account: account, run: run, members: members}
    end

    test "emails the deciders (owner/admin/operator), never viewers", %{
      run: run,
      members: members
    } do
      # Requested by an unrelated user so no decider is excluded as the asker.
      {:ok, _req} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs approval")

      recipients = notified_recipients()

      assert members["owner"].email in recipients
      assert members["admin"].email in recipients
      assert members["operator"].email in recipients
      refute members["viewer"].email in recipients
    end

    test "excludes the requester from their own notification", %{run: run, members: members} do
      {:ok, _req} = Approvals.create_request(run, members["owner"].id, "needs approval")

      recipients = notified_recipients()

      refute members["owner"].email in recipients
      assert members["admin"].email in recipients
    end

    test "stays within the request's account — other tenants aren't emailed", %{
      run: run,
      members: members
    } do
      other_owner = Fixtures.Users.create_user()
      other_account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: other_owner.id,
          role: "owner"
        )

      {:ok, _req} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs approval")

      recipients = notified_recipients()

      assert members["owner"].email in recipients
      refute other_owner.email in recipients
    end
  end

  describe "create_request_in_multi/5" do
    # create_request_in_multi composes the request insert into create_run's
    # dispatch transaction; the approval-gated MCP dispatch path is its real
    # exercise — a gated run and its request must commit atomically.
    test "approval-gated MCP dispatch creates a pending run and request through the domain path" do
      %{attrs: attrs, mcp_subject: mcp_subject, operator_subject: operator_subject} =
        approval_gated_mcp_dispatch_setup()

      assert {:ok, :pending_approval, %ActionRun{status: :pending_approval} = run} =
               Runs.dispatch_run(attrs, mcp_subject)

      assert {:ok, [%Request{run_id: run_id, status: :pending}], _} =
               Approvals.list_pending_approval_requests(operator_subject)

      assert run_id == run.id
    end

    test "an idempotency-replayed require-approval dispatch files only ONE request" do
      %{attrs: attrs, mcp_subject: mcp_subject} = approval_gated_mcp_dispatch_setup()

      # Two calls with the same Idempotency-Key resolve to the SAME run; the
      # request insert (composed into create_run's Multi, on_conflict :nothing)
      # must not file a second request for it.
      assert {:ok, :pending_approval, run1} = Runs.dispatch_run(attrs, mcp_subject)
      assert {:ok, :pending_approval, run2} = Runs.dispatch_run(attrs, mcp_subject)
      assert run1.id == run2.id

      requests = Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.all()
      assert length(requests) == 1
      assert run1.status == :pending_approval
    end

    test "inserts the request step into a caller's Multi, reading the run from changes" do
      {_account, run} = run_fixture()

      # Drive the composed step directly: seed the run under the run_key the
      # Multi reads, then assert the :approval_request step inserted the row.
      assert {:ok, %{approval_request: %Request{run_id: run_id, status: :pending}}} =
               Multi.new()
               |> Multi.put(:run, run)
               |> Approvals.create_request_in_multi(
                 :run,
                 Fixtures.Users.create_user().id,
                 "x",
                 []
               )
               |> Repo.transaction()

      assert run_id == run.id
    end
  end

  describe "notify_request_created/1" do
    setup do
      request_notification_fixture()
    end

    test "broadcasts the request and emails the deciders (the create_run post-commit hook)", %{
      account: account,
      run: run,
      decider: decider
    } do
      # Insert the request WITHOUT going through create_request (which notifies
      # on its own), so this exercises the post-commit hook in isolation.
      {:ok, request} =
        Request.Changeset.create(%{
          account_id: account.id,
          run_id: run.id,
          requested_by_id: Fixtures.Users.create_user().id,
          requested_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Repo.insert()

      :ok = Approvals.subscribe_account_approvals(account.id)

      assert :ok = Approvals.notify_request_created(%{approval_request: request, run: run})

      assert_receive {:approval_updated, %Request{id: id}}
      assert id == request.id

      emails = notified_emails()
      recipients = Enum.flat_map(emails, &Enum.map(&1.to, fn {_n, addr} -> addr end))
      assert decider.email in recipients

      # The queued email carries the canonical slugged approval deep link.
      assert Enum.any?(emails, &(&1.text_body =~ "/app/#{account.slug}/approvals/#{request.id}"))
    end
  end

  describe "notify_request_created/2" do
    setup do
      request_notification_fixture()
    end

    test "the dynamic-Multi arity emits the same post-commit notification", %{
      account: account,
      run: run,
      decider: decider
    } do
      {:ok, request} =
        Request.Changeset.create(%{
          account_id: account.id,
          run_id: run.id,
          requested_by_id: Fixtures.Users.create_user().id,
          requested_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Repo.insert()

      :ok = Approvals.subscribe_account_approvals(account.id)
      assert :ok = Approvals.notify_request_created(request, run)
      assert_receive {:approval_updated, %Request{id: id}}
      assert id == request.id
      assert decider.email in notified_recipients()
    end
  end

  describe "approve_request/3" do
    setup do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      %{account: account, run: run, subject: subject}
    end

    test "transitions the run to :sent + writes an audit event", %{run: run, subject: subject} do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, subject, "lgtm")

      assert Enum.any?(
               Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.approved")
             )
    end

    test "a decision emits [:emisar, :approval, :decided] tagged by the decision", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      handler = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler,
        [:emisar, :approval, :decided],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:approval_decided, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, {%Request{status: :approved}, _}} =
               Approvals.approve_request(request, subject, "lgtm")

      assert_receive {:approval_decided, %{count: 1}, %{decision: :approved}}
    end

    test "an expired (not-yet-swept) pending request cannot be approved", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      # Simulate the request lapsing past its 24h expiry before the
      # every-few-minutes sweep flips it to :expired — the row is still
      # :pending, so this is the window the decision predicate must close.
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {1, _} =
        Request.Query.all()
        |> Request.Query.by_id(request.id)
        |> Repo.update_all(set: [expires_at: past])

      assert {:error, :expired} = Approvals.approve_request(request, subject, "too late")

      # Refused, not flipped to approved — the run is never dispatched; the
      # sweep will expire it shortly.
      assert %Request{status: :pending} = Repo.reload!(request)
      assert %ActionRun{status: status} = Repo.reload!(run)
      refute status == :sent
    end

    test "a viewer (cannot decide) is refused with :unauthorized", %{account: account, run: run} do
      decider = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, decider.actor.id, "needs approve")

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Approvals.approve_request(request, viewer_subject, "no rights")
    end

    test "an owner of account B cannot approve account A's request (cross-account → :not_found)" do
      {account_a, run_a} = run_fixture()
      decider_a = operator_subject(account_a)
      {:ok, req_a} = Approvals.create_request(run_a, decider_a.actor.id, "needs approve")

      account_b = Fixtures.Accounts.create_account()
      owner_b = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: owner_b.id,
          role: "owner"
        )

      subject_b = Fixtures.Subjects.subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Approvals.approve_request(req_a, subject_b, "wrong account")
    end

    test "ABUSE: a forged request struct cannot cross the account boundary" do
      {account_a, run_a} = run_fixture()
      decider_a = operator_subject(account_a)
      {:ok, request_a} = Approvals.create_request(run_a, decider_a.actor.id, "needs approve")

      account_b = Fixtures.Accounts.create_account()
      subject_b = operator_subject(account_b)
      forged_request = %{request_a | account_id: account_b.id}

      assert {:error, :not_found} = Approvals.approve_request(forged_request, subject_b, "forged")
      assert %Request{status: :pending} = Repo.reload!(request_a)
      assert approved_count(request_a.id) == 0
      assert %ActionRun{status: :pending_approval} = Repo.reload!(run_a)
    end

    test "the second operator's decision loses with :already_decided" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      first = operator_subject(account)
      second = operator_subject(account)

      assert {:ok, _} = Approvals.deny_request(request, first, "no")
      assert {:error, :already_decided} = Approvals.approve_request(request, second)
      assert {:error, :already_decided} = Approvals.deny_request(request, second, "again")
    end
  end

  describe "approve_request/4 with grant duration" do
    # An MCP api-key-backed account + owner subject. Tests that mint a grant
    # build their own runner/run/request (the run's action/args vary per test).
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      subject = Fixtures.Subjects.membership_subject(membership)
      %{account: account, user: user, subject: subject, key: key}
    end

    test ":once duration creates no grant" do
      {account, run} = run_fixture()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, _} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: run.runner_id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :once)

      assert [] = Fixtures.Approvals.grants_for_api_key(key.id)
    end

    test "a windowed duration on an operator-sourced run mints no grant" do
      # a grant only exists to let an LLM's IDENTICAL
      # follow-up api-key call skip the gate. An operator-sourced run has no
      # api_key (`api_key_id: nil`), so `mint_grant/4`'s nil-key clause returns
      # `{:ok, nil}` even for a windowed duration: there's no key for a grant to
      # cover. The run still dispatches; only the grant is absent.
      {account, run} = run_fixture()
      assert run.api_key_id == nil
      subject = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "x")

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, subject, "ok",
                 duration: :one_day,
                 scope: :exact_args
               )

      assert {:ok, [], _meta} = Approvals.list_grants_for_account(subject)
    end

    test ":one_day creates a grant with expires_at ~24h from now", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(request, subject, nil, duration: :one_day, scope: :exact_args)

      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      assert grant.action_id == "linux.uptime"
      assert grant.args_sha256 == "abc123"
      assert grant.expires_at != nil
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :hour) in 23..24

      # Minting the grant dispatched the approved run — that's its first
      # use, so it starts at 1 (never "not used yet") with last_used_at set.
      assert grant.uses_count == 1
      assert grant.last_used_at != nil
    end

    test "honors the operator's max_uses cap on the minted grant", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :one_day, max_uses: 5)

      # Regression: approve_request used to drop :max_uses from grant_attrs,
      # minting an UNCAPPED grant even when the operator set a cap.
      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      assert grant.max_uses == 5
    end

    test "preloads the originating run so the UI can show the locked args", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "postgres.vacuum",
          source: "mcp",
          api_key_id: key.id,
          args: %{"table" => "users", "full" => true},
          args_sha256: "deadbeef",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(request, subject, nil, duration: :one_day, scope: :exact_args)

      # The grant stores only the hash; the UI opts into approval_request
      # → run so the operator can see exactly what args it's locked to.
      {:ok, [grant], _} =
        Approvals.list_grants_for_account(subject, preload: [:approval_request_run])

      assert grant.approval_request.run.args == %{"table" => "users", "full" => true}
    end

    test "a failed grant insert rolls the approval transaction back — no dispatch, no grant, no approved audit",
         %{account: account, user: user, subject: subject, key: key} do
      # Regression: when the operator approves "for 24h" but the durable
      # grant insert fails, the old code did `_ -> nil` and committed the
      # approval + dispatched as if it were `:once` — the grant silently
      # no-ops, the audit row records `grant_id: nil`, and the next identical
      # LLM call re-prompts. The fix rolls the grant/audit/dispatch
      # transaction back so the operator's intent isn't lost without a trace
      # (the error surfaces instead).
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      # Force create_grant to fail deterministically: blank the run's
      # action_id (bypassing the create changeset). Grant.Changeset.create
      # requires action_id, so the insert returns {:error, changeset} — the
      # exact branch that must roll back rather than commit as `:once`.
      {1, _} =
        ActionRun.Query.all()
        |> ActionRun.Query.by_id(run.id)
        |> Repo.update_all(set: [action_id: ""])

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:error, {:grant_failed, %Ecto.Changeset{}}} =
               Approvals.approve_request(request, subject, "ok", duration: :one_day)

      # No grant was minted.
      assert [] = Fixtures.Approvals.grants_for_api_key(key.id)

      # The run was NOT dispatched (the rollback aborted before dispatch).
      refute_receive {:cloud_to_runner, _generation, _}, 100

      # The approval.approved audit row was inside the rolled-back
      # transaction, so it never committed.
      {:ok, events, _} =
        Audit.list_events(subject, page: [limit: 50])

      refute Enum.any?(events, &(&1.event_type == "approval.approved"))
    end

    test ":any_args scope drops args_sha256 so any args match", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(request, subject, nil, duration: :ninety_days, scope: :any_args)

      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      assert grant.args_sha256 == nil
      # Every grant carries an explicit re-confirm horizon — there is
      # deliberately no indefinite duration.
      assert %DateTime{} = grant.expires_at
    end
  end

  describe "approve_request grant TTLs" do
    setup do
      {subject, key, request} = approvable_mcp_run()
      %{subject: subject, key: key, request: request}
    end

    test ":one_hour mints a grant expiring ~1h out", %{
      subject: subject,
      key: key,
      request: request
    } do
      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :one_hour)

      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      assert grant.expires_at != nil
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :minute) in 59..60
    end

    test ":thirty_days mints a grant expiring ~30d out", %{
      subject: subject,
      key: key,
      request: request
    } do
      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :thirty_days)

      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      assert grant.expires_at != nil
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :day) in 29..30
    end

    # there is deliberately NO indefinite grant. `expires_at_for/2`
    # has no catch-all, so a duration atom outside the five whitelisted windows
    # CRASHES on a finalizing api-key approve rather than minting a grant with a
    # nil (never-expiring) horizon. The web layer parses operator input down to
    # exactly these atoms; a value reaching mint outside them is a bug, and failing
    # loud is the safe behavior. No grant is left behind.
    test "an unknown duration atom crashes the mint instead of minting a never-expiring grant",
         %{subject: subject, key: key, request: request} do
      assert_raise FunctionClauseError, fn ->
        Approvals.approve_request(request, subject, nil, duration: :forever)
      end

      assert [] = Fixtures.Approvals.grants_for_api_key(key.id)
    end
  end

  describe "approve_request — signed-dispatch freshness gate (option b)" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # The runner enforces signing with a 1h freshness window.
      {:ok, runner} =
        Emisar.Runners.apply_state(runner, %{
          "enforce_signatures" => true,
          "max_attestation_age_seconds" => 3600
        })

      requester = Fixtures.Users.create_user()
      approver = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: approver.id,
          role: "owner"
        )

      approver_subject = Fixtures.Subjects.subject_for(approver, account, role: :owner)

      %{
        account: account,
        runner: runner,
        requester: requester,
        approver_subject: approver_subject
      }
    end

    test "approving a run whose signature aged out while parked is refused up front", %{
      account: account,
      runner: runner,
      requester: requester,
      approver_subject: approver_subject
    } do
      # Parked with a signature already 2h old — it would be refused at dispatch.
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{},
          status: :pending_approval,
          attestation: %{"key_id" => "k", "sig" => "x", "issued_at" => stale}
        })

      {:ok, request} = Approvals.create_request(run, requester.id, "please")

      # Refused before finalizing, so there's no approved-but-dead run; the
      # request stays pending for a re-issued (freshly-signed) request.
      assert {:error, :attestation_stale} =
               Approvals.approve_request(request, approver_subject, "go")

      assert %Request{status: :pending} = Repo.reload!(request)
    end

    test "approving a run with a still-fresh signature proceeds normally", %{
      account: account,
      runner: runner,
      requester: requester,
      approver_subject: approver_subject
    } do
      fresh = DateTime.to_iso8601(DateTime.utc_now())
      valid_until = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{},
          status: :pending_approval,
          attestation: %{
            "key_id" => "k",
            "sig" => "x",
            "issued_at" => fresh,
            "cert" => %{"valid_until" => valid_until}
          }
        })

      {:ok, request} = Approvals.create_request(run, requester.id, "please")

      assert {:ok, {%Request{status: :approved}, _run}} =
               Approvals.approve_request(request, approver_subject, "go")
    end
  end

  describe "approve_request — min_approvals threshold" do
    test "min_approvals: 2 — first approve records pending (no dispatch), second distinct operator finalizes + dispatches" do
      %{account: account, request: request, run: run} = gated_request(min_approvals: 2)
      a = distinct_operator(account)
      b = distinct_operator(account)

      # First approve: recorded, sub-threshold — run NOT sent.
      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, a, "lgtm-1")

      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert %ActionRun{status: status1} = Repo.reload!(run)
      refute status1 == :sent
      assert approved_count(request.id) == 1

      # Second DISTINCT operator: threshold met → approved + dispatched.
      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, b, "lgtm-2")

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      assert approved_count(request.id) == 2
    end

    test "min_approvals defaults to 1 — a single approve finalizes + dispatches (today's behavior)" do
      %{account: account, request: request} = gated_request()
      operator = distinct_operator(account)

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, operator, "ok")

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end

    test "ABUSE: a single operator approving twice counts once — second is :already_decided, not dispatched" do
      %{account: account, request: request} = gated_request(min_approvals: 2)
      operator = distinct_operator(account)

      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, operator, "first")

      # Same operator votes again under min 2 — the unique index rejects it.
      assert {:error, :already_decided} =
               Approvals.approve_request(request, operator, "again")

      assert approved_count(request.id) == 1
      assert %Request{status: :pending} = Repo.reload!(request)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end
  end

  describe "approve_request — self-approval gate" do
    # The requester is also an owner (so they CAN decide) on an operator-sourced
    # parked run. Each test files its own request with the self-approval posture
    # under test.
    setup do
      requester = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(requester, account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      %{requester: requester, subject: subject, run: run}
    end

    test "ABUSE: self-approval is refused server-side even when the UI would hide the button", %{
      requester: requester,
      subject: subject,
      run: run
    } do
      # The requester is the operator approving. allow_self_approval: false.
      {:ok, request} =
        Approvals.create_request(run, requester.id, "x",
          min_approvals: 1,
          allow_self_approval: false
        )

      assert {:error, :self_approval_forbidden} =
               Approvals.approve_request(request, subject, "approving my own")

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "a DIFFERENT operator can still approve when self-approval is forbidden" do
      %{account: account, request: request, requester_id: requester_id} =
        gated_request(min_approvals: 1, allow_self_approval: false)

      # Sanity: the requester is set and someone else is approving.
      other = distinct_operator(account)
      refute other.actor.id == requester_id

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, other, "ok")

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end

    test "a permissive request lets its requester self-approve (self-approval allowed)", %{
      requester: requester,
      subject: subject,
      run: run
    } do
      {:ok, request} =
        Approvals.create_request(run, requester.id, "x",
          min_approvals: 1,
          allow_self_approval: true
        )

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, subject, "approving my own")

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end

    # a nil requester has no "self" to block (vacuous, not a
    # bypass): even with allow_self_approval: false the self-check can't match, so
    # the gate is min_approvals alone — N distinct deciders still required.
    test "a nil requester is vacuously non-self; min_approvals still requires N distinct" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      # Operator-source run (no api_key) so effective_requester keeps the nil.
      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      {:ok, request} =
        Approvals.create_request(run, nil, "x", min_approvals: 2, allow_self_approval: false)

      assert is_nil(Repo.reload!(request).requested_by_id)

      a = distinct_operator(account)
      b = distinct_operator(account)

      # First approve is sub-threshold (no self to short-circuit, no bypass either).
      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, a, "lgtm-1")

      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert approved_count(request.id) == 1

      # Second distinct operator reaches the threshold.
      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, b, "lgtm-2")

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end

    # an MCP run's requested_by_id is nil, so
    # effective_requester resolves "self" to the api-key OWNER; the owner can't
    # launder a self-approval through their own key under allow_self_approval:
    # false, while a different operator still approves.
    test "ABUSE: an MCP run (requested_by_id nil) attributes self to the api-key owner; the owner can't self-approve" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: owner.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      # MCP-triggered: requested_by_id is nil. The request must record the
      # api-key OWNER as the effective requester.
      {:ok, request} =
        Approvals.create_request(run, nil, "x", min_approvals: 1, allow_self_approval: false)

      assert request.requested_by_id == owner.id

      # The owner (the human behind the key) cannot launder a self-approval
      # through their own key.
      assert {:error, :self_approval_forbidden} =
               Approvals.approve_request(request, owner_subject, "self via my key")

      assert %Request{status: :pending} = Repo.reload!(request)
      refute_receive {:cloud_to_runner, _generation, _}, 100

      # A DIFFERENT operator can approve.
      other = distinct_operator(account)

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, other, "ok")

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end
  end

  describe "approve_request — pack re-trust before approve (at the approve gate)" do
    # the approve path re-gates pack trust (recheck_trust)
    # before re-dispatching. A pack that drifted to :pending while the run was
    # parked makes the approve fail CLOSED — a tampered re-advertisement is never
    # shipped just because an approval window was open.
    test "approving a run whose pack drifted to :pending fails closed with :pack_untrusted" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      # A custom (no-baseline) pack lands :pending — the same untrusted state a
      # tampered re-advertisement produces during the approval window.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:DRIFT"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "high",
              "args" => []
            }
          ]
        })

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "custom.do",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      {:ok, request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs review")

      operator = distinct_operator(account)

      assert {:error, :pack_untrusted} = Approvals.approve_request(request, operator, "ok")

      # The run never reached the runner, and the request is left pending to retry.
      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert %Request{status: :pending} = Repo.reload!(request)
    end

    test "an in-flight request keeps its snapshotted threshold when the policy later changes" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      # Created under min 2 (the policy's posture at dispatch time).
      {:ok, request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "x", min_approvals: 2)

      assert request.min_approvals == 2

      # A later policy edit to min 1 must NOT move this in-flight request's bar
      # — it snapshots the value, not the live policy.
      a = distinct_operator(account)
      b = distinct_operator(account)

      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, a, "one")

      refute_receive {:cloud_to_runner, _generation, _}, 100

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, b, "two")
    end

    # the allow_self_approval posture is snapshotted onto the
    # request at CREATION (mirrors the min_approvals snapshot above). Flipping the
    # account policy to forbid self-approval AFTER the request exists must NOT
    # retroactively block the requester from approving this in-flight run: the
    # snapshot taken at dispatch time wins, never the live policy.
    test "an in-flight request keeps its self-approval snapshot when the policy later forbids it" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      # The requester is also an owner, so they CAN decide — self-approval is the
      # thing under test, not the permission.
      requester = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "owner"
        )

      requester_subject = Fixtures.Subjects.subject_for(requester, account, role: :owner)

      # Snapshotted self-approval-ALLOWED (the policy's posture at dispatch time).
      {:ok, request} =
        Approvals.create_request(run, requester.id, "x",
          min_approvals: 1,
          allow_self_approval: true
        )

      assert request.allow_self_approval == true

      # The account policy is tightened to forbid self-approval AFTER the request
      # was filed — this must not reach back into the parked request.
      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{"low" => "allow", "medium" => "allow"},
            "overrides" => [],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
          }
        )

      # The requester self-approves and it finalizes + dispatches — the snapshot,
      # not the now-stricter live policy, governs.
      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(
                 request,
                 requester_subject,
                 "self, but snapshot allows it"
               )

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end
  end

  describe "deny_request/3" do
    setup do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      %{account: account, run: run, subject: subject}
    end

    test "transitions the run to :cancelled + writes an audit event", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, subject, "not now")

      assert Enum.any?(
               Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.denied")
             )
    end

    test "cancels the run with the built-in 'approval denied' message when no reason is given", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "x")

      assert {:ok, {%Request{status: :denied}, cancelled_run}} =
               Approvals.deny_request(request, subject)

      assert cancelled_run.status == :cancelled
    end

    test "a viewer (cannot decide) is refused with :unauthorized", %{account: account, run: run} do
      decider = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, decider.actor.id, "needs approve")

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Approvals.deny_request(request, viewer_subject, "no rights")
    end

    # (context half) — a finalizing deny writes BOTH a per-vote
    # `approval.decision_recorded` (the running count) AND the finalizing
    # `approval.denied` row, inside the same transaction as the run.cancelled. The
    # decision_recorded step is decision-agnostic (not approve-only), so the deny
    # path must land it too — pin the pair so a future approve-only guard can't drop
    # the deny's running-count row.
    test "a deny writes approval.decision_recorded AND approval.denied in the same decision", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, subject, "not now")

      {:ok, events, _} = Audit.list_events(subject, page: [limit: 50])

      assert Enum.any?(
               events,
               &(&1.event_type == "approval.decision_recorded" and &1.target_id == request.id)
             )

      assert Enum.any?(
               events,
               &(&1.event_type == "approval.denied" and &1.target_id == request.id)
             )
    end

    test "an owner of account B cannot deny account A's request (cross-account → :not_found)" do
      {account_a, run_a} = run_fixture()
      decider_a = operator_subject(account_a)
      {:ok, req_a} = Approvals.create_request(run_a, decider_a.actor.id, "needs approve")

      account_b = Fixtures.Accounts.create_account()
      owner_b = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: owner_b.id,
          role: "owner"
        )

      subject_b = Fixtures.Subjects.subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Approvals.deny_request(req_a, subject_b, "wrong account")
    end

    # deny is `:decide`-gated only; it is NOT self-gated.
    # `check_self_approval` blocks an APPROVE by the recorded requester (when the
    # snapshot forbids self-approval) but lets a deny fall through. So the
    # requester denying their OWN request is allowed even under
    # allow_self_approval: false — denial can't sneak a run through, so there's
    # nothing to guard against; an operator killing their own pending ask is
    # legitimate (and the only way to retract it).
    test "the requester CAN deny their own request even when self-approval is forbidden" do
      requester = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(requester, account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      {:ok, request} =
        Approvals.create_request(run, requester.id, "x",
          min_approvals: 1,
          allow_self_approval: false
        )

      # The same user who asked can retract by denying — no :self_approval_forbidden.
      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, subject, "retracting my own ask")

      # And the run never went anywhere.
      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
    end

    # only APPROVE re-gates pack trust (recheck_trust(:approve)
    # → recheck_run_pack_trust; recheck_trust(:deny) is a flat :ok). Deny cancels the
    # run, it never ships bytes, so a drifted-to-:pending pack must NOT block the
    # operator from denying — the same drift that fails the approve closed lets the
    # deny through and cancels the held run.
    test "denying a run whose pack drifted to :pending still succeeds — no trust re-check" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      # A custom (no-baseline) pack lands :pending — the same untrusted state that
      # fails an approve closed.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:DRIFT"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "high",
              "args" => []
            }
          ]
        })

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "custom.do",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      {:ok, request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs review")

      operator = distinct_operator(account)

      # Deny needs no trust re-check — it finalizes denied and cancels the run.
      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, operator, "not shipping drifted bytes")

      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
    end

    test "ABUSE: one deny finalizes DENIED and a later approve cannot override it" do
      %{account: account, request: request, run: run} = gated_request(min_approvals: 3)
      a = distinct_operator(account)
      b = distinct_operator(account)
      c = distinct_operator(account)

      # A approves (1 of 3) — still pending.
      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, a, "yes")

      # B denies — finalizes DENIED and cancels the run.
      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, b, "no")

      # C's later approve can't out-vote the deny.
      assert {:error, :already_decided} = Approvals.approve_request(request, c, "let me in")

      assert %Request{status: :denied} = Repo.reload!(request)
      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "each vote logs approval.decision_recorded; only the release logs approval.approved" do
      %{account: account, request: request} = gated_request(min_approvals: 2)
      a = distinct_operator(account)
      b = distinct_operator(account)

      {:ok, _} = Approvals.approve_request(request, a, "one")
      {:ok, _} = Approvals.approve_request(request, b, "two")

      {:ok, events, _} = Audit.list_events(a, page: [limit: 50])
      recorded = Enum.filter(events, &(&1.event_type == "approval.decision_recorded"))
      approved = Enum.filter(events, &(&1.event_type == "approval.approved"))

      # Two votes → two decision_recorded rows; one release → one approved row.
      assert length(recorded) == 2
      assert length(approved) == 1
    end
  end

  describe "cancel_request_for_run_in_multi/2" do
    # gated_request already subscribes this process to the runner transport.
    setup do
      %{account: account, run: run, request: request} = gated_request()
      %{account: account, run: run, request: request}
    end

    test "cancelling a pending-approval run atomically cancels its request", %{
      account: account,
      run: run,
      request: request
    } do
      owner = operator_subject(account)

      assert {:ok, %ActionRun{status: :cancelled}} =
               Runs.cancel_run(run, owner, "changed my mind")

      assert %Request{status: :cancelled} = Repo.reload!(request)
    end

    # cancelling a :pending_approval run flips its request
    # to :cancelled in the SAME transaction, so a stale approve that lands after
    # finds a :cancelled request and is refused (:run_cancelled) — it can never
    # resurrect + dispatch the cancelled run.
    test "approving after the run was cancelled is refused — nothing dispatches", %{
      account: account,
      run: run,
      request: request
    } do
      owner = operator_subject(account)
      approver = distinct_operator(account)

      {:ok, _} = Runs.cancel_run(run, owner, "cancel")

      # The request was cancelled with the run, so the stale approve is refused.
      assert {:error, :run_cancelled} = Approvals.approve_request(request, approver, "too late")

      # The run stays cancelled and no envelope ever reached the runner.
      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "is a no-op (:none) when the run has no pending request to cancel", %{
      account: account
    } do
      # A run with NO approval request — the composed step finds nothing pending
      # and lands :none in changes, never erroring the caller's transaction.
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_run_attrs(account.id, runner.id))

      assert {:ok, %{request_cancel: :none}} =
               Multi.new()
               |> Approvals.cancel_request_for_run_in_multi(run.id)
               |> Repo.transaction()
    end
  end

  describe "broadcast_request_cancelled/1" do
    test "broadcasts the request on the account approvals feed for a {:cancelled, request} tuple" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

      :ok = Approvals.subscribe_account_approvals(account.id)

      assert :ok = Approvals.broadcast_request_cancelled({:cancelled, request})

      assert_receive {:approval_updated, %Request{id: id}}
      assert id == request.id
    end

    test "is a no-op for the :none result (no request was cancelled)" do
      {account, _run} = run_fixture()
      :ok = Approvals.subscribe_account_approvals(account.id)

      assert :ok = Approvals.broadcast_request_cancelled(:none)

      refute_receive {:approval_updated, _}, 100
    end
  end

  describe "subscribe_account_approvals/1" do
    test "the subscriber receives the account's approval-feed broadcasts" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      subject = operator_subject(account)

      assert :ok = Approvals.subscribe_account_approvals(account.id)

      # A decision publishes on the topic the subscriber just joined.
      assert {:ok, _} = Approvals.deny_request(request, subject, "no")
      assert_receive {:approval_updated, %Request{id: id, status: :denied}}
      assert id == request.id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      {account_a, _run_a} = run_fixture()
      {account_b, run_b} = run_fixture()
      {:ok, request_b} = Approvals.create_request(run_b, Fixtures.Users.create_user().id, "x")
      subject_b = operator_subject(account_b)

      assert :ok = Approvals.subscribe_account_approvals(account_a.id)

      # The decision happens on B's topic — A's subscriber must hear nothing.
      assert {:ok, _} = Approvals.deny_request(request_b, subject_b, "no")
      refute_receive {:approval_updated, _}, 100
    end
  end

  describe "peek_matching_grant/5" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      %{account: account, user: user}
    end

    test "returns nil when no grant exists", %{account: account, user: user} do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Approvals.peek_matching_grant(account.id, key.id, "x.y", runner.id, "sha") == nil
    end

    test "wildcards: nil runner_id and nil args_sha256 match anything", %{
      account: account,
      user: user
    } do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)

      _ = insert_grant(account, key, action_id: "linux.uptime", granted_by_id: user.id)

      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key.id,
                 "linux.uptime",
                 runner_a.id,
                 "sha-a"
               )

      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key.id,
                 "linux.uptime",
                 runner_b.id,
                 "sha-b"
               )
    end

    test "exact runner match: grant on runner_a doesn't match runner_b", %{
      account: account,
      user: user
    } do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)

      _ =
        insert_grant(account, key, action_id: "x", runner_id: runner_a.id, granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(account.id, key.id, "x", runner_a.id, "any")
      assert Approvals.peek_matching_grant(account.id, key.id, "x", runner_b.id, "any") == nil
    end

    test "expired grant is filtered out", %{account: account, user: user} do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      _ =
        insert_grant(account, key,
          action_id: "x",
          runner_id: runner.id,
          granted_by_id: user.id,
          granted_at: past,
          expires_at: past
        )

      assert Approvals.peek_matching_grant(account.id, key.id, "x", runner.id, "sha") == nil
    end

    test "revoked grant is filtered out", %{account: account, user: user} do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      subject = Fixtures.Subjects.membership_subject(membership)

      grant = insert_grant(account, key, action_id: "x", granted_by_id: user.id)
      {:ok, _} = Approvals.revoke_grant(grant, subject)

      assert Approvals.peek_matching_grant(account.id, key.id, "x", nil, "sha") == nil
    end

    test "a different API key's grant doesn't leak", %{account: account, user: user} do
      {_, key_a} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      {_, key_b} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      _ = insert_grant(account, key_a, action_id: "x", granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(account.id, key_a.id, "x", nil, "sha")
      assert Approvals.peek_matching_grant(account.id, key_b.id, "x", nil, "sha") == nil
    end

    test "cap 0 (standing grants disabled) makes a live matching grant inert", %{
      account: account,
      user: user
    } do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      _ = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      # The grant matches while grants are enabled…
      assert %Grant{} = Approvals.peek_matching_grant(account.id, key.id, "x", nil, "sha")

      # …and stops matching the moment the account flips the kill switch —
      # no revocation required.
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 0})
      assert Approvals.peek_matching_grant(account.id, key.id, "x", nil, "sha") == nil
    end
  end

  describe "consume_grant_in_multi/4" do
    # A dispatch that matches a grant: an MCP api-key call + a require_approval
    # policy + a wildcard grant for the action. Returns subject/attrs/grant.
    defp grant_dispatch_setup(grant_opts) do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      mcp_subject = Emisar.Auth.Subject.for_api_key(key, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")
      Emisar.Runners.subscribe_runner_transport(runner)

      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      grant =
        insert_grant(
          account,
          key,
          Keyword.merge([action_id: "linux.uptime", granted_by_id: user.id], grant_opts)
        )

      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "go",
        source: "mcp",
        api_key_id: key.id
      }

      %{subject: mcp_subject, attrs: attrs, grant: grant}
    end

    test "a grant-matched dispatch consumes exactly one use and runs" do
      %{subject: subject, attrs: attrs, grant: grant} = grant_dispatch_setup(max_uses: 2)

      assert {:ok, :running, _run} = Runs.dispatch_run(attrs, subject)
      assert Repo.reload!(grant).uses_count == 1
    end

    test "a run that fails validation does NOT burn a grant use" do
      %{subject: subject, attrs: attrs, grant: grant} = grant_dispatch_setup(max_uses: 1)
      huge = %{"blob" => String.duplicate("x", 300_000)}

      # The run insert fails inside the Multi, so the composed grant consume
      # rolls back with it — no use is burned without a durable run.
      assert {:error, changeset} = Runs.dispatch_run(Map.put(attrs, :args, huge), subject)
      assert "is too large (max 262144 bytes serialized)" in errors_on(changeset).args
      assert Repo.reload!(grant).uses_count == 0
    end

    test "an idempotency-replayed grant dispatch consumes the grant only ONCE" do
      %{subject: subject, attrs: attrs, grant: grant} = grant_dispatch_setup(max_uses: 5)
      attrs = Map.put(attrs, :idempotency_key, "idem-#{System.unique_integer([:positive])}")

      assert {:ok, :running, run1} = Runs.dispatch_run(attrs, subject)
      assert {:ok, _status, run2} = Runs.dispatch_run(attrs, subject)
      assert run1.id == run2.id
      assert Repo.reload!(grant).uses_count == 1
    end

    test "an exhausted grant falls back to the approval path without over-consuming" do
      %{subject: subject, attrs: attrs, grant: grant} = grant_dispatch_setup(max_uses: 1)

      assert {:ok, :running, _} = Runs.dispatch_run(attrs, subject)
      assert Repo.reload!(grant).uses_count == 1

      # Exhausted now → the next dispatch can't match the grant, so it files an
      # approval request instead of erroring or over-consuming.
      assert {:ok, :pending_approval, run2} = Runs.dispatch_run(attrs, subject)
      assert run2.status == :pending_approval
      assert Repo.reload!(grant).uses_count == 1
    end
  end

  describe "Runs.dispatch_run fast-path with grant" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      operator_subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      mcp_subject = Emisar.Auth.Subject.for_api_key(key, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")

      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      Emisar.Runners.subscribe_runner_transport(runner)
      %{mcp_subject: mcp_subject, operator_subject: operator_subject, key: key, runner: runner}
    end

    test "matching grant bypasses approval and runs immediately", %{
      mcp_subject: mcp_subject,
      operator_subject: operator_subject,
      key: key,
      runner: runner
    } do
      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "first call",
        source: "mcp",
        api_key_id: key.id
      }

      assert {:ok, :pending_approval, run1} =
               Runs.dispatch_run(attrs, mcp_subject)

      request =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} =
        Approvals.approve_request(request, operator_subject, nil,
          duration: :one_day,
          scope: :any_args
        )

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      assert {:ok, :running, run2} = Runs.dispatch_run(attrs, mcp_subject)
      assert run2.id != run1.id
      refute Request.Query.all() |> Request.Query.by_run_id(run2.id) |> Repo.peek()
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      # Two executions under this grant: the approved first call (its
      # minting use) and the auto-approved second call.
      assert grant.uses_count == 2
    end

    test ":once approval doesn't create a reusable grant", %{
      mcp_subject: mcp_subject,
      operator_subject: operator_subject,
      key: key,
      runner: runner
    } do
      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "x",
        source: "mcp",
        api_key_id: key.id
      }

      {:ok, :pending_approval, run1} =
        Runs.dispatch_run(attrs, mcp_subject)

      request =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} = Approvals.approve_request(request, operator_subject, nil, duration: :once)

      assert {:ok, :pending_approval, _run2} =
               Runs.dispatch_run(attrs, mcp_subject)
    end
  end

  describe "create_grant/4" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      operator = Fixtures.Users.create_user()

      {_, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: operator.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{},
          api_key_id: key.id,
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, operator.id, "x")
      %{account: account, run: run, request: request, operator: operator}
    end

    test "refuses a windowed duration beyond the account cap (the IL-15 server gate)",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 86_400})

      assert {:error, :grant_exceeds_account_max_lifetime} =
               Approvals.create_grant(request, run, operator.id, %{duration: :ninety_days})

      assert {:error, :grant_exceeds_account_max_lifetime} =
               Approvals.create_grant(request, run, operator.id, %{duration: :thirty_days})
    end

    test "allows a duration within the cap",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 86_400})

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :one_day})

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :one_hour})
    end

    test "exempts :once (single-use, not a standing grant) even under a tight cap",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 60})

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :once})
    end

    test "no cap → any duration allowed",
         %{run: run, request: request, operator: operator} do
      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :ninety_days})
    end

    test "cap 0 (standing grants disabled) refuses every windowed duration, :once still works",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 0})

      assert {:error, :grant_exceeds_account_max_lifetime} =
               Approvals.create_grant(request, run, operator.id, %{duration: :one_hour})

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :once})
    end
  end

  describe "allowed_grant_durations/1" do
    test "offers only the in-cap durations (:once always); shares the gate's predicate" do
      account = Fixtures.Accounts.create_account()

      # Uncapped → every duration is offered.
      assert Approvals.allowed_grant_durations(account.id) ==
               [:once, :one_hour, :one_day, :thirty_days, :ninety_days]

      # A 1-day cap drops the over-cap windows but keeps :once + the in-cap ones,
      # matching exactly what create_grant/4's server gate would accept.
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 86_400})

      assert Approvals.allowed_grant_durations(account.id) == [:once, :one_hour, :one_day]

      # Cap 0 = standing grants disabled — only single-use remains.
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 0})
      assert Approvals.allowed_grant_durations(account.id) == [:once]
    end

    test "an unknown account id (no settings) imposes no cap — every duration offered" do
      # account_grant_lifetime_cap/1 maps a missing account's settings to nil,
      # so the predicate allows everything rather than crashing.
      assert Approvals.allowed_grant_durations(Ecto.UUID.generate()) ==
               [:once, :one_hour, :one_day, :thirty_days, :ninety_days]
    end
  end

  describe "revoke_grant/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      grant = insert_grant(account, key, action_id: "x", granted_by_id: user.id)
      %{account: account, user: user, key: key, grant: grant}
    end

    test "an operator (no manage_grants permission) is refused with :unauthorized", %{
      account: account,
      grant: grant
    } do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Approvals.revoke_grant(grant, operator_subject)
    end

    # `manage_grants` = owner/admin, so an ADMIN (not just an
    # owner) can revoke a grant. Mirrors the operator-denial test above with the
    # laxest role that still holds the permission.
    test "an admin (manage_grants holder) can revoke a grant", %{
      account: account,
      grant: grant
    } do
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:ok, %Grant{revoked_at: %DateTime{}, revoked_by_id: revoked_by}} =
               Approvals.revoke_grant(grant, admin_subject)

      assert revoked_by == admin.id
    end

    test "an owner of account B cannot revoke account A's grant (cross-account → :not_found)" do
      account_a = Fixtures.Accounts.create_account()
      user_a = Fixtures.Users.create_user()

      {_, key_a} =
        Fixtures.ApiKeys.create_api_key(account_id: account_a.id, created_by_id: user_a.id)

      g_a = insert_grant(account_a, key_a, action_id: "x", granted_by_id: user_a.id)

      account_b = Fixtures.Accounts.create_account()
      owner_b = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: owner_b.id,
          role: "owner"
        )

      subject_b = Fixtures.Subjects.subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Approvals.revoke_grant(g_a, subject_b)
    end

    test "writes an `approval.grant_revoked` audit row", %{
      account: account,
      user: user,
      key: key,
      grant: grant
    } do
      # The audit log used to live in the LV handler. Moving it into the
      # context means the row lands on every code path (LV, future
      # scripts, tasks) — pin it with a context-level test.
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      subject = Fixtures.Subjects.membership_subject(membership)

      assert {:ok, _} = Approvals.revoke_grant(grant, subject)

      {:ok, events, _} = Emisar.Audit.list_events(subject)
      audit = Enum.find(events, &(&1.event_type == "approval.grant_revoked"))

      assert audit, "expected an approval.grant_revoked audit row"
      assert audit.target_kind == "approval_grant"
      assert audit.target_id == grant.id
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      assert audit.payload["action_id"] == "x"
      assert audit.payload["api_key_id"] == key.id
    end

    # re-revoking an already-revoked grant is benign. The
    # revoke read is status-agnostic (`Grant.Query.all() |> by_id`, no
    # `not_revoked` filter), so the revoked row is still fetchable and
    # `Grant.Changeset.revoke` simply re-stamps `revoked_at`/`revoked_by_id`. No
    # crash, no error — idempotent-ish (a double-click on Revoke can't fail).
    test "revoking an already-revoked grant re-stamps without crashing (benign)", %{
      account: account,
      user: user,
      grant: grant
    } do
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      subject = Fixtures.Subjects.membership_subject(membership)

      assert {:ok, %Grant{revoked_at: first}} = Approvals.revoke_grant(grant, subject)
      assert %DateTime{} = first

      # A second revoke on the same (already-revoked) grant succeeds and re-stamps.
      assert {:ok, %Grant{revoked_at: second, revoked_by_id: by}} =
               Approvals.revoke_grant(grant, subject)

      assert %DateTime{} = second
      assert by == user.id
      assert DateTime.compare(second, first) != :lt
    end
  end

  describe "revoke_all_grants/1" do
    test "revokes every un-revoked grant in the account, each with its audit row" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      insert_grant(account, key, action_id: "a.one", granted_by_id: user.id)
      insert_grant(account, key, action_id: "a.two", granted_by_id: user.id)

      # Cross-account isolation: B's grant survives A's sweep.
      account_b = Fixtures.Accounts.create_account()
      user_b = Fixtures.Users.create_user()

      {_, key_b} =
        Fixtures.ApiKeys.create_api_key(account_id: account_b.id, created_by_id: user_b.id)

      grant_b = insert_grant(account_b, key_b, action_id: "b.one", granted_by_id: user_b.id)

      assert Approvals.revoke_all_grants(subject) == {:ok, 2}

      assert Grant.Query.not_revoked() |> Grant.Query.by_account_id(account.id) |> Repo.all() ==
               []

      refute Repo.reload!(grant_b).revoked_at

      {:ok, events, _} = Emisar.Audit.list_events(subject)
      revoked = Enum.filter(events, &(&1.event_type == "approval.grant_revoked"))
      assert length(revoked) == 2

      # Idempotent on an already-clean account.
      assert Approvals.revoke_all_grants(subject) == {:ok, 0}
    end

    test "an operator (no manage_grants) is refused" do
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Approvals.revoke_all_grants(operator_subject) == {:error, :unauthorized}
    end
  end

  describe "list_grants_for_account/2" do
    test "applies every preload and the include_expired filter (an empty account is fine)" do
      subject = operator_subject(Fixtures.Accounts.create_account())

      assert {:ok, [], _meta} =
               Approvals.list_grants_for_account(subject,
                 include_expired: true,
                 preload: [:api_key, :runner, :granted_by, :revoked_by, :approval_request_run]
               )
    end

    test "an operator (no manage_grants) is refused with :unauthorized" do
      {_user, account, _owner} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert {:error, :unauthorized} = Approvals.list_grants_for_account(operator)
    end

    test "lists only the subject's account grants (cross-account isolation)" do
      account_a = Fixtures.Accounts.create_account()
      user_a = Fixtures.Users.create_user()

      {_, key_a} =
        Fixtures.ApiKeys.create_api_key(account_id: account_a.id, created_by_id: user_a.id)

      _ = insert_grant(account_a, key_a, action_id: "x", granted_by_id: user_a.id)

      subject_a = operator_subject(account_a)
      assert {:ok, [%Grant{}], _} = Approvals.list_grants_for_account(subject_a)

      # A second account's owner sees none of A's grants.
      subject_b = operator_subject(Fixtures.Accounts.create_account())
      assert {:ok, [], _} = Approvals.list_grants_for_account(subject_b)
    end
  end

  describe "fetch_grant_by_id/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      operator = Fixtures.Users.create_user()

      {_, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: operator.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{},
          api_key_id: key.id,
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, operator.id, "x")
      subject = operator_subject(account)

      {:ok, grant} =
        Approvals.create_grant(request, run, operator.id, %{
          duration: :one_day,
          scope: :exact_args
        })

      %{account: account, grant: grant, subject: subject}
    end

    test "scopes to the subject's account; cross-account is :not_found", %{
      grant: grant,
      subject: subject
    } do
      assert {:ok, %Grant{id: id}} = Approvals.fetch_grant_by_id(grant.id, subject)
      assert id == grant.id

      {other_account, _} = run_fixture()
      other_subject = operator_subject(other_account)
      assert {:error, :not_found} = Approvals.fetch_grant_by_id(grant.id, other_subject)

      # A malformed id is :not_found, never a crash.
      assert {:error, :not_found} = Approvals.fetch_grant_by_id("not-a-uuid", subject)
    end

    test "an operator (no manage_grants) is refused with :unauthorized", %{
      account: account,
      grant: grant
    } do
      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert {:error, :unauthorized} = Approvals.fetch_grant_by_id(grant.id, operator)
    end
  end

  describe "subject_can_view_approvals?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert Approvals.subject_can_view_approvals?(viewer_subject)
      refute Approvals.subject_can_view_approvals?(billing_manager_subject)
    end
  end

  describe "subject_can_decide_approval?/1" do
    test "operator may decide; viewer may not — matches the decide_approval gate" do
      {_user, account, _owner} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert Approvals.subject_can_decide_approval?(operator)
      refute Approvals.subject_can_decide_approval?(viewer)
    end
  end

  describe "subject_can_manage_grants?/1" do
    test "owner may; operator may not — matches revoke_grant/2's manage_grants gate" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert Approvals.subject_can_manage_grants?(owner)
      refute Approvals.subject_can_manage_grants?(operator)
    end
  end

  describe "expire_overdue_requests/1" do
    test "expires a request exactly at its decision deadline" do
      {_account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      now = DateTime.utc_now()

      {1, _} =
        Request.Query.all()
        |> Request.Query.by_id(request.id)
        |> Repo.update_all(set: [expires_at: now])

      assert Approvals.expire_overdue_requests(now) == 1
      assert %Request{status: :expired} = Repo.reload!(request)
      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
    end

    test "transitions pending requests past expires_at to expired + cancels the run" do
      {account, run} = run_fixture()
      user = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      {:ok, request} = Approvals.create_request(run, user.id, "x")

      # Move the request's expiry into the past.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {1, _} =
        Request.Query.all()
        |> Request.Query.by_id(request.id)
        |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1

      expired =
        Request.Query.all() |> Request.Query.by_id(request.id) |> Repo.fetch!(Request.Query)

      assert expired.status == :expired
      assert expired.decided_at != nil
      assert expired.decision_reason =~ "expired"

      reloaded_run =
        Emisar.Runs.ActionRun.Query.all()
        |> Emisar.Runs.ActionRun.Query.by_id(run.id)
        |> Repo.fetch!(Emisar.Runs.ActionRun.Query)

      assert reloaded_run.status == :cancelled

      assert Enum.any?(
               Emisar.Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.expired" and &1.target_id == request.id)
             )
    end

    test "is idempotent — second sweep is a no-op" do
      {_account, run} = run_fixture()
      user = Fixtures.Users.create_user()
      {:ok, request} = Approvals.create_request(run, user.id, "x")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      Request.Query.all()
      |> Request.Query.by_id(request.id)
      |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1
      assert Approvals.expire_overdue_requests() == 0
    end

    test "leaves pending requests within the window alone" do
      {_account, run} = run_fixture()
      user = Fixtures.Users.create_user()
      {:ok, request} = Approvals.create_request(run, user.id, "x")
      # default 24h is in the future
      assert Approvals.expire_overdue_requests() == 0

      assert (Request.Query.all()
              |> Request.Query.by_id(request.id)
              |> Repo.fetch!(Request.Query)).status == :pending
    end

    test "expiry stays pending-only even with sub-threshold decision rows recorded" do
      %{account: account, request: request, run: run} = gated_request(min_approvals: 2)
      a = distinct_operator(account)

      # One sub-threshold approve — a decision row exists, request still pending.
      {:ok, {%Request{status: :pending}, :pending}} = Approvals.approve_request(request, a, "one")
      assert approved_count(request.id) == 1

      # Move the request's expiry into the past; the sweep flips only pending rows.
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {1, _} =
        Request.Query.all()
        |> Request.Query.by_id(request.id)
        |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1

      assert %Request{status: :expired} = Repo.reload!(request)
      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
      # The recorded decision row persists — expiry doesn't touch it.
      assert approved_count(request.id) == 1
    end
  end

  # Operator-sourced base run attrs (no api_key) for the composed-Multi probes.
  defp base_run_attrs(account_id, runner_id) do
    %{
      account_id: account_id,
      runner_id: runner_id,
      action_id: "linux.uptime",
      source: "operator",
      args: %{}
    }
  end
end
