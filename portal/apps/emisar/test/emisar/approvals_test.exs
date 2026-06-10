defmodule Emisar.ApprovalsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Audit, Repo, Runs}
  alias Emisar.Approvals.{Grant, Request}
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

  defp operator_subject(account) do
    operator = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "owner")
    subject_for(operator, account, role: :owner)
  end

  describe "create_request/3" do
    test "creates an approval request in :pending status" do
      {_account, run} = run_fixture()
      operator = user_fixture()

      assert {:ok, %Request{status: "pending", run_id: run_id}} =
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
      {:ok, req} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: "approved"}, %ActionRun{status: "sent"}}} =
               Approvals.approve_request(req, subject, "lgtm")

      assert Enum.any?(
               Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.approved")
             )
    end

    test "a viewer (cannot decide) is refused with :unauthorized" do
      {account, run} = run_fixture()
      decider = operator_subject(account)
      {:ok, req} = Approvals.create_request(run, decider.actor.id, "needs approve")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Approvals.approve_request(req, viewer_subject, "no rights")
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
      {:ok, req} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: "denied"}, %ActionRun{status: "cancelled"}}} =
               Approvals.deny_request(req, subject, "not now")

      assert Enum.any?(
               Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.denied")
             )
    end

    test "a viewer (cannot decide) is refused with :unauthorized" do
      {account, run} = run_fixture()
      decider = operator_subject(account)
      {:ok, req} = Approvals.create_request(run, decider.actor.id, "needs approve")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Approvals.deny_request(req, viewer_subject, "no rights")
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

      g = insert_grant(account, key, action_id: "x", granted_by_id: user.id)
      {:ok, _} = Approvals.revoke_grant(g, subject)

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

      g = insert_grant(account, key, action_id: "act.revoke-audit", granted_by_id: user.id)
      assert {:ok, _} = Approvals.revoke_grant(g, subject)

      {:ok, events, _} = Emisar.Audit.list_events(subject)
      audit = Enum.find(events, &(&1.event_type == "approval.grant_revoked"))

      assert audit, "expected an approval.grant_revoked audit row"
      assert audit.subject_kind == "approval_grant"
      assert audit.subject_id == g.id
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
      g = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Approvals.revoke_grant(g, operator_subject)
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
      g = insert_grant(account, key, action_id: "x", max_uses: 1, granted_by_id: user.id)

      assert :ok = Approvals.use_grant(g)
      reloaded = Repo.reload!(g)
      assert reloaded.uses_count == 1
      assert reloaded.last_used_at != nil

      assert {:error, :exhausted} = Approvals.use_grant(reloaded)
    end

    test "unlimited grant keeps incrementing" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      g = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      assert :ok = Approvals.use_grant(g)
      assert :ok = Approvals.use_grant(Repo.reload!(g))
      assert :ok = Approvals.use_grant(Repo.reload!(g))

      assert Repo.reload!(g).uses_count == 3
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

      {:ok, req} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(req, subject, "ok", duration: :once)

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

      {:ok, req} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(req, subject, nil, duration: :one_day, scope: :exact_args)

      [g] = grants_for_api_key(key.id)
      assert g.action_id == "linux.uptime"
      assert g.args_sha256 == "abc123"
      assert g.expires_at != nil
      assert DateTime.diff(g.expires_at, DateTime.utc_now(), :hour) in 23..24

      # Minting the grant dispatched the approved run — that's its first
      # use, so it starts at 1 (never "not used yet") with last_used_at set.
      assert g.uses_count == 1
      assert g.last_used_at != nil
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

      {:ok, req} = Approvals.create_request(run, user.id, "x")

      {:ok, _} = Approvals.approve_request(req, subject, nil, duration: :one_day, max_uses: 5)

      # Regression: approve_request used to drop :max_uses from grant_attrs,
      # minting an UNCAPPED grant even when the operator set a cap.
      [g] = grants_for_api_key(key.id)
      assert g.max_uses == 5
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

      {:ok, req} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(req, subject, nil, duration: :one_day, scope: :exact_args)

      # The grant stores only the hash; the list preloads approval_request
      # → run so the operator can see exactly what args it's locked to.
      {:ok, [g], _} = Approvals.list_grants_for_account(subject)
      assert g.approval_request.run.args == %{"table" => "users", "full" => true}
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

      {:ok, req} = Approvals.create_request(run, user.id, "x")

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
               Approvals.approve_request(req, subject, "ok", duration: :one_day)

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

      {:ok, req} = Approvals.create_request(run, user.id, "x")

      {:ok, _} =
        Approvals.approve_request(req, subject, nil, duration: :indefinite, scope: :any_args)

      [g] = grants_for_api_key(key.id)
      assert g.args_sha256 == nil
      assert g.expires_at == nil
    end
  end

  describe "expire_overdue_requests/1" do
    test "transitions pending requests past expires_at to expired + cancels the run" do
      {account, run} = run_fixture()
      user = user_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      {:ok, req} = Approvals.create_request(run, user.id, "x")

      # Move the request's expiry into the past.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {1, _} =
        Request.Query.all()
        |> Request.Query.by_id(req.id)
        |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1

      expired = Request.Query.all() |> Request.Query.by_id(req.id) |> Repo.fetch!(Request.Query)
      assert expired.status == "expired"
      assert expired.decided_at != nil
      assert expired.decision_reason =~ "expired"

      reloaded_run =
        Emisar.Runs.ActionRun.Query.all()
        |> Emisar.Runs.ActionRun.Query.by_id(run.id)
        |> Repo.fetch!(Emisar.Runs.ActionRun.Query)

      assert reloaded_run.status == "cancelled"

      assert Enum.any?(
               Emisar.Audit.list_events(subject, page: [limit: 50])
               |> elem(1),
               &(&1.event_type == "approval.expired" and &1.subject_id == req.id)
             )
    end

    test "is idempotent — second sweep is a no-op" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      Request.Query.all()
      |> Request.Query.by_id(req.id)
      |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1
      assert Approvals.expire_overdue_requests() == 0
    end

    test "leaves pending requests within the window alone" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")
      # default 24h is in the future
      assert Approvals.expire_overdue_requests() == 0

      assert (Request.Query.all()
              |> Request.Query.by_id(req.id)
              |> Repo.fetch!(Request.Query)).status == "pending"
    end
  end

  describe "create_request/3 expiry default" do
    test "sets expires_at 24h from now by default" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")

      assert req.expires_at != nil
      assert DateTime.diff(req.expires_at, DateTime.utc_now(), :hour) in 23..24
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

      req =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} =
        Approvals.approve_request(req, subject, nil, duration: :one_day, scope: :any_args)

      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500

      assert {:ok, :running, run2} = Runs.dispatch_run(attrs, subject)
      assert run2.id != run1.id
      refute Request.Query.all() |> Request.Query.by_run_id(run2.id) |> Repo.peek()
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500

      [g] = grants_for_api_key(key.id)
      # Two executions under this grant: the approved first call (its
      # minting use) and the auto-approved second call.
      assert g.uses_count == 2
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

      req =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} = Approvals.approve_request(req, subject, nil, duration: :once)

      assert {:ok, :pending_approval, _run2} =
               Runs.dispatch_run(attrs, subject)
    end
  end
end
