defmodule Emisar.Runbooks.ExecutionApprovalTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Approvals, Catalog, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Approvals.Request
  alias Emisar.Runbooks.{ExecutionItem, RunbookExecution, Scheduler}
  alias Emisar.Runners.Presence

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

  test "one frozen execution approval covers every stage before dispatch", %{
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
    assert request.runbook_execution_id == result.execution_id
    assert request.context["kind"] == "runbook_execution"
    assert request.context["execution_kind"] == "published"
    assert request.context["runbook"]["id"] == runbook.id
    assert request.context["runbook"]["title"] == runbook.title

    assert get_in(request.context, [
             "plan",
             "stages",
             Access.at(0),
             "items",
             Access.at(0),
             "pack_ref"
           ]) ==
             "linux-core@1.4.2/#{@hash}"

    assert {:ok, {_approved, :runbook_execution}} =
             Approvals.approve_request(request, approver, "change window confirmed")

    assert [run] = Runs.list_runs_for_runbook_execution(account.id, result.execution_id)
    assert run.runbook_step_id == "inspect"
    assert run.expected_pack_hash == @hash
    assert run.policy_decision == "require_approval"

    assert run.policy_reason ==
             "The account policy requires approval for high-risk actions by default. " <>
               "An approved runbook execution satisfied that requirement."

    refute run.requires_approval

    assert {:ok, [], _metadata} =
             Approvals.list_pending_approval_requests(approver)
  end

  test "an approved execution retries a wait without opening another request", %{
    account: account,
    approver: approver,
    runner: runner,
    subject: subject
  } do
    _policy =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        rules: %{
          "schema_version" => 2,
          "defaults" => %{
            "low" => "require_approval",
            "medium" => "require_approval",
            "high" => "require_approval",
            "critical" => "deny"
          },
          "overrides" => [],
          "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
        }
      )

    definition = waiting_definition(runner.group)
    runbook = published_runbook(subject, definition)

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "wait after approval", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert {:ok, {_approved, :runbook_execution}} =
             Approvals.approve_request(request, approver, "observe until ready")

    assert [first_attempt] =
             Runs.list_runs_for_runbook_execution(account.id, result.execution_id)

    assert {:ok, _first_attempt} =
             Fixtures.Runs.finish(first_attempt, %{
               "status" => "success",
               "structured_output" => %{"ready" => false}
             })

    ExecutionItem.Query.by_execution_id(result.execution_id)
    |> Repo.one!()
    |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert Scheduler.advance_execution(result.execution_id) == :ok

    assert [_first, second_attempt] =
             Runs.list_runs_for_runbook_execution(account.id, result.execution_id)

    assert second_attempt.attempt_number == 2

    request_count =
      Request.Query.all()
      |> Request.Query.by_runbook_execution_id(result.execution_id)
      |> Repo.aggregate(:count)

    assert request_count == 1
    assert {:ok, [], _metadata} = Approvals.list_pending_approval_requests(approver)
  end

  test "a denied execution halts without creating an action run", %{
    account: account,
    approver: approver,
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "deny maintenance", subject)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert {:ok, {_denied, :runbook_execution}} =
             Approvals.deny_request(request, approver, "outside the change window")

    execution = execution(result.execution_id)
    assert execution.status == :halted
    assert execution.terminal_code == "approval_denied"
    assert Runs.list_runs_for_runbook_execution(account.id, result.execution_id) == []
  end

  test "a fresh policy denial vetoes approval", %{
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

    assert Approvals.approve_request(request, approver, "reviewed before policy change") ==
             {:error, :runbook_execution_not_approvable}

    assert Runs.list_runs_for_runbook_execution(account.id, result.execution_id) == []
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
             {:error, :run_cancelled}
  end

  test "restricted approvers must retain scope to every frozen execution runner", %{
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

  test "cross-account approvers cannot see an execution request", %{
    runner: runner,
    subject: subject
  } do
    runbook = published_runbook(subject, required_definition(runner.group))
    assert {:ok, _result} = Runbooks.dispatch_runbook(runbook, "tenant boundary", subject)

    {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

    assert {:ok, [], _metadata} =
             Approvals.list_pending_approval_requests(other_subject)
  end

  test "an expired execution request halts without dispatch and cannot be decided", %{
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
             {:error, :runbook_execution_not_approvable}

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "authorization_lost"
    assert Repo.reload!(request).status == :cancelled
  end

  test "one-runner group selection stays frozen when the chosen runner disconnects", %{
    account: account,
    approver: approver,
    runner: first,
    subject: subject
  } do
    second = trusted_runner(account, subject, group: first.group)
    Runners.subscribe_runner_transport(second)

    definition =
      first.group
      |> required_definition()
      |> put_in(
        ["stages", Access.at(0), "steps", Access.at(0), "targets", "selection"],
        "random_one"
      )

    runbook = published_runbook(subject, definition)

    assert {:ok, result} =
             Runbooks.dispatch_runbook(runbook, "freeze one runner", subject,
               target_selection_seed: "approval-offline-test"
             )

    item = ExecutionItem.Query.by_execution_id(result.execution_id) |> Repo.one!()
    other_id = if item.runner_id == first.id, do: second.id, else: first.id

    assert Runners.online?(account.id, item.runner_id)
    assert Runners.online?(account.id, other_id)

    assert Presence.untrack(self(), Presence.topic(account.id), item.runner_id) == :ok
    refute Runners.online?(account.id, item.runner_id)
    assert Runners.online?(account.id, other_id)

    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert Approvals.approve_request(request, approver, "chosen runner reviewed") ==
             {:error, :runbook_execution_not_approvable}

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "approval_preflight_failed"
    assert Runs.list_runs_for_runbook_execution(account.id, result.execution_id) == []
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
                 },
                 %{
                   "id" => "linux.health",
                   "pack_id" => "linux-core",
                   "title" => "Health",
                   "kind" => "exec",
                   "risk" => "low",
                   "summary" => "Reports health",
                   "description" => "Reports health",
                   "side_effects" => [],
                   "args" => [],
                   "examples" => [],
                   "search_terms" => [],
                   "output_schema" => %{
                     "type" => "object",
                     "properties" => %{"ready" => %{"type" => "boolean"}},
                     "required" => ["ready"],
                     "additionalProperties" => false
                   }
                 }
               ]
             })

    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

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
               %{"title" => title, "slug" => title, "draft_definition" => definition},
               subject
             )

    Fixtures.Runbooks.publish_runbook(runbook)
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
          "steps" => [
            %{
              "id" => "inspect",
              "pack" => %{"id" => "linux-core"},
              "action" => "linux.uptime",
              "targets" => %{"selection" => "all", "refs" => ["group:" <> group]},
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

  defp waiting_definition(group) do
    required_definition(group)
    |> put_in(
      ["stages", Access.at(0), "steps", Access.at(0), "action"],
      "linux.health"
    )
    |> put_in(
      ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
      [
        %{
          "id" => "ready",
          "source" => "structured_output",
          "sensitive" => false,
          "extract" => %{"type" => "json_pointer", "expression" => "/ready"}
        }
      ]
    )
    |> put_in(
      ["stages", Access.at(0), "steps", Access.at(0), "success"],
      [%{"output" => "ready", "operator" => "equals", "value" => true}]
    )
    |> put_in(
      ["stages", Access.at(0), "steps", Access.at(0), "wait"],
      %{"interval_seconds" => 5, "timeout_seconds" => 20, "max_attempts" => 3}
    )
  end

  defp execution(id),
    do: RunbookExecution.Query.by_id(id) |> Repo.fetch!(RunbookExecution.Query)
end
