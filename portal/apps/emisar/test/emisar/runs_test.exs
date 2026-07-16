defmodule Emisar.RunsTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Approvals, Catalog, MCPOperations, Repo, RequestContext, Runners, Runs}
  alias Emisar.Fixtures
  alias Emisar.Runners.Presence
  alias Emisar.Runs.{ActionRun, RunEvent}

  defp base_attrs(account_id, runner_id, attrs \\ %{}) do
    Map.merge(
      %{
        runner_id: runner_id,
        action_id: "linux.uptime",
        args: %{},
        reason: "test",
        source: "operator",
        account_id: account_id
      },
      attrs
    )
  end

  defp no_permissions_subject(account) do
    Fixtures.Subjects.build_subject(account: account, role: :runner)
  end

  defp reconnect_runner(runner) do
    assert {:ok, _} =
             Runners.mark_disconnected(
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               "test reconnect"
             )

    :ok = Presence.untrack(self(), Presence.topic(runner.account_id), runner.id)
    assert {:ok, successor} = Runners.connect_runner(runner)
    successor
  end

  defp deny_all_rules do
    %{
      "schema_version" => 2,
      "defaults" => %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"},
      "overrides" => [],
      "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
    }
  end

  @mcp_pack_hash "sha256:" <> String.duplicate("a", 64)
  @mcp_pack_ref "linux-core@1.0.0/" <> @mcp_pack_hash

  describe "list_runs/2" do
    test "pages the subject's account only (cross-account isolation)" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, [listed], _meta} = Runs.list_runs(subject)
      assert listed.id == run.id

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:ok, [], _meta} = Runs.list_runs(subject_b)
    end

    test "preloads the runner on each row for the list template" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, preload: [:runner])
      assert listed.runner.id == runner.id
    end

    test "a viewer can list runs (view_runs is enough for a read)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:ok, [_run], _meta} = Runs.list_runs(viewer_subject)
    end

    test "a subject without view_runs permission is refused" do
      account = Fixtures.Accounts.create_account()
      subject = no_permissions_subject(account)

      assert {:error, :unauthorized} = Runs.list_runs(subject)
    end

    test "the runner_id filter scopes the feed to one runner" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, on_a} = Runs.create_run(base_attrs(account.id, runner_a.id))
      {:ok, _on_b} = Runs.create_run(base_attrs(account.id, runner_b.id))

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, filter: [runner_id: runner_a.id])
      assert listed.id == on_a.id
    end

    test "the api_key_id (Agent) filter scopes the feed to one key's runs" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      {:ok, agent_run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{source: "mcp", api_key_id: key.id}))

      {:ok, _operator_run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, filter: [api_key_id: key.id])
      assert listed.id == agent_run.id
    end

    test "the requested_by_id (Operator) and runbook_id (Runbook) filters scope the feed" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      runbook = Fixtures.Runbooks.create_runbook(account_id: account.id)

      {:ok, my_run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: user.id}))

      {:ok, runbook_run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{source: "runbook", runbook_id: runbook.id})
        )

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, filter: [requested_by_id: user.id])
      assert listed.id == my_run.id

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, filter: [runbook_id: runbook.id])
      assert listed.id == runbook_run.id
    end
  end

  describe "list_runs_by_operation/3" do
    test "returns only the credential's operation rows in target creation order" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      operation_id = "op_724NN9NMDZ1T76NARWCKM5A0D6"

      {:ok, first} =
        Runs.create_run(
          base_attrs(account.id, runner_a.id, %{
            source: "mcp",
            api_key_id: key.id,
            operation_id: operation_id
          })
        )

      {:ok, second} =
        Runs.create_run(
          base_attrs(account.id, runner_b.id, %{
            source: "mcp",
            api_key_id: key.id,
            operation_id: operation_id
          })
        )

      assert {:ok, runs} = Runs.list_runs_by_operation(operation_id, key.id, subject)
      assert Enum.map(runs, & &1.id) == [first.id, second.id]
      assert Enum.all?(runs, &Ecto.assoc_loaded?(&1.runner))
    end

    test "applies permission and cross-account boundaries" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      operation_id = "op_624NN9NMDZ1T76NARWCKM5A0D6"

      {:ok, run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            source: "mcp",
            api_key_id: key.id,
            operation_id: operation_id
          })
        )

      assert {:ok, [listed]} = Runs.list_runs_by_operation(operation_id, key.id, subject)
      assert listed.id == run.id

      {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      assert {:ok, []} = Runs.list_runs_by_operation(operation_id, key.id, other_subject)

      assert {:error, :unauthorized} =
               Runs.list_runs_by_operation(operation_id, key.id, no_permissions_subject(account))
    end
  end

  describe "list_runs_by_runbook_execution/2" do
    test "returns only the subject's execution rows with runners preloaded" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      execution_id = Ecto.UUID.generate()

      {:ok, run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{runbook_execution_id: execution_id}))

      assert {:ok, [listed]} = Runs.list_runs_by_runbook_execution(execution_id, subject)
      assert listed.id == run.id
      assert Ecto.assoc_loaded?(listed.runner)

      {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      assert {:ok, []} = Runs.list_runs_by_runbook_execution(execution_id, other_subject)

      assert {:error, :unauthorized} =
               Runs.list_runs_by_runbook_execution(
                 execution_id,
                 no_permissions_subject(account)
               )
    end
  end

  describe "list_run_operator_options/1" do
    test "returns the distinct dispatching operators, deduplicated" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: user.id}))
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: user.id}))
      # A run with no requesting user (an engine path) contributes no option.
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.list_run_operator_options(subject) == {:ok, [{user.id, user.full_name}]}
    end

    test "a subject without view_runs permission is refused" do
      account = Fixtures.Accounts.create_account()
      subject = no_permissions_subject(account)

      assert {:error, :unauthorized} = Runs.list_run_operator_options(subject)
    end

    test "cross-account — B's options never include A's operators" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: user.id}))

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Runs.list_run_operator_options(subject_b) == {:ok, []}
      assert {:ok, [_]} = Runs.list_run_operator_options(subject)
    end
  end

  describe "list_run_runbook_options/1" do
    test "returns the distinct runbooks that dispatched runs; cross-account isolated" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      runbook = Fixtures.Runbooks.create_runbook(account_id: account.id, title: "Failover")

      base = %{source: "runbook", runbook_id: runbook.id}
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, base))
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, base))
      # An operator run contributes no runbook option.
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.list_run_runbook_options(subject) == {:ok, [{runbook.id, "Failover"}]}

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Runs.list_run_runbook_options(subject_b) == {:ok, []}
    end

    test "a subject without view_runs permission is refused" do
      account = Fixtures.Accounts.create_account()
      subject = no_permissions_subject(account)

      assert {:error, :unauthorized} = Runs.list_run_runbook_options(subject)
    end
  end

  describe "list_recent_runs/2" do
    test "narrows by runner_id and action_id (composable)" do
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      {:ok, _} =
        Runs.create_run(base_attrs(account.id, runner_a.id, %{action_id: "linux.uptime"}))

      {:ok, _} =
        Runs.create_run(base_attrs(account.id, runner_a.id, %{action_id: "linux.disk_usage"}))

      {:ok, _} =
        Runs.create_run(base_attrs(account.id, runner_b.id, %{action_id: "linux.uptime"}))

      {:ok, by_runner, _} = Runs.list_recent_runs(subject, runner_id: runner_a.id)
      assert length(by_runner) == 2
      assert Enum.all?(by_runner, &(&1.runner_id == runner_a.id))

      {:ok, by_action, _} = Runs.list_recent_runs(subject, action_id: "linux.uptime")
      assert length(by_action) == 2
      assert Enum.all?(by_action, &(&1.action_id == "linux.uptime"))

      {:ok, both, _} =
        Runs.list_recent_runs(subject, runner_id: runner_a.id, action_id: "linux.uptime")

      assert length(both) == 1
    end

    test "applies the :runner and :api_key preloads" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, [run], _meta} =
               Runs.list_recent_runs(subject, preload: [:runner, :api_key], limit: 8)

      assert run.runner.id == runner.id
    end

    test "scope: :own returns only this API key's runs" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      {:ok, mine} =
        Runs.create_run(base_attrs(account.id, runner.id, %{source: "mcp", api_key_id: key.id}))

      {:ok, _operator_run} = Runs.create_run(base_attrs(account.id, runner.id))

      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, runs, _meta} = Runs.list_recent_runs(subject, scope: :own, limit: 50)
      assert Enum.map(runs, & &1.id) == [mine.id]
    end

    test "scope: :account returns every agent's runs in the account" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      {:ok, mine} =
        Runs.create_run(base_attrs(account.id, runner.id, %{source: "mcp", api_key_id: key.id}))

      {:ok, operator_run} = Runs.create_run(base_attrs(account.id, runner.id))

      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, runs, _meta} = Runs.list_recent_runs(subject, scope: :account, limit: 50)
      assert MapSet.new(runs, & &1.id) == MapSet.new([mine.id, operator_run.id])
    end

    test "a second account's key sees none of the first account's runs (cross-account)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {:ok, _mine} = Runs.create_run(base_attrs(account.id, runner.id, %{api_key_id: key.id}))

      other_account = Fixtures.Accounts.create_account()
      {_raw, other_key} = Fixtures.ApiKeys.create_api_key(account_id: other_account.id)
      subject = Emisar.Auth.Subject.for_api_key(other_key, other_account)

      # Even scope: :account is bounded by for_subject to the caller's account,
      # and this account has no runs — the first account's key.id leaks nothing.
      assert {:ok, [], _meta} = Runs.list_recent_runs(subject, scope: :account, limit: 50)
      assert {:ok, [], _meta} = Runs.list_recent_runs(subject, scope: :own, limit: 50)
      refute other_key.id == key.id
    end
  end

  describe "list_recent_mcp_runs/3" do
    test "returns only fixed-contract runs in the key lineage and current runner scope" do
      %{
        subject: subject,
        owner_subject: owner_subject,
        membership: membership,
        runners: [runner],
        key: key
      } = mcp_fanout_fixture(["low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      operation = mcp_operation_attrs("op_134NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)
      assert {:ok, [run]} = Runs.dispatch_mcp_fanout(operation, [target], subject)

      {:ok, _operator_run} =
        Runs.create_run(base_attrs(subject.account.id, runner.id, %{source: "operator"}))

      assert {:ok, [listed], metadata} =
               Runs.list_recent_mcp_runs(%{scope: :own}, subject, limit: 15)

      assert listed.id == run.id
      assert metadata.count == nil

      assert {:ok, :ok} =
               Emisar.Runners.replace_runner_scopes(
                 membership,
                 [{"group", "not-this-runner"}],
                 owner_subject
               )

      assert {:ok, [], _metadata} =
               Runs.list_recent_mcp_runs(%{scope: :own}, subject, limit: 15)
    end

    test "rejects subjects without run-view permission" do
      account = Fixtures.Accounts.create_account()

      assert {:error, :unauthorized} =
               Runs.list_recent_mcp_runs(
                 %{scope: :account},
                 no_permissions_subject(account),
                 limit: 15
               )
    end
  end

  describe "fetch_run_stats/2" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "rolls up totals by status", %{account: account, runner: runner, subject: subject} do
      for status <- ~w[success success failed pending] do
        {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{status: status}))
      end

      assert {:ok, stats} = Runs.fetch_run_stats(subject)
      assert stats.total == 4
      assert stats.success == 2
      assert stats.failed == 1
      assert stats.success_rate == 67
    end

    test "classifies every outcome, not just failed/error/timed_out", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      # refused + validation_failed are genuine failures (were excluded before);
      # denied + cancelled are their own buckets; running is in-flight.
      for status <- ~w[success refused validation_failed denied cancelled running] do
        {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{status: status}))
      end

      assert {:ok, stats} = Runs.fetch_run_stats(subject)
      assert stats.total == 6
      assert stats.success == 1
      assert stats.failed == 2
      assert stats.denied == 1
      assert stats.cancelled == 1
      assert stats.in_progress == 1
      # 1 success out of 3 results (success + failed); denied/cancelled/running
      # are excluded from the denominator.
      assert stats.success_rate == 33
    end

    test "counts only the subject's own account (cross-account isolation)", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{status: "success"}))

      # A second account with its own runs must not leak into the headline.
      other_account = Fixtures.Accounts.create_account()
      other_runner = Fixtures.Runners.create_runner(account_id: other_account.id)

      {:ok, _} =
        Runs.create_run(base_attrs(other_account.id, other_runner.id, %{status: "failed"}))

      assert {:ok, %{total: 1, success: 1}} = Runs.fetch_run_stats(subject)
    end

    test "success_rate is nil before any run has a result" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{status: "running"}))

      assert {:ok, %{total: 1, success_rate: nil}} = Runs.fetch_run_stats(subject)
    end

    test "a subject without view_runs permission is refused", %{account: account} do
      subject = no_permissions_subject(account)

      assert {:error, :unauthorized} = Runs.fetch_run_stats(subject)
    end
  end

  describe "report_run_stats/3" do
    test "tallies outcomes for runs inside the [from, to) window only" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      from = ~U[2026-06-01 00:00:00.000000Z]
      to = ~U[2026-07-01 00:00:00.000000Z]
      in_window = ~U[2026-06-15 12:00:00.000000Z]

      for status <- [:success, :success, :failed, :denied] do
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          status: status,
          inserted_at: in_window
        )
      end

      # Just before the window and exactly at the exclusive upper bound — both out.
      Fixtures.Runs.create_run(
        account_id: account.id,
        status: :success,
        inserted_at: ~U[2026-05-31 23:59:59.000000Z]
      )

      Fixtures.Runs.create_run(account_id: account.id, status: :success, inserted_at: to)

      stats = Runs.report_run_stats(account.id, from, to)
      assert stats.total == 4
      assert stats.success == 2
      assert stats.failed == 1
      assert stats.denied == 1
      # All four in-window runs used the one runner.
      assert stats.distinct_runners == 1
    end

    test "excludes another account's runs (cross-account isolation)" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      from = ~U[2026-06-01 00:00:00.000000Z]
      to = ~U[2026-07-01 00:00:00.000000Z]
      at = ~U[2026-06-15 12:00:00.000000Z]

      Fixtures.Runs.create_run(account_id: account.id, status: :success, inserted_at: at)
      Fixtures.Runs.create_run(account_id: other_account.id, status: :failed, inserted_at: at)

      assert %{total: 1, success: 1, failed: 0} = Runs.report_run_stats(account.id, from, to)
    end
  end

  describe "list_recent_runs_for_runner/3" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "scopes to the runner and the subject's account", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      other_runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, mine} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _theirs} = Runs.create_run(base_attrs(account.id, other_runner.id))

      assert {:ok, [only], _} = Runs.list_recent_runs_for_runner(runner.id, subject)
      assert only.id == mine.id

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:ok, [], _} = Runs.list_recent_runs_for_runner(runner.id, subject_b)
    end

    test "a viewer can read a runner's recent runs (view_runs gates it)", %{
      account: account,
      runner: runner
    } do
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id))

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:ok, [_run], _} = Runs.list_recent_runs_for_runner(runner.id, viewer_subject)
    end
  end

  describe "fetch_run_by_id/3" do
    test "scopes to the subject's account and survives a bad id" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, fetched} = Runs.fetch_run_by_id(run.id, subject)
      assert fetched.id == run.id

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Runs.fetch_run_by_id(run.id, subject_b)
      assert {:error, :not_found} = Runs.fetch_run_by_id("not-a-uuid", subject)
    end

    test "honors the :preload option for the run-detail render" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{runner: %Emisar.Runners.Runner{}}} =
               Runs.fetch_run_by_id(run.id, subject, preload: [:runner])
    end

    test "rejects a subject without view_runs permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.fetch_run_by_id(run.id, no_permissions_subject(account)) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_mcp_run_by_id/2" do
    test "returns the exact fixed-contract run and fails closed outside account or scope" do
      %{
        subject: subject,
        owner_subject: owner_subject,
        membership: membership,
        runners: [runner],
        key: key
      } = mcp_fanout_fixture(["low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      operation = mcp_operation_attrs("op_234NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)
      assert {:ok, [run]} = Runs.dispatch_mcp_fanout(operation, [target], subject)

      assert {:ok, fetched} = Runs.fetch_mcp_run_by_id(run.id, subject)
      assert fetched.id == run.id
      assert fetched.args_raw == "{}"
      assert fetched.pack_ref == @mcp_pack_ref
      assert is_binary(fetched.runner_ref)

      {_user, _account, foreign_subject} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Runs.fetch_mcp_run_by_id(run.id, foreign_subject)

      assert {:ok, :ok} =
               Emisar.Runners.replace_runner_scopes(
                 membership,
                 [{"group", "not-this-runner"}],
                 owner_subject
               )

      assert {:error, :not_found} = Runs.fetch_mcp_run_by_id(run.id, subject)
      assert {:error, :not_found} = Runs.fetch_mcp_run_by_id("not-a-uuid", subject)
    end
  end

  describe "fetch_run_by_request_id_for_runner/2" do
    test "never crosses runners" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      other_runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, found} = Runs.fetch_run_by_request_id_for_runner(run.request_id, runner.id)
      assert found.id == run.id

      # Another runner in the SAME account must not see it — the runner
      # socket may only touch runs dispatched to that runner.
      assert {:error, :not_found} =
               Runs.fetch_run_by_request_id_for_runner(run.request_id, other_runner.id)
    end

    test "an unknown request_id is :not_found" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:error, :not_found} =
               Runs.fetch_run_by_request_id_for_runner("req_nope", runner.id)
    end
  end

  describe "create_run/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "auto-assigns request_id + queued_at", %{account: account, runner: runner} do
      assert {:ok, %ActionRun{} = run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert String.starts_with?(run.request_id, "req_")
      assert %DateTime{} = run.queued_at
    end

    test "rejects oversized args (a hostile MCP client can't write a multi-MB row)", %{
      account: account,
      runner: runner
    } do
      huge = %{"blob" => String.duplicate("x", 300_000)}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runs.create_run(base_attrs(account.id, runner.id, %{args: huge}))

      assert Keyword.has_key?(changeset.errors, :args_raw)
    end

    test "broadcasts the new run on the account topic (fresh insert only)", %{
      account: account,
      runner: runner
    } do
      Emisar.Runs.subscribe_account_runs(account.id)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert_receive {:run_updated, %ActionRun{id: id}}, 500
      assert id == run.id
    end
  end

  describe "dispatch_run/2" do
    test "allow policy returns {:ok, :running, run} and delivers to runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert run.account_id == account.id

      # Cloud-to-runner envelope was delivered.
      assert_receive {:cloud_to_runner, _generation,
                      %{"type" => "run_action", "action_id" => "linux.uptime"}},
                     500
    end

    test "a viewer (view-only) is refused — dispatch executes infra, so it gates on :dispatch" do
      # A viewer holds only `view_runs_permission`; dispatching is the
      # most dangerous write in the system (it runs real infra), so the
      # permission gate must reject before any runner/policy lookup.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "an MCP key dispatches normally — its reach is the minter's scope + Policy" do
      # The key carries no per-key scope: an unscoped minter (empty UserRunnerScope
      # = every runner) + a permissive policy means the api-key subject dispatches.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, :running, %ActionRun{}} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "an MCP subject cannot attribute a dispatch to another API key" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {_raw, authentic_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {_raw, forged_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      subject = Emisar.Auth.Subject.for_api_key(authentic_key, account)

      attrs = base_attrs(account.id, runner.id, %{source: "mcp", api_key_id: forged_key.id})

      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)
      assert run.api_key_id == authentic_key.id
    end

    test "audits only the policy decision + terminal outcome, decision first" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      types =
        events |> Enum.filter(&(&1.payload["run_id"] == run.id)) |> Enum.map(& &1.event_type)

      # The terminal outcome ONLY — none of the intermediate lifecycle noise
      # (pending/sent/running) and NO policy.evaluated row: the audit-logging diet
      # (#1) dropped it because the allow decision + matched rules already live on
      # the ActionRun itself.
      assert Enum.sort(types) == ["action_run.success"]
      refute "action_run.pending" in types
      refute "action_run.sent" in types
      refute "action_run.running" in types
      refute "policy.evaluated" in types

      # The allow decision survives on the run row (where the diet relies on it).
      assert run.policy_decision == "allow"
    end

    test "stamps the dispatcher's ip/ua on the run and its terminal audit event (no runner bleed)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()

      # An api_key/LLM dispatch from a host: the dispatcher's request context.
      context = %RequestContext{ip_address: "203.0.113.7", user_agent: "Codex-CLI/1.0"}
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner, context: context)

      {:ok, :running, run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # Snapshotted on the run at create time.
      assert run.ip_address == "203.0.113.7"
      assert run.user_agent == "Codex-CLI/1.0"

      # The terminal transition is written from the runner-socket path (no inbound
      # request there) — it must still attribute the DISPATCHER's ip, never the
      # runner's connection (the regression guard for the old process-dict bleed).
      {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])

      success =
        Enum.find(
          events,
          &(&1.payload["run_id"] == run.id and &1.event_type == "action_run.success")
        )

      assert success.ip_address == "203.0.113.7"
      assert success.user_agent == "Codex-CLI/1.0"

      # The run event's target is WHERE it executed; what ran is a payload fact.
      assert success.target_kind == "runner"
      assert success.target_id == run.runner_id
      assert success.payload["action"] == "linux.uptime"
    end

    test "snapshots self-reported MCP client metadata onto the run and its terminal audit event" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()

      metadata = %{"asset_tag" => "LT-4417", "device_id" => "d-99"}
      context = %RequestContext{mcp_client_metadata: metadata}
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner, context: context)

      {:ok, :running, run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # Snapshotted on the run at create time, not just on the api-key record.
      assert run.mcp_client_metadata == metadata

      # The terminal transition (written from the runner-socket path, long after
      # the request) still carries the metadata that was present at dispatch.
      {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 6})
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])

      success =
        Enum.find(
          events,
          &(&1.payload["run_id"] == run.id and &1.event_type == "action_run.success")
        )

      assert success.payload["mcp_client_metadata"] == metadata
    end

    test "a run with no client metadata stores an empty map and omits it from the audit payload" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      {:ok, :running, run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
      assert run.mcp_client_metadata == %{}

      {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 6})
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])

      success =
        Enum.find(
          events,
          &(&1.payload["run_id"] == run.id and &1.event_type == "action_run.success")
        )

      refute Map.has_key?(success.payload, "mcp_client_metadata")
    end

    test "client metadata does not change the policy decision (never an authz input)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()

      # A key an over-strict design might have treated as "managed/compliant";
      # policy must ignore it entirely — same decision as a bare dispatch.
      context = %RequestContext{mcp_client_metadata: %{"managed" => "true", "role" => "admin"}}
      with_metadata = Fixtures.Subjects.subject_for(user, account, role: :owner, context: context)
      without = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, :running, run_with} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), with_metadata)

      {:ok, :running, run_without} = Runs.dispatch_run(base_attrs(account.id, runner.id), without)

      assert run_with.policy_decision == run_without.policy_decision
      assert run_with.policy_decision == "allow"
    end

    test "wire envelope carries trusted pack hash when one is on file" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # Drive the catalog through `observe_state` so pack_version is
      # populated on the action AND a PackVersion row exists. Custom
      # packs land pending — operator approves before dispatch can
      # carry the trusted hash on the wire.
      :ok =
        case Emisar.Catalog.observe_state(runner, %{
               "hostname" => "h",
               "version" => "0.1",
               "labels" => %{},
               "packs" => %{
                 "linux-core" => %{"version" => "1.2.3", "hash" => "sha256:CLOUD_TRUSTED"}
               },
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => "low",
                   "description" => "t",
                   "args" => []
                 }
               ]
             }) do
          {:ok, _} -> :ok
        end

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      assert {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      _ = Fixtures.Policies.create_policy(account_id: account.id)

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, _run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert_receive {:cloud_to_runner, _generation, payload}, 500
      assert payload["expected_pack_hash"] == "sha256:CLOUD_TRUSTED"
    end

    test "rejects dispatch when the action is not advertised by the runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:error, :action_not_found} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )
    end

    test "rejects dispatch to a soft-deleted runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # Soft-delete the runner (sets deleted_at). The dispatch gate runs
      # before the action-advertised check, so a deleted runner is refused
      # as :runner_not_found rather than slipping through to execution.
      {:ok, _} = runner |> Emisar.Runners.Runner.Changeset.delete() |> Emisar.Repo.update()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:error, :runner_not_found} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )
    end

    test "policy sees the catalog's risk, not what the caller passes" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # Catalog says high risk.
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")

      # Policy: require approval for high.
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
            "overrides" => [],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          }
        )

      # Caller spoofs `risk: "low"` — should be ignored.
      attrs = base_attrs(account.id, runner.id, %{risk: "low"})
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:ok, :pending_approval, _run} =
               Runs.dispatch_run(attrs, subject)
    end

    test "require_approval policy stores the run as pending, creates a request, + audits the gating" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)

      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "allow",
              "critical" => "allow"
            },
            "overrides" => [
              %{"name" => "needs-approval", "action" => "*", "decision" => "require_approval"}
            ],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          }
        )

      requester = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:ok, :pending_approval, %ActionRun{status: :pending_approval} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{requested_by_id: requester.id}),
                 subject
               )

      assert {:ok, [_req], _} = Approvals.list_pending_approval_requests(subject)
      assert {:ok, %{status: :pending_approval}} = Runs.fetch_run_by_id(run.id, subject)

      # The gating earns an append-only audit row. `require_approval` no longer
      # writes a `policy.evaluated` row (diet #3), so `action_run.pending_approval`
      # IS the record that a risky action was sent to the approval queue — not just
      # the mutable run-row status. Regression: `:pending_approval` was missing from
      # `@audited_run_statuses`, so this row was silently never written.
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])

      types =
        events |> Enum.filter(&(&1.payload["run_id"] == run.id)) |> Enum.map(& &1.event_type)

      assert "action_run.pending_approval" in types
      refute "policy.evaluated" in types
    end

    test "corrupt approval settings block a gated dispatch before any row is created" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)

      policy =
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
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          }
        )

      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      corrupt_approvals = [
        :missing,
        %{"min_approvals" => 1},
        %{"min_approvals" => 1, "allow_self_approval" => "yes"}
      ]

      _policy =
        Enum.reduce(corrupt_approvals, policy, fn approval, policy ->
          rules =
            if approval == :missing,
              do: Map.delete(policy.rules, "approval"),
              else: Map.put(policy.rules, "approval", approval)

          policy = policy |> Ecto.Changeset.change(rules: rules) |> Repo.update!()

          assert {:error, :invalid_policy_approval} =
                   Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

          policy
        end)

      refute Repo.exists?(ActionRun)
      refute Repo.exists?(Emisar.Approvals.Request)
    end

    test "policy with no matching allow rule denies and records the attempt for audit" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)

      # Policy only allows cassandra.* actions; the dispatched
      # `linux.uptime` doesn't match, so it falls through to the
      # tier defaults — which are all `deny` here.
      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "deny",
              "medium" => "deny",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => [
              %{"name" => "cassandra-only", "action" => "cassandra.*", "decision" => "allow"}
            ]
          }
        )

      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:error, :denied_by_policy, reason} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert is_binary(reason)
      # A denied run is recorded with status="denied" so operators can
      # see attempts in the audit log.
      assert {:ok, [%{status: :denied, policy_decision: "deny"}], _meta} =
               Runs.list_recent_runs(subject, limit: 50)
    end

    test "stamps policy_version on the dispatched run so audit can correlate vN edits" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert run.policy_id == policy.id
      assert run.policy_version == policy.vsn
    end

    test "resolves a runner-scoped override, replacing the account allow" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      _ = Fixtures.Catalog.create_action(runner: runner)

      {:ok, _} = Emisar.Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, owner)

      assert {:error, :denied_by_policy, _reason} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), owner)

      assert {:ok, [%{status: :denied, policy_decision: "deny"}], _meta} =
               Runs.list_recent_runs(owner, limit: 50)
    end

    test "resolves a group-scoped override; other groups keep the account default" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      db_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      _ = Fixtures.Catalog.create_action(runner: db_runner)
      _ = Fixtures.Catalog.create_action(runner: web_runner)

      {:ok, _} = Emisar.Policies.save_scoped_rules(deny_all_rules(), :group, "db", owner)

      # The db-group runner is denied by the group override…
      assert {:error, :denied_by_policy, _reason} =
               Runs.dispatch_run(base_attrs(account.id, db_runner.id), owner)

      # …while a web-group runner falls through to the allowing account default.
      assert {:ok, :running, %ActionRun{}} =
               Runs.dispatch_run(base_attrs(account.id, web_runner.id), owner)
    end

    test "an enforcing runner refuses an unsigned (portal-originated) dispatch" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id, enforce_signatures: true)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      assert {:error, :runner_requires_attestation} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "a signed dispatch persists the attestation and relays it on the wire" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id, enforce_signatures: true)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      attestation = %{
        "key_id" => "k1",
        "sig" => "deadbeef",
        "nonce" => "n1",
        "issued_at" => "2026-06-17T12:00:00Z"
      }

      Emisar.Runners.subscribe_runner_transport(runner)

      attrs = base_attrs(account.id, runner.id, %{attestation: attestation})
      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)

      # Stored on the run row, and relayed verbatim — the portal only carries it.
      assert run.attestation == attestation
      assert_receive {:cloud_to_runner, _generation, payload}, 500
      assert payload["attestation"] == attestation
    end

    test "canonical runner options survive the DB and wire round-trip" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      opts = %{
        "timeout" => 5_000_000_000,
        "max_stdout_bytes" => 65_536,
        "max_stderr_bytes" => 16_384
      }

      Emisar.Runners.subscribe_runner_transport(runner)

      attrs = base_attrs(account.id, runner.id, %{opts: opts})
      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)
      assert run.opts == opts
      assert_receive {:cloud_to_runner, _generation, payload}, 500
      assert payload["opts"] == opts
    end

    test "rich args survive the DB + wire round-trip unchanged (so the signature still verifies)" do
      # The MCP signs over the canonical args; the runner re-canonicalizes the
      # args the portal relayed. If the portal's jsonb/Jason round-trip mangled
      # a value (int↔float, key order, nesting), the signature would fail. Prove
      # the relay is lossless for mixed scalar / array / nested types.
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      rich_args = %{
        "container" => "web",
        "force" => true,
        "signal" => 15,
        "names" => ["a", "b"],
        "opts" => %{"z" => 1, "a" => 2}
      }

      Emisar.Runners.subscribe_runner_transport(runner)

      attrs = base_attrs(account.id, runner.id, %{args: rich_args})
      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)

      # The exact encoded arguments are the only persisted representation.
      assert Repo.reload!(run).args_raw |> Jason.decode!() == rich_args
      # The wire encoder inserts those same bytes without another conversion.
      assert_receive {:cloud_to_runner, _generation, payload}, 500
      assert payload |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("args") == rich_args
    end

    test "a portal-originated run carries no attestation on the wire" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, _run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
      assert_receive {:cloud_to_runner, _generation, payload}, 500
      refute Map.has_key?(payload, "attestation")
    end

    test "the refusal records a dispatch_blocked_requires_attestation audit row" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id, enforce_signatures: true)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      {:error, :runner_requires_attestation} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])
      blocked = Enum.find(events, &(&1.event_type == "dispatch_blocked_requires_attestation"))

      assert blocked
      assert blocked.target_kind == "runner"
      assert blocked.target_id == runner.id
      assert blocked.payload["action_id"] == "linux.uptime"
    end

    test "a failed run insert leaves no run row, no audit row, and fires no broadcast" do
      # the run row + its terminal audit event commit in ONE Multi. When the :run
      # insert fails (oversized args), the whole transaction rolls back: no orphan
      # run row, no orphan audit row, and no broadcast — a rolled-back dispatch can
      # never leave a trace.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      Emisar.Runs.subscribe_account_runs(account.id)

      huge = %{"blob" => String.duplicate("x", 300_000)}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runs.dispatch_run(base_attrs(account.id, runner.id, %{args: huge}), subject)

      assert Keyword.has_key?(changeset.errors, :args_raw)

      # No run persisted for this account…
      assert {:ok, [], _} = Runs.list_recent_runs(subject, limit: 50)

      # …no run audit row orphaned by the rolled-back transaction…
      refute Enum.any?(
               Repo.all(Emisar.Audit.Event),
               &String.starts_with?(&1.event_type, "action_run")
             )

      # …and a rolled-back transaction announces nothing (broadcasts are after_commit).
      refute_receive {:run_updated, _}, 200
    end

    test "rejects a missing action_id with :action_required" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      attrs = %{runner_id: runner.id, reason: "x", source: "operator", args: %{}}
      assert {:error, :action_required} = Runs.dispatch_run(attrs, subject)
    end

    test "rejects a missing reason with :reason_required" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      attrs = %{runner_id: runner.id, action_id: "linux.uptime", source: "operator", args: %{}}
      assert {:error, :reason_required} = Runs.dispatch_run(attrs, subject)
    end
  end

  describe "compose_dispatch_batch_in_multi/5" do
    test "rejects a subject without dispatch permission" do
      %{account: account, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      operation = mcp_operation_attrs("op_334NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)

      assert Runs.compose_dispatch_batch_in_multi(
               Multi.new(),
               [target],
               no_permissions_subject(account),
               :denied
             ) == {:error, :unauthorized}
    end

    test "rejects a runner from another account" do
      %{runners: [runner_a], key: key_a} = mcp_fanout_fixture(["low"])
      {user_b, account_b, _subject_b} = Fixtures.Subjects.owner_subject()

      {_raw, key_b} =
        Fixtures.ApiKeys.create_api_key(account_id: account_b.id, created_by_id: user_b.id)

      subject_b = Emisar.Auth.Subject.for_api_key(key_b, account_b)
      operation = mcp_operation_attrs("op_334NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner_a, key_a, operation.operation_id)

      assert {:ok, multi} =
               Runs.compose_dispatch_batch_in_multi(
                 Multi.new(),
                 [target],
                 subject_b,
                 :cross_account
               )

      assert {:error, {:dispatch_batch, :cross_account}, :runner_not_found, _changes} =
               Repo.transaction(multi)
    end

    test "commits the complete batch without running post-commit side effects" do
      %{changes: changes, runner: runner} = composed_dispatch_fixture(:compose_contract)

      assert %ActionRun{runner_id: runner_id, status: :pending} =
               changes[{:composed_run, :compose_contract, 0}]

      assert runner_id == runner.id
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "rejects an empty batch before adding it to the caller's transaction" do
      %{subject: subject} = mcp_fanout_fixture(["low"])

      assert {:error, :invalid_targets} =
               Runs.compose_dispatch_batch_in_multi(Multi.new(), [], subject, :empty)
    end
  end

  describe "after_composed_dispatches_committed/1" do
    test "delivers and broadcasts the rows only after the outer transaction commits" do
      %{changes: changes, runner: runner} = composed_dispatch_fixture(:post_commit_contract)
      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      :ok = Runs.subscribe_account_runs(runner.account_id)

      assert :ok = Runs.after_composed_dispatches_committed(changes)
      assert_receive {:run_updated, %ActionRun{runner_id: runner_id}}, 500
      assert runner_id == runner.id

      assert_receive {:cloud_to_runner, _generation,
                      %{
                        "type" => "run_action",
                        "pack_ref" => @mcp_pack_ref,
                        "operation_id" => "op_334NN9NMDZ1T76NARWCKM5A0D6"
                      }},
                     500
    end
  end

  describe "dispatch_mcp_fanout/3" do
    test "rejects a subject without dispatch permission" do
      %{account: account, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      operation = mcp_operation_attrs("op_334NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)

      assert Runs.dispatch_mcp_fanout(operation, [target], no_permissions_subject(account)) ==
               {:error, :unauthorized}
    end

    test "rejects a runner from another account" do
      %{runners: [runner_a], key: key_a} = mcp_fanout_fixture(["low"])
      {user_b, account_b, _subject_b} = Fixtures.Subjects.owner_subject()

      {_raw, key_b} =
        Fixtures.ApiKeys.create_api_key(account_id: account_b.id, created_by_id: user_b.id)

      subject_b = Emisar.Auth.Subject.for_api_key(key_b, account_b)
      operation = mcp_operation_attrs("op_334NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner_a, key_a, operation.operation_id)

      assert Runs.dispatch_mcp_fanout(operation, [target], subject_b) ==
               {:error, :runner_not_found}
    end

    test "commits every target before delivery and exact replay never redelivers" do
      %{subject: subject, runners: [runner_a, runner_b], key: key} =
        mcp_fanout_fixture(["low", "low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner_a)
      :ok = Emisar.Runners.subscribe_runner_transport(runner_b)

      operation = mcp_operation_attrs("op_724NN9NMDZ1T76NARWCKM5A0D6")
      targets = Enum.map([runner_a, runner_b], &mcp_target_attrs(&1, key, operation.operation_id))

      assert {:ok, runs} = Runs.dispatch_mcp_fanout(operation, targets, subject)
      assert length(runs) == 2
      assert Enum.uniq_by(runs, & &1.mcp_operation_record_id) |> length() == 1
      assert Enum.all?(runs, &(&1.status == :sent))

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      original_ids = Enum.map(runs, & &1.id)
      assert {:ok, replayed} = Runs.dispatch_mcp_fanout(operation, targets, subject)
      assert Enum.map(replayed, & &1.id) == original_ids
      refute_receive {:cloud_to_runner, _generation, _}, 100

      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
      assert Repo.aggregate(ActionRun, :count) == 2
    end

    test "concurrent identical fan-outs converge on one complete delivered target set" do
      %{subject: subject, runners: [runner_a, runner_b], key: key} =
        mcp_fanout_fixture(["low", "low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner_a)
      :ok = Emisar.Runners.subscribe_runner_transport(runner_b)

      operation = mcp_operation_attrs("op_714NN9NMDZ1T76NARWCKM5A0D6")
      targets = Enum.map([runner_a, runner_b], &mcp_target_attrs(&1, key, operation.operation_id))

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> Runs.dispatch_mcp_fanout(operation, targets, subject) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, [_run_a, _run_b]}, &1))

      target_sets =
        Enum.map(results, fn {:ok, runs} ->
          runs |> Enum.map(& &1.id) |> Enum.sort()
        end)

      assert target_sets |> Enum.uniq() |> length() == 1

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      refute_receive {:cloud_to_runner, _generation, _}, 100

      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
      assert Repo.aggregate(ActionRun, :count) == 2
    end

    test "rolls back the operation and every target when any preflight fails" do
      %{account: account, subject: subject, runners: [ready], key: key} =
        mcp_fanout_fixture(["low"])

      missing = Fixtures.Runners.create_runner(account_id: account.id)
      :ok = Emisar.Runners.subscribe_runner_transport(ready)

      operation = mcp_operation_attrs("op_624NN9NMDZ1T76NARWCKM5A0D6")

      targets = [
        mcp_target_attrs(ready, key, operation.operation_id),
        mcp_target_attrs(missing, key, operation.operation_id)
      ]

      assert {:error, :action_not_found} =
               Runs.dispatch_mcp_fanout(operation, targets, subject)

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "commits mixed allow and approval outcomes in one operation" do
      gated_rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "require_approval",
          "medium" => "require_approval",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      }

      %{
        subject: subject,
        owner_subject: owner_subject,
        runners: [allowed, gated],
        key: key
      } = mcp_fanout_fixture(["low", "low"])

      assert {:ok, _policy} =
               Emisar.Policies.save_scoped_rules(
                 gated_rules,
                 :runner,
                 gated.id,
                 owner_subject
               )

      :ok = Emisar.Runners.subscribe_runner_transport(allowed)

      operation = mcp_operation_attrs("op_524NN9NMDZ1T76NARWCKM5A0D6")
      targets = Enum.map([allowed, gated], &mcp_target_attrs(&1, key, operation.operation_id))

      assert {:ok, runs} = Runs.dispatch_mcp_fanout(operation, targets, subject)
      assert Enum.sort(Enum.map(runs, & &1.status)) == [:pending_approval, :sent]
      assert Enum.uniq_by(runs, & &1.mcp_operation_record_id) |> length() == 1

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      refute_receive {:cloud_to_runner, _generation, _}, 100

      assert {:ok, [request], _meta} =
               Approvals.list_pending_approval_requests(owner_subject)

      gated_run = Enum.find(runs, &(&1.status == :pending_approval))
      assert request.run_id == gated_run.id
    end

    test "corrupt approval settings roll back the complete MCP operation" do
      gated_rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "require_approval",
          "medium" => "require_approval",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      }

      %{account: account, subject: subject, runners: [runner], key: key} =
        mcp_fanout_fixture(["low"], gated_rules)

      policy = Emisar.Policies.peek_policy_for_account(account.id)
      rules = Map.delete(policy.rules, "approval")
      _policy = policy |> Ecto.Changeset.change(rules: rules) |> Repo.update!()

      operation = mcp_operation_attrs("op_504NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)

      assert {:error, :invalid_policy_approval} =
               Runs.dispatch_mcp_fanout(operation, [target], subject)

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
      refute Repo.exists?(Emisar.Approvals.Request)
    end

    test "rejects an already-stale signed fan-out before reserving its operation" do
      %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])

      assert {:ok, _runner} =
               Emisar.Runners.apply_state(runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      operation = mcp_operation_attrs("op_514NN9NMDZ1T76NARWCKM5A0D6")
      now = DateTime.utc_now()

      attestation = %{
        "issued_at" => now |> DateTime.add(-7_200, :second) |> DateTime.to_iso8601(),
        "cert" => %{"valid_until" => now |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()}
      }

      target =
        runner
        |> mcp_target_attrs(key, operation.operation_id)
        |> Map.put(:attestation, attestation)

      assert {:error, :attestation_stale} =
               Runs.dispatch_mcp_fanout(operation, [target], subject)

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
    end

    test "caps a signed approval at the earliest attestation deadline" do
      gated_rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "require_approval",
          "medium" => "require_approval",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      }

      %{
        subject: subject,
        owner_subject: owner_subject,
        runners: [runner],
        key: key
      } = mcp_fanout_fixture(["low"], gated_rules)

      assert {:ok, _runner} =
               Emisar.Runners.apply_state(runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      operation = mcp_operation_attrs("op_414NN9NMDZ1T76NARWCKM5A0D6")
      now = DateTime.utc_now()
      cert_deadline = DateTime.add(now, 600, :second)

      attestation = %{
        "issued_at" => DateTime.to_iso8601(now),
        "cert" => %{"valid_until" => DateTime.to_iso8601(cert_deadline)}
      }

      target =
        runner
        |> mcp_target_attrs(key, operation.operation_id)
        |> Map.put(:attestation, attestation)

      assert {:ok, [%ActionRun{status: :pending_approval} = run]} =
               Runs.dispatch_mcp_fanout(operation, [target], subject)

      assert {:ok, [request], _meta} =
               Approvals.list_pending_approval_requests(owner_subject)

      assert request.run_id == run.id
      assert DateTime.diff(request.expires_at, now, :second) in 599..600
      assert DateTime.compare(request.expires_at, cert_deadline) != :gt
    end

    test "rejects duplicate targets before reserving an operation" do
      %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      operation = mcp_operation_attrs("op_424NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)

      assert {:error, :invalid_targets} =
               Runs.dispatch_mcp_fanout(operation, [target, target], subject)

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
    end
  end

  describe "list_runs_by_mcp_operation/2" do
    test "uses the subject account boundary" do
      %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      operation = mcp_operation_attrs("op_324NN9NMDZ1T76NARWCKM5A0D6")
      target = mcp_target_attrs(runner, key, operation.operation_id)

      assert {:ok, [run]} = Runs.dispatch_mcp_fanout(operation, [target], subject)

      assert {:ok, [listed]} =
               Runs.list_runs_by_mcp_operation(run.mcp_operation_record_id, subject)

      assert listed.id == run.id

      {_user, _account, foreign_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, []} =
               Runs.list_runs_by_mcp_operation(run.mcp_operation_record_id, foreign_subject)
    end
  end

  describe "dispatch_run_for_account/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "dispatches with no %Subject{} — the explicit account is the scope", %{
      account: account,
      runner: runner
    } do
      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run_for_account(base_attrs(account.id, runner.id), account.id)

      assert run.account_id == account.id
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
    end

    test "still enforces the reason / action / runner gates", %{
      account: account,
      runner: runner
    } do
      assert {:error, :reason_required} =
               Runs.dispatch_run_for_account(
                 base_attrs(account.id, runner.id, %{reason: "   "}),
                 account.id
               )

      assert {:error, :action_required} =
               Runs.dispatch_run_for_account(
                 %{runner_id: runner.id, reason: "x", source: "runbook", args: %{}},
                 account.id
               )

      assert {:error, :runner_required} =
               Runs.dispatch_run_for_account(
                 %{action_id: "linux.uptime", reason: "x", source: "runbook", args: %{}},
                 account.id
               )
    end

    test "re-checks the initiating membership's runner scope — out-of-scope is refused", %{
      account: account,
      runner: runner
    } do
      # The continuation threads `requested_by_membership_id`; if that membership's
      # runner scope no longer covers this runner (a scope revoked mid-execution),
      # the wave is refused — the same per-membership check the first wave runs.
      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      # Scope the membership to a group the runner is NOT in (scope_type is a
      # string — the team LV passes "group"/"runner").
      {:ok, _} = Emisar.Runners.replace_runner_scopes(membership, [{"group", "nope"}], owner)

      attrs =
        base_attrs(account.id, runner.id, %{requested_by_membership_id: membership.id})

      assert {:error, :runner_out_of_scope} =
               Runs.dispatch_run_for_account(attrs, account.id)
    end
  end

  defp mcp_fanout_fixture(risks, rules \\ nil) do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    owner_subject = Emisar.Auth.Subject.for_user(user, account, membership)
    {:ok, _raw, key} = ApiKeys.create_key(%{name: "MCP fanout", kind: :mcp}, owner_subject)
    subject = Emisar.Auth.Subject.for_api_key(key, account)

    policy_attrs = %{account_id: account.id, created_by_id: user.id}
    policy_attrs = if rules, do: Map.put(policy_attrs, :rules, rules), else: policy_attrs
    _policy = Fixtures.Policies.create_policy(policy_attrs)

    runners =
      Enum.map(risks, fn risk ->
        runner = Fixtures.Runners.create_runner(account_id: account.id)

        assert {:ok, _runner} =
                 Catalog.observe_state(runner, %{
                   "hostname" => runner.hostname,
                   "version" => runner.runner_version,
                   "labels" => runner.labels,
                   "packs" => %{
                     "linux-core" => %{"version" => "1.0.0", "hash" => @mcp_pack_hash}
                   },
                   "actions" => [
                     %{
                       "id" => "linux.uptime",
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

        runner
      end)

    {:ok, pack_versions} = Catalog.list_all_pack_versions_for_account(owner_subject)

    Enum.each(pack_versions, fn pack_version ->
      if pack_version.trust_state != :trusted do
        assert {:ok, _pack_version} = Catalog.trust_pack_version(pack_version.id, owner_subject)
      end
    end)

    %{
      account: account,
      owner_subject: owner_subject,
      subject: subject,
      membership: membership,
      key: key,
      runners: runners
    }
  end

  defp mcp_operation_attrs(operation_id) do
    %{
      operation_id: operation_id,
      tool: :run_action,
      fingerprint: String.duplicate("b", 64),
      action_id: "linux.uptime",
      pack_ref: @mcp_pack_ref
    }
  end

  defp mcp_target_attrs(runner, key, operation_id) do
    %{
      action_id: "linux.uptime",
      runner_id: runner.id,
      args: %{},
      args_raw: "{}",
      reason: "inspect uptime",
      source: "mcp",
      api_key_id: key.id,
      operation_id: operation_id,
      pack_ref: @mcp_pack_ref
    }
  end

  defp composed_dispatch_fixture(namespace) do
    %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
    target = mcp_target_attrs(runner, key, "op_334NN9NMDZ1T76NARWCKM5A0D6")

    assert {:ok, multi} =
             Runs.compose_dispatch_batch_in_multi(Multi.new(), [target], subject, namespace)

    assert {:ok, changes} = Repo.transaction(multi)
    %{changes: changes, runner: runner}
  end

  describe "recheck_run_pack_trust/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "refuses a run whose action pack drifted to :pending", %{
      account: account,
      runner: runner
    } do
      # A custom pack lands :pending (untrusted) — the same state a tampered
      # re-advertisement produces during an approval window.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"linux-core" => %{"version" => "1.2.3", "hash" => "sha256:DRIFT"}},
          "actions" => [
            %{
              "id" => "linux.uptime",
              "pack_id" => "linux-core",
              "title" => "Uptime",
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
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      assert {:error, :pack_untrusted} = Runs.recheck_run_pack_trust(run.id)
    end

    test "passes a packless run when the runner no longer advertises the action", %{
      account: account,
      runner: runner
    } do
      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "ghost.action",
          source: "operator",
          args: %{}
        })

      assert :ok = Runs.recheck_run_pack_trust(run.id)
    end

    test "refuses a versioned run when its advertised action disappeared", %{
      account: account,
      runner: runner
    } do
      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "ghost.action",
          source: "operator",
          args: %{},
          expected_pack_hash: "sha256:AUTHORIZED"
        })

      assert {:error, :action_not_found} = Runs.recheck_run_pack_trust(run.id)
    end
  end

  describe "check_run_attestation_fresh/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      # The runner advertises signing enforcement + a 1h freshness window.
      {:ok, runner} =
        Emisar.Runners.apply_state(runner, %{
          "enforce_signatures" => true,
          "max_attestation_age_seconds" => 3600
        })

      %{account: account, runner: runner}
    end

    defp signed_run(account, runner, issued_at) do
      cert_deadline = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      {:ok, run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            attestation: %{
              "issued_at" => issued_at,
              "cert" => %{"valid_until" => cert_deadline}
            }
          })
        )

      run
    end

    test "a fresh signature passes", %{account: account, runner: runner} do
      run = signed_run(account, runner, DateTime.to_iso8601(DateTime.utc_now()))
      assert :ok = Runs.check_run_attestation_fresh(run.id)
    end

    test "a signature older than the window is refused as :attestation_stale", %{
      account: account,
      runner: runner
    } do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
      run = signed_run(account, runner, stale)
      assert {:error, :attestation_stale} = Runs.check_run_attestation_fresh(run.id)
    end

    test "an unsigned run for an enforcing runner fails closed", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert {:error, :attestation_stale} = Runs.check_run_attestation_fresh(run.id)
    end
  end

  describe "list_stale_dispatches/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{account: account, subject: subject}
    end

    test "returns only pending/sent runs older than the cutoff", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)

      {:ok, :running, fresh} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # Backdate one run so it's past the cutoff.
      stale_inserted_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      stale =
        fresh
        |> Ecto.Changeset.change(queued_at: stale_inserted_at, status: :sent)
        |> Repo.update!()

      cutoff = DateTime.utc_now() |> DateTime.add(-2 * 60, :second)
      assert [stale_row] = Runs.list_stale_dispatches(cutoff)
      assert stale_row.id == stale.id
    end
  end

  describe "RunDispatchTimeout sweep (worker over list_stale_dispatches/1)" do
    setup do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{account: account, subject: subject}
    end

    test "worker fails closed when a sent run's runner disconnected", %{
      account: account,
      subject: subject
    } do
      # connected?: false → never tracked in presence → offline.
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      _ = Fixtures.Catalog.create_action(runner: runner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # Backdate + flip to sent so it's a sweep candidate.
      stale_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      run
      |> Ecto.Changeset.change(queued_at: stale_at, status: :sent)
      |> Repo.update!()

      assert :ok = Emisar.Runs.Jobs.DispatchTimeout.execute([])

      reloaded = Repo.get!(ActionRun, run.id)
      assert reloaded.status == :error
      assert reloaded.error_message =~ "disconnected after accepting this dispatch"
      assert reloaded.error_message =~ "outcome is unknown"
      assert reloaded.error_message =~ "did not execute it again"
    end

    test "worker leaves a stale run alone while its runner is online", %{
      account: account,
      subject: subject
    } do
      # connected?: true → tracked in presence from this process → online.
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      _ = Fixtures.Catalog.create_action(runner: runner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      stale_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      run
      |> Ecto.Changeset.change(queued_at: stale_at, status: :sent)
      |> Repo.update!()

      assert :ok = Emisar.Runs.Jobs.DispatchTimeout.execute([])

      assert Repo.get!(ActionRun, run.id).status == :sent
    end
  end

  describe "dispatch_queued_for_runner/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "dispatches pending work without replaying a sent run", %{
      account: account,
      runner: runner
    } do
      Emisar.Runners.subscribe_runner_transport(runner)
      {:ok, sent} = Runs.create_run(base_attrs(account.id, runner.id))
      sent = Fixtures.Runs.put_status(sent, :sent)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      sent = sent |> Ecto.Changeset.change(sent_at: past) |> Repo.update!()

      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))
      assert pending.status == :pending
      {:ok, next_pending} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.dispatch_queued_for_runner(runner.id)

      assert_receive {:cloud_to_runner, _generation, %{"request_id" => request_id}}, 500
      assert request_id == pending.request_id
      refute_receive {:cloud_to_runner, _generation, _}, 100

      unchanged = Runs.peek_run_by_id(sent.id)
      assert unchanged.status == :sent
      assert DateTime.compare(unchanged.sent_at, sent.sent_at) == :eq
      assert Runs.peek_run_by_id(pending.id).status == :sent
      assert Runs.peek_run_by_id(next_pending.id).status == :pending
    end

    test "leaves :running, terminal, and other-runner runs untouched (no double-exec)", %{
      account: account,
      runner: runner
    } do
      other = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, running} = Runs.create_run(base_attrs(account.id, runner.id))
      running = Fixtures.Runs.put_status(running, :running)

      {:ok, other_sent} = Runs.create_run(base_attrs(account.id, other.id))
      other_sent = Fixtures.Runs.put_status(other_sent, :sent)

      assert :ok = Runs.dispatch_queued_for_runner(runner.id)

      # A :running run is excluded by the :pending filter — never re-sent.
      reloaded_running = Runs.peek_run_by_id(running.id)
      assert reloaded_running.status == :running
      assert DateTime.compare(reloaded_running.sent_at, running.sent_at) == :eq

      # Another runner's in-flight run is out of scope — untouched.
      reloaded_other = Runs.peek_run_by_id(other_sent.id)
      assert DateTime.compare(reloaded_other.sent_at, other_sent.sent_at) == :eq
    end

    test "leaves a versioned run pending until its catalog action is available", %{
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{expected_pack_hash: "sha256:AUTHORIZED"})
        )

      assert :ok = Runs.dispatch_queued_for_runner(runner.id)
      assert Runs.peek_run_by_id(run.id).status == :pending
      refute_receive {:cloud_to_runner, _generation, _payload}, 100
    end
  end

  describe "resume_runs_for_runner/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)
      %{account: account, runner: runner}
    end

    test "replays the persisted execution intent on the current connection", %{
      account: account,
      runner: runner
    } do
      args_raw = ~s({"job_id":9007199254740993,"ratio":0.1234567890123456789})

      {:ok, run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            args_raw: args_raw,
            opts: %{"timeout" => 30_000_000_000}
          })
        )

      assert :ok = Runs.dispatch_to_runner(run)

      assert_receive {:cloud_to_runner, first_generation, %{"type" => "run_action"} = original},
                     500

      successor = reconnect_runner(runner)
      assert :ok = Runs.resume_runs_for_runner(runner.id)

      assert_receive {:cloud_to_runner, successor_generation,
                      %{"type" => "run_action"} = recovered},
                     500

      assert first_generation == runner.connection_generation
      assert successor_generation == successor.connection_generation
      assert recovered == original
      assert Jason.encode!(recovered) =~ ~s("job_id":9007199254740993)
      assert Runs.peek_run_by_id(run.id).status == :sent
    end

    test "replays cancellation after the execution intent", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      run
      |> Ecto.Changeset.change(status: :cancelling, reason_text: "operator requested stop")
      |> Repo.update!()

      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))

      successor = reconnect_runner(runner)
      assert :ok = Runs.resume_runs_for_runner(runner.id)

      assert_receive {:cloud_to_runner, generation,
                      %{"type" => "run_action", "request_id" => request_id}},
                     500

      assert_receive {:cloud_to_runner, ^generation,
                      %{
                        "type" => "cancel",
                        "request_id" => ^request_id,
                        "reason" => "operator requested stop"
                      }},
                     500

      assert generation == successor.connection_generation
      assert request_id == run.request_id
      assert Runs.peek_run_by_id(run.id).status == :cancelling
      assert Runs.peek_run_by_id(pending.id).status == :pending
      refute_receive {:cloud_to_runner, _generation, _message}, 100
    end
  end

  describe "mark_started_from_connection/5" do
    test "marks a sent run running only for the current connection owner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      assert {:ok, started} =
               Runs.mark_started_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 run.request_id
               )

      assert started.status == :running
      assert %DateTime{} = started.started_at

      assert {:error, :not_dispatchable} =
               Runs.mark_started_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 run.request_id
               )
    end

    test "rejects a superseded lease without changing the run" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      reconnect_runner(runner)

      assert {:error, :connection_superseded} =
               Runs.mark_started_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 run.request_id
               )

      assert Runs.peek_run_by_id(run.id).status == :sent
    end
  end

  describe "list_running_runs/0" do
    test "returns only in-flight rows" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.create_run(base_attrs(account.id, runner.id))
      running = Fixtures.Runs.put_status(running, :running)

      ids = Runs.list_running_runs() |> Enum.map(& &1.id)
      assert running.id in ids
      refute pending.id in ids
      assert running.status == :running
      assert %DateTime{} = running.started_at
    end
  end

  describe "list_runs_for_runbook_execution/2" do
    test "returns an execution's runs in dispatch (oldest-first) order, scoped to the account" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      execution_id = Ecto.UUID.generate()

      {:ok, first} =
        Runs.create_run(base_attrs(account.id, runner.id, %{runbook_execution_id: execution_id}))

      {:ok, second} =
        Runs.create_run(base_attrs(account.id, runner.id, %{runbook_execution_id: execution_id}))

      # A run in a DIFFERENT execution must not bleed in.
      {:ok, _other} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{runbook_execution_id: Ecto.UUID.generate()})
        )

      runs = Runs.list_runs_for_runbook_execution(account.id, execution_id)
      assert Enum.map(runs, & &1.id) == [first.id, second.id]
      _ = subject

      # Another account asking for the same execution id sees nothing.
      other_account = Fixtures.Accounts.create_account()
      assert Runs.list_runs_for_runbook_execution(other_account.id, execution_id) == []
    end
  end

  describe "fetch_active_runbook_execution/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      # runbook_id is a real FK, so the run needs a persisted runbook to point at.
      runbook = create_runbook(subject)
      %{account: account, runner: runner, subject: subject, runbook: runbook}
    end

    test "returns the latest in-flight execution's runs (runner preloaded)", %{
      account: account,
      runner: runner,
      subject: subject,
      runbook: runbook
    } do
      execution_id = Ecto.UUID.generate()

      {:ok, _run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            status: :running,
            runbook_id: runbook.id,
            runbook_execution_id: execution_id
          })
        )

      assert {:ok, %{execution_id: ^execution_id, runs: [run]}} =
               Runs.fetch_active_runbook_execution(runbook.id, subject)

      assert %Emisar.Runners.Runner{} = run.runner
    end

    test "is :not_found when the runbook's latest execution is fully settled", %{
      account: account,
      runner: runner,
      subject: subject,
      runbook: runbook
    } do
      {:ok, _settled} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            status: :success,
            runbook_id: runbook.id,
            runbook_execution_id: Ecto.UUID.generate()
          })
        )

      assert {:error, :not_found} = Runs.fetch_active_runbook_execution(runbook.id, subject)
    end

    test "is :not_found when the runbook has no executions at all", %{
      subject: subject,
      runbook: runbook
    } do
      assert {:error, :not_found} = Runs.fetch_active_runbook_execution(runbook.id, subject)
    end

    test "an owner of another account can't rehydrate this runbook's execution (cross-account)",
         %{
           account: account,
           runner: runner,
           runbook: runbook
         } do
      {:ok, _run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            status: :running,
            runbook_id: runbook.id,
            runbook_execution_id: Ecto.UUID.generate()
          })
        )

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Runs.fetch_active_runbook_execution(runbook.id, subject_b)
    end

    defp create_runbook(subject) do
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "rb-#{System.unique_integer([:positive])}",
            "name" => "rb-#{System.unique_integer([:positive])}",
            "slug" => "rb-#{System.unique_integer([:positive])}",
            "definition" => %{"steps" => []}
          },
          subject
        )

      runbook
    end
  end

  describe "dispatch_to_runner/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "delivers a dispatchable (:pending) run and marks it :sent", %{
      account: account,
      runner: runner
    } do
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      assert Runs.peek_run_by_id(run.id).status == :sent
    end

    test "refuses to publish a run that's no longer dispatchable (closes the publish-before-claim hole)",
         %{account: account, runner: runner} do
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      # The run reaches a terminal state (e.g. cancelled) before delivery.
      {:ok, _} = run |> Ecto.Changeset.change(status: :cancelled) |> Repo.update()

      # The row-locked claim must refuse it before anything reaches the runner.
      assert {:error, :not_dispatchable} = Runs.dispatch_to_runner(run)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "leaves an offline run pending for the next connection", %{
      account: account,
      runner: runner
    } do
      {:ok, connected} =
        Emisar.Runners.mark_disconnected(
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          "offline"
        )

      :ok =
        Emisar.Runners.Presence.untrack(
          self(),
          Emisar.Runners.Presence.topic(account.id),
          connected.id
        )

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.dispatch_to_runner(run)
      reloaded = Runs.peek_run_by_id(run.id)
      assert reloaded.status == :pending
      assert is_nil(reloaded.runner_connection_generation)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "refuses to publish a run still waiting for approval", %{
      account: account,
      runner: runner
    } do
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{status: :pending_approval}))

      assert {:error, :not_dispatchable} = Runs.dispatch_to_runner(run)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end
  end

  describe "redeliver_to_runner/1" do
    test "a pack drifting to pending after authorization is refused at send, not shipped hash-less" do
      {_user, owner_account, subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Policies.create_policy(account_id: owner_account.id)
      {runner, pack_version} = observe_pending_pack(owner_account, subject)

      # Operator trusts the pack → a run dispatches normally and goes :sent.
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, :running, run} =
               Runs.dispatch_run(
                 base_attrs(owner_account.id, runner.id, %{action_id: "custom.do"}),
                 subject
               )

      assert Runs.peek_run_by_id(run.id).status == :sent

      # The pack drifts to a new hash (a tampered re-advertisement) → :pending.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:TAMPERED"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "description" => "Perform the custom test action.",
              "side_effects" => [],
              "args" => []
            }
          ]
        })

      # Redelivery must NOT ship a hash-less envelope — it refuses the run.
      assert {:error, :pack_untrusted} = Runs.redeliver_to_runner(run)
      assert Runs.peek_run_by_id(run.id).status == :refused
    end

    test "refuses redelivery after trust moves away from the snapshotted hash" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      {runner, pack_version} = observe_pending_pack(account, subject)

      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, :running, run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{action_id: "custom.do"}),
                 subject
               )

      # The trusted hash is snapshotted onto the run + shipped in the envelope.
      assert Runs.peek_run_by_id(run.id).expected_pack_hash == "sha256:NOPE"

      assert_receive {:cloud_to_runner, _generation, %{"expected_pack_hash" => "sha256:NOPE"}},
                     500

      # The pack drifts to a NEW hash AND is re-trusted (trusted hash now TAMPERED).
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:TAMPERED"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "description" => "Perform the custom test action.",
              "side_effects" => [],
              "args" => []
            }
          ]
        })

      {:ok, [drifted], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(drifted.id, subject)

      assert {:error, :pack_untrusted} = Runs.redeliver_to_runner(run)
      assert Runs.peek_run_by_id(run.id).status == :refused
      refute_receive {:cloud_to_runner, _generation, _payload}, 100
    end

    # Observe a custom (no-baseline) pack + its action; the version lands
    # :pending and the action is advertised. Returns {runner, pack_version}.
    defp observe_pending_pack(account, subject) do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "description" => "Perform the custom test action.",
              "side_effects" => [],
              "args" => []
            }
          ]
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {runner, pack_version}
    end
  end

  describe "mark_refused/2" do
    test "transitions to :refused with the cause in error_message" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :refused, error_message: msg, finished_at: %DateTime{}}} =
               Runs.mark_refused(run, "pack trust changed after this run was authorized")

      assert msg =~ "pack trust changed"
      assert ActionRun.terminal?(:refused)
    end
  end

  describe "cancel_run/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "cancelling a terminal run is a no-op", %{account: account, runner: runner} do
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Fixtures.Runs.finish(run, %{"status" => "success"})

      assert {:ok, ^finished} = Runs.cancel_run(finished, subject, "no need")
    end

    test "cancelling a running run waits for its runner-authoritative result", %{
      account: account,
      runner: runner
    } do
      _ = Fixtures.Catalog.create_action(runner: runner)
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, run} =
        Runs.mark_started_from_connection(
          account.id,
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          run.request_id
        )

      Emisar.Runs.subscribe_account_runs(account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok,
              %ActionRun{
                status: :cancelling,
                cancelled_at: nil,
                finished_at: nil,
                reason_text: "user pressed stop"
              }} =
               Runs.cancel_run(run, subject, "user pressed stop")

      assert_receive {:cloud_to_runner, _generation,
                      %{
                        "type" => "cancel",
                        "request_id" => request_id,
                        "reason" => "user pressed stop"
                      }},
                     500

      assert request_id == run.request_id
      assert Runs.peek_run_by_id(run.id).status == :cancelling

      # Payload contract: runner is preloaded so subscribers (e.g.
      # RunDetailLive's meta strip) can render `runner.name` without
      # tripping over `%Ecto.Association.NotLoaded{}`.
      assert_receive {:run_updated,
                      %ActionRun{status: :cancelling, runner: %Emisar.Runners.Runner{}}},
                     500

      assert {:ok, %ActionRun{status: :success}} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{"request_id" => run.request_id, "status" => "success", "exit_code" => 0}
               )

      assert Runs.peek_run_by_id(run.id).status == :success
    end

    test "repeating an in-flight cancellation reaches a successor connection", %{
      account: account,
      runner: runner
    } do
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      run = Fixtures.Runs.put_status(run, :sent)

      run =
        run
        |> Ecto.Changeset.change(runner_connection_generation: runner.connection_generation)
        |> Repo.update!()

      assert {:ok, %ActionRun{status: :cancelling} = cancelling} =
               Runs.cancel_run(run, subject, "stop")

      assert_receive {:cloud_to_runner, first_generation, %{"type" => "cancel"}}, 500
      assert first_generation == runner.connection_generation

      successor = reconnect_runner(runner)

      assert {:ok, %ActionRun{status: :cancelling}} =
               Runs.cancel_run(cancelling, subject, "stop")

      assert_receive {:cloud_to_runner, successor_generation, %{"type" => "cancel"}}, 500
      assert successor_generation == successor.connection_generation

      assert {:ok, %ActionRun{status: :cancelled, cancelled_at: %DateTime{}}} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 successor.connection_generation,
                 successor.connection_lease_id,
                 %{"request_id" => run.request_id, "status" => "cancelled"}
               )
    end

    test "cancelling a :denied run is a no-op — it never reached a runner", %{
      account: account,
      runner: runner
    } do
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "deny",
              "medium" => "deny",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => [],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          }
        )

      assert {:error, :denied_by_policy, _reason} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      assert {:ok, [%ActionRun{status: :denied} = denied], _} =
               Runs.list_recent_runs(subject, limit: 50)

      Emisar.Runs.subscribe_account_runs(account.id)

      # :denied is terminal → cancel returns it unchanged, tells no runner, and
      # broadcasts nothing (before the fix it transitioned denied→cancelled).
      assert {:ok, %ActionRun{status: :denied}} = Runs.cancel_run(denied, subject, "stop")
      refute_receive {:run_updated, _}, 200
    end

    test "a viewer (no cancel permission) is refused with :unauthorized", %{
      account: account,
      runner: runner
    } do
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:error, :unauthorized} = Runs.cancel_run(run, subject, "no rights")
    end

    test "an owner of account B cannot cancel account A's run (cross-account → :not_found)", %{
      account: account_a,
      runner: runner_a
    } do
      {:ok, run_a} = Runs.create_run(base_attrs(account_a.id, runner_a.id))

      account_b = Fixtures.Accounts.create_account()
      owner_b = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: owner_b.id,
          role: "owner"
        )

      subject_b = Fixtures.Subjects.subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Runs.cancel_run(run_a, subject_b, "wrong account")
    end

    test "cancel is accepted from :pending_approval and cancels the parked run", %{
      account: account,
      runner: runner
    } do
      # cancelling a :pending_approval run (parked, never sent) flips it to
      # :cancelled and the cancel is composed atomically with cancelling its
      # still-pending request (cancel_run_for_status's pending_approval clause).
      # A later stale approve then finds a :cancelled request (see approvals).
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, parked} =
        Runs.create_run(base_attrs(account.id, runner.id, %{status: :pending_approval}))

      {:ok, _request} = Approvals.create_request(parked, user.id, "needs review")

      assert {:ok, %ActionRun{status: :cancelled}} =
               Runs.cancel_run(parked, subject, "changed my mind")

      assert Runs.peek_run_by_id(parked.id).status == :cancelled
    end

    test "a cancel writes reason_text only; the operator reason stays put", %{
      account: account,
      runner: runner
    } do
      # reason / reason_text / error_message are three fields with three jobs:
      #   reason       — the operator's "why", shipped on the wire envelope
      #   reason_text  — the CANCEL cause
      #   error_message — the FAILURE/refusal cause
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{reason: "operator why"}))

      run = Fixtures.Runs.put_status(run, :sent)

      assert {:ok, %ActionRun{} = cancelled} = Runs.cancel_run(run, subject, "user pressed stop")
      assert cancelled.reason_text == "user pressed stop"
      assert cancelled.reason == "operator why"
      assert is_nil(cancelled.error_message)
    end
  end

  describe "cancel_run_in_multi/3" do
    test "composes the cancel into a caller's transaction, landing {:cancelled, run} in changes" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %{run_cancel: {:cancelled, %ActionRun{status: :cancelled} = cancelled}}} =
               Ecto.Multi.new()
               |> Runs.cancel_run_in_multi(run.id, "composed cancel")
               |> Repo.commit_multi()

      assert cancelled.id == run.id
      assert cancelled.reason_text == "composed cancel"
      assert Runs.peek_run_by_id(run.id).status == :cancelled
    end

    test "refuses to terminally cancel work already dispatched to a runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      sent = Fixtures.Runs.put_status(run, :sent)

      assert {:error, :run_already_dispatched} =
               Ecto.Multi.new()
               |> Runs.cancel_run_in_multi(sent.id, "too late")
               |> Repo.commit_multi()

      assert Runs.peek_run_by_id(run.id).status == :sent
    end

    test "an already-terminal run yields {:noop, run} — no transition, no audit row" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Fixtures.Runs.finish(run, %{"status" => "success"})

      assert {:ok, %{run_cancel: {:noop, %ActionRun{status: :success}}, run_cancel_audit: nil}} =
               Ecto.Multi.new()
               |> Runs.cancel_run_in_multi(finished.id, "too late")
               |> Repo.commit_multi()

      assert Runs.peek_run_by_id(run.id).status == :success
    end

    test "a missing run row yields :no_run" do
      assert {:ok, %{run_cancel: :no_run}} =
               Ecto.Multi.new()
               |> Runs.cancel_run_in_multi(Ecto.UUID.generate(), "gone")
               |> Repo.commit_multi()
    end
  end

  describe "mark_errored/2" do
    test "transitions to :error with the provided message + finished_at" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      run = Runs.peek_run_by_id(run.id)

      assert {:ok, %ActionRun{status: :error, error_message: msg, finished_at: %DateTime{}}} =
               Runs.mark_errored(run, "runner was disconnected")

      assert msg =~ "disconnected"
    end
  end

  describe "handle_runner_error/3" do
    test "returns a cap-refused dispatch to pending and redelivers it after a slot opens" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      Runners.subscribe_runner_transport(runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      old_queued_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      run = run |> Ecto.Changeset.change(queued_at: old_queued_at) |> Repo.update!()

      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, _generation, %{"request_id" => request_id}}, 500
      assert request_id == run.request_id

      sent = Runs.peek_run_by_id(run.id)

      assert {:ok, %ActionRun{status: :pending, sent_at: nil} = pending} =
               Runs.handle_runner_error(account.id, runner.id, %{
                 "code" => "concurrency_cap_reached",
                 "request_id" => run.request_id
               })

      assert pending.runner_connection_generation == nil
      assert DateTime.compare(pending.queued_at, sent.queued_at) == :gt
      refute ActionRun.terminal?(pending.status)

      assert :ok = Runs.dispatch_queued_for_runner(runner.id)
      assert_receive {:cloud_to_runner, _generation, %{"request_id" => ^request_id}}, 500

      redelivered = Runs.peek_run_by_id(run.id)
      assert redelivered.status == :sent
      assert DateTime.compare(redelivered.sent_at, sent.sent_at) == :gt
      refute redelivered.status == :error
    end

    test "does not correlate a cap refusal outside the runner's account" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      other_account = Fixtures.Accounts.create_account()
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.dispatch_to_runner(run)

      assert {:error, :unknown_request_id} =
               Runs.handle_runner_error(other_account.id, runner.id, %{
                 "code" => "concurrency_cap_reached",
                 "request_id" => run.request_id
               })

      assert Runs.peek_run_by_id(run.id).status == :sent
    end
  end

  describe "runner-result finalization" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "walks the valid sequence pending → sent → running → success", %{
      account: account,
      runner: runner
    } do
      # The valid production path pending → sent → running → success, each
      # transition stamping its own timestamp. The terminal flip is the only
      # one that's final.
      _ = Fixtures.Catalog.create_action(runner: runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert run.status == :pending

      assert :ok = Runs.dispatch_to_runner(run)
      sent = Repo.reload!(run)
      assert sent.status == :sent
      assert %DateTime{} = sent.sent_at

      {:ok, running} =
        Runs.mark_started_from_connection(
          account.id,
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          run.request_id
        )

      assert running.status == :running
      assert %DateTime{} = running.started_at

      {:ok, finished} =
        Fixtures.Runs.finish(running, %{
          "status" => "success",
          "duration_ms" => 4,
          "truncated_stdout" => true,
          "truncated_stderr" => true
        })

      assert finished.status == :success
      assert %DateTime{} = finished.finished_at
      assert finished.stdout_truncated
      assert finished.stderr_truncated
      assert ActionRun.terminal?(:success)
    end

    test "marks output complete when every unique progress chunk arrived", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 stream: "stdout",
                 payload: %{"chunk" => "ok\n"}
               })

      assert {:error, :duplicate_event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 stream: "stdout",
                 payload: %{"chunk" => "ok\n"}
               })

      payload = %{
        "status" => "success",
        "progress_chunks" => 1,
        "emitted_stdout_bytes" => 3,
        "emitted_stderr_bytes" => 0
      }

      assert {:ok, %ActionRun{output_complete: true}} = Fixtures.Runs.finish(run, payload)
    end

    test "keeps later output but marks it incomplete when progress was dropped", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 2,
                 kind: "progress",
                 stream: "stdout",
                 payload: %{"chunk" => "later chunk"}
               })

      payload = %{
        "status" => "success",
        "progress_chunks" => 2,
        "dropped_progress_chunks" => 1,
        "emitted_stdout_bytes" => 11,
        "emitted_stderr_bytes" => 0
      }

      assert {:ok, %ActionRun{output_complete: false}} = Fixtures.Runs.finish(run, payload)
    end

    test "a terminal run is final — later transitions no-op and never re-open it", %{
      account: account,
      runner: runner
    } do
      # once terminal, every further transition is a benign no-op that keeps the
      # run final (the locked re-read in transition/3 treats an already-terminal
      # row as `:already_terminal`).
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Fixtures.Runs.finish(run, %{"status" => "success"})

      assert finished.status == :success

      # A duplicate terminal result is an idempotent no-op.
      assert {:ok, _} = Fixtures.Runs.finish(finished, %{"status" => "failed"})
      assert Runs.peek_run_by_id(run.id).status == :success
    end

    test "preserves exact runner terminal outcomes", %{account: account, runner: runner} do
      for {wire_status, stored_status} <- [
            {"cancelled", :cancelled},
            {"timed_out", :timed_out},
            {"blocked_by_admission", :refused}
          ] do
        {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

        {:ok, finished} =
          Fixtures.Runs.finish(run, %{"status" => wire_status})

        assert finished.status == stored_status
      end
    end

    test "a failed result writes error_message only; reason_text stays nil", %{
      account: account,
      runner: runner
    } do
      {:ok, run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{reason: "operator why"}))

      {:ok, finished} =
        Fixtures.Runs.finish(run, %{
          "status" => "failed",
          "error" => "exit status 1"
        })

      assert finished.error_message == "exit status 1"
      assert finished.reason == "operator why"
      assert is_nil(finished.reason_text)
    end

    test "a next-wave step that fails to dispatch writes a runbook.step_dispatch_failed audit row" do
      # Regression: a continuation that can't dispatch (denied / out-of-scope /
      # unknown action) used to stop the runbook with NO audit event and NO
      # signal — operators couldn't see WHY it halted. The failure must leave
      # a trace. Six steps: the first wave of five is advertised + allowed,
      # step 6 names an action no runner advertises, so its wave-2 dispatch
      # returns {:error, :action_not_found}.
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      target = %{"runner_id" => [runner.id]}

      good_steps =
        for n <- 1..5 do
          %{
            "id" => "step#{n}",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          }
        end

      steps =
        good_steps ++
          [
            %{
              "id" => "step6",
              "action_id" => "linux.missing",
              "args" => %{},
              "runner_selector" => target
            }
          ]

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "six-step",
            "name" => "six-step",
            "slug" => "six-step",
            "definition" => %{"steps" => steps}
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, %{execution_id: execution_id, runs: wave1, errors: []}} =
        Emisar.Runbooks.dispatch_runbook(runbook, "ship it", subject)

      assert length(wave1) == 5

      # The wave finishes successfully → fires the (doomed) step 6 dispatch.
      Enum.each(wave1, fn run ->
        {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 5})
      end)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      failed = Enum.find(events, &(&1.event_type == "runbook.step_dispatch_failed"))

      assert failed, "expected a runbook.step_dispatch_failed audit row"
      assert failed.target_kind == "runbook"
      assert failed.target_id == runbook.id
      assert failed.payload["runbook_id"] == runbook.id
      assert failed.payload["runbook_execution_id"] == execution_id
      assert failed.payload["runbook_step_id"] == "step6"
      assert failed.payload["runner_id"] == runner.id
      assert failed.payload["reason"] =~ "action_not_found"
    end

    test "a successful continuation writes no failure audit row" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "two-step-ok",
            "name" => "two-step-ok",
            "slug" => "two-step-ok",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "step1",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"runner_id" => [runner.id]}
                },
                %{
                  "id" => "step2",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"runner_id" => [runner.id]}
                }
              ]
            }
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, %{runs: runs, errors: []}} =
        Emisar.Runbooks.dispatch_runbook(runbook, "ship it", subject)

      Enum.each(runs, fn run ->
        {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 5})
      end)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      refute Enum.any?(events, &(&1.event_type == "runbook.step_dispatch_failed"))
    end
  end

  describe "append_event/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "broadcasts + inserts", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Emisar.Runs.subscribe_run(run.account_id, run.id)

      assert {:ok, %RunEvent{seq: 1, kind: :progress}} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "hi"}})

      assert_receive {:run_event, %RunEvent{seq: 1}}, 500
    end

    test "a re-sent (run_id, seq) is classified :duplicate_event, not a changeset", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %RunEvent{seq: 1}} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}})

      # The runner re-sends the same chunk (its retry) — a benign duplicate the
      # socket drops quietly, distinct from a malformed event it must log.
      assert {:error, :duplicate_event} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}})
    end

    test "the first progress chunk flips a :sent run to :running", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      sent = Fixtures.Runs.put_status(run, :sent)

      assert {:ok, %RunEvent{seq: 1}} =
               Runs.append_event(sent, %{seq: 1, kind: "progress", payload: %{"line" => "go"}})

      assert Runs.peek_run_by_id(run.id).status == :running
    end

    test "rejects a chunk for an already-terminal run — no persist, no resurrection", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Fixtures.Runs.finish(run, %{"status" => "success"})

      assert finished.status == :success

      # A late chunk (arriving after the run settled) is the hostile-flood
      # vector: it's refused under the row lock before any insert, so a terminal
      # run can never accrue unbounded events or be resurrected.
      assert {:error, :run_terminal} =
               Runs.append_event(finished, %{
                 seq: 99,
                 kind: "progress",
                 payload: %{"chunk" => "x"}
               })

      assert Runs.peek_run_by_id(run.id).status == :success
      refute Repo.exists?(RunEvent)
    end

    test "rejects a chunk whose seq is not positive", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:error, changeset} =
               Runs.append_event(run, %{seq: 0, kind: "progress", payload: %{"chunk" => "x"}})

      assert "must be greater than 0" in errors_on(changeset).seq
      refute Repo.exists?(RunEvent)
    end

    test "charges each accepted chunk against the run's durable budget", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "aa"}})
      {:ok, _} = Runs.append_event(run, %{seq: 2, kind: "progress", payload: %{"chunk" => "bb"}})

      reloaded = Runs.peek_run_by_id(run.id)
      assert reloaded.progress_event_count == 2
      assert reloaded.progress_byte_count > 0
    end

    test "accepts the last chunk within the event-count budget and refuses the next", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      # One under the ceiling, so the next append lands exactly on it.
      Fixtures.Runs.charge_progress_budget(run, events: 49_999)

      assert {:ok, %RunEvent{seq: 1}} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})

      # The 50_000th accepted event spent the budget; the 50_001st is refused.
      assert {:error, :progress_budget_exceeded} =
               Runs.append_event(run, %{seq: 2, kind: "progress", payload: %{"chunk" => "b"}})
    end

    test "refuses a chunk that would exceed the per-run byte budget", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      # Sitting on the byte ceiling, so any non-empty chunk tips it over.
      Fixtures.Runs.charge_progress_budget(run, bytes: 67_108_864)

      assert {:error, :progress_budget_exceeded} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "x"}})

      refute Repo.exists?(RunEvent)
    end

    test "append_event/2 with an unknown run id returns :unknown_run" do
      assert {:error, :unknown_run} =
               Runs.append_event(Repo.generate_id(), %{seq: 1, kind: "progress", payload: %{}})
    end
  end

  describe "append_event_from_connection/6" do
    test "accepts the current owner across reconnects and rejects a superseded lease" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, sent} =
        run
        |> Ecto.Changeset.change(
          status: :sent,
          runner_connection_generation: runner.connection_generation
        )
        |> Repo.update()

      assert {:ok, %RunEvent{seq: 1}} =
               Runs.append_event_from_connection(
                 sent.id,
                 %{seq: 1, kind: "progress", payload: %{"line" => "owned"}},
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id
               )

      successor = reconnect_runner(runner)

      assert {:ok, %RunEvent{seq: 2}} =
               Runs.append_event_from_connection(
                 sent.id,
                 %{seq: 2, kind: "progress", payload: %{"line" => "resumed"}},
                 account.id,
                 runner.id,
                 successor.connection_generation,
                 successor.connection_lease_id
               )

      assert {:error, :connection_superseded} =
               Runs.append_event_from_connection(
                 sent.id,
                 %{seq: 3, kind: "progress", payload: %{"line" => "stale"}},
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id
               )

      assert Repo.reload!(sent).progress_event_count == 2
    end
  end

  describe "peek_run_by_id/1" do
    test "returns the run struct when it exists" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert %ActionRun{id: id} = Runs.peek_run_by_id(run.id)
      assert id == run.id
    end

    test "returns nil for a missing run (nil is the meaningful no-row state)" do
      assert is_nil(Runs.peek_run_by_id(Ecto.UUID.generate()))
    end
  end

  describe "fetch_run!/1" do
    test "returns the approval-gated run" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert %ActionRun{id: id} = Runs.fetch_run!(run.id)
      assert id == run.id
    end

    test "raises when the run is missing (a broken FK invariant, not a caller state)" do
      assert_raise Ecto.NoResultsError, fn -> Runs.fetch_run!(Ecto.UUID.generate()) end
    end
  end

  describe "fetch_and_lock_pending_approval_run/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "returns the run while it is still :pending_approval (locked in the caller's txn)", %{
      account: account,
      runner: runner
    } do
      {:ok, parked} =
        Runs.create_run(base_attrs(account.id, runner.id, %{status: :pending_approval}))

      assert {:ok, %{locked: {:ok, %ActionRun{id: id, status: :pending_approval}}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 {:ok, Runs.fetch_and_lock_pending_approval_run(repo, parked.id)}
               end)
               |> Repo.transaction()

      assert id == parked.id
    end

    test "refuses a run that is no longer pending approval", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      sent = Fixtures.Runs.put_status(run, :sent)

      assert {:ok, %{locked: {:error, :run_not_pending_approval}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 {:ok, Runs.fetch_and_lock_pending_approval_run(repo, sent.id)}
               end)
               |> Repo.transaction()
    end

    test "is :not_found for a missing run id", %{account: _account} do
      assert {:ok, %{locked: {:error, :not_found}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 {:ok, Runs.fetch_and_lock_pending_approval_run(repo, Ecto.UUID.generate())}
               end)
               |> Repo.transaction()
    end
  end

  describe "release_pending_approval_run/2" do
    test "releases a locked approval run with a fresh dispatch timestamp" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, parked} =
        Runs.create_run(base_attrs(account.id, runner.id, %{status: :pending_approval}))

      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      {:ok, parked} = Repo.update(Ecto.Changeset.change(parked, queued_at: past))

      assert {:ok, %{released: %ActionRun{status: :pending, queued_at: queued_at}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 Runs.fetch_and_lock_pending_approval_run(repo, parked.id)
               end)
               |> Ecto.Multi.run(:released, fn repo, %{locked: run} ->
                 Runs.release_pending_approval_run(run, repo: repo)
               end)
               |> Repo.transaction()

      assert DateTime.compare(queued_at, past) == :gt
    end
  end

  describe "runner result payloads" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "persists local audit failure without changing the action outcome", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok,
              %ActionRun{
                status: :success,
                event_id: nil,
                local_audit_failed: true
              }} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "exit_code" => 0,
                 "local_audit_failed" => true
               })

      event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.payload["run_id"] == run.id and &1.event_type == "action_run.success"))

      assert event.payload["local_audit_failed"]
    end

    test "persists executed_command and carries it into the audit event", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok,
              %ActionRun{
                status: :success,
                executed_command: "uptime -p",
                executed_command_truncated: true
              }} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "exit_code" => 0,
                 "executed_command" => "uptime -p",
                 "executed_command_truncated" => true
               })

      # The terminal run audit event records what actually ran.
      event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.payload["run_id"] == run.id and &1.event_type == "action_run.success"))

      assert event.payload["executed_command"] == "uptime -p"
      assert event.payload["executed_command_truncated"]
    end

    test "a refusal's human `error` sentence is surfaced as error_message, not the terse code", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      # A signature/pack refusal carries both: a terse `reason` code and a human
      # `error` sentence. The operator must see the sentence.
      {:ok, finished} =
        Fixtures.Runs.finish(run, %{
          "status" => "signature_invalid",
          "reason" => "stale",
          "error" => "refused: issued_at is outside the freshness window"
        })

      assert finished.error_message == "refused: issued_at is outside the freshness window"
      # …and the run lands in the distinct `:refused` terminal state, not `:failed`.
      assert finished.status == :refused
    end

    test "signature_invalid + pack_hash_mismatch both map to :refused, audited as action_run.refused",
         %{account: account, runner: runner} do
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      for wire <- ["signature_invalid", "pack_hash_mismatch"] do
        {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

        {:ok, finished} =
          Fixtures.Runs.finish(run, %{"status" => wire})

        assert finished.status == :refused
        assert Emisar.Runs.ActionRun.terminal?(:refused)
      end

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])
      refused = Enum.filter(events, &(&1.event_type == "action_run.refused"))
      assert length(refused) == 2
    end

    test "an ordinary failure with no `error` falls back to the reason code", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Fixtures.Runs.finish(run, %{
          "status" => "failed",
          "reason" => "exit status 1"
        })

      assert finished.error_message == "exit status 1"
    end

    test "an unrecognized result status defaults to :failed", %{account: account, runner: runner} do
      # an unrecognized result-status string defaults to :failed rather than
      # crashing or inventing a status (the mapping table's fail-safe fallback;
      # a compromised/buggy runner can't mint a new state).
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :failed}} =
               Fixtures.Runs.finish(run, %{"status" => "totally-made-up-status"})
    end
  end

  describe "finalize_from_connection/5" do
    test "accepts a result from the current owner after reconnect" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, sent} =
        run
        |> Ecto.Changeset.change(
          status: :sent,
          runner_connection_generation: runner.connection_generation
        )
        |> Repo.update()

      successor = reconnect_runner(runner)

      assert {:error, :connection_superseded} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{"request_id" => sent.request_id, "status" => "success"}
               )

      assert Repo.reload!(sent).status == :sent

      assert {:ok, %ActionRun{status: :success}} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 successor.connection_generation,
                 successor.connection_lease_id,
                 %{"request_id" => sent.request_id, "status" => "success"}
               )
    end

    test "rejects an unknown request id" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:error, :unknown_request_id} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{"request_id" => "req_does_not_exist", "status" => "success"}
               )
    end

    test "a runner cannot finalize another runner's run in the same account" do
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner_a.id))

      assert {:error, :unknown_request_id} =
               Runs.finalize_from_connection(
                 account.id,
                 runner_b.id,
                 runner_b.connection_generation,
                 runner_b.connection_lease_id,
                 %{"request_id" => run.request_id, "status" => "success"}
               )
    end

    test "requires a request id" do
      assert {:error, :missing_request_id} =
               Runs.finalize_from_connection("account", "runner", 1, "lease", %{})
    end
  end

  describe "list_events_for_run/3" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "returns seq-ordered events and refuses cross-account", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}})
      {:ok, _} = Runs.append_event(run, %{seq: 2, kind: "progress", payload: %{"line" => "b"}})

      assert {:ok, [%RunEvent{seq: 1}, %RunEvent{seq: 2}], _} =
               Runs.list_events_for_run(run.id, subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Runs.list_events_for_run(run.id, subject_b)
    end
  end

  describe "list_recent_events_for_run/3" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "returns the chronological tail and refuses cross-account", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      for seq <- 1..5 do
        {:ok, _} =
          Runs.append_event(run, %{
            seq: seq,
            kind: "progress",
            payload: %{"chunk" => "line#{seq}"}
          })
      end

      # A non-output event must not crowd out an output line in the preview.
      {:ok, _} = Runs.append_event(run, %{seq: 6, kind: "transition", payload: %{}})

      # Last 3 progress chunks, oldest→newest (the DESC+limit page reversed).
      assert {:ok, [%RunEvent{seq: 3}, %RunEvent{seq: 4}, %RunEvent{seq: 5}]} =
               Runs.list_recent_events_for_run(run.id, 3, subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Runs.list_recent_events_for_run(run.id, 3, subject_b)
    end
  end

  describe "subscribe_account_runs/1" do
    test "the subscriber receives the account's run create/transition feed" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert :ok = Runs.subscribe_account_runs(account.id)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert_receive {:run_updated, %ActionRun{id: id}}, 500
      assert id == run.id
    end

    test "a subscriber to account A does not receive account B's run feed (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

      assert :ok = Runs.subscribe_account_runs(account_a.id)

      {:ok, _run_b} = Runs.create_run(base_attrs(account_b.id, runner_b.id))
      refute_receive {:run_updated, _}, 200
    end
  end

  describe "unsubscribe_account_runs/1" do
    test "stops delivery from the account feed" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert :ok = Runs.subscribe_account_runs(account.id)
      assert :ok = Runs.unsubscribe_account_runs(account.id)
      assert {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))
      refute_receive {:run_updated, _}, 100
    end
  end

  describe "subscribe_run/2" do
    test "the subscriber receives that run's transitions and progress chunks" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.subscribe_run(run.account_id, run.id)

      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "x"}})
      assert_receive {:run_event, %RunEvent{seq: 1}}, 500

      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:run_updated, %ActionRun{status: :sent}}, 500
    end

    test "a subscriber to one run does not receive another run's updates (per-run topic)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, watched} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, other} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.subscribe_run(watched.account_id, watched.id)

      {:ok, _} = Runs.append_event(other, %{seq: 1, kind: "progress", payload: %{"line" => "x"}})
      refute_receive {:run_event, _}, 200
    end
  end

  describe "unsubscribe_run/2" do
    test "after unsubscribing, the caller stops receiving that run's updates" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      :ok = Runs.subscribe_run(run.account_id, run.id)
      assert :ok = Runs.unsubscribe_run(run.account_id, run.id)

      assert :ok = Runs.dispatch_to_runner(run)
      refute_receive {:run_updated, _}, 200
    end
  end

  describe "broadcast_cancelled_run/1" do
    test "broadcasts the run for the {:cancelled, run} shape" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Runs.subscribe_account_runs(account.id)

      assert :ok = Runs.broadcast_cancelled_run({:cancelled, run})

      assert_receive {:run_updated, %ActionRun{id: id, runner: %Emisar.Runners.Runner{}}}, 500
      assert id == run.id
    end

    test "is a no-op for the :noop / :no_run shapes (nothing to announce)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Runs.subscribe_account_runs(account.id)

      assert :ok = Runs.broadcast_cancelled_run({:noop, run})
      assert :ok = Runs.broadcast_cancelled_run(:no_run)
      refute_receive {:run_updated, _}, 200
    end
  end

  describe "subject_can_view_runs?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert Runs.subject_can_view_runs?(viewer_subject)
      refute Runs.subject_can_view_runs?(billing_manager_subject)
    end
  end

  describe "subject_can_dispatch_run?/1" do
    test "is true for an owner and an operator (they hold dispatch_run)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Runs.subject_can_dispatch_run?(owner_subject)
      assert Runs.subject_can_dispatch_run?(operator_subject)
    end

    test "is false for a viewer" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Runs.subject_can_dispatch_run?(viewer_subject)
    end
  end

  describe "subject_can_cancel_run?/1" do
    test "is true for an owner and an operator (they hold cancel_run)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Runs.subject_can_cancel_run?(owner_subject)
      assert Runs.subject_can_cancel_run?(operator_subject)
    end

    test "is false for a viewer" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Runs.subject_can_cancel_run?(viewer_subject)
    end
  end

  describe "Authorizer.for_subject runner-scoping" do
    test "a runner subject's run reads are scoped to that runner, not account-wide" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      peer = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, mine} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _theirs} = Runs.create_run(base_attrs(account.id, peer.id))

      runner_subject = Emisar.Auth.Subject.for_runner(runner, account)

      ids =
        ActionRun.Query.all()
        |> Runs.Authorizer.for_subject(runner_subject)
        |> Repo.all()
        |> Enum.map(& &1.id)

      # A runner socket sees only its own runs, even within the account.
      assert ids == [mine.id]
    end

    test "an account-less / actor-less subject leaves the query unscoped (fallback)" do
      query = ActionRun.Query.all()
      assert Runs.Authorizer.for_subject(query, %Emisar.Auth.Subject{}) == query
    end
  end
end
