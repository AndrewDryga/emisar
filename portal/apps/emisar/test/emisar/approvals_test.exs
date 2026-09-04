defmodule Emisar.ApprovalsTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Catalog, Repo, Runbooks, Runs}
  alias Emisar.Approvals.{Decision, Grant, Request}
  alias Emisar.Fixtures
  alias Emisar.Runs.ActionRun

  @grant_pack_hash "sha256:" <> String.duplicate("a", 64)
  @grant_pack_ref "linux-core@1.0.0/" <> @grant_pack_hash

  defp run_fixture(opts \\ []) do
    account =
      Keyword.get(opts, :account) || Fixtures.Accounts.create_account()

    runner = Keyword.get(opts, :runner) || Fixtures.Runners.create_runner(account_id: account.id)
    # An approvable run needs a currently-advertised action: approve re-resolves
    # the trusted contract and fails closed when it is gone.
    Fixtures.Catalog.create_action(runner: runner)
    initiator = Fixtures.Users.create_user()

    initiating_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: initiator.id,
        role: "operator"
      )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        requested_by_id: initiator.id,
        initiating_membership_id: initiating_membership.id,
        args: %{},
        # A parked gated run carries the trusted pack contract dispatch would
        # have snapshotted; approve re-resolves it and compares the hash.
        pack_ref: Fixtures.Catalog.default_pack_ref(),
        expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
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

  # A frozen execution plan carrying exactly the risk tiers under test — `nil`
  # stands for an item whose tier the plan never recorded.
  defp execution_stage_plan(risks) do
    items =
      Enum.with_index(risks, fn risk, index ->
        %{
          "action" => "postgres.config_validate",
          "step_id" => "validate-#{index}",
          "runner_ref" => "db-0#{index}~" <> String.duplicate("1", 64),
          "pack_ref" => "postgres@1.4.2/sha256:" <> String.duplicate("a", 64),
          "risk" => risk,
          "args" => %{}
        }
      end)

    %{
      "id" => "apply",
      "title" => "Apply database change",
      "mode" => "parallel",
      "max_parallel" => 2,
      "items" => items
    }
  end

  defp subject_with_runner_access(subject, access) do
    membership = Fixtures.Memberships.fetch_membership(subject.account.id, subject.actor.id)
    Fixtures.Memberships.force_runner_access(membership, access)
    Fixtures.Subjects.subject_for(subject.actor, subject.account, role: subject.role)
  end

  defp all_runner_pack_access(pack_ids) do
    {:ok, access} = Accounts.RunnerAccess.new(:all, [], [], :restricted, pack_ids)
    access
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
    Fixtures.Approvals.create_grant(
      Map.merge(
        %{account_id: account.id, api_key_id: key.id, pack_ref: @grant_pack_ref},
        Map.new(opts)
      )
    )
  end

  defp observe_trusted_grant_action(account, user, runner, risk, action_id \\ "linux.uptime") do
    assert {:ok, _runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "packs" => %{
                 "linux-core" => %{"version" => "1.0.0", "hash" => @grant_pack_hash}
               },
               "actions" => [
                 %{
                   "id" => action_id,
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => risk,
                   "summary" => "Reports uptime",
                   "description" => "Reports uptime",
                   "side_effects" => [],
                   "args" => [],
                   "examples" => [],
                   "search_terms" => []
                 }
               ]
             })

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    assert [pack_version] = Fixtures.Catalog.list_pack_versions(subject.account.id)
    assert {:ok, _pack_version} = Catalog.trust_pack_version(pack_version.id, subject)
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
    observe_trusted_grant_action(account, user, runner, "high")

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        pack_ref: @grant_pack_ref,
        expected_pack_hash: @grant_pack_hash,
        api_key_id: key.id,
        initiating_membership_id: key.created_by_membership_id,
        args: %{},
        args_sha256: "abc123",
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, user.id, "x")
    {subject, key, request}
  end

  # -- Configurable approval gate (GitHub-style) -----------------------

  # A fresh operator (owner) in the account, distinct from any other.
  defp distinct_operator(account), do: distinct_member(account, :owner)

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
      api_key_id: key.id
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

    membership = Fixtures.Memberships.fetch_membership(account.id, decider.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        requested_by_id: decider.id,
        initiating_membership_id: membership.id,
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
    Fixtures.Catalog.create_action(runner: runner)
    Emisar.Runners.subscribe_runner_transport(runner)
    initiator = Fixtures.Users.create_user()

    initiating_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: initiator.id,
        role: "operator"
      )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        requested_by_id: initiator.id,
        initiating_membership_id: initiating_membership.id,
        args: %{},
        # A parked gated run carries the trusted pack contract dispatch would
        # have snapshotted; approve re-resolves it and compares the hash.
        pack_ref: Fixtures.Catalog.default_pack_ref(),
        expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
        # A real require-approval run is parked :pending_approval; the finalizer
        # only dispatches a run still in that state.
        status: :pending_approval
      })

    requester_subject =
      case Keyword.get(opts, :requester_role) do
        nil -> nil
        role -> distinct_member(account, role)
      end

    requester =
      cond do
        requested_by_id = Keyword.get(opts, :requested_by_id) -> requested_by_id
        requester_subject -> requester_subject.actor.id
        true -> Fixtures.Users.create_user().id
      end

    {:ok, request} =
      Approvals.create_request(run, requester, "needs review",
        min_approvals: Keyword.get(opts, :min_approvals, 1),
        allow_self_approval: Keyword.get(opts, :allow_self_approval, true)
      )

    %{
      account: account,
      runner: runner,
      run: run,
      request: request,
      requester_id: requester,
      requester_subject: requester_subject
    }
  end

  defp distinct_member(account, role) do
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: Atom.to_string(role)
      )

    Fixtures.Subjects.membership_subject(membership)
  end

  defp stale_signed_gated_request do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Fixtures.Catalog.create_action(runner: runner)

    {:ok, runner} =
      Emisar.Runners.apply_state(runner, %{
        "enforce_signatures" => true,
        "max_attestation_age_seconds" => 3600
      })

    requester = Fixtures.Users.create_user()

    requester_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: requester.id,
        role: "operator"
      )

    stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

    %{attestation: attestation} =
      Fixtures.Runs.signed_attestation(
        issued_at: stale,
        pack_ref: Fixtures.Catalog.default_pack_ref()
      )

    run =
      Fixtures.Runs.create_signed_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        requested_by_id: requester.id,
        initiating_membership_id: requester_membership.id,
        args: %{},
        pack_ref: Fixtures.Catalog.default_pack_ref(),
        expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
        status: :pending_approval,
        attestation: attestation
      })

    {:ok, request} =
      Approvals.create_request(run, requester.id, "please", min_approvals: 2)

    %{request: request, owner: distinct_member(account, :owner)}
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

    test "rejects a subject without view permission" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.permissionless_subject(account)

      assert Approvals.list_pending_approval_requests(subject) == {:error, :unauthorized}
    end

    test "does not list another account's pending requests" do
      {_account_a, run_a} = run_fixture()
      {:ok, _request} = Approvals.create_request(run_a, Fixtures.Users.create_user().id, nil)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:ok, [], _metadata} = Approvals.list_pending_approval_requests(subject_b)
    end

    test "runner access filters the queue, badge, detail, and decision authority" do
      account = Fixtures.Accounts.create_account()
      db_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      {_, db_run} = run_fixture(account: account, runner: db_runner)
      {_, web_run} = run_fixture(account: account, runner: web_runner)

      {:ok, db_request} =
        Approvals.create_request(db_run, Fixtures.Users.create_user().id, "database")

      {:ok, web_request} =
        Approvals.create_request(web_run, Fixtures.Users.create_user().id, "web")

      {:ok, database_access} = Accounts.RunnerAccess.restricted(["database"], [])

      subject =
        account
        |> operator_subject()
        |> subject_with_runner_access(database_access)

      assert {:ok, [%Request{id: id}], _meta} =
               Approvals.list_pending_approval_requests(subject)

      assert id == db_request.id
      assert Approvals.count_pending_approval_requests(subject) == 1

      assert Approvals.fetch_approval_request_by_id(web_request.id, subject) ==
               {:error, :not_found}

      assert Approvals.deny_request(web_request, subject, "forged") == {:error, :not_found}
      assert Repo.reload!(web_request).status == :pending

      assert {:ok, {%Request{status: :denied}, _run}} =
               Approvals.deny_request(db_request, subject, "in scope")
    end

    test "pack access filters every request read and both decision paths" do
      {subject, _key, request} = approvable_mcp_run()

      subject = subject_with_runner_access(subject, all_runner_pack_access(["postgres"]))

      assert {:ok, [], _metadata} = Approvals.list_pending_approval_requests(subject)
      assert Approvals.count_pending_approval_requests(subject) == 0
      assert Approvals.fetch_approval_request_by_id(request.id, subject) == {:error, :not_found}
      assert Approvals.approve_request(request, subject, "forged") == {:error, :not_found}
      assert Approvals.deny_request(request, subject, "forged") == {:error, :not_found}
      assert Repo.reload!(request).status == :pending

      subject = subject_with_runner_access(subject, all_runner_pack_access(["linux-core"]))

      assert {:ok, [%Request{id: id}], _metadata} =
               Approvals.list_pending_approval_requests(subject)

      assert id == request.id

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, subject, "covered")
    end

    test "a stale request cannot be approved after current pack access is revoked" do
      {subject, _key, request} = approvable_mcp_run()
      allowed = subject_with_runner_access(subject, all_runner_pack_access(["linux-core"]))

      assert {:ok, stale_request} =
               Approvals.fetch_approval_request_by_id(request.id, allowed)

      _revoked = subject_with_runner_access(allowed, all_runner_pack_access(["postgres"]))

      assert Approvals.approve_request(stale_request, allowed, "access was revoked") ==
               {:error, :not_found}

      assert Repo.reload!(request).status == :pending
    end

    test "a stale request cannot be denied after current pack access is revoked" do
      {subject, _key, request} = approvable_mcp_run()
      allowed = subject_with_runner_access(subject, all_runner_pack_access(["linux-core"]))

      assert {:ok, stale_request} =
               Approvals.fetch_approval_request_by_id(request.id, allowed)

      _revoked = subject_with_runner_access(allowed, all_runner_pack_access(["postgres"]))

      assert Approvals.deny_request(stale_request, allowed, "access was revoked") ==
               {:error, :not_found}

      assert Repo.reload!(request).status == :pending
    end

    test "whole-execution approvals require every frozen runner and pack" do
      {requester, account, subject} = Fixtures.Subjects.owner_subject()

      stage_plan =
        execution_stage_plan(["medium", "high"])
        |> update_in(["items"], fn [postgres, redis] ->
          redis = %{
            redis
            | "pack_ref" => "redis@2.1.0/sha256:" <> String.duplicate("b", 64)
          }

          [postgres, redis]
        end)

      request =
        Fixtures.Approvals.create_execution_request(account, requester, stage_plan: stage_plan)

      pack_partial = subject_with_runner_access(subject, all_runner_pack_access(["postgres"]))

      assert Approvals.fetch_approval_request_by_id(request.id, pack_partial) ==
               {:error, :not_found}

      all_packs =
        subject_with_runner_access(subject, all_runner_pack_access(["postgres", "redis"]))

      assert {:ok, %Request{id: id}} =
               Approvals.fetch_approval_request_by_id(request.id, all_packs)

      assert id == request.id

      [first_item | _rest] =
        Runbooks.ExecutionItem.Query.by_execution_id(request.runbook_execution_id)
        |> Repo.all()

      {:ok, one_runner} =
        Accounts.RunnerAccess.new(
          :restricted,
          [],
          [first_item.runner_id],
          :restricted,
          ["postgres", "redis"]
        )

      runner_partial = subject_with_runner_access(subject, one_runner)

      assert Approvals.fetch_approval_request_by_id(request.id, runner_partial) ==
               {:error, :not_found}
    end

    test "missing or malformed frozen approval targets fail closed" do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, nil)

      {1, _} =
        ActionRun.Query.all()
        |> ActionRun.Query.by_id(run.id)
        |> Repo.update_all(set: [pack_ref: "not-a-pack-ref"])

      assert Approvals.fetch_approval_request_by_id(request.id, subject) == {:error, :not_found}
      assert Approvals.deny_request(request, subject, "corrupt") == {:error, :not_found}

      {requester, execution_account, execution_subject} = Fixtures.Subjects.owner_subject()

      execution_request =
        Fixtures.Approvals.create_execution_request(execution_account, requester)

      {_count, _} =
        Runbooks.ExecutionItem.Query.by_execution_id(execution_request.runbook_execution_id)
        |> Repo.delete_all()

      assert Approvals.fetch_approval_request_by_id(execution_request.id, execution_subject) ==
               {:error, :not_found}
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
    test "tallies every window outcome plus the current waiting backlog" do
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
      assert stats.expired == 0
      assert stats.cancelled == 0
      assert stats.waiting_now == 1
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
      assert stats.waiting_now == 0
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

      assert Approvals.fetch_approval_request_by_id(request.id, other_subject) ==
               {:error, :not_found}

      assert Approvals.fetch_approval_request_by_id("not-a-uuid", subject) == {:error, :not_found}
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

      assert Approvals.fetch_approval_request_by_run_id(run.id, other_subject) ==
               {:error, :not_found}
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

      assert Approvals.fetch_approval_request_by_run_id(run.id, no_perms) ==
               {:error, :unauthorized}
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

  describe "list_requests_for_runbook_executions/2" do
    test "returns only visible requests for the bounded execution set" do
      account = Fixtures.Accounts.create_account()
      subject = operator_subject(account)

      assert Approvals.list_requests_for_runbook_executions([], subject) == {:ok, []}

      other_account = Fixtures.Accounts.create_account()
      other_subject = operator_subject(other_account)
      assert Approvals.list_requests_for_runbook_executions([], other_subject) == {:ok, []}
    end

    test "accepts a full batch and refuses anything larger" do
      account = Fixtures.Accounts.create_account()
      subject = operator_subject(account)
      id = Ecto.UUID.generate()

      assert Approvals.list_requests_for_runbook_executions(List.duplicate(id, 64), subject) ==
               {:ok, []}

      assert Approvals.list_requests_for_runbook_executions(List.duplicate(id, 65), subject) ==
               {:error, :too_many_execution_ids}
    end
  end

  describe "risk_by_request_ids/2" do
    test "answers an action request with the risk its exact runner advertises" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_account, run} = run_fixture(account: account, runner: runner)
      Fixtures.Catalog.create_action(runner: runner, risk: "high")
      subject = operator_subject(account)

      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, nil)

      assert Approvals.risk_by_request_ids([request.id], subject) ==
               {:ok, %{request.id => :high}}
    end

    test "folds a frozen execution plan's string tiers to its worst" do
      {requester, account, subject} = Fixtures.Subjects.owner_subject()

      request =
        Fixtures.Approvals.create_execution_request(account, requester,
          stage_plan: execution_stage_plan(["medium", "critical", "low"])
        )

      assert Approvals.risk_by_request_ids([request.id], subject) ==
               {:ok, %{request.id => :critical}}
    end

    test "keeps a visible request whose risk cannot be resolved, at nil" do
      {requester, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_account, run} = run_fixture(account: account, runner: runner)

      {:ok, action_request} = Approvals.create_request(run, requester.id, nil)
      Fixtures.Catalog.delete_actions_for_runner(runner.id)

      # One unresolved item makes the whole plan unknown — the readable
      # remainder would understate the execution.
      execution_request =
        Fixtures.Approvals.create_execution_request(account, requester,
          stage_plan: execution_stage_plan(["critical", nil])
        )

      assert Approvals.risk_by_request_ids([action_request.id, execution_request.id], subject) ==
               {:ok, %{action_request.id => nil, execution_request.id => nil}}
    end

    test "answers only for requests the caller's current runner access reaches" do
      account = Fixtures.Accounts.create_account()
      db_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      {_account, db_run} = run_fixture(account: account, runner: db_runner)
      {_account, web_run} = run_fixture(account: account, runner: web_runner)
      Fixtures.Catalog.create_action(runner: db_runner, risk: "high")
      Fixtures.Catalog.create_action(runner: web_runner, risk: "critical")

      {:ok, db_request} = Approvals.create_request(db_run, Fixtures.Users.create_user().id, nil)

      {:ok, _web_request} =
        Approvals.create_request(web_run, Fixtures.Users.create_user().id, nil)

      {:ok, database_access} = Accounts.RunnerAccess.restricted(["database"], [])

      subject =
        account
        |> operator_subject()
        |> subject_with_runner_access(database_access)

      {:ok, [%Request{id: visible_id}], _metadata} =
        Approvals.list_pending_approval_requests(subject)

      assert visible_id == db_request.id

      assert Approvals.risk_by_request_ids([db_request.id], subject) ==
               {:ok, %{db_request.id => :high}}
    end

    test "omits another account's request and ids that resolve to nothing" do
      {_account_a, run_a} = run_fixture()
      {:ok, request_a} = Approvals.create_request(run_a, Fixtures.Users.create_user().id, nil)
      {account_b, _run_b} = run_fixture()

      ids = [request_a.id, Ecto.UUID.generate(), "not-a-uuid"]

      assert Approvals.risk_by_request_ids(ids, operator_subject(account_b)) == {:ok, %{}}
    end

    test "denies a subject without view permission, including for an empty list" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.permissionless_subject(account)

      assert Approvals.risk_by_request_ids([], subject) == {:error, :unauthorized}

      assert Approvals.risk_by_request_ids([Ecto.UUID.generate()], subject) ==
               {:error, :unauthorized}
    end

    test "accepts a full batch and refuses anything larger or unbounded" do
      {account, _run} = run_fixture()
      subject = operator_subject(account)
      id = Ecto.UUID.generate()

      assert Approvals.risk_by_request_ids(List.duplicate(id, 64), subject) == {:ok, %{}}

      assert Approvals.risk_by_request_ids(List.duplicate(id, 65), subject) ==
               {:error, :too_many_request_ids}

      assert Approvals.risk_by_request_ids(%{}, subject) == {:error, :too_many_request_ids}
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

      assert Approvals.fetch_request_for_visible_run(foreign_run, subject) == {:error, :not_found}
    end

    test "still requires run-view permission" do
      {account, run} = run_fixture()

      no_permissions = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert Approvals.fetch_request_for_visible_run(run, no_permissions) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_request_for_visible_runbook_execution/2" do
    test "lets an API client read only the approval attached to its visible account execution" do
      {requester, account, owner} = Fixtures.Subjects.owner_subject()
      request = Fixtures.Approvals.create_execution_request(account, requester)
      execution = Repo.one!(Runbooks.RunbookExecution)

      {:ok, _raw, key} = Emisar.ApiKeys.create_key(%{name: "approval observer"}, owner)
      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, fetched} =
               Approvals.fetch_request_for_visible_runbook_execution(execution, subject)

      assert fetched.id == request.id

      {foreign_requester, foreign_account, _foreign_subject} = Fixtures.Subjects.owner_subject()

      foreign_request =
        Fixtures.Approvals.create_execution_request(foreign_account, foreign_requester)

      foreign_execution = %Runbooks.RunbookExecution{
        id: foreign_request.runbook_execution_id,
        account_id: foreign_account.id
      }

      # `Subject.ensure_in_account` refuses the cross-account read.
      assert Approvals.fetch_request_for_visible_runbook_execution(foreign_execution, subject) ==
               {:error, :not_found}
    end

    test "still requires runbook-view permission" do
      {requester, account, _subject} = Fixtures.Subjects.owner_subject()
      _request = Fixtures.Approvals.create_execution_request(account, requester)
      execution = Repo.one!(Runbooks.RunbookExecution)

      no_permissions = %Emisar.Auth.Subject{
        account: account,
        role: :viewer,
        permissions: MapSet.new()
      }

      assert Approvals.fetch_request_for_visible_runbook_execution(execution, no_permissions) ==
               {:error, :unauthorized}
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

      assert Approvals.list_decisions_for_request(request, no_perms) == {:error, :unauthorized}
    end

    test "an owner of another account can't read this request's decisions (cross-account)", %{
      request: request
    } do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # `Subject.ensure_in_account` refuses the cross-account read.
      assert Approvals.list_decisions_for_request(request, subject_b) == {:error, :not_found}
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

      assert Approvals.approved_count_for_request(request, a) === {:ok, 0}

      {:ok, _} = Approvals.approve_request(request, a, "yes")
      assert Approvals.approved_count_for_request(request, a) === {:ok, 1}

      # A deny doesn't add to the approver tally.
      {:ok, _} = Approvals.deny_request(request, b, "no")
      assert Approvals.approved_count_for_request(request, a) === {:ok, 1}
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

      assert Approvals.approved_count_for_request(request, no_perms) == {:error, :unauthorized}
    end

    test "an owner of another account can't read this request's count (cross-account)", %{
      request: request
    } do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Approvals.approved_count_for_request(request, subject_b) == {:error, :not_found}
    end
  end

  describe "actor_labels_for_ids/2" do
    test "returns bounded account-local labels and omits cross-account ids" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      other_account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user(full_name: "Global Name")
      outsider = Fixtures.Users.create_user(full_name: "Other Account Name")

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      _other_membership =
        Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: outsider.id)

      _membership = Fixtures.Memberships.sync_display_name(membership, "Directory Name")

      ids = [user.id, outsider.id, nil, user.id]

      assert Approvals.actor_labels_for_ids(ids, subject) ==
               {:ok, %{user.id => "Directory Name"}}
    end

    test "denies a principal without approval visibility" do
      account = Fixtures.Accounts.create_account()

      subject =
        Fixtures.Subjects.build_subject(
          account: account,
          role: :viewer,
          permissions: MapSet.new()
        )

      assert Approvals.actor_labels_for_ids([], subject) == {:error, :unauthorized}
    end

    test "rejects an oversized id set before querying" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      ids = List.duplicate(Ecto.UUID.generate(), 257)

      assert Approvals.actor_labels_for_ids(ids, subject) == {:error, :too_many_ids}
      assert Approvals.actor_labels_for_ids(:not_a_list, subject) == {:error, :too_many_ids}
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

    test "rejects an approval threshold outside the storage range" do
      {_account, run} = run_fixture()

      assert {:error, changeset} =
               Approvals.create_request(run, Fixtures.Users.create_user().id, "x",
                 min_approvals: Emisar.Policies.max_min_approvals() + 1
               )

      assert "must be less than or equal to #{Emisar.Policies.max_min_approvals()}" in errors_on(
               changeset
             ).min_approvals
    end

    test "snapshots the run's evidence/expected justification chain onto the request" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          reason: "restart the stuck worker",
          evidence: "run 0f9c showed the queue depth climbing for 20m",
          expected: "queue depth drops to zero within a minute",
          args: %{},
          status: :pending_approval
        })

      assert {:ok, request} =
               Approvals.create_request(run, Fixtures.Users.create_user().id, run.reason)

      assert request.evidence == "run 0f9c showed the queue depth climbing for 20m"
      assert request.expected == "queue depth drops to zero within a minute"
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
          pack_ref: @grant_pack_ref,
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

    test "does not notify an approver until their invitation is accepted", %{
      account: account,
      run: run,
      members: members
    } do
      owner_membership = Fixtures.Memberships.fetch_membership(account.id, members["owner"].id)
      owner_subject = Fixtures.Subjects.membership_subject(owner_membership)
      invited = Fixtures.Users.create_user()

      assert {:ok, %{membership: invitation}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: invited.email, role: "admin"),
                 owner_subject
               )

      assert Accounts.membership_invitation_pending?(invitation)

      {:ok, _request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs approval")

      recipients = notified_recipients()
      assert members["owner"].email in recipients
      refute invited.email in recipients
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

    test "emails only deciders whose current pack access covers the action", %{
      account: account,
      run: run,
      members: members
    } do
      operator_membership =
        Fixtures.Memberships.fetch_membership(account.id, members["operator"].id)

      admin_membership = Fixtures.Memberships.fetch_membership(account.id, members["admin"].id)

      Fixtures.Memberships.force_runner_access(
        operator_membership,
        all_runner_pack_access(["postgres"])
      )

      Fixtures.Memberships.force_runner_access(
        admin_membership,
        all_runner_pack_access(["linux-core"])
      )

      {:ok, _request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs approval")

      recipients = notified_recipients()

      assert members["owner"].email in recipients
      assert members["admin"].email in recipients
      refute members["operator"].email in recipients
    end

    test "rechecks current eligibility before a lifecycle update", %{
      account: account,
      run: run,
      members: members
    } do
      {:ok, request} =
        Approvals.create_request(run, Fixtures.Users.create_user().id, "needs approval")

      _created = notified_emails()

      owner_membership = Fixtures.Memberships.fetch_membership(account.id, members["owner"].id)
      Fixtures.Memberships.suspend_membership(owner_membership)

      cancelled =
        request
        |> Ecto.Changeset.change(
          status: :cancelled,
          decided_at: DateTime.utc_now(),
          decision_reason: "parent run cancelled"
        )
        |> Repo.update!()

      assert Approvals.broadcast_cancelled_requests([cancelled]) == :ok

      recipients = notified_recipients()
      refute members["owner"].email in recipients
      assert members["admin"].email in recipients
      assert members["operator"].email in recipients
      refute members["viewer"].email in recipients
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

  describe "create_runbook_execution_request_in_multi/3" do
    test "composes one execution-owned request without manufacturing an action run" do
      multi =
        Approvals.create_runbook_execution_request_in_multi(
          Multi.new(),
          :execution,
          %{
            min_approvals: 2,
            allow_self_approval: false,
            runbook: %{"id" => Ecto.UUID.generate(), "title" => "Maintenance", "version" => 1}
          }
        )

      assert [
               {{:runbook_execution_approval_request, :execution}, {:run, changeset_fun}}
             ] = Multi.to_list(multi)

      assert is_function(changeset_fun, 2)
    end
  end

  describe "runbook_execution_approved?/2" do
    test "requires an approved request for the exact execution and account" do
      {requester, account, _subject} = Fixtures.Subjects.owner_subject()
      request = Fixtures.Approvals.create_execution_request(account, requester)

      refute Approvals.runbook_execution_approved?(
               request.runbook_execution_id,
               account.id
             )

      request
      |> Ecto.Changeset.change(status: :approved, decided_at: DateTime.utc_now())
      |> Repo.update!()

      assert Approvals.runbook_execution_approved?(
               request.runbook_execution_id,
               account.id
             )

      refute Approvals.runbook_execution_approved?(
               request.runbook_execution_id,
               Ecto.UUID.generate()
             )
    end
  end

  describe "after_runbook_execution_request_committed/1" do
    test "is idempotent when a replay inserted no execution request" do
      assert Approvals.after_runbook_execution_request_committed(%{}) == :ok
    end

    test "emails only deciders who cover every execution runner and pack" do
      {requester, account, _subject} = Fixtures.Subjects.owner_subject()
      eligible = Fixtures.Users.create_user()
      pack_partial = Fixtures.Users.create_user()

      eligible_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: eligible.id,
          role: "operator"
        )

      pack_partial_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: pack_partial.id,
          role: "operator"
        )

      Fixtures.Memberships.force_runner_access(
        eligible_membership,
        all_runner_pack_access(["postgres", "redis"])
      )

      Fixtures.Memberships.force_runner_access(
        pack_partial_membership,
        all_runner_pack_access(["postgres"])
      )

      stage_plan =
        execution_stage_plan(["medium", "high"])
        |> update_in(["items"], fn [postgres, redis] ->
          redis = %{
            redis
            | "pack_ref" => "redis@2.1.0/sha256:" <> String.duplicate("b", 64)
          }

          [postgres, redis]
        end)

      request =
        Fixtures.Approvals.create_execution_request(account, requester, stage_plan: stage_plan)

      assert Approvals.after_runbook_execution_request_committed(%{
               {:runbook_execution_approval_request, :execution} => request
             }) == :ok

      recipients = notified_recipients()
      assert eligible.email in recipients
      refute pack_partial.email in recipients
    end
  end

  describe "cancel_request_for_runbook_execution_in_multi/2" do
    test "records an explicit no-op when no pending execution request exists" do
      execution_id = Ecto.UUID.generate()

      assert {:ok, changes} =
               Multi.new()
               |> Approvals.cancel_request_for_runbook_execution_in_multi(execution_id)
               |> Repo.transaction()

      assert changes[{:runbook_execution_request_cancel, execution_id}] == :none
    end
  end

  describe "after_runbook_execution_cancellation_committed/1" do
    test "is idempotent when no execution request changed" do
      assert Approvals.after_runbook_execution_cancellation_committed(%{}) == :ok
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

      assert Approvals.notify_request_created(%{approval_request: request, run: run}) == :ok

      assert_receive {:approval_updated, id}
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
      assert Approvals.notify_request_created(request, run) == :ok
      assert_receive {:approval_updated, id}
      assert id == request.id
      assert decider.email in notified_recipients()
    end
  end

  describe "request_facts/2" do
    test "a request still inside its window is live, with the seconds left" do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, 90, :second)

      assert Approvals.request_facts(%Request{status: :pending, expires_at: expires_at}, now) ==
               %{
                 status: :pending,
                 expired?: false,
                 expires_at: expires_at,
                 expires_in_seconds: 90
               }
    end

    # The decide gate claims a row only while `expires_at > now`
    # (`Request.Query.decide_pending/5`), so the deadline instant itself is
    # already past deciding — the projection must not read it as live.
    test "a pending request AT its deadline already reads expired" do
      now = DateTime.utc_now()

      assert %{status: :expired, expired?: true, expires_in_seconds: 0} =
               Approvals.request_facts(%Request{status: :pending, expires_at: now}, now)
    end

    test "a pending request past its deadline reads expired with the countdown clamped at 0" do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, -3600, :second)

      assert Approvals.request_facts(%Request{status: :pending, expires_at: expires_at}, now) ==
               %{
                 status: :expired,
                 expired?: true,
                 expires_at: expires_at,
                 expires_in_seconds: 0
               }
    end

    test "a request with no deadline is live and has no countdown" do
      now = DateTime.utc_now()

      assert Approvals.request_facts(%Request{status: :pending, expires_at: nil}, now) ==
               %{status: :pending, expired?: false, expires_at: nil, expires_in_seconds: nil}
    end

    test "a decided request keeps its own status past the deadline" do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, -3600, :second)

      assert %{status: :approved, expired?: false} =
               Approvals.request_facts(%Request{status: :approved, expires_at: expires_at}, now)

      assert %{status: :denied, expired?: false} =
               Approvals.request_facts(%Request{status: :denied, expires_at: expires_at}, now)
    end

    test "a swept request reads expired whatever its deadline" do
      now = DateTime.utc_now()

      assert %{status: :expired, expired?: true} =
               Approvals.request_facts(%Request{status: :expired, expires_at: nil}, now)
    end
  end

  describe "request_name/1" do
    test "an action request is named by the action it holds" do
      context = %{"runner_id" => Ecto.UUID.generate(), "action_id" => "postgres.vacuum"}

      assert Approvals.request_name(%Request{context: context}) == "postgres.vacuum"
    end

    test "a runbook execution is named by its runbook's title" do
      context = %{
        "kind" => "runbook_execution",
        "execution_kind" => "published",
        "runbook" => %{"title" => "Rotate the edge certificates"}
      }

      assert Approvals.request_name(%Request{context: context}) == "Rotate the edge certificates"
    end

    test "a draft test says so before the title" do
      context = %{
        "kind" => "runbook_execution",
        "execution_kind" => "draft_test",
        "runbook" => %{"title" => "Rotate the edge certificates"}
      }

      assert Approvals.request_name(%Request{context: context}) ==
               "Draft test · Rotate the edge certificates"
    end

    test "a runbook frozen without a title still names its kind" do
      published = %{"kind" => "runbook_execution", "runbook" => %{}}
      draft = %{"kind" => "runbook_execution", "execution_kind" => "draft_test", "runbook" => %{}}

      assert Approvals.request_name(%Request{context: published}) == "Runbook execution"
      assert Approvals.request_name(%Request{context: draft}) == "Draft test · Runbook"
    end

    test "takes the stored context directly, so the audit label batch skips the rows" do
      # Audit projects {id, context} pairs rather than loading whole requests.
      assert Approvals.request_name(%{"action_id" => "linux.uptime"}) == "linux.uptime"
    end

    test "a context naming neither leaves the placeholder to the surface" do
      assert Approvals.request_name(%Request{context: %{}}) == nil
    end
  end

  describe "change_decision_input/1" do
    test "no attrs means a single-use approval with no cap" do
      changeset = Approvals.change_decision_input()

      assert changeset.valid?
      assert changeset.changes == %{}
      assert {:ok, input} = Ecto.Changeset.apply_action(changeset, :insert)
      assert input.duration == :once
      assert input.scope == :exact_args
      assert input.max_uses == nil
    end

    test "casts the raw decision form's strings, ignoring the fields it doesn't own" do
      attrs = %{
        "decision" => "approve",
        "reason" => "lgtm",
        "duration" => "thirty_days",
        "scope" => "any_args",
        "max_uses" => "5"
      }

      changeset = Approvals.change_decision_input(attrs)

      assert changeset.valid?
      assert changeset.changes == %{duration: :thirty_days, scope: :any_args, max_uses: 5}
    end

    test "accepts a keyword caller's atoms" do
      changeset = Approvals.change_decision_input(duration: :one_hour, scope: :any_args)

      assert changeset.valid?
      assert changeset.changes == %{duration: :one_hour, scope: :any_args}
    end

    test "an unknown duration is a field error, never coerced to a default" do
      changeset = Approvals.change_decision_input(%{"duration" => "forever"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).duration
    end

    test "an unknown scope is a field error" do
      changeset = Approvals.change_decision_input(%{"scope" => "everything"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).scope
    end

    test "a blank cap means unlimited within the window" do
      changeset = Approvals.change_decision_input(%{"duration" => "one_day", "max_uses" => ""})

      assert changeset.valid?
      assert changeset.changes == %{duration: :one_day}
    end

    test "a malformed cap is a field error" do
      changeset = Approvals.change_decision_input(%{"max_uses" => "lots"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).max_uses
    end

    test "a zero cap is a field error" do
      changeset = Approvals.change_decision_input(%{"max_uses" => "0"})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).max_uses
    end

    test "a negative cap is a field error" do
      changeset = Approvals.change_decision_input(%{"max_uses" => "-3"})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).max_uses
    end
  end

  describe "decision_input/1" do
    test "applies valid raw attrs into the typed choices an approve will use" do
      attrs = %{"duration" => "ninety_days", "scope" => "any_args", "max_uses" => "2"}

      assert {:ok, input} = Approvals.decision_input(attrs)
      assert input.duration == :ninety_days
      assert input.scope == :any_args
      assert input.max_uses == 2
    end

    test "returns the changeset for input it can't type" do
      assert {:error, changeset} = Approvals.decision_input(%{"duration" => "forever"})
      assert "is invalid" in errors_on(changeset).duration
    end
  end

  describe "approve_request/3" do
    setup do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      %{account: account, run: run, subject: subject}
    end

    # A viewer holds view_approvals but NOT decide_approval — it can watch the
    # queue and must not clear it. This is the product's core safety mutation and
    # nothing proved the gate held.
    test "a viewer is refused and the request stays pending", %{run: run, subject: subject} do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: subject.account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, subject.account, role: :viewer)

      assert Approvals.approve_request(request, viewer_subject, "lgtm") ==
               {:error, :unauthorized}

      assert {:ok, %Request{status: :pending}} =
               Approvals.fetch_approval_request_by_id(request.id, subject)

      assert {:ok, %ActionRun{status: :pending_approval}} = Runs.fetch_run_by_id(run.id, subject)
    end

    # The decision is scoped by the deciding subject's account, so an owner of
    # another tenant holding this request cannot decide it — permission alone is
    # not enough.
    test "an owner of another account cannot decide this request", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")
      other_subject = operator_subject(Fixtures.Accounts.create_account())

      assert Approvals.approve_request(request, other_subject, "lgtm") ==
               {:error, :not_found}

      assert {:ok, %Request{status: :pending}} =
               Approvals.fetch_approval_request_by_id(request.id, subject)
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

    # decision_reason was varchar(255) written through a bare update_all, so a
    # note of about two sentences raised Postgres 22001 INSIDE the decision
    # transaction. A raise, not an {:error, _}: the LiveView died, the request
    # stayed pending, the gated run stayed parked in :pending_approval, and no
    # approval audit row was written at all. Reject it as a value instead, and
    # leave every one of those intact.
    test "rejects an over-long decision note without touching the request or the run", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")
      too_long = String.duplicate("a", Approvals.max_decision_reason_length() + 1)

      assert Approvals.approve_request(request, subject, too_long) ==
               {:error, :decision_reason_too_long}

      assert {:ok, %Request{status: :pending}} =
               Approvals.fetch_approval_request_by_id(request.id, subject)

      assert {:ok, %ActionRun{status: :pending_approval}} =
               Runs.fetch_run_by_id(run.id, subject)

      refute Audit.list_events(subject, page: [limit: 50])
             |> elem(1)
             |> Enum.any?(&(&1.event_type == "approval.approved"))
    end

    test "stores a decision note at the maximum length", %{run: run, subject: subject} do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")
      at_limit = String.duplicate("a", Approvals.max_decision_reason_length())

      assert {:ok, {%Request{status: :approved} = decided, _run}} =
               Approvals.approve_request(request, subject, at_limit)

      assert decided.decision_reason == at_limit
    end

    test "rejects a decision note carrying a bidi override", %{run: run, subject: subject} do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert Approvals.approve_request(request, subject, "reviewed \u202Ednetxe-emit") ==
               {:error, :decision_reason_unsafe_text}

      assert %Request{status: :pending} = Repo.reload!(request)

      # Line breaks stay legal — the note is a multi-line textarea.
      assert {:ok, {%Request{status: :approved}, _run}} =
               Approvals.approve_request(request, subject, "reviewed\nlooks fine")
    end

    test "emails the requester the outcome, without argument values", %{
      account: account,
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")
      # Drop the approval-needed blast so only the decision email is left.
      _created = notified_emails()

      assert {:ok, {%Request{status: :approved}, _run}} =
               Approvals.approve_request(request, subject, "lgtm")

      emails = notified_emails()

      assert [email] =
               Enum.filter(emails, fn email ->
                 Enum.map(email.to, &elem(&1, 1)) == [subject.actor.email]
               end)

      assert email.subject == "Approval complete · linux.uptime"
      assert email.text_body =~ "approved with 1 of 1 approvals"
      assert email.text_body =~ "lgtm"
      assert email.text_body =~ "/app/#{account.slug}/runs/#{run.id}"
      assert email.html_body =~ ">View run</a>"
      refute email.text_body =~ "Arguments"

      assert Enum.any?(emails, fn email ->
               email.headers["In-Reply-To"] &&
                 email.text_body =~ "approval request was approved with 1 of 1"
             end)
    end

    test "a sub-threshold vote is not an outcome, so the requester hears nothing", %{
      account: account,
      run: run,
      subject: subject
    } do
      {:ok, request} =
        Approvals.create_request(run, subject.actor.id, "needs approve", min_approvals: 2)

      _created = notified_emails()

      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, subject, "one of two")

      emails = notified_emails()
      recipients = Enum.flat_map(emails, &Enum.map(&1.to, fn {_name, email} -> email end))

      refute subject.actor.email in recipients

      assert Enum.any?(
               emails,
               &(&1.text_body =~ "approved this request. 1 of 2 approvals received")
             )

      assert account.id == request.account_id
    end

    test "a removed requester receives no tenant outcome detail", %{
      account: account,
      run: run,
      subject: requester_subject
    } do
      {:ok, request} =
        Approvals.create_request(run, requester_subject.actor.id, "needs approve")

      _created = notified_emails()

      membership =
        Fixtures.Memberships.fetch_membership(account.id, requester_subject.actor.id)

      Fixtures.Memberships.suspend_membership(membership)
      decider = operator_subject(account)

      assert {:ok, {%Request{status: :approved}, _run}} =
               Approvals.approve_request(request, decider, "reviewed")

      recipients = notified_recipients()
      refute requester_subject.actor.email in recipients
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

      assert Approvals.approve_request(request, subject, "too late") == {:error, :expired}

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

      assert Approvals.approve_request(request, viewer_subject, "no rights") ==
               {:error, :unauthorized}
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

      assert Approvals.approve_request(req_a, subject_b, "wrong account") == {:error, :not_found}
    end

    test "ABUSE: a forged request struct cannot cross the account boundary" do
      {account_a, run_a} = run_fixture()
      decider_a = operator_subject(account_a)
      {:ok, request_a} = Approvals.create_request(run_a, decider_a.actor.id, "needs approve")

      account_b = Fixtures.Accounts.create_account()
      subject_b = operator_subject(account_b)
      forged_request = %{request_a | account_id: account_b.id}

      assert Approvals.approve_request(forged_request, subject_b, "forged") ==
               {:error, :not_found}

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
      assert Approvals.approve_request(request, second) == {:error, :already_decided}
      assert Approvals.deny_request(request, second, "again") == {:error, :already_decided}
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
          pack_ref: @grant_pack_ref,
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(request, subject, "ok", duration: :once)

      assert Fixtures.Approvals.grants_for_api_key(key.id) == []
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
      observe_trusted_grant_action(account, user, runner, "high")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
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
      assert grant.pack_ref == @grant_pack_ref
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
      observe_trusted_grant_action(account, user, runner, "high")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
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
      observe_trusted_grant_action(account, user, runner, "high", "postgres.vacuum")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "postgres.vacuum",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
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

      assert grant.approval_request.run.args_raw |> Jason.decode!() == %{
               "table" => "users",
               "full" => true
             }
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
      observe_trusted_grant_action(account, user, runner, "high")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      # Force create_grant to fail deterministically: blank the run's
      # pack_ref (bypassing the create changeset). Grant.Changeset.create
      # requires pack_ref, so the insert returns {:error, changeset} — the
      # exact branch that must roll back rather than commit as `:once`. The
      # action itself stays advertised, so the approve gate's trust re-check
      # passes and the grant insert is what fails.
      {1, _} =
        ActionRun.Query.all()
        |> ActionRun.Query.by_id(run.id)
        |> Repo.update_all(set: [pack_ref: nil])

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:error, {:grant_failed, %Ecto.Changeset{}}} =
               Approvals.approve_request(request, subject, "ok", duration: :one_day)

      # No grant was minted.
      assert Fixtures.Approvals.grants_for_api_key(key.id) == []

      # The run was NOT dispatched (the rollback aborted before dispatch).
      refute_receive {:cloud_to_runner, _generation, _}, 100

      # The approval.approved audit row was inside the rolled-back
      # transaction, so it never committed.
      {:ok, events, _} =
        Audit.list_events(subject, page: [limit: 50])

      refute Enum.any?(events, &(&1.event_type == "approval.approved"))
    end

    test "raw decision-form attrs mint the scoped, capped grant the operator picked", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      observe_trusted_grant_action(account, user, runner, "high")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")

      # Exactly what the browser posts — the context types it, the web doesn't.
      attrs = %{
        "decision" => "approve",
        "reason" => "lgtm",
        "duration" => "thirty_days",
        "scope" => "any_args",
        "max_uses" => "3"
      }

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.approve_request(request, subject, "lgtm", attrs)

      [grant] = Fixtures.Approvals.grants_for_api_key(key.id)
      assert grant.args_sha256 == nil
      assert grant.max_uses == 3
      assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :day) in 29..30
    end

    test "input the context can't type settles nothing — no vote, no transition, no grant, no dispatch",
         %{account: account, user: user, subject: subject, key: key} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      observe_trusted_grant_action(account, user, runner, "high")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123",
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, user.id, "x")
      Emisar.Runners.subscribe_runner_transport(runner)

      attrs = %{"duration" => "forever", "scope" => "any_args", "max_uses" => "3"}

      assert {:error, changeset} = Approvals.approve_request(request, subject, "ok", attrs)
      assert "is invalid" in errors_on(changeset).duration

      assert %Request{status: :pending, decided_by_id: nil} = Repo.reload!(request)
      assert Repo.all(Decision) == []
      assert Fixtures.Approvals.grants_for_api_key(key.id) == []
      assert %ActionRun{status: :pending_approval} = Repo.reload!(run)
      refute_receive {:cloud_to_runner, _generation, _}, 100

      {:ok, events, _meta} = Audit.list_events(subject, page: [limit: 50])

      refute Enum.any?(
               events,
               &(&1.event_type in ["approval.decision_recorded", "approval.approved"])
             )
    end

    test ":any_args scope drops args_sha256 so any args match", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      observe_trusted_grant_action(account, user, runner, "high")

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          pack_ref: @grant_pack_ref,
          expected_pack_hash: @grant_pack_hash,
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

    # There is deliberately NO indefinite grant. A duration outside the five
    # whitelisted windows is refused by `DecisionInput` before the decision path
    # opens, so it can never reach the mint and become a never-expiring horizon —
    # the request stays pending and no grant is left behind.
    test "a duration outside the five windows is refused before anything is decided",
         %{subject: subject, key: key, request: request} do
      assert {:error, changeset} =
               Approvals.approve_request(request, subject, nil, duration: :forever)

      assert "is invalid" in errors_on(changeset).duration
      assert Fixtures.Approvals.grants_for_api_key(key.id) == []
      assert %Request{status: :pending} = Repo.reload!(request)
    end
  end

  describe "approve_request — signed-dispatch freshness gate (option b)" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner)

      # The runner enforces signing with a 1h freshness window.
      {:ok, runner} =
        Emisar.Runners.apply_state(runner, %{
          "enforce_signatures" => true,
          "max_attestation_age_seconds" => 3600
        })

      requester = Fixtures.Users.create_user()
      approver = Fixtures.Users.create_user()

      requester_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "operator"
        )

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
        requester_membership: requester_membership,
        approver_subject: approver_subject
      }
    end

    test "approving a run whose signature aged out while parked is refused up front", %{
      account: account,
      runner: runner,
      requester: requester,
      requester_membership: requester_membership,
      approver_subject: approver_subject
    } do
      # Parked with a signature already 2h old — it would be refused at dispatch.
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      %{attestation: attestation} =
        Fixtures.Runs.signed_attestation(
          issued_at: stale,
          pack_ref: Fixtures.Catalog.default_pack_ref()
        )

      run =
        Fixtures.Runs.create_signed_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          requested_by_id: requester.id,
          initiating_membership_id: requester_membership.id,
          args: %{},
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
          status: :pending_approval,
          attestation: attestation
        })

      {:ok, request} = Approvals.create_request(run, requester.id, "please")

      # Refused before finalizing, so there's no approved-but-dead run; the
      # request stays pending for a re-issued (freshly-signed) request.
      assert Approvals.approve_request(request, approver_subject, "go") ==
               {:error, :attestation_stale}

      assert %Request{status: :pending} = Repo.reload!(request)
    end

    test "approving a run with a still-fresh signature proceeds normally", %{
      account: account,
      runner: runner,
      requester: requester,
      requester_membership: requester_membership,
      approver_subject: approver_subject
    } do
      fresh = DateTime.to_iso8601(DateTime.utc_now())
      valid_until = DateTime.add(DateTime.utc_now(), 3_600, :second)

      %{attestation: attestation} =
        Fixtures.Runs.signed_attestation(
          issued_at: fresh,
          valid_until: valid_until,
          pack_ref: Fixtures.Catalog.default_pack_ref()
        )

      run =
        Fixtures.Runs.create_signed_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          requested_by_id: requester.id,
          initiating_membership_id: requester_membership.id,
          args: %{},
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
          status: :pending_approval,
          attestation: attestation
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
      assert Approvals.approve_request(request, operator, "again") == {:error, :already_decided}

      assert approved_count(request.id) == 1
      assert %Request{status: :pending} = Repo.reload!(request)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end
  end

  describe "override_request/3" do
    test "an admin releases below quorum with one distinct audit receipt and no extra vote" do
      %{
        account: account,
        request: request,
        run: run,
        requester_subject: requester_subject
      } = gated_request(min_approvals: 3, requester_role: :operator)

      first = distinct_operator(account)

      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, first, "reviewed")

      _pre_override_emails = notified_emails()

      admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.membership_subject(admin_membership)

      assert {:ok, {%Request{status: :approved} = overridden, %ActionRun{status: :sent}}} =
               Approvals.override_request(
                 request,
                 "Production recovery cannot wait",
                 admin_subject
               )

      assert overridden.decided_by_id == admin.id
      assert overridden.decision_reason == "Production recovery cannot wait"
      assert approved_count(request.id) == 1
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      assert %ActionRun{status: :sent} = Repo.reload!(run)

      {:ok, events, _metadata} = Audit.list_events(admin_subject, page: [limit: 50])
      override_events = Enum.filter(events, &(&1.event_type == "approval.overridden"))

      assert [event] = override_events
      assert event.target_id == request.id
      assert event.payload["reason"] == "Production recovery cannot wait"
      assert event.payload["approved_count"] == 1
      assert event.payload["min_approvals"] == 3
      assert event.payload["remaining_approvals_waived"] == 2
      refute event.payload["self_approval_waived"]
      refute Enum.any?(events, &(&1.event_type == "approval.approved"))

      emails = notified_emails()

      assert Enum.any?(emails, fn email ->
               Enum.map(email.to, &elem(&1, 1)) == [requester_subject.actor.email] &&
                 email.subject == "Approved using an override · linux.uptime" &&
                 email.text_body =~ "approved using an override after 1 of 3 approvals"
             end)
    end

    test "an owner may override after voting, including a no-self-approval request" do
      %{request: request, requester_subject: owner} =
        gated_request(
          min_approvals: 2,
          allow_self_approval: false,
          requester_role: :owner
        )

      assert Approvals.approve_request(request, owner, "ordinary vote") ==
               {:error, :self_approval_forbidden}

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.override_request(request, "I accept the break-glass risk", owner)

      assert approved_count(request.id) == 0

      {:ok, events, _metadata} = Audit.list_events(owner, page: [limit: 50])
      event = Enum.find(events, &(&1.event_type == "approval.overridden"))
      assert event.payload["self_approval_waived"]
      assert event.payload["approved_count"] == 0
    end

    test "an owner who already cast an ordinary vote can still waive the remaining vote" do
      %{account: account, request: request} = gated_request(min_approvals: 2)
      owner = distinct_operator(account)

      assert {:ok, {%Request{status: :pending}, :pending}} =
               Approvals.approve_request(request, owner, "first review")

      assert {:ok, {%Request{status: :approved}, %ActionRun{status: :sent}}} =
               Approvals.override_request(request, "No second reviewer is available", owner)

      assert approved_count(request.id) == 1
    end

    test "operators and viewers cannot override" do
      %{account: account, request: request} = gated_request(min_approvals: 2)

      for role <- [:operator, :viewer] do
        user = Fixtures.Users.create_user()

        membership =
          Fixtures.Memberships.create_membership(
            account_id: account.id,
            user_id: user.id,
            role: Atom.to_string(role)
          )

        subject = Fixtures.Subjects.membership_subject(membership)

        assert Approvals.override_request(request, "crafted override", subject) ==
                 {:error, :unauthorized}
      end

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
    end

    test "a subject cannot borrow another user's privileged membership" do
      account = Fixtures.Accounts.create_account()
      owner = distinct_member(account, :owner)

      request =
        Fixtures.Approvals.create_execution_request(account, owner.actor,
          executable?: false,
          min_approvals: 2
        )

      attacker = Fixtures.Users.create_user()
      forged = %{owner | actor: attacker}

      assert Approvals.override_request(request, "forged owner", forged) ==
               {:error, :unauthorized}

      assert %Request{status: :pending} = Repo.reload!(request)

      assert %Runbooks.RunbookExecution{status: :pending_approval} =
               Repo.get!(Runbooks.RunbookExecution, request.runbook_execution_id)
    end

    test "a stale demoted owner cannot trigger invalid-execution cleanup" do
      account = Fixtures.Accounts.create_account()
      owner = distinct_member(account, :owner)

      request =
        Fixtures.Approvals.create_execution_request(account, owner.actor,
          executable?: false,
          min_approvals: 2
        )

      membership = Fixtures.Memberships.fetch_membership(account.id, owner.actor.id)

      Fixtures.Memberships.force_role(membership, "operator")

      assert Approvals.subject_can_override_approval?(owner)

      assert Approvals.override_request(request, "stale session", owner) ==
               {:error, :unauthorized}

      assert %Request{status: :pending} = Repo.reload!(request)

      assert %Runbooks.RunbookExecution{status: :pending_approval} =
               Repo.get!(Runbooks.RunbookExecution, request.runbook_execution_id)
    end

    test "current runner access is rechecked from the locked membership" do
      %{account: account, request: request} = gated_request(min_approvals: 2)
      owner = distinct_member(account, :owner)
      membership = Fixtures.Memberships.fetch_membership(account.id, owner.actor.id)

      Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())

      assert Approvals.override_request(request, "scope was revoked", owner) ==
               {:error, :not_found}

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
    end

    test "an owner in another account cannot discover or override the request" do
      %{request: request} = gated_request(min_approvals: 2)
      other_account = Fixtures.Accounts.create_account()
      other_owner = distinct_operator(other_account)

      assert Approvals.override_request(request, "wrong account", other_owner) ==
               {:error, :not_found}

      assert %Request{status: :pending} = Repo.reload!(request)
    end

    test "a required override reason is trimmed and bounded before any write" do
      %{account: account, request: request} = gated_request(min_approvals: 2)
      owner = distinct_operator(account)

      assert Approvals.override_request(request, nil, owner) ==
               {:error, :override_reason_required}

      assert Approvals.override_request(request, "   ", owner) ==
               {:error, :override_reason_required}

      too_long = String.duplicate("x", Approvals.max_decision_reason_length() + 1)

      assert Approvals.override_request(request, too_long, owner) ==
               {:error, :decision_reason_too_long}

      assert Approvals.override_request(request, "urgent \u202Essap-yssalg", owner) ==
               {:error, :decision_reason_unsafe_text}

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
    end

    test "a cancelled request cannot be resurrected by an override" do
      %{account: account, request: request} = gated_request(min_approvals: 2)
      owner = distinct_member(account, :owner)

      Fixtures.Approvals.cancel_request(request)

      assert Approvals.override_request(request, "resurrect cancelled work", owner) ==
               {:error, :run_cancelled}

      assert %Request{status: :cancelled} = Repo.reload!(request)
      assert approved_count(request.id) == 0
    end

    test "a stale signed dispatch cannot be released by an override" do
      %{request: request, owner: owner} = stale_signed_gated_request()

      assert Approvals.override_request(request, "signature is stale", owner) ==
               {:error, :attestation_stale}

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
    end

    test "a suspended initiating membership still blocks release" do
      %{account: account, run: run, request: request} = gated_request(min_approvals: 2)
      owner = distinct_member(account, :owner)
      initiator = Fixtures.Memberships.fetch_membership(account.id, run.requested_by_id)

      Fixtures.Memberships.suspend_membership(initiator)

      assert Approvals.override_request(request, "initiator lost access", owner) ==
               {:error, :initiator_no_longer_authorized}

      assert %Request{status: :pending} = Repo.reload!(request)
      assert approved_count(request.id) == 0
    end

    test "override preserves expiry and trusted-action checks" do
      %{account: account, request: expired_request} = gated_request(min_approvals: 2)
      owner = distinct_operator(account)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Fixtures.Approvals.set_request_expiry(expired_request, past)

      assert Approvals.override_request(expired_request, "too late", owner) ==
               {:error, :expired}

      %{account: trust_account, runner: runner, request: untrusted_request} =
        gated_request(min_approvals: 2)

      trust_owner = distinct_operator(trust_account)
      Fixtures.Catalog.delete_actions_for_runner(runner.id)

      assert Approvals.override_request(untrusted_request, "contract vanished", trust_owner) ==
               {:error, :action_not_found}

      assert %Request{status: :pending} = Repo.reload!(untrusted_request)
    end

    test "an execution override advances the same frozen runbook approval path" do
      account = Fixtures.Accounts.create_account()
      owner = distinct_member(account, :owner)

      request =
        Fixtures.Approvals.create_execution_request(account, owner.actor,
          executable?: true,
          min_approvals: 2
        )

      assert {:ok, {%Request{status: :approved}, :runbook_execution}} =
               Approvals.override_request(request, "Restore the database now", owner)

      execution = Repo.get!(Runbooks.RunbookExecution, request.runbook_execution_id)
      assert execution.status == :active
      assert [_run | _] = Runs.list_runs_for_runbook_execution(account.id, execution.id)
    end
  end

  describe "approve_request — self-approval gate" do
    # The requester is also an owner (so they CAN decide) on an operator-sourced
    # parked run. Each test files its own request with the self-approval posture
    # under test.
    setup do
      requester = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      requester_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(requester, account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          requested_by_id: requester.id,
          initiating_membership_id: requester_membership.id,
          args: %{},
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
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

      assert Approvals.approve_request(request, subject, "approving my own") ==
               {:error, :self_approval_forbidden}

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
      Fixtures.Catalog.create_action(runner: runner)
      Emisar.Runners.subscribe_runner_transport(runner)

      initiator = Fixtures.Users.create_user()

      initiating_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: initiator.id,
          role: "operator"
        )

      # Operator-source run (no api_key) so effective_requester keeps the nil.
      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          requested_by_id: initiator.id,
          initiating_membership_id: initiating_membership.id,
          args: %{},
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
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
      Fixtures.Catalog.create_action(runner: runner)
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
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
          status: :pending_approval
        })

      # MCP-triggered: requested_by_id is nil. The request must record the
      # api-key OWNER as the effective requester.
      {:ok, request} =
        Approvals.create_request(run, nil, "x", min_approvals: 1, allow_self_approval: false)

      assert request.requested_by_id == owner.id

      # The owner (the human behind the key) cannot launder a self-approval
      # through their own key.
      assert Approvals.approve_request(request, owner_subject, "self via my key") ==
               {:error, :self_approval_forbidden}

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
          "packs" => %{
            "custom" => %{"version" => "1.0", "hash" => Fixtures.Catalog.pack_hash("DRIFT")}
          },
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

      assert Approvals.approve_request(request, operator, "ok") == {:error, :pack_untrusted}

      # The run never reached the runner, and the request is left pending to retry.
      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert %Request{status: :pending} = Repo.reload!(request)
    end

    # A packless run has no snapshotted hash, but approve still has to bind the
    # decision to a CURRENT trusted contract. Once the runner stops advertising
    # the action there is none, so the approve fails closed — a later action
    # minted under the same id is not the artifact the operator reviewed.
    test "approving a packless run whose advertised action disappeared fails closed" do
      %{account: account, runner: runner, run: run, request: request} = gated_request()
      Fixtures.Catalog.delete_actions_for_runner(runner.id)
      operator = distinct_operator(account)

      assert Approvals.approve_request(request, operator, "ok") == {:error, :action_not_found}

      # Nothing shipped and the request is still decidable.
      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert %Request{status: :pending} = Repo.reload!(request)

      # Deny needs no contract, so the stale request stays retractable.
      assert {:ok, {%Request{status: :denied}, %ActionRun{status: :cancelled}}} =
               Approvals.deny_request(request, operator, "stale, re-issue it")

      assert %ActionRun{status: :cancelled} = Repo.reload!(run)
    end

    test "an in-flight request keeps its snapshotted threshold when the policy later changes" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner)
      Emisar.Runners.subscribe_runner_transport(runner)

      initiator = Fixtures.Users.create_user()

      initiating_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: initiator.id,
          role: "operator"
        )

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          requested_by_id: initiator.id,
          initiating_membership_id: initiating_membership.id,
          args: %{},
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
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
      Fixtures.Catalog.create_action(runner: runner)
      Emisar.Runners.subscribe_runner_transport(runner)

      # The requester is also an owner, so they CAN decide — self-approval is the
      # thing under test, not the permission.
      requester = Fixtures.Users.create_user()

      requester_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "owner"
        )

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          requested_by_id: requester.id,
          initiating_membership_id: requester_membership.id,
          args: %{},
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
          status: :pending_approval
        })

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

    test "emails the requester that it was denied", %{run: run, subject: subject} do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")
      _created = notified_emails()

      assert {:ok, {%Request{status: :denied}, _run}} =
               Approvals.deny_request(request, subject, "not now")

      emails = notified_emails()

      assert [email] =
               Enum.filter(emails, fn email ->
                 Enum.map(email.to, &elem(&1, 1)) == [subject.actor.email]
               end)

      assert email.subject == "Approval denied · linux.uptime"
      assert email.text_body =~ "was denied by Test User with 0 of 1"
      assert email.text_body =~ "not now"

      assert Enum.any?(
               emails,
               &(&1.headers["In-Reply-To"] &&
                   &1.text_body =~ "approval request was denied by")
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

    test "a note at the maximum length records the denial and cancels the run", %{
      run: run,
      subject: subject
    } do
      {:ok, request} = Approvals.create_request(run, subject.actor.id, "needs approve")
      at_limit = String.duplicate("a", Approvals.max_decision_reason_length())

      assert {:ok, {%Request{status: :denied} = decided, cancelled_run}} =
               Approvals.deny_request(request, subject, at_limit)

      assert decided.decision_reason == at_limit
      assert cancelled_run.status == :cancelled
      assert String.starts_with?(cancelled_run.reason_text, "approval denied: aaa")
      assert String.ends_with?(cancelled_run.reason_text, "…")
      # `action_runs.reason_text` is varchar(255) and its changeset counts CODE
      # POINTS, so the excerpt is measured in the same unit the column is.
      assert length(String.to_charlist(cancelled_run.reason_text)) == 255
    end

    test "a note at the maximum length halts a runbook execution" do
      {requester, account, subject} = Fixtures.Subjects.owner_subject()
      request = Fixtures.Approvals.create_execution_request(account, requester)
      at_limit = String.duplicate("a", Approvals.max_decision_reason_length())

      assert {:ok, {%Request{status: :denied} = decided, :runbook_execution}} =
               Approvals.deny_request(request, subject, at_limit)

      assert decided.decision_reason == at_limit

      execution =
        Runbooks.RunbookExecution.Query.by_id(request.runbook_execution_id) |> Repo.one()

      assert execution.status == :halted
      assert String.ends_with?(execution.terminal_message, "…")
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

      assert Approvals.deny_request(request, viewer_subject, "no rights") ==
               {:error, :unauthorized}
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

      assert Approvals.deny_request(req_a, subject_b, "wrong account") == {:error, :not_found}
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
          "packs" => %{
            "custom" => %{"version" => "1.0", "hash" => Fixtures.Catalog.pack_hash("DRIFT")}
          },
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
      assert Approvals.approve_request(request, c, "let me in") == {:error, :already_decided}

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
      %{account: account, runner: runner, run: run, request: request} = gated_request()
      %{account: account, runner: runner, run: run, request: request}
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

    # Cancellation resolves no action contract, so a run the approve gate now
    # refuses (:action_not_found) is still cleanable — it can never be stranded.
    test "cancelling still works once the run's advertised action is gone", %{
      account: account,
      runner: runner,
      run: run,
      request: request
    } do
      Fixtures.Catalog.delete_actions_for_runner(runner.id)
      owner = operator_subject(account)

      assert {:ok, %ActionRun{status: :cancelled}} = Runs.cancel_run(run, owner, "stale request")

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
      assert Approvals.approve_request(request, approver, "too late") == {:error, :run_cancelled}

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

  describe "lock_pending_requests_for_runs/2" do
    test "locks only the pending requests for the selected runs in stable order" do
      %{run: run, request: request} = gated_request()

      assert {:ok, [locked]} = Approvals.lock_pending_requests_for_runs(Repo, [run.id])
      assert locked.id == request.id
      assert locked.status == :pending
      assert Approvals.lock_pending_requests_for_runs(Repo, []) == {:ok, []}
    end
  end

  describe "cancel_locked_requests/3" do
    test "cancels the exact rows already locked by the parent transaction" do
      %{run: run, request: request} = gated_request()
      assert {:ok, locked} = Approvals.lock_pending_requests_for_runs(Repo, [run.id])

      assert {:ok, [cancelled]} =
               Approvals.cancel_locked_requests(Repo, locked, "parent execution halted")

      assert cancelled.id == request.id
      assert cancelled.status == :cancelled
      assert Repo.reload!(request).status == :cancelled
    end
  end

  describe "broadcast_cancelled_requests/1" do
    test "broadcasts every cancelled request returned by the transaction helper" do
      %{account: account, request: request} = gated_request()
      assert Approvals.subscribe_account_approvals(account.id) == :ok

      assert Approvals.broadcast_cancelled_requests([request]) == :ok
      assert_receive {:approval_updated, request_id}
      assert request_id == request.id
    end
  end

  describe "broadcast_request_cancelled/1" do
    test "broadcasts the request on the account approvals feed for a {:cancelled, request} tuple" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

      :ok = Approvals.subscribe_account_approvals(account.id)

      assert Approvals.broadcast_request_cancelled({:cancelled, request}) == :ok

      assert_receive {:approval_updated, id}
      assert id == request.id
    end

    test "is a no-op for the :none result (no request was cancelled)" do
      {account, _run} = run_fixture()
      :ok = Approvals.subscribe_account_approvals(account.id)

      assert Approvals.broadcast_request_cancelled(:none) == :ok

      refute_receive {:approval_updated, _}, 100
    end
  end

  describe "subscribe_account_approvals/1" do
    test "the subscriber receives the account's approval-feed broadcasts" do
      {account, run} = run_fixture()
      {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
      subject = operator_subject(account)

      assert Approvals.subscribe_account_approvals(account.id) == :ok

      # A decision publishes on the topic the subscriber just joined.
      assert {:ok, _} = Approvals.deny_request(request, subject, "no")
      assert_receive {:approval_updated, id}
      assert id == request.id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      {account_a, _run_a} = run_fixture()
      {account_b, run_b} = run_fixture()
      {:ok, request_b} = Approvals.create_request(run_b, Fixtures.Users.create_user().id, "x")
      subject_b = operator_subject(account_b)

      assert Approvals.subscribe_account_approvals(account_a.id) == :ok

      # The decision happens on B's topic — A's subscriber must hear nothing.
      assert {:ok, _} = Approvals.deny_request(request_b, subject_b, "no")
      refute_receive {:approval_updated, _}, 100
    end

    test "a restricted same-account subscriber gets only an id it cannot dereference" do
      account = Fixtures.Accounts.create_account()
      database_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      {_, web_run} = run_fixture(account: account, runner: web_runner)
      {:ok, request} = Approvals.create_request(web_run, Fixtures.Users.create_user().id, "x")
      {:ok, database_access} = Accounts.RunnerAccess.restricted(["database"], [])

      restricted_subject =
        account
        |> operator_subject()
        |> subject_with_runner_access(database_access)

      assert Approvals.subscribe_account_approvals(account.id) == :ok
      assert {:ok, _} = Approvals.deny_request(request, operator_subject(account), "no")
      assert_receive {:approval_updated, request_id}
      assert request_id == request.id

      assert Approvals.fetch_approval_request_by_id(request_id, restricted_subject) ==
               {:error, :not_found}

      refute database_runner.id == web_runner.id
    end
  end

  describe "subscribe_request/2" do
    test "the exact request subscriber receives the full request only for that account and id" do
      {account, watched_run} = run_fixture()
      {_account, other_run} = run_fixture(account: account)

      {:ok, watched} =
        Approvals.create_request(watched_run, Fixtures.Users.create_user().id, "watched")

      {:ok, other} =
        Approvals.create_request(other_run, Fixtures.Users.create_user().id, "other")

      subject = operator_subject(account)
      assert Approvals.subscribe_request(account.id, watched.id) == :ok

      assert {:ok, _} = Approvals.deny_request(other, subject, "no")
      refute_receive {:approval_request_updated, _}, 100

      assert {:ok, _} = Approvals.deny_request(watched, subject, "no")

      assert_receive {:approval_request_updated, %Request{id: watched_id, status: :denied}}

      assert watched_id == watched.id
    end

    test "the exact request topic is account-qualified" do
      {account_a, run_a} = run_fixture()
      {account_b, _run_b} = run_fixture()
      {:ok, request_a} = Approvals.create_request(run_a, Fixtures.Users.create_user().id, "x")

      assert Approvals.subscribe_request(account_b.id, request_a.id) == :ok
      assert {:ok, _} = Approvals.deny_request(request_a, operator_subject(account_a), "no")
      refute_receive {:approval_request_updated, _}, 100
    end
  end

  describe "peek_matching_grant/6" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      %{account: account, user: user}
    end

    test "returns nil when no grant exists", %{account: account, user: user} do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Approvals.peek_matching_grant(
               account.id,
               key.id,
               "x.y",
               @grant_pack_ref,
               runner.id,
               "sha"
             ) == nil
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
                 @grant_pack_ref,
                 runner_a.id,
                 "sha-a"
               )

      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key.id,
                 "linux.uptime",
                 @grant_pack_ref,
                 runner_b.id,
                 "sha-b"
               )
    end

    test "does not reuse approval across pack contracts", %{account: account, user: user} do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      _ = insert_grant(account, key, action_id: "linux.uptime", granted_by_id: user.id)

      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key.id,
                 "linux.uptime",
                 @grant_pack_ref,
                 runner.id,
                 "sha"
               )

      assert Approvals.peek_matching_grant(
               account.id,
               key.id,
               "linux.uptime",
               "linux-core@1.0.1/sha256:changed-contract",
               runner.id,
               "sha"
             ) == nil
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

      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key.id,
                 "x",
                 @grant_pack_ref,
                 runner_a.id,
                 "any"
               )

      assert Approvals.peek_matching_grant(
               account.id,
               key.id,
               "x",
               @grant_pack_ref,
               runner_b.id,
               "any"
             ) == nil
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

      assert Approvals.peek_matching_grant(
               account.id,
               key.id,
               "x",
               @grant_pack_ref,
               runner.id,
               "sha"
             ) == nil
    end

    test "revoked grant is filtered out", %{account: account, user: user} do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      subject = Fixtures.Subjects.membership_subject(membership)

      grant = insert_grant(account, key, action_id: "x", granted_by_id: user.id)
      {:ok, _} = Approvals.revoke_grant(grant, subject)

      assert Approvals.peek_matching_grant(
               account.id,
               key.id,
               "x",
               @grant_pack_ref,
               nil,
               "sha"
             ) == nil
    end

    test "a different API key's grant doesn't leak", %{account: account, user: user} do
      {_, key_a} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      {_, key_b} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      _ = insert_grant(account, key_a, action_id: "x", granted_by_id: user.id)

      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key_a.id,
                 "x",
                 @grant_pack_ref,
                 nil,
                 "sha"
               )

      assert Approvals.peek_matching_grant(
               account.id,
               key_b.id,
               "x",
               @grant_pack_ref,
               nil,
               "sha"
             ) == nil
    end

    test "cap 0 (standing grants disabled) makes a live matching grant inert", %{
      account: account,
      user: user
    } do
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      _ = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      # The grant matches while grants are enabled…
      assert %Grant{} =
               Approvals.peek_matching_grant(
                 account.id,
                 key.id,
                 "x",
                 @grant_pack_ref,
                 nil,
                 "sha"
               )

      # …and stops matching the moment the account flips the kill switch —
      # no revocation required.
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 0)

      assert Approvals.peek_matching_grant(
               account.id,
               key.id,
               "x",
               @grant_pack_ref,
               nil,
               "sha"
             ) == nil
    end
  end

  describe "consume_grant_in_multi/3" do
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
      observe_trusted_grant_action(account, user, runner, "high")
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
        pack_ref: @grant_pack_ref,
        api_key_id: key.id
      }

      %{subject: mcp_subject, attrs: attrs, grant: grant}
    end

    test "a grant-matched dispatch consumes exactly one use and runs" do
      %{subject: subject, attrs: attrs, grant: grant} = grant_dispatch_setup(max_uses: 2)

      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)

      assert run.policy_reason ==
               "The account policy requires approval for high-risk actions by default. " <>
                 "A standing grant satisfied that requirement."

      assert Repo.reload!(grant).uses_count == 1
    end

    test "a run that fails validation does NOT burn a grant use" do
      %{subject: subject, attrs: attrs, grant: grant} = grant_dispatch_setup(max_uses: 1)
      huge = %{"blob" => String.duplicate("x", 300_000)}

      # The run insert fails inside the Multi, so the composed grant consume
      # rolls back with it — no use is burned without a durable run.
      assert {:error, changeset} = Runs.dispatch_run(Map.put(attrs, :args, huge), subject)
      assert "is too large (max 32768 bytes)" in errors_on(changeset).args_raw
      assert Repo.reload!(grant).uses_count == 0
    end

    test "a grant matched before the kill switch landed can no longer be consumed" do
      %{subject: subject, grant: grant} = grant_dispatch_setup([])

      # Dispatch peeked this grant while the account was uncapped…
      assert %Grant{} =
               Approvals.peek_matching_grant(
                 subject.account.id,
                 grant.api_key_id,
                 grant.action_id,
                 grant.pack_ref,
                 nil,
                 "sha"
               )

      # …and the kill switch commits before the run's transaction consumes it.
      # The cap recheck under the account row lock is what stops the use.
      Fixtures.Accounts.set_max_grant_lifetime_seconds(subject.account, 0)
      multi = Approvals.consume_grant_in_multi(Multi.new(), :run, grant)

      assert {:error, :grant_use, :grant_unusable, _changes} = Repo.transaction(multi)
      assert Repo.reload!(grant).uses_count == 0
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
      observe_trusted_grant_action(account, user, runner, "high")

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
        pack_ref: @grant_pack_ref,
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

      assert run2.policy_reason ==
               "The account policy requires approval for high-risk actions by default. " <>
                 "A standing grant satisfied that requirement."

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
          pack_ref: @grant_pack_ref,
          args: %{},
          api_key_id: key.id,
          status: :pending_approval
        })

      {:ok, request} = Approvals.create_request(run, operator.id, "x")
      %{account: account, run: run, request: request, operator: operator}
    end

    test "refuses a windowed duration beyond the account cap (the IL-15 server gate)",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 86_400)

      assert Approvals.create_grant(request, run, operator.id, %{duration: :ninety_days}) ==
               {:error, :grant_exceeds_account_max_lifetime}

      assert Approvals.create_grant(request, run, operator.id, %{duration: :thirty_days}) ==
               {:error, :grant_exceeds_account_max_lifetime}
    end

    test "allows a duration within the cap",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 86_400)

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :one_day})

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :one_hour})
    end

    test "exempts :once (single-use, not a standing grant) even under a tight cap",
         %{account: account, run: run, request: request, operator: operator} do
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 60)

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
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 0)

      assert Approvals.create_grant(request, run, operator.id, %{duration: :one_hour}) ==
               {:error, :grant_exceeds_account_max_lifetime}

      assert {:ok, %Grant{}} =
               Approvals.create_grant(request, run, operator.id, %{duration: :once})
    end
  end

  describe "max_decision_reason_length/0" do
    test "is the bound the decision path and the textarea both use" do
      assert Approvals.max_decision_reason_length() == 2000
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
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 86_400)

      assert Approvals.allowed_grant_durations(account.id) == [:once, :one_hour, :one_day]

      # Cap 0 = standing grants disabled — only single-use remains.
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 0)
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

      assert Approvals.revoke_grant(grant, operator_subject) == {:error, :unauthorized}
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

      assert Approvals.revoke_grant(g_a, subject_b) == {:error, :not_found}
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
    test "revokes every active grant in the account, each with its audit row" do
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

      expired =
        insert_grant(account, key,
          action_id: "a.expired",
          granted_by_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      # Cross-account isolation: B's grant survives A's sweep.
      account_b = Fixtures.Accounts.create_account()
      user_b = Fixtures.Users.create_user()

      {_, key_b} =
        Fixtures.ApiKeys.create_api_key(account_id: account_b.id, created_by_id: user_b.id)

      grant_b = insert_grant(account_b, key_b, action_id: "b.one", granted_by_id: user_b.id)

      assert Approvals.revoke_all_grants(subject) == {:ok, 2}

      assert Grant.Query.not_revoked() |> Grant.Query.by_account_id(account.id) |> Repo.all() ==
               [expired]

      refute Repo.reload!(expired).revoked_at
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

  describe "revoke_grants_granted_by_membership/2" do
    test "revokes exactly the approver's own live grants, each with an audit row" do
      account = Fixtures.Accounts.create_account()
      approver = Fixtures.Users.create_user()

      approver_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: approver.id,
          role: "admin"
        )

      other_approver = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: other_approver.id,
        role: "admin"
      )

      # The grants ride ANOTHER member's key — that is the whole exposure:
      # revoking the approver's own credentials never reaches them.
      requester = Fixtures.Users.create_user()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: requester.id)

      mine = insert_grant(account, key, action_id: "a.one", granted_by_id: approver.id)
      theirs = insert_grant(account, key, action_id: "a.two", granted_by_id: other_approver.id)

      expired =
        insert_grant(account, key,
          action_id: "a.expired",
          granted_by_id: approver.id,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      assert {:ok, %{revoked: 1}} =
               Repo.commit_multi(
                 Multi.run(Multi.new(), :revoked, fn repo, _changes ->
                   Approvals.revoke_grants_granted_by_membership(repo, approver_membership)
                 end)
               )

      assert Repo.reload!(mine).revoked_at
      refute Repo.reload!(theirs).revoked_at
      refute Repo.reload!(expired).revoked_at

      event =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_account_id(account.id)
        |> Audit.Event.Query.by_event_type("approval.grant_revoked")
        |> Repo.one()

      assert event.actor_kind == "system"
      assert event.target_id == mine.id
      assert event.payload["granted_by_id"] == approver.id
    end

    test "a membership in another account revokes nothing" do
      account = Fixtures.Accounts.create_account()
      approver = Fixtures.Users.create_user()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: approver.id)

      grant = insert_grant(account, key, action_id: "a.one", granted_by_id: approver.id)

      # Same person, a membership somewhere else: `granted_by_id` alone is not
      # the match — the account is half of it.
      other_account = Fixtures.Accounts.create_account()

      elsewhere =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: approver.id,
          role: "admin"
        )

      assert {:ok, %{revoked: 0}} =
               Repo.commit_multi(
                 Multi.run(Multi.new(), :revoked, fn repo, _changes ->
                   Approvals.revoke_grants_granted_by_membership(repo, elsewhere)
                 end)
               )

      refute Repo.reload!(grant).revoked_at
    end
  end

  describe "change_grant_lifetime_settings/1" do
    test "no attrs means no cap at all" do
      changeset = Approvals.change_grant_lifetime_settings()

      assert changeset.valid?
      assert changeset.changes == %{}
      assert {:ok, input} = Ecto.Changeset.apply_action(changeset, :insert)
      assert input.seconds == nil
    end

    test "casts the guardrail form's string cap" do
      changeset = Approvals.change_grant_lifetime_settings(%{"seconds" => "86400"})

      assert changeset.valid?
      assert changeset.changes == %{seconds: 86_400}
    end

    test "a blank cap removes the cap" do
      changeset = Approvals.change_grant_lifetime_settings(%{"seconds" => ""})

      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "zero is valid — it is the kill switch, not a missing value" do
      changeset = Approvals.change_grant_lifetime_settings(%{"seconds" => "0"})

      assert changeset.valid?
      assert changeset.changes == %{seconds: 0}
    end

    test "a malformed cap is a field error" do
      changeset = Approvals.change_grant_lifetime_settings(%{"seconds" => "forever"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).seconds
    end

    test "a negative cap is a field error" do
      changeset = Approvals.change_grant_lifetime_settings(seconds: -1)

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).seconds
    end
  end

  describe "update_grant_lifetime_settings/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {_secret, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      %{account: account, user: user, subject: subject, key: key}
    end

    # The cap bounds how long a standing approval grant stays usable, so who may
    # move it is a security decision. An operator holds decide_approval and
    # view_approvals but not manage_grants.
    test "an operator cannot move the cap", %{account: account} do
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Approvals.update_grant_lifetime_settings(
               account,
               %{"seconds" => "86400"},
               operator_subject
             ) == {:error, :unauthorized}

      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.max_grant_lifetime_seconds == nil
    end

    test "an owner of another account cannot move this account's cap", %{account: account} do
      other_account = Fixtures.Accounts.create_account()
      other_user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: other_user.id,
        role: "owner"
      )

      other_subject = Fixtures.Subjects.subject_for(other_user, other_account, role: :owner)

      assert Approvals.update_grant_lifetime_settings(
               account,
               %{"seconds" => "86400"},
               other_subject
             ) == {:error, :not_found}

      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.max_grant_lifetime_seconds == nil
    end

    test "an owner caps the lifetime with the raw form value", %{
      account: account,
      subject: subject
    } do
      assert {:ok, %{account: updated, revoked_count: 0}} =
               Approvals.update_grant_lifetime_settings(account, %{"seconds" => "86400"}, subject)

      assert updated.settings.max_grant_lifetime_seconds == 86_400
      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.max_grant_lifetime_seconds == 86_400

      {:ok, events, _} = Audit.list_events(subject)
      assert [audit] = Enum.filter(events, &(&1.event_type == "account.max_grant_lifetime_set"))
      assert audit.target_id == account.id
    end

    test "a blank cap removes it and leaves standing grants alone", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 3_600)
      grant = insert_grant(account, key, action_id: "a.one", granted_by_id: user.id)

      assert {:ok, %{account: updated, revoked_count: 0}} =
               Approvals.update_grant_lifetime_settings(account, %{"seconds" => ""}, subject)

      assert updated.settings.max_grant_lifetime_seconds == nil
      refute Repo.reload!(grant).revoked_at
    end

    test "0 disables standing grants and revokes every one with its own audit row", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      insert_grant(account, key, action_id: "a.one", granted_by_id: user.id)
      insert_grant(account, key, action_id: "a.two", granted_by_id: user.id)

      assert {:ok, %{account: updated, revoked_count: 2}} =
               Approvals.update_grant_lifetime_settings(account, %{"seconds" => "0"}, subject)

      assert updated.settings.max_grant_lifetime_seconds == 0

      unrevoked =
        Grant.Query.not_revoked() |> Grant.Query.by_account_id(account.id) |> Repo.all()

      assert unrevoked == []

      {:ok, events, _} = Audit.list_events(subject)
      revoked = Enum.filter(events, &(&1.event_type == "approval.grant_revoked"))
      assert length(revoked) == 2
      assert Enum.any?(events, &(&1.event_type == "account.max_grant_lifetime_set"))
    end

    test "0 revokes grants beyond the manager's own runner access", %{
      account: account,
      user: user,
      subject: subject,
      key: key
    } do
      db_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      db_grant = insert_grant(account, key, runner_id: db_runner.id, granted_by_id: user.id)
      web_grant = insert_grant(account, key, runner_id: web_runner.id, granted_by_id: user.id)
      wildcard = insert_grant(account, key, runner_id: nil, granted_by_id: user.id)
      {:ok, database_access} = Accounts.RunnerAccess.restricted(["database"], [])
      restricted_subject = subject_with_runner_access(subject, database_access)

      assert {:ok, %{revoked_count: 3}} =
               Approvals.update_grant_lifetime_settings(
                 account,
                 %{"seconds" => "0"},
                 restricted_subject
               )

      assert Repo.reload!(db_grant).revoked_at
      assert Repo.reload!(web_grant).revoked_at
      assert Repo.reload!(wildcard).revoked_at

      {:ok, events, _} = Audit.list_events(subject)
      revoked = Enum.filter(events, &(&1.event_type == "approval.grant_revoked"))
      assert length(revoked) == 3
    end

    test "a malformed cap is a field error and writes nothing", %{
      account: account,
      subject: subject
    } do
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 3_600)

      assert {:error, changeset} =
               Approvals.update_grant_lifetime_settings(
                 account,
                 %{"seconds" => "forever"},
                 subject
               )

      assert "is invalid" in errors_on(changeset).seconds
      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.max_grant_lifetime_seconds == 3_600
    end

    test "a negative cap is a field error and writes nothing", %{
      account: account,
      subject: subject
    } do
      assert {:error, changeset} =
               Approvals.update_grant_lifetime_settings(account, %{"seconds" => "-1"}, subject)

      assert "must be greater than or equal to 0" in errors_on(changeset).seconds
      refute Repo.reload!(account).settings.max_grant_lifetime_seconds
    end

    test "an operator (no manage_grants) is refused and nothing is written", %{account: account} do
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Approvals.update_grant_lifetime_settings(
               account,
               %{"seconds" => "0"},
               operator_subject
             ) == {:error, :unauthorized}

      refute Repo.reload!(account).settings.max_grant_lifetime_seconds

      refute Enum.any?(
               Repo.all(Audit.Event),
               &(&1.event_type in ["account.max_grant_lifetime_set", "approval.grant_revoked"])
             )
    end

    test "another account's owner gets :not_found and cannot disable this account's grants", %{
      account: account,
      user: user,
      key: key
    } do
      grant = insert_grant(account, key, action_id: "a.one", granted_by_id: user.id)
      other_account = Fixtures.Accounts.create_account()
      other_user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: other_user.id,
        role: "owner"
      )

      other_subject = Fixtures.Subjects.subject_for(other_user, other_account, role: :owner)

      assert Approvals.update_grant_lifetime_settings(account, %{"seconds" => "0"}, other_subject) ==
               {:error, :not_found}

      refute Repo.reload!(account).settings.max_grant_lifetime_seconds
      refute Repo.reload!(grant).revoked_at
    end
  end

  describe "list_grants_for_account/2" do
    test "an operator (no manage_grants) is refused with :unauthorized" do
      {_user, account, _owner} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert Approvals.list_grants_for_account(operator) == {:error, :unauthorized}
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

    test "restricted managers see and revoke only grants within runner and pack access" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      {_, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)
      db_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")

      postgres_ref = "postgres@1.0.0/sha256:" <> String.duplicate("b", 64)

      db_grant =
        insert_grant(account, key,
          runner_id: db_runner.id,
          pack_ref: postgres_ref,
          granted_by_id: user.id
        )

      denied_pack =
        insert_grant(account, key,
          runner_id: db_runner.id,
          pack_ref: @grant_pack_ref,
          granted_by_id: user.id
        )

      web_grant =
        insert_grant(account, key,
          runner_id: web_runner.id,
          pack_ref: postgres_ref,
          granted_by_id: user.id
        )

      wildcard = insert_grant(account, key, runner_id: nil, granted_by_id: user.id)

      {:ok, database_access} =
        Accounts.RunnerAccess.new(:restricted, ["database"], [], :restricted, ["postgres"])

      subject =
        account
        |> operator_subject()
        |> subject_with_runner_access(database_access)

      assert {:ok, [%Grant{id: id}], _meta} = Approvals.list_grants_for_account(subject)
      assert id == db_grant.id
      assert Approvals.fetch_grant_by_id(denied_pack.id, subject) == {:error, :not_found}
      assert Approvals.fetch_grant_by_id(web_grant.id, subject) == {:error, :not_found}
      assert Approvals.revoke_grant(web_grant, subject) == {:error, :not_found}

      assert Approvals.revoke_all_grants(subject) === {:ok, 1}
      assert Repo.reload!(db_grant).revoked_at
      refute Repo.reload!(denied_pack).revoked_at
      refute Repo.reload!(web_grant).revoked_at
      refute Repo.reload!(wildcard).revoked_at
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
          pack_ref: @grant_pack_ref,
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
      assert Approvals.fetch_grant_by_id(grant.id, other_subject) == {:error, :not_found}

      # A malformed id is :not_found, never a crash.
      assert Approvals.fetch_grant_by_id("not-a-uuid", subject) == {:error, :not_found}
    end

    test "an operator (no manage_grants) is refused with :unauthorized", %{
      account: account,
      grant: grant
    } do
      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert Approvals.fetch_grant_by_id(grant.id, operator) == {:error, :unauthorized}
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

  describe "subject_can_override_approval?/1" do
    test "owner and admin may override; operator and viewer may not" do
      account = Fixtures.Accounts.create_account()

      subjects =
        for role <- [:owner, :admin, :operator, :viewer], into: %{} do
          user = Fixtures.Users.create_user()

          membership =
            Fixtures.Memberships.create_membership(
              account_id: account.id,
              user_id: user.id,
              role: Atom.to_string(role)
            )

          {role, Fixtures.Subjects.membership_subject(membership)}
        end

      assert Approvals.subject_can_override_approval?(subjects.owner)
      assert Approvals.subject_can_override_approval?(subjects.admin)
      refute Approvals.subject_can_override_approval?(subjects.operator)
      refute Approvals.subject_can_override_approval?(subjects.viewer)
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
      subject = operator_subject(account)
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
