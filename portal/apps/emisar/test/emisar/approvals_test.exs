defmodule Emisar.ApprovalsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Audit, Repo, Runs}
  alias Emisar.Approvals.{Decision, Grant, Request}
  alias Emisar.Runs.ActionRun

  defp run_fixture(opts \\ []) do
    account =
      Keyword.get(opts, :account) || account_fixture()

    runner = Keyword.get(opts, :runner) || runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    {account, run}
  end

  describe "fetch_approval_request_by_id/3" do
    test "returns the request inside the subject's account; cross-account is :not_found" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, user_fixture().id, "x")
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

  describe "double decide" do
    test "the second operator's decision loses with :already_decided" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, user_fixture().id, "x")
      first = operator_subject(account)
      second = operator_subject(account)

      assert {:ok, _} = Approvals.deny_request(request, first, "no")
      assert {:error, :already_decided} = Approvals.approve_request(request, second)
      assert {:error, :already_decided} = Approvals.deny_request(request, second, "again")
    end
  end

  defp operator_subject(account) do
    operator = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "owner")
    subject_for(operator, account, role: :owner)
  end

  describe "request + grant reads" do
    test "fetch_approval_request_by_run_id finds the run's single request, account-scoped" do
      {account, run} = run_fixture()
      operator = user_fixture()
      {:ok, request} = Approvals.create_request(run, operator.id, "x")

      subject = operator_subject(account)
      assert {:ok, %Request{id: id}} = Approvals.fetch_approval_request_by_run_id(run.id, subject)
      assert id == request.id

      {other_account, _run_b} = run_fixture()
      other_subject = operator_subject(other_account)

      assert {:error, :not_found} =
               Approvals.fetch_approval_request_by_run_id(run.id, other_subject)
    end

    test "fetch_approval_request_by_run_id still returns a DENIED request — the decision record persists" do
      {account, run} = run_fixture()
      operator = user_fixture()
      {:ok, request} = Approvals.create_request(run, operator.id, "x")
      subject = operator_subject(account)
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

    test "list_approval_requests_for_account filters by status" do
      {account, run} = run_fixture()
      operator = user_fixture()
      {:ok, request} = Approvals.create_request(run, operator.id, "x")

      subject = operator_subject(account)
      {:ok, _} = Approvals.deny_request(request, subject, "no")

      assert {:ok, [%Request{status: :denied}], _} =
               Approvals.list_approval_requests_for_account(subject, status: "denied")

      assert {:ok, [], _} =
               Approvals.list_approval_requests_for_account(subject, status: "pending")
    end

    test "fetch_grant_by_id scopes to the subject's account" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      operator = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: operator.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{},
          api_key_id: key.id
        })

      {:ok, request} = Approvals.create_request(run, operator.id, "x")
      subject = operator_subject(account)

      {:ok, grant} =
        Approvals.create_grant(request, run, operator.id, %{
          duration: :one_day,
          scope: :exact_args
        })

      assert {:ok, %Grant{id: id}} = Approvals.fetch_grant_by_id(grant.id, subject)
      assert id == grant.id

      {other_account, _} = run_fixture()
      other_subject = operator_subject(other_account)
      assert {:error, :not_found} = Approvals.fetch_grant_by_id(grant.id, other_subject)
    end
  end

  describe "create_request/3" do
    test "creates an approval request in :pending status" do
      {_account, run} = run_fixture()
      operator = user_fixture()

      assert {:ok, %Request{status: :pending, run_id: run_id}} =
               Approvals.create_request(run, operator.id, "high-risk action")

      assert run_id == run.id
    end
  end

  describe "create_request/3 approver notifications" do
    setup do
      account = account_fixture()

      members =
        for role <- ~w(owner admin operator viewer), into: %{} do
          user = user_fixture()
          _ = membership_fixture(account_id: account.id, user_id: user.id, role: role)
          {role, user}
        end

      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      %{account: account, run: run, members: members}
    end

    test "emails the deciders (owner/admin/operator), never viewers", %{
      run: run,
      members: members
    } do
      # Requested by an unrelated user so no decider is excluded as the asker.
      {:ok, _req} = Approvals.create_request(run, user_fixture().id, "needs approval")

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
      other_owner = user_fixture()
      other_account = account_fixture()
      _ = membership_fixture(account_id: other_account.id, user_id: other_owner.id, role: "owner")

      {:ok, _req} = Approvals.create_request(run, user_fixture().id, "needs approval")

      recipients = notified_recipients()

      assert members["owner"].email in recipients
      refute other_owner.email in recipients
    end
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

  describe "approve_request/3" do
    test "transitions the run to :sent + writes an audit event" do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, subject, "lgtm")

      assert Enum.any?(
               Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.approved")
             )
    end

    test "an expired (not-yet-swept) pending request cannot be approved" do
      {account, run} = run_fixture()
      subject = operator_subject(account)
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

    test "a viewer (cannot decide) is refused with :unauthorized" do
      {account, run} = run_fixture()
      decider = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, decider.actor.id, "needs approve")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Approvals.approve_request(request, viewer_subject, "no rights")
    end

    test "an owner of account B cannot approve account A's request (cross-account → :not_found)" do
      {account_a, run_a} = run_fixture()
      decider_a = operator_subject(account_a)
      {:ok, req_a} = Approvals.create_request(run_a, decider_a.actor.id, "needs approve")

      account_b = account_fixture()
      owner_b = user_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: owner_b.id, role: "owner")
      subject_b = subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Approvals.approve_request(req_a, subject_b, "wrong account")
    end
  end

  describe "deny_request/3" do
    test "transitions the run to :cancelled + writes an audit event" do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, subject, "not now")

      assert Enum.any?(
               Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.denied")
             )
    end

    test "a viewer (cannot decide) is refused with :unauthorized" do
      {account, run} = run_fixture()
      decider = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, decider.actor.id, "needs approve")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Approvals.deny_request(request, viewer_subject, "no rights")
    end

    test "an owner of account B cannot deny account A's request (cross-account → :not_found)" do
      {account_a, run_a} = run_fixture()
      decider_a = operator_subject(account_a)
      {:ok, req_a} = Approvals.create_request(run_a, decider_a.actor.id, "needs approve")

      account_b = account_fixture()
      owner_b = user_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: owner_b.id, role: "owner")
      subject_b = subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Approvals.deny_request(req_a, subject_b, "wrong account")
    end
  end

  describe "list_pending_approval_requests/1" do
    test "only returns pending requests" do
      {account, run1} = run_fixture()
      {_, run2} = run_fixture(account: account)
      subject = operator_subject(account)

      {:ok, req_pending} = Approvals.create_request(run1, user_fixture().id, nil)
      {:ok, req_to_deny} = Approvals.create_request(run2, user_fixture().id, nil)
      {:ok, _} = Approvals.deny_request(req_to_deny, subject, "nope")

      {:ok, pending, _} = Approvals.list_pending_approval_requests(subject)
      ids = pending |> Enum.map(& &1.id)
      assert ids == [req_pending.id]
    end
  end

  describe "count_pending_approval_requests/1" do
    test "returns the count of pending rows (decided rows excluded)" do
      {account, run1} = run_fixture()
      {_, run2} = run_fixture(account: account)
      {_, run3} = run_fixture(account: account)
      subject = operator_subject(account)

      {:ok, _} = Approvals.create_request(run1, user_fixture().id, nil)
      {:ok, _} = Approvals.create_request(run2, user_fixture().id, nil)
      {:ok, to_deny} = Approvals.create_request(run3, user_fixture().id, nil)
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
      {:ok, _} = Approvals.create_request(run_a, user_fixture().id, nil)

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

  # -- Grants ---------------------------------------------------------

  defp insert_grant(account, key, opts) do
    Grant.Changeset.create(
      Map.merge(
        %{
          account_id: account.id,
          api_key_id: key.id,
          action_id: "linux.uptime",
          granted_by_id: opts[:granted_by_id] || user_fixture().id,
          granted_at: DateTime.utc_now()
        },
        Map.new(opts)
      )
    )
    |> Repo.insert!()
  end

  describe "peek_matching_grant/4" do
    test "returns nil when no grant exists" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      assert Approvals.peek_matching_grant(key.id, "x.y", runner.id, "sha") == nil
    end

    test "wildcards: nil runner_id and nil args_sha256 match anything" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)

      _ = insert_grant(account, key, action_id: "linux.uptime", granted_by_id: user.id)

      assert %Grant{} =
               Approvals.peek_matching_grant(key.id, "linux.uptime", runner_a.id, "sha-a")

      assert %Grant{} =
               Approvals.peek_matching_grant(key.id, "linux.uptime", runner_b.id, "sha-b")
    end

    test "exact runner match: grant on runner_a doesn't match runner_b" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)

      _ =
        insert_grant(account, key, action_id: "x", runner_id: runner_a.id, granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(key.id, "x", runner_a.id, "any")
      assert Approvals.peek_matching_grant(key.id, "x", runner_b.id, "any") == nil
    end

    test "expired grant is filtered out" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      _ =
        insert_grant(account, key,
          action_id: "x",
          runner_id: runner.id,
          granted_by_id: user.id,
          granted_at: past,
          expires_at: past
        )

      assert Approvals.peek_matching_grant(key.id, "x", runner.id, "sha") == nil
    end

    test "revoked grant is filtered out" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      grant = insert_grant(account, key, action_id: "x", granted_by_id: user.id)
      {:ok, _} = Approvals.revoke_grant(grant, subject)

      assert Approvals.peek_matching_grant(key.id, "x", nil, "sha") == nil
    end

    test "revoke_grant writes an `approval.grant_revoked` audit row" do
      # The audit log used to live in the LV handler. Moving it into the
      # context means the row lands on every code path (LV, future
      # scripts, tasks) — pin it with a context-level test.
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      grant = insert_grant(account, key, action_id: "act.revoke-audit", granted_by_id: user.id)
      assert {:ok, _} = Approvals.revoke_grant(grant, subject)

      {:ok, events, _} = Emisar.Audit.list_events(subject)
      audit = Enum.find(events, &(&1.event_type == "approval.grant_revoked"))

      assert audit, "expected an approval.grant_revoked audit row"
      assert audit.subject_kind == "approval_grant"
      assert audit.subject_id == grant.id
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      assert audit.payload["action_id"] == "act.revoke-audit"
      assert audit.payload["api_key_id"] == key.id
    end

    test "a different API key's grant doesn't leak" do
      account = account_fixture()
      user = user_fixture()
      {_, key_a} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      {_, key_b} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      _ = insert_grant(account, key_a, action_id: "x", granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(key_a.id, "x", nil, "sha")
      assert Approvals.peek_matching_grant(key_b.id, "x", nil, "sha") == nil
    end
  end

  describe "revoke_grant/2" do
    test "an operator (no manage_grants permission) is refused with :unauthorized" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      grant = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Approvals.revoke_grant(grant, operator_subject)
    end

    test "an owner of account B cannot revoke account A's grant (cross-account → :not_found)" do
      account_a = account_fixture()
      user_a = user_fixture()
      {_, key_a} = api_key_fixture(account_id: account_a.id, created_by_id: user_a.id)
      g_a = insert_grant(account_a, key_a, action_id: "x", granted_by_id: user_a.id)

      account_b = account_fixture()
      owner_b = user_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: owner_b.id, role: "owner")
      subject_b = subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Approvals.revoke_grant(g_a, subject_b)
    end
  end

  describe "use_grant/1" do
    test "single-use grant is exhausted after one use" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      grant = insert_grant(account, key, action_id: "x", max_uses: 1, granted_by_id: user.id)

      assert :ok = Approvals.use_grant(grant)
      reloaded = Repo.reload!(grant)
      assert reloaded.uses_count == 1
      assert reloaded.last_used_at != nil

      assert {:error, :exhausted} = Approvals.use_grant(reloaded)
    end

    test "unlimited grant keeps incrementing" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      grant = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      assert :ok = Approvals.use_grant(grant)
      assert :ok = Approvals.use_grant(Repo.reload!(grant))
      assert :ok = Approvals.use_grant(Repo.reload!(grant))

      assert Repo.reload!(grant).uses_count == 3
    end
  end

  describe "approve_request/4 with grant duration" do
    test ":once duration creates no grant" do
      {account, run} = run_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      {:ok, _} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: run.runner_id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc"
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :once)

      assert [] = grants_for_api_key(key.id)
    end

    test ":one_day creates a grant with expires_at ~24h from now" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(request, subject, nil, duration: :one_day, scope: :exact_args)

      [grant] = grants_for_api_key(key.id)
      assert grant.action_id == "linux.uptime"
      assert grant.args_sha256 == "abc123"
      assert grant.expires_at != nil
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :hour) in 23..24

      # Minting the grant dispatched the approved run — that's its first
      # use, so it starts at 1 (never "not used yet") with last_used_at set.
      assert grant.uses_count == 1
      assert grant.last_used_at != nil
    end

    test "honors the operator's max_uses cap on the minted grant" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :one_day, max_uses: 5)

      # Regression: approve_request used to drop :max_uses from grant_attrs,
      # minting an UNCAPPED grant even when the operator set a cap.
      [grant] = grants_for_api_key(key.id)
      assert grant.max_uses == 5
    end

    test "preloads the originating run so the UI can show the locked args" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "postgres.vacuum",
          source: "mcp",
          api_key_id: key.id,
          args: %{"table" => "users", "full" => true},
          args_sha256: "deadbeef"
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

    test "a failed grant insert rolls the approval transaction back — no dispatch, no grant, no approved audit" do
      # Regression: when the operator approves "for 24h" but the durable
      # grant insert fails, the old code did `_ -> nil` and committed the
      # approval + dispatched as if it were `:once` — the grant silently
      # no-ops, the audit row records `grant_id: nil`, and the next identical
      # LLM call re-prompts. The fix rolls the grant/audit/dispatch
      # transaction back so the operator's intent isn't lost without a trace
      # (the error surfaces instead).
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
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
      assert [] = grants_for_api_key(key.id)

      # The run was NOT dispatched (the rollback aborted before dispatch).
      refute_receive {:cloud_to_runner, _}, 100

      # The approval.approved audit row was inside the rolled-back
      # transaction, so it never committed.
      {:ok, events, _} =
        Audit.list_events(subject, page: [limit: 50])

      refute Enum.any?(events, &(&1.event_type == "approval.approved"))
    end

    test ":any_args scope drops args_sha256 so any args match" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(request, subject, nil, duration: :ninety_days, scope: :any_args)

      [grant] = grants_for_api_key(key.id)
      assert grant.args_sha256 == nil
      # Every grant carries an explicit re-confirm horizon — there is
      # deliberately no indefinite duration.
      assert %DateTime{} = grant.expires_at
    end
  end

  describe "expire_overdue_requests/1" do
    test "transitions pending requests past expires_at to expired + cancels the run" do
      {account, run} = run_fixture()
      user = user_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
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
               &(&1.event_type == "approval.expired" and &1.subject_id == request.id)
             )
    end

    test "is idempotent — second sweep is a no-op" do
      {_account, run} = run_fixture()
      user = user_fixture()
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
      user = user_fixture()
      {:ok, request} = Approvals.create_request(run, user.id, "x")
      # default 24h is in the future
      assert Approvals.expire_overdue_requests() == 0

      assert (Request.Query.all()
              |> Request.Query.by_id(request.id)
              |> Repo.fetch!(Request.Query)).status == :pending
    end
  end

  describe "create_request/3 expiry default" do
    test "sets expires_at 24h from now by default" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, request} = Approvals.create_request(run, user.id, "x")

      assert request.expires_at != nil
      assert DateTime.diff(request.expires_at, DateTime.utc_now(), :hour) in 23..24
    end
  end

  describe "Runs.dispatch_run fast-path with grant" do
    test "matching grant bypasses approval and runs immediately" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")

      _ =
        policy_fixture(
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

      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "first call",
        source: "mcp",
        api_key_id: key.id
      }

      assert {:ok, :pending_approval, run1} =
               Runs.dispatch_run(attrs, subject)

      request =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} =
        Approvals.approve_request(request, subject, nil, duration: :one_day, scope: :any_args)

      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500

      assert {:ok, :running, run2} = Runs.dispatch_run(attrs, subject)
      assert run2.id != run1.id
      refute Request.Query.all() |> Request.Query.by_run_id(run2.id) |> Repo.peek()
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500

      [grant] = grants_for_api_key(key.id)
      # Two executions under this grant: the approved first call (its
      # minting use) and the auto-approved second call.
      assert grant.uses_count == 2
    end

    test ":once approval doesn't create a reusable grant" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")

      _ =
        policy_fixture(
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

      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "x",
        source: "mcp",
        api_key_id: key.id
      }

      {:ok, :pending_approval, run1} =
        Runs.dispatch_run(attrs, subject)

      request =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :once)

      assert {:ok, :pending_approval, _run2} =
               Runs.dispatch_run(attrs, subject)
    end
  end

  # An MCP-sourced run (carries api_key_id) parked behind a pending
  # request — the shape approve_request needs to mint a durable grant.
  defp approvable_mcp_run do
    account = account_fixture()
    user = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    subject = subject_for(user, account, role: :owner)
    {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
    runner = runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        api_key_id: key.id,
        args: %{},
        args_sha256: "abc123"
      })

    {:ok, request} = Approvals.create_request(run, user.id, "x")
    {subject, key, request}
  end

  describe "list_approval_requests_for_account/2" do
    test "lists pending requests with no filter, narrows by status, scopes to the account" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, user_fixture().id, "x")
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
  end

  describe "deny_request/3 with the default reason" do
    test "cancels the run with the built-in 'approval denied' message" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, user_fixture().id, "x")
      subject = operator_subject(account)

      assert {:ok, {%Request{status: :denied}, cancelled_run}} =
               Approvals.deny_request(request, subject)

      assert cancelled_run.status == :cancelled
    end
  end

  describe "list_grants_for_account/2 read options" do
    test "applies every preload and the include_expired filter (an empty account is fine)" do
      subject = operator_subject(account_fixture())

      assert {:ok, [], _meta} =
               Approvals.list_grants_for_account(subject,
                 include_expired: true,
                 preload: [:api_key, :runner, :granted_by, :revoked_by, :approval_request_run]
               )
    end
  end

  describe "approve_request grant TTLs" do
    test ":one_hour mints a grant expiring ~1h out" do
      {subject, key, request} = approvable_mcp_run()

      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :one_hour)

      [grant] = grants_for_api_key(key.id)
      assert grant.expires_at != nil
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :minute) in 59..60
    end

    test ":thirty_days mints a grant expiring ~30d out" do
      {subject, key, request} = approvable_mcp_run()

      {:ok, _} = Approvals.approve_request(request, subject, nil, duration: :thirty_days)

      [grant] = grants_for_api_key(key.id)
      assert grant.expires_at != nil
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :day) in 29..30
    end
  end

  # -- Configurable approval gate (GitHub-style) -----------------------

  # A fresh operator (owner) in the account, distinct from any other.
  defp distinct_operator(account) do
    user = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    subject_for(user, account, role: :owner)
  end

  # Count of distinct approve votes recorded on a request.
  defp approved_count(request_id) do
    Repo.one(Decision.Query.approved_distinct_decider_count(request_id))
  end

  # Account + an online (subscribed) runner + a parked request snapshotting
  # `opts` (min_approvals / allow_self_approval). The requester is a separate
  # user so self-approval is opt-in per test.
  defp gated_request(opts \\ []) do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)
    Emisar.Runners.subscribe_runner_transport(runner)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    requester = Keyword.get(opts, :requested_by_id, user_fixture().id)

    {:ok, request} =
      Approvals.create_request(run, requester, "needs review",
        min_approvals: Keyword.get(opts, :min_approvals, 1),
        allow_self_approval: Keyword.get(opts, :allow_self_approval, true)
      )

    %{account: account, runner: runner, run: run, request: request, requester_id: requester}
  end

  describe "min_approvals threshold" do
    test "min_approvals: 2 — first approve records pending (no dispatch), second distinct operator finalizes + dispatches" do
      %{account: account, request: request, run: run} = gated_request(min_approvals: 2)
      a = distinct_operator(account)
      b = distinct_operator(account)

      # First approve: recorded, sub-threshold — run NOT sent.
      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, a, "lgtm-1")

      refute_receive {:cloud_to_runner, _}, 100
      assert %ActionRun{status: status1} = Repo.reload!(run)
      refute status1 == :sent
      assert approved_count(request.id) == 1

      # Second DISTINCT operator: threshold met → approved + dispatched.
      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, b, "lgtm-2")

      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
      assert approved_count(request.id) == 2
    end

    test "min_approvals defaults to 1 — a single approve finalizes + dispatches (today's behavior)" do
      %{account: account, request: request} = gated_request()
      operator = distinct_operator(account)

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, operator, "ok")

      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
    end
  end

  describe "self-approval gate" do
    test "ABUSE: self-approval is refused server-side even when the UI would hide the button" do
      # The requester is the operator approving. allow_self_approval: false.
      requester = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: requester.id, role: "owner")
      subject = subject_for(requester, account, role: :owner)
      runner = runner_fixture(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      {:ok, request} =
        Approvals.create_request(run, requester.id, "x",
          min_approvals: 1,
          allow_self_approval: false
        )

      assert {:error, :self_approval_forbidden} =
               Approvals.approve_request(request, subject, "approving my own")

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
      refute_receive {:cloud_to_runner, _}, 100
    end

    test "a DIFFERENT operator can still approve when self-approval is forbidden" do
      %{account: account, request: request, requester_id: requester_id} =
        gated_request(min_approvals: 1, allow_self_approval: false)

      # Sanity: the requester is set and someone else is approving.
      other = distinct_operator(account)
      refute other.actor.id == requester_id

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, other, "ok")

      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
    end
  end

  describe "distinctness (DB unique (request_id, decider_id))" do
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
      refute_receive {:cloud_to_runner, _}, 100
    end
  end

  describe "deny finalizes DENIED" do
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
      refute_receive {:cloud_to_runner, _}, 100
    end
  end

  describe "decision isolation" do
    test "ABUSE: an owner of account B recording a decision on A's request → :not_found" do
      %{request: request} = gated_request(min_approvals: 1)

      account_b = account_fixture()
      subject_b = distinct_operator(account_b)

      assert {:error, :not_found} = Approvals.approve_request(request, subject_b, "wrong account")
      assert {:error, :not_found} = Approvals.deny_request(request, subject_b, "wrong account")
      assert approved_count(request.id) == 0
    end

    test "ABUSE: a viewer recording a decision → :unauthorized" do
      %{account: account, request: request} = gated_request(min_approvals: 1)

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Approvals.approve_request(request, viewer_subject, "nope")
      assert {:error, :unauthorized} = Approvals.deny_request(request, viewer_subject, "nope")
      assert approved_count(request.id) == 0
    end
  end

  describe "snapshot integrity" do
    test "an in-flight request keeps its snapshotted threshold when the policy later changes" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      # Created under min 2 (the policy's posture at dispatch time).
      {:ok, request} = Approvals.create_request(run, user_fixture().id, "x", min_approvals: 2)
      assert request.min_approvals == 2

      # A later policy edit to min 1 must NOT move this in-flight request's bar
      # — it snapshots the value, not the live policy.
      a = distinct_operator(account)
      b = distinct_operator(account)

      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, a, "one")

      refute_receive {:cloud_to_runner, _}, 100

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, b, "two")
    end
  end

  describe "MCP self-approval (closes the api-key bypass)" do
    test "ABUSE: an MCP run (requested_by_id nil) attributes self to the api-key owner; the owner can't self-approve" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      owner_subject = subject_for(owner, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: owner.id)
      runner = runner_fixture(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
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
      refute_receive {:cloud_to_runner, _}, 100

      # A DIFFERENT operator can approve.
      other = distinct_operator(account)

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, other, "ok")

      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
    end
  end

  describe "expiry with decisions present" do
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

  describe "per-vote audit" do
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
end
