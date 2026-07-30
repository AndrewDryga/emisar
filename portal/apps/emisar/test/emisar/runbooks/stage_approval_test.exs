defmodule Emisar.Runbooks.StageApprovalTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Approvals, Catalog, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Runbooks.RunbookExecution

  @hash "sha256:" <> String.duplicate("c", 64)

  defp notified_recipients(acc \\ []) do
    receive do
      {:email, email} ->
        recipients = Enum.map(email.to, fn {_name, address} -> address end)
        notified_recipients(recipients ++ acc)
    after
      0 -> acc
    end
  end

  setup do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    approver = approver_subject(account)
    runner = trusted_runner(account, subject)
    Runners.subscribe_runner_transport(runner)

    %{account: account, approver: approver, runner: runner, subject: subject}
  end

  test "a required stage creates one frozen approval before dispatch", %{
    account: account,
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "approve maintenance", subject)
    assert Runs.list_runs_for_runbook_execution(account.id, result.execution_id) == []
    assert approver.actor.email in notified_recipients()

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert is_nil(request.run_id)
    assert is_binary(request.runbook_execution_stage_id)
    assert request.context["kind"] == "runbook_stage"

    assert get_in(request.context, ["stage", "items", Access.at(0), "pack_ref"]) ==
             "linux-core@1.4.2/#{@hash}"

    assert {:ok, {_approved, :runbook_stage}} =
             Approvals.approve_request(request, approver, "change window confirmed")

    assert [run] = Runs.list_runs_for_runbook_execution(account.id, result.execution_id)
    assert run.runbook_step_id == "inspect"
    assert run.expected_pack_hash == @hash
    assert run.policy_decision == "require_approval"
    assert run.policy_reason =~ "satisfied by approved runbook stage"
    refute run.requires_approval

    assert {:ok, [], _metadata} =
             Approvals.list_pending_approval_requests(approver)
  end

  test "a denied stage halts without creating an action run", %{
    account: account,
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "deny maintenance", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert {:ok, {_denied, :runbook_stage}} =
             Approvals.deny_request(request, approver, "outside the change window")

    execution = execution(result.execution_id)
    assert execution.status == :halted
    assert execution.terminal_code == "approval_denied"
    assert Runs.list_runs_for_runbook_execution(account.id, result.execution_id) == []
  end

  test "a fresh policy denial still wins after the stage was approved", %{
    account: account,
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))
    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "policy moved", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    _policy =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        rules: %{
          "schema_version" => 2,
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "deny",
            "critical" => "deny"
          },
          "overrides" => [],
          "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
        }
      )

    assert {:ok, {_approved, :runbook_stage}} =
             Approvals.approve_request(request, approver, "reviewed before policy change")

    assert [run] = Runs.list_runs_for_runbook_execution(account.id, result.execution_id)
    assert run.status == :denied
    assert run.policy_decision == "deny"

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "denied_by_policy"
  end

  test "cancelling while awaiting approval closes the request atomically", %{
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "cancel approval", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert {:ok, execution} = Runbooks.cancel_execution(result.execution_id, subject)
    assert execution.status == :cancelled
    assert Repo.reload!(request).status == :cancelled

    assert Approvals.approve_request(request, approver, "stale approval") ==
             {:error, :runbook_stage_not_approvable}
  end

  test "restricted approvers must retain scope to every frozen stage runner", %{
    account: account,
    approver: approver,
    runner: first,
    subject: subject
  } do
    second = trusted_runner(account, subject, group: first.group)
    runbook = published_runbook(subject, required_definition(first.group))

    {:ok, one_runner} = RunnerAccess.restricted([], [first.id])
    approver_membership = Fixtures.Memberships.fetch_membership(account.id, approver.actor.id)
    _membership = Fixtures.Memberships.force_runner_access(approver_membership, one_runner)

    assert {:ok, _result} = Runbooks.dispatch_runbook(runbook, "scope approval", subject)
    refute approver.actor.email in notified_recipients()

    assert {:ok, [], _metadata} = Approvals.list_pending_approval_requests(approver)

    {:ok, both_runners} = RunnerAccess.restricted([], [first.id, second.id])
    _membership = Fixtures.Memberships.force_runner_access(approver_membership, both_runners)

    assert {:ok, [_request], _metadata} =
             Approvals.list_pending_approval_requests(approver)
  end

  test "cross-account approvers cannot see or decide a stage request", %{
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))
    assert {:ok, _result} = Runbooks.dispatch_runbook(runbook, "tenant boundary", subject)

    {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

    assert {:ok, [], _metadata} =
             Approvals.list_pending_approval_requests(other_subject)
  end

  test "an expired stage request halts without dispatch and cannot be decided", %{
    account: account,
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "expired window", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    now = DateTime.utc_now()

    request
    |> Ecto.Changeset.change(expires_at: DateTime.add(now, -1, :second))
    |> Repo.update!()

    assert Approvals.expire_overdue_requests(now) == 1
    expired = Repo.reload!(request)
    assert expired.status == :expired

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "approval_expired"
    assert Runs.list_runs_for_runbook_execution(account.id, result.execution_id) == []

    assert Approvals.approve_request(expired, approver, "too late") == {:error, :expired}
  end

  test "membership loss at decision halts and closes the pending request", %{
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))

    assert {:ok, result} =
             Runbooks.dispatch_runbook(runbook, "membership decision recheck", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    membership =
      Fixtures.Memberships.fetch_membership(subject.account.id, subject.actor.id)

    _suspended = Fixtures.Memberships.suspend_membership(membership)

    assert Approvals.approve_request(request, approver, "still approve") ==
             {:error, :runbook_stage_not_approvable}

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "authorization_lost"
    assert Repo.reload!(request).status == :cancelled
  end

  defp approver_subject(account) do
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "admin"
      )

    Fixtures.Subjects.membership_subject(membership)
  end

  defp trusted_runner(account, subject, opts \\ []) do
    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        group: Keyword.get(opts, :group, "database")
      )

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => "1.4.2", "hash" => @hash}},
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => "high",
                   "summary" => "Reports uptime",
                   "description" => "Reports uptime",
                   "side_effects" => [],
                   "args" => [],
                   "examples" => [],
                   "search_terms" => [],
                   "output_schema" => nil
                 }
               ]
             })

    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    runner
  end

  defp published_runbook(subject, definition) do
    title = "approval-#{System.unique_integer([:positive])}"

    assert {:ok, runbook} =
             Runbooks.create_runbook(
               %{"title" => title, "slug" => title, "definition" => definition},
               subject
             )

    assert {:ok, published} = Runbooks.publish(runbook, subject)
    published
  end

  defp required_definition(group) do
    %{
      "schema_version" => 1,
      "context_markdown" => "Confirm the maintenance window.",
      "inputs" => [],
      "stages" => [
        %{
          "id" => "change",
          "title" => "Apply change",
          "mode" => "parallel",
          "max_parallel" => 2,
          "approval" => "required",
          "steps" => [
            %{
              "id" => "inspect",
              "pack" => %{"id" => "linux-core", "requirement" => "~> 1.4.0"},
              "action" => "linux.uptime",
              "targets" => %{"kind" => "group", "refs" => [group]},
              "args" => %{},
              "outputs" => [],
              "success" => [],
              "wait" => nil
            }
          ]
        }
      ]
    }
  end

  defp execution(id),
    do: RunbookExecution.Query.by_id(id) |> Repo.fetch!(RunbookExecution.Query)
end
