defmodule Emisar.RunsTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Approvals, Audit, Catalog, Fixtures}
  alias Emisar.{MCPOperations, Repo, RequestContext, Runners, Runs}
  alias Emisar.Runners.Presence
  alias Emisar.Runs.{ActionRun, RunEvent}

  defp base_attrs(account_id, runner_id, attrs \\ %{}) do
    initiator = Fixtures.Users.create_user()

    initiating_membership =
      Fixtures.Memberships.create_membership(
        account_id: account_id,
        user_id: initiator.id,
        role: "operator"
      )

    Map.merge(
      %{
        runner_id: runner_id,
        action_id: "linux.uptime",
        args: %{},
        reason: "test",
        source: "operator",
        account_id: account_id,
        requested_by_id: initiator.id,
        initiating_membership_id: initiating_membership.id
      },
      attrs
    )
  end

  defp no_permissions_subject(account) do
    Fixtures.Subjects.build_subject(account: account, role: :runner)
  end

  defp owner_subject_for(account) do
    user = Fixtures.Users.create_user()

    _membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    Fixtures.Subjects.subject_for(user, account, role: :owner)
  end

  defp reconnect_runner(runner) do
    assert {:ok, _} =
             Runners.disconnect_runner(
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
  @mcp_portal_origin "https://portal.example"

  describe "run_filters/0" do
    test "carries the Runs table's filters in panel order" do
      assert Enum.map(Runs.run_filters(), & &1.name) == [
               :status,
               :action_id,
               :runner_id,
               :source,
               :api_key_id,
               :requested_by_id,
               :runbook_id
             ]
    end
  end

  describe "terminal_status?/1" do
    test "classifies every status the schema defines" do
      terminal = [
        :success,
        :failed,
        :error,
        :validation_failed,
        :unknown_action,
        :cancelled,
        :timed_out,
        :refused,
        :denied
      ]

      in_flight = [:pending, :pending_approval, :sent, :running, :cancelling]

      for status <- terminal do
        assert Runs.terminal_status?(status), "expected #{status} to be terminal"
      end

      for status <- in_flight do
        refute Runs.terminal_status?(status), "expected #{status} to be non-terminal"
      end

      assert Enum.sort(terminal ++ in_flight) == Enum.sort(Ecto.Enum.values(ActionRun, :status))
    end

    test "a non-atom is never terminal" do
      refute Runs.terminal_status?(nil)
      refute Runs.terminal_status?("success")
    end
  end

  describe "run_outcome_facts/1" do
    test "gives every status its terminality" do
      terminal = %{
        pending: false,
        pending_approval: false,
        sent: false,
        running: false,
        cancelling: false,
        success: true,
        denied: true,
        failed: true,
        error: true,
        validation_failed: true,
        unknown_action: true,
        cancelled: true,
        timed_out: true,
        refused: true
      }

      assert Enum.sort(Map.keys(terminal)) == Enum.sort(Ecto.Enum.values(ActionRun, :status))

      for {status, terminal?} <- terminal do
        facts = Runs.run_outcome_facts(%ActionRun{status: status})

        assert facts.status == status
        assert facts.terminal? == terminal?, "expected #{status} terminal? to be #{terminal?}"
      end
    end

    test "carries exactly the outcome contract" do
      queued_at = ~U[2026-07-13 14:42:10.000000Z]
      run = %ActionRun{status: :sent, queued_at: queued_at, error_message: "runner detail"}

      assert Runs.run_outcome_facts(run) == %{
               status: :sent,
               terminal?: false,
               output_complete: nil,
               approval_pending?: false,
               dispatch_deadline_at: ~U[2026-07-13 14:52:10.000000Z],
               local_audit_failed?: false
             }
    end

    test "reports output completeness only once the run has settled" do
      completeness = fn status, complete? ->
        %ActionRun{status: status, output_complete: complete?}
        |> Runs.run_outcome_facts()
        |> Map.fetch!(:output_complete)
      end

      assert completeness.(:success, true) == true
      assert completeness.(:failed, false) == false
      assert completeness.(:running, true) == nil
      assert completeness.(:sent, false) == nil
    end

    test "flags only a run waiting on an approval decision" do
      assert Runs.run_outcome_facts(%ActionRun{status: :pending_approval}).approval_pending?
      refute Runs.run_outcome_facts(%ActionRun{status: :pending}).approval_pending?
      refute Runs.run_outcome_facts(%ActionRun{status: :cancelled}).approval_pending?
    end

    test "reports the local-audit warning without changing the outcome" do
      facts = Runs.run_outcome_facts(%ActionRun{status: :success, local_audit_failed: true})

      assert facts.local_audit_failed?
      assert facts.status == :success
      refute Runs.run_outcome_facts(%ActionRun{status: :success}).local_audit_failed?
    end

    test "dates a sent run's dispatch deadline ten minutes after it was queued" do
      queued_at = DateTime.utc_now()
      sent = Runs.run_outcome_facts(%ActionRun{status: :sent, queued_at: queued_at})

      assert sent.dispatch_deadline_at == DateTime.add(queued_at, 600, :second)
      assert Runs.run_outcome_facts(%ActionRun{status: :sent}).dispatch_deadline_at == nil

      for status <- Ecto.Enum.values(ActionRun, :status) -- [:sent] do
        facts = Runs.run_outcome_facts(%ActionRun{status: status, queued_at: queued_at})
        assert facts.dispatch_deadline_at == nil, "#{status} must not carry a dispatch deadline"
      end
    end

    test "never relays a recorded reason, policy reason, or runner message" do
      canary = "password=do-not-echo"

      runs = [
        %ActionRun{status: :failed, reason: canary},
        %ActionRun{status: :error, reason_text: canary},
        %ActionRun{status: :denied, policy_reason: canary},
        %ActionRun{status: :refused, error_message: canary},
        %ActionRun{status: :cancelled, reason_text: canary}
      ]

      for run <- runs do
        facts = Runs.run_outcome_facts(run)
        without_text = Runs.run_outcome_facts(%ActionRun{status: run.status})

        refute inspect(facts) =~ canary, "#{run.status} leaked untrusted text"
        # The facts are decided by status alone, so a run carrying untrusted
        # text produces exactly the same outcome as one without it.
        assert facts == without_text
      end
    end

    test "never lets cancellation text classify the model-facing outcome" do
      for reason_text <- ["approval denied", "approval denied: password=do-not-echo"] do
        facts = Runs.run_outcome_facts(%ActionRun{status: :cancelled, reason_text: reason_text})

        assert facts.status == :cancelled
        refute inspect(facts) =~ reason_text
      end
    end
  end

  describe "run_who_via/1" do
    test "names an operator through only the run account's initiating membership" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      requester = Fixtures.Users.create_user(full_name: "Global Name")

      local_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "operator"
        )

      other_membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: requester.id,
          role: "operator"
        )

      _local_membership =
        Fixtures.Memberships.sync_display_name(local_membership, "Local Directory Name")

      _other_membership =
        Fixtures.Memberships.sync_display_name(other_membership, "Foreign Directory Name")

      attrs = %{
        requested_by_id: requester.id,
        initiating_membership_id: local_membership.id
      }

      assert {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id, attrs))
      assert {:ok, [run], _metadata} = Runs.list_runs(subject, preload: [:attribution])
      assert Runs.run_who_via(run) == {"Local Directory Name", nil}

      foreign_run = %ActionRun{
        account_id: account.id,
        initiating_membership_id: other_membership.id,
        source: :operator,
        requested_by: %{requester | memberships: [other_membership]}
      }

      assert Runs.run_who_via(foreign_run) == {requester.email, nil}
    end

    test "names an MCP key owner, then degrades deleted attribution safely" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      key_owner = Fixtures.Users.create_user(full_name: "Global Key Owner")

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: key_owner.id,
          role: "owner"
        )

      membership = Fixtures.Memberships.sync_display_name(membership, "Local Key Owner")

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: account.id,
          created_by_id: key_owner.id,
          name: "Claude Code"
        )

      attrs = %{
        source: "mcp",
        requested_by_id: nil,
        api_key_id: key.id,
        initiating_membership_id: membership.id
      }

      assert {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id, attrs))
      assert {:ok, [run], _metadata} = Runs.list_runs(subject, preload: [:attribution])
      assert Runs.run_who_via(run) == {"Local Key Owner", "Claude Code"}

      _membership = Fixtures.Memberships.mark_membership_as_deleted(membership)

      assert {:ok, [former], _metadata} = Runs.list_runs(subject, preload: [:attribution])
      assert Runs.run_who_via(former) == {key_owner.email, "Claude Code"}

      _user = Fixtures.Users.mark_user_as_deleted(key_owner)

      assert {:ok, [deleted], _metadata} = Runs.list_runs(subject, preload: [:attribution])
      assert Runs.run_who_via(deleted) == {nil, "Claude Code"}
    end

    test "does not reinterpret unloaded or legacy associations" do
      key = %ApiKeys.ApiKey{name: "Claude Code"}
      unloaded = %ActionRun{source: :mcp, api_key: key}
      legacy = %ActionRun{source: :operator, requested_by: nil}

      assert Runs.run_who_via(unloaded) == {nil, "Claude Code"}
      assert Runs.run_who_via(legacy) == {nil, nil}
    end
  end

  describe "client_version/1" do
    test "returns only a nonblank snapshotted version" do
      assert Runs.client_version(%ActionRun{client_info: %{"version" => "1.2.3"}}) == "1.2.3"
      assert Runs.client_version(%ActionRun{client_info: %{}}) == nil
      assert Runs.client_version(%ActionRun{client_info: %{"version" => ""}}) == nil
    end
  end

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

    test "counts the filtered feed without its rendering joins" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))
      test_pid = self()
      handler = {__MODULE__, test_pid, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:emisar, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:runs_repo_query, self(), metadata.query})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, [_listed], %{count: 1}} =
               Runs.list_runs(subject,
                 preload: [:runner, :attribution],
                 filter: [runner_id: runner.id]
               )

      count_sql =
        test_pid
        |> drain_runs_queries()
        |> Enum.find(&(String.trim(&1) =~ ~r/^SELECT count\(/i))

      assert count_sql
      refute String.downcase(count_sql) =~ " join "
      assert count_sql =~ ~s|"runner_id"|
    end

    test "preloads only the requester's membership in the run account" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      requester = Fixtures.Users.create_user(full_name: "Maya Chen")

      local_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: requester.id,
          role: "operator"
        )

      other_membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: requester.id,
          role: "operator"
        )

      local_membership =
        Fixtures.Memberships.sync_display_name(local_membership, "Maya C. (Contractor)")

      _other_membership =
        Fixtures.Memberships.sync_display_name(other_membership, "Maya Chen (Employee)")

      attrs = %{
        requested_by_id: requester.id,
        initiating_membership_id: local_membership.id
      }

      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id, attrs))

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, preload: [:requested_by])
      assert Enum.map(listed.requested_by.memberships, & &1.id) == [local_membership.id]
    end

    test "preloads the API key owner's membership in the run account" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      key_owner = Fixtures.Users.create_user(full_name: "Maya Chen")

      local_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: key_owner.id,
          role: "owner"
        )

      other_membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: key_owner.id,
          role: "operator"
        )

      local_membership =
        Fixtures.Memberships.sync_display_name(local_membership, "Maya C. (Contractor)")

      _other_membership =
        Fixtures.Memberships.sync_display_name(other_membership, "Maya Chen (Employee)")

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: key_owner.id)

      {:ok, _run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            source: "mcp",
            requested_by_id: nil,
            api_key_id: key.id,
            initiating_membership_id: local_membership.id
          })
        )

      assert {:ok, [listed], _meta} = Runs.list_runs(subject, preload: [:api_key])
      assert listed.api_key.created_by.id == key_owner.id
      assert listed.api_key.created_by_membership.id == local_membership.id
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

      assert Runs.list_runs(subject) == {:error, :unauthorized}
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

    # These four filters are deep-link entry points (a runner's "View all runs",
    # an agent's "View activity"), so a mangled URL reaches them. Their options are
    # filled in at render time and never validated, so the declared TYPE is the
    # only boundary: a non-UUID must come back as a bad filter, not as an
    # `Ecto.Query.CastError` 500 from a `binary_id` comparison.
    for name <- [:runner_id, :api_key_id, :requested_by_id, :runbook_id] do
      test "the #{name} filter rejects a non-UUID instead of raising" do
        {_user, _account, subject} = Fixtures.Subjects.owner_subject()

        assert {:error, {:invalid_type, metadata}} =
                 Runs.list_runs(subject, filter: [{unquote(name), "zzz"}])

        assert metadata[:name] == unquote(name)
      end
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
      assert Runs.list_runs_by_runbook_execution(execution_id, other_subject) == {:ok, []}

      assert Runs.list_runs_by_runbook_execution(
               execution_id,
               no_permissions_subject(account)
             ) == {:error, :unauthorized}
    end
  end

  describe "list_latest_runbook_attempts/2" do
    test "returns an empty scoped projection and enforces view permission" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      execution_id = Ecto.UUID.generate()

      assert Runs.list_latest_runbook_attempts(execution_id, subject) == {:ok, []}

      assert Runs.list_latest_runbook_attempts(
               execution_id,
               no_permissions_subject(account)
             ) == {:error, :unauthorized}
    end
  end

  describe "list_run_operator_options/1" do
    test "returns the distinct dispatching operators, deduplicated" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      _membership = Fixtures.Memberships.sync_display_name(membership, "Local Operator")

      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: user.id}))
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: user.id}))
      # A run with no requesting user (an engine path) contributes no option.
      {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{requested_by_id: nil}))

      assert Runs.list_run_operator_options(subject) == {:ok, [{user.id, "Local Operator"}]}
    end

    test "a subject without view_runs permission is refused" do
      account = Fixtures.Accounts.create_account()
      subject = no_permissions_subject(account)

      assert Runs.list_run_operator_options(subject) == {:error, :unauthorized}
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

      assert Runs.list_run_runbook_options(subject) == {:error, :unauthorized}
    end
  end

  describe "list_recent_runs/2" do
    test "narrows by runner_id and action_id (composable)" do
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      subject = owner_subject_for(account)

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

    test "count: false skips the total while keeping the fixed limit" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      for _ <- 1..3, do: Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, runs, metadata} =
               Runs.list_recent_runs(subject, limit: 2, count: false)

      assert length(runs) == 2
      assert metadata.limit == 2
      assert metadata.count == nil
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
    test "keeps fixed-contract lineage history after current runner scope changes" do
      %{
        subject: subject,
        membership: membership,
        runners: [runner]
      } = mcp_fanout_fixture(["low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      facts = mcp_action_facts("op_134NN9NMDZ1T76NARWCKM5A0D6", [runner])
      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)

      {:ok, _operator_run} =
        Runs.create_run(base_attrs(subject.account.id, runner.id, %{source: "operator"}))

      assert {:ok, [listed], metadata} =
               Runs.list_recent_mcp_runs(%{scope: :own}, subject, limit: 15)

      assert listed.id == run.id
      assert metadata.count == nil

      {:ok, access} =
        Emisar.Accounts.RunnerAccess.restricted(["not-this-runner"], [])

      Fixtures.Memberships.force_runner_access(membership, access)

      assert {:ok, [listed_after_scope_change], _metadata} =
               Runs.list_recent_mcp_runs(%{scope: :own}, subject, limit: 15)

      assert listed_after_scope_change.id == run.id
    end

    test "rejects subjects without run-view permission" do
      account = Fixtures.Accounts.create_account()

      assert Runs.list_recent_mcp_runs(
               %{scope: :account},
               no_permissions_subject(account),
               limit: 15
             ) == {:error, :unauthorized}
    end

    test "filters by exact statuses without widening account or credential scope" do
      %{
        subject: subject,
        runners: [runner]
      } = mcp_fanout_fixture(["low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :created, [failed]} =
               Runs.dispatch_mcp_action(
                 mcp_action_facts("op_234NN9NMDZ1T76NARWCKM5A0D6", [runner]),
                 subject
               )

      assert {:ok, :created, [successful]} =
               Runs.dispatch_mcp_action(
                 mcp_action_facts("op_235NN9NMDZ1T76NARWCKM5A0D6", [runner]),
                 subject
               )

      failed |> Ecto.Changeset.change(status: :failed) |> Repo.update!()
      successful |> Ecto.Changeset.change(status: :success) |> Repo.update!()

      assert {:ok, [listed], _metadata} =
               Runs.list_recent_mcp_runs(%{scope: :own, statuses: [:failed]}, subject, limit: 15)

      assert listed.id == failed.id
    end
  end

  describe "summarize_runs/1" do
    test "classifies exactly the rows it is handed, in the windowed read's vocabulary" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      runs =
        for status <- ~w[success success refused denied cancelled running] do
          {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id, %{status: status}))
          run
        end

      # Refused is a failure; denied and cancelled are their own outcomes and
      # running is in flight, so only success + failed form the success_rate
      # denominator (2 of 3 = 67%).
      assert Runs.summarize_runs(runs) == %{
               total: 6,
               success: 2,
               failed: 1,
               success_rate: 67
             }
    end

    test "an empty list totals zero and has no rate yet" do
      assert Runs.summarize_runs([]) == %{total: 0, success: 0, failed: 0, success_rate: nil}
    end

    test "success_rate is nil while nothing has a result" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id, %{status: "running"}))

      assert Runs.summarize_runs([run]) == %{
               total: 1,
               success: 0,
               failed: 0,
               success_rate: nil
             }
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
          inserted_at: in_window,
          sent_at: if(status == :denied, do: nil, else: in_window)
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
      assert stats.dispatched == 3
      # Three in-window runs were actually sent to the one runner; the denied
      # row never exercised it.
      assert stats.distinct_runners == 1
    end

    test "excludes another account's runs (cross-account isolation)" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      from = ~U[2026-06-01 00:00:00.000000Z]
      to = ~U[2026-07-01 00:00:00.000000Z]
      at = ~U[2026-06-15 12:00:00.000000Z]

      Fixtures.Runs.create_run(
        account_id: account.id,
        status: :success,
        inserted_at: at,
        sent_at: at
      )

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
      assert Runs.fetch_run_by_id(run.id, subject_b) == {:error, :not_found}
      assert Runs.fetch_run_by_id("not-a-uuid", subject) == {:error, :not_found}
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

  describe "project_action_args/2" do
    test "keeps every number's exact spelling through JSON encoding" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          args_raw: ~s({"ratio":0.1234567890123456789,"scale":1e3})
        )

      assert {:ok, args} = Runs.project_action_args(run, subject)
      encoded = Jason.encode!(args)

      assert encoded =~ ~s("ratio":0.1234567890123456789)
      assert encoded =~ ~s("scale":1e3)
    end

    test "redacts every declared sensitive value and leaves the rest exactly as stored" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          args_raw: ~s({"path":"/etc/caddy","token":"secret-value","password":"hunter2"}),
          # `api_key` is declared but absent from the payload — a redaction
          # placeholder for an argument that was never sent would be a lie.
          sensitive_arg_names: ["token", "password", "api_key"]
        )

      assert Runs.project_action_args(run, subject) ==
               {:ok,
                %{
                  "path" => "/etc/caddy",
                  "token" => "[REDACTED]",
                  "password" => "[REDACTED]"
                }}
    end

    test "collapses malformed stored bytes to one reason that carries no payload" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      run = Fixtures.Runs.create_run(account_id: account.id)

      truncated = Fixtures.Runs.put_malformed_args_raw(run, ~s({"canary":"secret-value",}))
      duplicated = Fixtures.Runs.put_malformed_args_raw(run, ~s({"canary":1,"canary":2}))

      assert Runs.project_action_args(truncated, subject) == {:error, :invalid_action_args}
      # The parser names the offending key in its own error; the projection
      # must not pass that key — or the bytes around it — to a presenter.
      assert Runs.project_action_args(duplicated, subject) == {:error, :invalid_action_args}
    end

    test "rejects a same-account subject without view_runs before it decodes" do
      account = Fixtures.Accounts.create_account()
      run = Fixtures.Runs.create_run(account_id: account.id)
      malformed = Fixtures.Runs.put_malformed_args_raw(run, ~s({"canary":"secret-value",}))

      assert Runs.project_action_args(malformed, no_permissions_subject(account)) ==
               {:error, :unauthorized}
    end

    test "returns not_found for a run in another account before it decodes" do
      account = Fixtures.Accounts.create_account()
      run = Fixtures.Runs.create_run(account_id: account.id)
      malformed = Fixtures.Runs.put_malformed_args_raw(run, ~s({"canary":"secret-value",}))

      {_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runs.project_action_args(malformed, other_subject) == {:error, :not_found}
    end
  end

  describe "project_action_command/3" do
    # `linux.disk_usage` is `df -P -h {{ args.paths }}` with `paths` defaulting
    # to ["/"], so one published action exercises the default fill AND the
    # whole-expression array expansion the preview must match the runner on.
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      pack = Catalog.PublishedRegistry.get("linux-core")

      advertised_action =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "linux.disk_usage",
          pack_id: "linux-core",
          pack_hash: pack.content_hash
        )

      %{
        account: account,
        subject: subject,
        runner: runner,
        pack: pack,
        advertised_action: advertised_action
      }
    end

    test "renders the published template with the pack's declared default filled", %{
      account: account,
      subject: subject,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      assert Runs.project_action_command(run.id, advertised_action, subject) ==
               {:ok, "df -P -h /"}
    end

    test "masks every element of a value only the run recorded as sensitive", %{
      account: account,
      subject: subject,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      # The published pack does not declare `paths` sensitive, so the run's own
      # snapshot is the only thing keeping these out of the command line — and
      # the array expands into one token per element, each of which must be
      # masked on its own.
      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          args_raw: ~s({"paths":["/srv/alpha","/srv/beta"]}),
          sensitive_arg_names: ["paths"],
          expected_pack_hash: pack.content_hash
        )

      assert Runs.project_action_command(run.id, advertised_action, subject) ==
               {:ok, "df -P -h '[REDACTED]' '[REDACTED]'"}
    end

    test "is unauthorized for a same-account subject without view_runs", %{
      account: account,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      assert Runs.project_action_command(
               run.id,
               advertised_action,
               no_permissions_subject(account)
             ) ==
               {:error, :unauthorized}
    end

    test "is not_found for a run in another account", %{
      account: account,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      {_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runs.project_action_command(run.id, advertised_action, other_subject) ==
               {:error, :not_found}
    end

    test "freshly scopes the run to the account, not the member's current runner reach", %{
      account: account,
      subject: subject,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      membership = Repo.get!(Emisar.Accounts.Membership, subject.membership_id)
      {:ok, restricted} = Emisar.Accounts.RunnerAccess.restricted(["another-group"], [])
      Fixtures.Memberships.force_runner_access(membership, restricted)

      assert Runs.project_action_command(run.id, advertised_action, subject) ==
               {:ok, "df -P -h /"}
    end

    test "rejects an advertisement that is not this run's", %{
      account: account,
      subject: subject,
      runner: runner,
      pack: pack
    } do
      other_runner = Fixtures.Runners.create_runner(account_id: account.id)

      other_runner_action =
        Fixtures.Catalog.create_action(
          runner: other_runner,
          action_id: "linux.disk_usage",
          pack_id: "linux-core",
          pack_hash: pack.content_hash
        )

      other_action =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "linux.uptime",
          pack_id: "linux-core",
          pack_hash: pack.content_hash
        )

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      assert Runs.project_action_command(run.id, other_runner_action, subject) ==
               {:error, :action_mismatch}

      assert Runs.project_action_command(run.id, other_action, subject) ==
               {:error, :action_mismatch}
    end

    test "renders nothing when either half of the hash proof drifts", %{
      account: account,
      subject: subject,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      drifted_hash = "sha256:" <> String.duplicate("0", 64)

      drifted_run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: drifted_hash
        )

      assert Runs.project_action_command(drifted_run.id, advertised_action, subject) ==
               {:error, :no_command_preview}

      drifted_advertisement =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "linux.disk_usage",
          pack_id: "linux-core",
          pack_hash: drifted_hash
        )

      pinned_run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      assert Runs.project_action_command(pinned_run.id, drifted_advertisement, subject) ==
               {:error, :no_command_preview}
    end

    test "collapses malformed stored bytes to one reason that carries no payload", %{
      account: account,
      subject: subject,
      runner: runner,
      pack: pack,
      advertised_action: advertised_action
    } do
      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.disk_usage",
          expected_pack_hash: pack.content_hash
        )

      malformed = Fixtures.Runs.put_malformed_args_raw(run, ~s({"paths":"secret-value",}))

      assert Runs.project_action_command(malformed.id, advertised_action, subject) ==
               {:error, :invalid_action_args}
    end
  end

  describe "fetch_mcp_run_by_id/2" do
    test "returns the exact fixed-contract run across scope changes, but not across accounts" do
      %{
        subject: subject,
        membership: membership,
        runners: [runner]
      } = mcp_fanout_fixture(["low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      facts = mcp_action_facts("op_234NN9NMDZ1T76NARWCKM5A0D6", [runner])
      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)

      assert {:ok, fetched} = Runs.fetch_mcp_run_by_id(run.id, subject)
      assert fetched.id == run.id
      assert fetched.args_raw == "{}"
      assert fetched.pack_ref == @mcp_pack_ref
      assert is_binary(fetched.runner_ref)

      {_user, _account, foreign_subject} = Fixtures.Subjects.owner_subject()
      assert Runs.fetch_mcp_run_by_id(run.id, foreign_subject) == {:error, :not_found}

      {:ok, access} =
        Emisar.Accounts.RunnerAccess.restricted(["not-this-runner"], [])

      Fixtures.Memberships.force_runner_access(membership, access)

      assert {:ok, fetched_after_scope_change} = Runs.fetch_mcp_run_by_id(run.id, subject)
      assert fetched_after_scope_change.id == run.id
      assert Runs.fetch_mcp_run_by_id("not-a-uuid", subject) == {:error, :not_found}
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
      assert Runs.fetch_run_by_request_id_for_runner(run.request_id, other_runner.id) ==
               {:error, :not_found}
    end

    test "an unknown request_id is :not_found" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runs.fetch_run_by_request_id_for_runner("req_nope", runner.id) ==
               {:error, :not_found}
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

      assert errors_on(changeset).args_raw == ["is too large (max 32768 bytes)"]
    end

    # Signed audit state is minted by exactly one path — the preflighted MCP
    # fan-out — so this seam refuses the raw envelope and the carrier alike
    # rather than letting another domain caller mint one.
    test "refuses any attestation", %{account: account, runner: runner} do
      signed = Fixtures.Runs.signed_attestation()

      for claimed <- [signed.envelope, signed.attestation] do
        attrs = base_attrs(account.id, runner.id, %{attestation: claimed})

        assert {:error, changeset} = Runs.create_run(attrs)
        assert "must be a validated attestation" in errors_on(changeset).attestation
      end

      refute Repo.one(ActionRun)
      refute Repo.one(Audit.Event)
    end

    test "broadcasts the new run on the account topic (fresh insert only)", %{
      account: account,
      runner: runner
    } do
      Emisar.Runs.subscribe_account_runs(account.id)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert_receive {:run_updated, id}, 500
      assert id == run.id
    end
  end

  describe "dispatch_run/2" do
    test "allow policy returns {:ok, :running, run} and delivers to runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

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

    test "snapshots whether the trusted action requires structured output" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      _ =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "linux.uptime",
          risk: "low",
          output_schema: %{"type" => "object"}
        )

      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

      assert {:ok, :running, %ActionRun{structured_output_expected: true} = run} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      assert run.output_schema_snapshot == %{"type" => "object"}
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

      assert Runs.dispatch_run(base_attrs(account.id, runner.id), subject) ==
               {:error, :unauthorized}
    end

    test "an MCP key dispatches normally — its reach is the minter's scope + Policy" do
      # The key carries no per-key scope: a minter with explicit all-runner access
      # plus a permissive policy means the api-key subject dispatches.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, :running, %ActionRun{}} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "a stale subject cannot dispatch after its account is disabled" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert Runs.dispatch_run(base_attrs(account.id, runner.id), subject) ==
               {:error, :runner_not_found}

      refute_receive {:cloud_to_runner, _generation, _message}, 100
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
      policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      run_events = Enum.filter(events, &(&1.payload["run_id"] == run.id))
      types = Enum.map(run_events, & &1.event_type)

      # The terminal outcome ONLY — none of the intermediate lifecycle noise
      # (pending/sent/running) and NO policy.evaluated row: the audit-logging diet
      # (#1) dropped it because the allow decision + matched rules already live on
      # the ActionRun itself.
      assert Enum.sort(types) == ["action_run.success"]
      refute "action_run.pending" in types
      refute "action_run.sent" in types
      refute "action_run.running" in types
      refute "policy.evaluated" in types

      [success] = Enum.filter(run_events, &(&1.event_type == "action_run.success"))

      assert Map.take(success.payload, ~w[
               dispatch_reason policy_id policy_decision policy_reason policy_version matched_rules
             ]) == %{
               "dispatch_reason" => "test",
               "policy_id" => policy.id,
               "policy_decision" => "allow",
               "policy_reason" => run.policy_reason,
               "policy_version" => policy.vsn,
               "matched_rules" => []
             }

      # The allow decision survives on the run row and terminal receipt.
      assert run.policy_decision == "allow"
    end

    test "stamps the dispatcher's ip/ua on the run and its terminal audit event (no runner bleed)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

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

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

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
      subject = owner_subject_for(account)

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

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

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
      payload = %{
        "hostname" => "h",
        "version" => "0.1",
        "labels" => %{},
        "packs" => %{
          "linux-core" => %{
            "version" => "1.2.3",
            "hash" => Fixtures.Catalog.pack_hash("CLOUD_TRUSTED")
          }
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
      }

      assert {:ok, _} = Emisar.Catalog.observe_state(runner, payload)

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
      assert payload["expected_pack_hash"] == Fixtures.Catalog.pack_hash("CLOUD_TRUSTED")
    end

    test "rejects dispatch when the action is not advertised by the runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

      assert Runs.dispatch_run(
               base_attrs(account.id, runner.id),
               subject
             ) == {:error, :action_not_found}
    end

    test "rejects dispatch when the runner reports the primary executable missing" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      _ =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "linux.uptime",
          risk: "low",
          primary_executable_available: false,
          missing_executable: "uptime"
        )

      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

      assert Runs.dispatch_run(base_attrs(account.id, runner.id), subject) ==
               {:error, :action_unavailable}

      refute Repo.exists?(ActionRun)
    end

    test "rejects dispatch to a soft-deleted runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # Soft-delete the runner (sets deleted_at). The dispatch gate runs
      # before the action-advertised check, so a deleted runner is refused
      # as :runner_not_found rather than slipping through to execution.
      Fixtures.Runners.mark_deleted(runner)
      subject = owner_subject_for(account)

      assert Runs.dispatch_run(
               base_attrs(account.id, runner.id),
               subject
             ) == {:error, :runner_not_found}
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
      subject = owner_subject_for(account)

      assert {:ok, :pending_approval, _run} =
               Runs.dispatch_run(attrs, subject)
    end

    test "require_approval policy stores the run as pending, creates a request, + audits the gating" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)

      policy =
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
      subject = owner_subject_for(account)

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

      run_events = Enum.filter(events, &(&1.payload["run_id"] == run.id))
      types = Enum.map(run_events, & &1.event_type)

      assert "action_run.pending_approval" in types
      refute "policy.evaluated" in types

      [pending] = Enum.filter(run_events, &(&1.event_type == "action_run.pending_approval"))

      assert Map.take(pending.payload, ~w[
               dispatch_reason policy_id policy_decision policy_reason policy_version matched_rules
             ]) == %{
               "dispatch_reason" => "test",
               "policy_id" => policy.id,
               "policy_decision" => "require_approval",
               "policy_reason" => run.policy_reason,
               "policy_version" => policy.vsn,
               "matched_rules" => ["needs-approval"]
             }

      refute Map.has_key?(pending.payload, "reason")
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

      subject = owner_subject_for(account)

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

          assert Runs.dispatch_run(base_attrs(account.id, runner.id), subject) ==
                   {:error, :invalid_policy_approval}

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
      policy =
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

      subject = owner_subject_for(account)

      assert {:error, :denied_by_policy, reason} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert is_binary(reason)
      # A denied run is recorded with status="denied" so operators can
      # see attempts in the audit log.
      assert {:ok, [%{status: :denied, policy_decision: "deny"} = denied_run], _meta} =
               Runs.list_recent_runs(subject, limit: 50)

      assert {:ok, [denied_event], _metadata} =
               Audit.list_events(subject, filter: [event_type: ["action_run.denied"]])

      assert denied_event.payload["run_id"] == denied_run.id

      assert Map.take(denied_event.payload, ~w[
               dispatch_reason policy_id policy_decision policy_reason policy_version matched_rules
             ]) == %{
               "dispatch_reason" => "test",
               "policy_id" => policy.id,
               "policy_decision" => "deny",
               "policy_reason" => reason,
               "policy_version" => policy.vsn,
               "matched_rules" => []
             }

      refute Map.has_key?(denied_event.payload, "reason")
    end

    test "stamps policy_version on the dispatched run so audit can correlate vN edits" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)

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
      owner = owner_subject_for(account)
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
      owner = owner_subject_for(account)
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
      subject = owner_subject_for(account)
      runner = Fixtures.Runners.create_runner(account_id: account.id, enforce_signatures: true)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      assert Runs.dispatch_run(base_attrs(account.id, runner.id), subject) ==
               {:error, :runner_requires_attestation}

      refute Repo.one(ActionRun)
    end

    # A `%Attestation{}` is an ordinary struct: holding one says nothing about
    # what dispatch it was bound to. Only the MCP fan-out, which validates the
    # raw header against its own facts, may assert signed authority — so a
    # direct dispatch refuses the envelope AND the carrier alike.
    test "no caller-supplied attestation satisfies signature-required dispatch" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)
      runner = Fixtures.Runners.create_runner(account_id: account.id, enforce_signatures: true)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      signed = Fixtures.Runs.signed_attestation()

      for claimed <- [signed.envelope, signed.attestation] do
        attrs = base_attrs(account.id, runner.id, %{attestation: claimed})
        assert Runs.dispatch_run(attrs, subject) == {:error, :invalid_attestation}
      end

      refute Repo.one(ActionRun)
      refute Repo.one(Audit.Event)
    end

    test "canonical runner options survive the DB and wire round-trip" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      opts = %{
        "timeout_ms" => 5_000,
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
      subject = owner_subject_for(account)
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
      subject = owner_subject_for(account)
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
      subject = owner_subject_for(account)
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
      subject = owner_subject_for(account)

      Emisar.Runs.subscribe_account_runs(account.id)

      huge = %{"blob" => String.duplicate("x", 300_000)}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runs.dispatch_run(base_attrs(account.id, runner.id, %{args: huge}), subject)

      assert errors_on(changeset).args_raw == ["is too large (max 32768 bytes)"]

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
      subject = owner_subject_for(account)

      attrs = %{runner_id: runner.id, reason: "x", source: "operator", args: %{}}
      assert Runs.dispatch_run(attrs, subject) == {:error, :action_required}
    end

    test "rejects a missing reason with :reason_required" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = owner_subject_for(account)

      attrs = %{runner_id: runner.id, action_id: "linux.uptime", source: "operator", args: %{}}
      assert Runs.dispatch_run(attrs, subject) == {:error, :reason_required}
    end
  end

  describe "compose_dispatch_batch_in_multi/5" do
    test "rejects a subject without dispatch permission" do
      %{account: account, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      target = mcp_target_attrs(runner, key, "op_334NN9NMDZ1T76NARWCKM5A0D6")

      assert Runs.compose_dispatch_batch_in_multi(
               Multi.new(),
               [target],
               no_permissions_subject(account),
               :denied
             ) == {:error, :unauthorized}
    end

    test "rejects a permission-bearing subject without a concrete membership" do
      %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      target = mcp_target_attrs(runner, key, "op_334NN9NMDZ1T76NARWCKM5A0D7")
      unbound = %{subject | membership_id: nil}

      assert Runs.compose_dispatch_batch_in_multi(
               Multi.new(),
               [target],
               unbound,
               :unbound
             ) == {:error, :runner_out_of_scope}
    end

    test "rejects a runner from another account" do
      %{runners: [runner_a], key: key_a} = mcp_fanout_fixture(["low"])
      {user_b, account_b, _subject_b} = Fixtures.Subjects.owner_subject()

      {_raw, key_b} =
        Fixtures.ApiKeys.create_api_key(account_id: account_b.id, created_by_id: user_b.id)

      subject_b = Emisar.Auth.Subject.for_api_key(key_b, account_b)
      target = mcp_target_attrs(runner_a, key_a, "op_334NN9NMDZ1T76NARWCKM5A0D6")

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

      assert Runs.compose_dispatch_batch_in_multi(Multi.new(), [], subject, :empty) ==
               {:error, :invalid_targets}
    end

    test "refuses any caller-supplied attestation before composing the batch" do
      %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])
      signed = Fixtures.Runs.signed_attestation()

      for claimed <- [signed.envelope, signed.attestation] do
        target =
          runner
          |> mcp_target_attrs(key, "op_334NN9NMDZ1T76NARWCKM5A0D6")
          |> Map.put(:attestation, claimed)

        assert Runs.compose_dispatch_batch_in_multi(Multi.new(), [target], subject, :forged) ==
                 {:error, :invalid_attestation}
      end

      refute Repo.one(ActionRun)
    end

    test "refuses an unsigned composed target on an enforcing runner" do
      %{subject: subject, runners: [runner], key: key} = mcp_fanout_fixture(["low"])

      assert {:ok, runner} =
               Emisar.Runners.apply_state(runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      target = mcp_target_attrs(runner, key, "op_334NN9NMDZ1T76NARWCKM5A0D6")

      assert {:ok, multi} =
               Runs.compose_dispatch_batch_in_multi(Multi.new(), [target], subject, :unsigned)

      assert {:error, {:dispatch_batch, :unsigned}, :runner_requires_attestation, _changes} =
               Repo.transaction(multi)

      refute Repo.one(ActionRun)
    end
  end

  describe "compose_runbook_attempts_in_multi/6" do
    test "rejects empty and malformed attempt batches before composing writes" do
      account_id = Ecto.UUID.generate()
      membership_id = Ecto.UUID.generate()

      assert Runs.compose_runbook_attempts_in_multi(
               Multi.new(),
               [],
               account_id,
               membership_id,
               :empty
             ) == {:error, :invalid_targets}

      assert Runs.compose_runbook_attempts_in_multi(
               Multi.new(),
               [%{runner_id: Ecto.UUID.generate()}],
               account_id,
               membership_id,
               :malformed
             ) == {:error, :invalid_targets}
    end

    test "refuses any caller-supplied attestation before composing attempts" do
      account_id = Ecto.UUID.generate()
      membership_id = Ecto.UUID.generate()
      execution_id = Ecto.UUID.generate()
      signed = Fixtures.Runs.signed_attestation()

      for claimed <- [signed.envelope, signed.attestation] do
        target = %{
          runner_id: Ecto.UUID.generate(),
          runbook_execution_item_id: Ecto.UUID.generate(),
          runbook_execution_id: execution_id,
          attempt_number: 1,
          attestation: claimed
        }

        assert Runs.compose_runbook_attempts_in_multi(
                 Multi.new(),
                 [target],
                 account_id,
                 membership_id,
                 :forged,
                 runbook_execution_id: execution_id
               ) == {:error, :invalid_attestation}
      end

      refute Repo.one(ActionRun)
    end
  end

  describe "after_composed_dispatches_committed/1" do
    test "delivers and broadcasts the rows only after the outer transaction commits" do
      %{changes: changes, runner: runner} = composed_dispatch_fixture(:post_commit_contract)
      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      :ok = Runs.subscribe_account_runs(runner.account_id)

      assert Runs.after_composed_dispatches_committed(changes) == :ok
      assert_receive {:run_updated, run_id}, 500
      assert run_id == changes[{:composed_run, :post_commit_contract, 0}].id

      assert_receive {:cloud_to_runner, _generation,
                      %{
                        "type" => "run_action",
                        "pack_ref" => @mcp_pack_ref,
                        "operation_id" => "op_334NN9NMDZ1T76NARWCKM5A0D6"
                      }},
                     500
    end
  end

  describe "dispatch_mcp_action/2" do
    test "rejects a subject without dispatch permission" do
      %{account: account, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_334NN9NMDZ1T76NARWCKM5A0D6", [runner])

      assert Runs.dispatch_mcp_action(facts, no_permissions_subject(account)) ==
               {:error, :unauthorized}
    end

    test "a stale MCP subject cannot reserve or create fan-out work" do
      %{account: account, subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_334NN9NMDZ1T76NARWCKM5A0D7", [runner])

      Fixtures.Accounts.disable_account(account)

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :not_found}
      refute Repo.exists?(ActionRun)
    end

    test "rejects a permission-bearing subject without a concrete membership" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_334NN9NMDZ1T76NARWCKM5A0D8", [runner])
      unbound = %{subject | membership_id: nil}

      assert Runs.dispatch_mcp_action(facts, unbound) == {:error, :runner_out_of_scope}
    end

    test "rejects a runner ref that another account owns" do
      %{runners: [runner_a]} = mcp_fanout_fixture(["low"])
      {user_b, account_b, _subject_b} = Fixtures.Subjects.owner_subject()

      {_raw, key_b} =
        Fixtures.ApiKeys.create_api_key(account_id: account_b.id, created_by_id: user_b.id)

      subject_b = Emisar.Auth.Subject.for_api_key(key_b, account_b)
      facts = mcp_action_facts("op_334NN9NMDZ1T76NARWCKM5A0D6", [runner_a])

      assert Runs.dispatch_mcp_action(facts, subject_b) ==
               {:error, :target_contract_changed}

      refute Repo.exists?(MCPOperations.Operation)
    end

    test "persists the optional evidence/expected justification chain on each run" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      :ok = Emisar.Runners.subscribe_runner_transport(runner)

      facts =
        Map.merge(mcp_action_facts("op_534NN9NMDZ1T76NARWCKM5A0D6", [runner]), %{
          evidence: "run 0f9c showed the queue depth climbing for 20m",
          expected: "queue depth drops to zero within a minute"
        })

      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)
      assert run.evidence == "run 0f9c showed the queue depth climbing for 20m"
      assert run.expected == "queue depth drops to zero within a minute"

      # Echo: the chain round-trips through the persisted row, not just the
      # in-memory insert struct.
      assert {:ok, fetched} = Runs.fetch_mcp_run_by_id(run.id, subject)
      assert fetched.evidence == run.evidence
      assert fetched.expected == run.expected

      changed_retry = %{
        facts
        | evidence: "replacement evidence",
          expected: "replacement expectation"
      }

      assert {:ok, :replay, [replayed]} = Runs.dispatch_mcp_action(changed_retry, subject)
      assert replayed.id == run.id
      assert replayed.evidence == run.evidence
      assert replayed.expected == run.expected
    end

    test "attributes the run to the authenticated credential, not to caller-supplied facts" do
      %{subject: subject, membership: membership, runners: [runner], key: key} =
        mcp_fanout_fixture(["low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner)

      facts =
        Map.merge(mcp_action_facts("op_534NN9NMDZ1T76NARWCKM5A0D7", [runner]), %{
          api_key_id: Ecto.UUID.generate(),
          requested_by_membership_id: Ecto.UUID.generate(),
          source: "operator"
        })

      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)
      assert run.api_key_id == key.id
      assert run.initiating_membership_id == membership.id
      assert run.source == :mcp
      assert is_nil(run.requested_by_id)
    end

    test "commits every target before delivery and exact replay never redelivers" do
      %{subject: subject, runners: [runner_a, runner_b]} = mcp_fanout_fixture(["low", "low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner_a)
      :ok = Emisar.Runners.subscribe_runner_transport(runner_b)

      facts = mcp_action_facts("op_724NN9NMDZ1T76NARWCKM5A0D6", [runner_a, runner_b])

      assert {:ok, :created, runs} = Runs.dispatch_mcp_action(facts, subject)
      assert length(runs) == 2
      assert Enum.uniq_by(runs, & &1.mcp_operation_record_id) |> length() == 1
      assert Enum.all?(runs, &(&1.status == :sent))

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      original_ids = Enum.map(runs, & &1.id)
      assert {:ok, :replay, replayed} = Runs.dispatch_mcp_action(facts, subject)
      assert Enum.map(replayed, & &1.id) == original_ids
      refute_receive {:cloud_to_runner, _generation, _}, 100

      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
      assert Repo.aggregate(ActionRun, :count) == 2
    end

    test "replays without consulting current catalog state" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      facts = mcp_action_facts("op_734NN9NMDZ1T76NARWCKM5A0D6", [runner])

      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      {:ok, action} =
        Catalog.fetch_action_for_account("linux.uptime", runner.id, subject.account.id)

      action |> Ecto.Changeset.change(risk: :critical) |> Repo.update!()

      assert {:ok, :replay, [replayed]} = Runs.dispatch_mcp_action(facts, subject)
      assert replayed.id == run.id
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "changed immutable facts conflict under the same operation identity" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      :ok = Emisar.Runners.subscribe_runner_transport(runner)
      facts = mcp_action_facts("op_744NN9NMDZ1T76NARWCKM5A0D6", [runner])

      assert {:ok, :created, _runs} = Runs.dispatch_mcp_action(facts, subject)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      changed = [
        %{facts | reason: "something else"},
        %{facts | args_raw: ~s({"verbose":true})},
        %{facts | action_id: "linux.reboot"},
        %{facts | pack_ref: "linux-core@2.0.0/" <> @mcp_pack_hash}
      ]

      for facts <- changed do
        assert Runs.dispatch_mcp_action(facts, subject) == {:error, :operation_conflict}
      end

      assert Repo.aggregate(ActionRun, :count) == 1
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "reports an incomplete operation when a committed target row is missing" do
      %{subject: subject, runners: [runner_a, runner_b]} = mcp_fanout_fixture(["low", "low"])
      facts = mcp_action_facts("op_754NN9NMDZ1T76NARWCKM5A0D6", [runner_a, runner_b])

      assert {:ok, :created, [first, _second]} = Runs.dispatch_mcp_action(facts, subject)
      Repo.delete!(first)

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :operation_incomplete}
    end

    test "concurrent identical first attempts converge on one complete delivered target set" do
      %{subject: subject, runners: [runner_a, runner_b]} = mcp_fanout_fixture(["low", "low"])

      :ok = Emisar.Runners.subscribe_runner_transport(runner_a)
      :ok = Emisar.Runners.subscribe_runner_transport(runner_b)

      facts = mcp_action_facts("op_714NN9NMDZ1T76NARWCKM5A0D6", [runner_a, runner_b])

      results =
        1..8
        |> Enum.map(fn _index ->
          Task.async(fn -> Runs.dispatch_mcp_action(facts, subject) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, _outcome, [_run_a, _run_b]}, &1))
      assert Enum.count(results, &match?({:ok, :created, _runs}, &1)) == 1

      target_sets =
        Enum.map(results, fn {:ok, _outcome, runs} ->
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
      %{account: account, subject: subject, runners: [ready]} = mcp_fanout_fixture(["low"])

      missing = Fixtures.Runners.create_runner(account_id: account.id)
      :ok = Emisar.Runners.subscribe_runner_transport(ready)

      facts = mcp_action_facts("op_624NN9NMDZ1T76NARWCKM5A0D6", [ready, missing])

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :target_contract_changed}

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "rejects arguments the trusted contract does not accept" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])

      facts =
        Map.merge(mcp_action_facts("op_634NN9NMDZ1T76NARWCKM5A0D6", [runner]), %{
          args: %{"unknown" => true},
          args_raw: ~s({"unknown":true})
        })

      assert {:error, {:invalid_action_arguments, issue}} =
               Runs.dispatch_mcp_action(facts, subject)

      assert issue.code == "unknown_arg"
      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
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
        runners: [allowed, gated]
      } = mcp_fanout_fixture(["low", "low"])

      assert {:ok, _policy} =
               Emisar.Policies.save_scoped_rules(
                 gated_rules,
                 :runner,
                 gated.id,
                 owner_subject
               )

      :ok = Emisar.Runners.subscribe_runner_transport(allowed)

      facts = mcp_action_facts("op_524NN9NMDZ1T76NARWCKM5A0D6", [allowed, gated])

      assert {:ok, :created, runs} = Runs.dispatch_mcp_action(facts, subject)
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

      %{account: account, subject: subject, runners: [runner]} =
        mcp_fanout_fixture(["low"], gated_rules)

      policy = Emisar.Policies.peek_policy_for_account(account.id)
      rules = Map.delete(policy.rules, "approval")
      _policy = policy |> Ecto.Changeset.change(rules: rules) |> Repo.update!()

      facts = mcp_action_facts("op_504NN9NMDZ1T76NARWCKM5A0D6", [runner])

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :invalid_policy_approval}

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
      refute Repo.exists?(Emisar.Approvals.Request)
    end

    test "rolls back an already-stale signed fan-out with its operation" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])

      assert {:ok, _runner} =
               Emisar.Runners.apply_state(runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      facts = mcp_action_facts("op_514NN9NMDZ1T76NARWCKM5A0D6", [runner])
      now = DateTime.utc_now()

      signed =
        signed_mcp_attestation(facts, [runner],
          issued_at: now |> DateTime.add(-7_200, :second) |> DateTime.to_iso8601(),
          valid_until: DateTime.add(now, 3_600, :second)
        )

      assert Runs.dispatch_mcp_action(signed_mcp_facts(facts, signed.header), subject) ==
               {:error, :attestation_stale}

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
        runners: [runner]
      } = mcp_fanout_fixture(["low"], gated_rules)

      assert {:ok, _runner} =
               Emisar.Runners.apply_state(runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      facts = mcp_action_facts("op_414NN9NMDZ1T76NARWCKM5A0D6", [runner])
      now = DateTime.utc_now()
      cert_deadline = DateTime.add(now, 600, :second)

      signed =
        signed_mcp_attestation(facts, [runner],
          issued_at: DateTime.to_iso8601(now),
          valid_until: cert_deadline
        )

      assert {:ok, :created, [%ActionRun{status: :pending_approval} = run]} =
               Runs.dispatch_mcp_action(signed_mcp_facts(facts, signed.header), subject)

      assert {:ok, [request], _meta} =
               Approvals.list_pending_approval_requests(owner_subject)

      assert request.run_id == run.id
      assert DateTime.diff(request.expires_at, now, :second) in 599..600
      assert DateTime.compare(request.expires_at, cert_deadline) != :gt
    end

    test "a valid signed fan-out persists and relays the normalized envelope" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])

      assert {:ok, runner} =
               Emisar.Runners.apply_state(runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      :ok = Emisar.Runners.subscribe_runner_transport(runner)

      facts = mcp_action_facts("op_424NN9NMDZ1T76NARWCKM5A0D7", [runner])
      signed = signed_mcp_attestation(facts, [runner])

      assert {:ok, :created, [run]} =
               Runs.dispatch_mcp_action(signed_mcp_facts(facts, signed.header), subject)

      assert run.attestation == signed.envelope
      assert_receive {:cloud_to_runner, _generation, payload}, 500
      assert payload["attestation"] == signed.envelope
    end

    test "an unsigned call to an enforcing runner names the refs that enforce" do
      %{subject: subject, runners: [open_runner, enforcing_runner]} =
        mcp_fanout_fixture(["low", "low"])

      assert {:ok, enforcing_runner} =
               Emisar.Runners.apply_state(enforcing_runner, %{
                 "enforce_signatures" => true,
                 "max_attestation_age_seconds" => 3_600
               })

      facts =
        mcp_action_facts("op_424NN9NMDZ1T76NARWCKM5A0D8", [open_runner, enforcing_runner])

      assert Runs.dispatch_mcp_action(facts, subject) ==
               {:error, {:signature_required, mcp_runner_refs([enforcing_runner])}}

      refute Repo.one(MCPOperations.Operation)
      refute Repo.one(ActionRun)
    end

    test "every bound fact must agree with the call before any run is persisted" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_424NN9NMDZ1T76NARWCKM5A0DA", [runner])

      mismatches = [
        [action_id: "linux.reboot"],
        [pack_ref: "linux-core@2.0.0/" <> @mcp_pack_hash],
        [args_raw: ~s({"verbose":true})],
        [runner_refs: ["stand-in~" <> String.duplicate("0", 32)]],
        [reason: "something else"],
        [operation_id: "op_00000000000000000000000000"],
        [portal_origin: "https://attacker.example"]
      ]

      for overrides <- mismatches do
        signed = signed_mcp_attestation(facts, [runner], overrides)

        assert Runs.dispatch_mcp_action(signed_mcp_facts(facts, signed.header), subject) ==
                 {:error, :invalid_attestation}
      end

      refute Repo.one(MCPOperations.Operation)
      refute Repo.one(ActionRun)
    end

    test "the signed target set is compared against the runners this account scopes" do
      %{subject: subject, runners: [selected, unselected]} = mcp_fanout_fixture(["low", "low"])

      facts = mcp_action_facts("op_424NN9NMDZ1T76NARWCKM5A0DB", [selected])
      signed = signed_mcp_attestation(facts, [unselected])

      assert Runs.dispatch_mcp_action(signed_mcp_facts(facts, signed.header), subject) ==
               {:error, :invalid_attestation}

      refute Repo.one(MCPOperations.Operation)
      refute Repo.one(ActionRun)
    end

    test "rejects duplicate runner refs before reserving an operation" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_424NN9NMDZ1T76NARWCKM5A0D6", [runner, runner])

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :invalid_targets}

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
    end

    test "rejects a malformed or empty fact set before reserving an operation" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_424NN9NMDZ1T76NARWCKM5A0D7", [runner])

      malformed = [
        %{facts | runner_refs: []},
        %{facts | args_raw: nil},
        %{facts | reason: nil},
        Map.delete(facts, :pack_ref)
      ]

      Enum.each(malformed, fn facts ->
        assert Runs.dispatch_mcp_action(facts, subject) == {:error, :invalid_targets}

        refute Repo.exists?(MCPOperations.Operation)
        refute Repo.exists?(ActionRun)
      end)
    end

    test "uses the trusted risk and rejects an advertisement that lowers it" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["high"])
      facts = mcp_action_facts("op_434NN9NMDZ1T76NARWCKM5A0D6", [runner])

      readvertise_mcp_action(runner, %{"risk" => "low"})

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :target_contract_changed}

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
    end

    test "one descriptor mismatch rolls back the complete fan-out" do
      %{subject: subject, runners: [ready, changed]} = mcp_fanout_fixture(["low", "low"])

      :ok = Emisar.Runners.subscribe_runner_transport(ready)
      facts = mcp_action_facts("op_444NN9NMDZ1T76NARWCKM5A0D6", [ready, changed])

      readvertise_mcp_action(changed, %{
        "args" => [
          %{"name" => "token", "type" => "string", "required" => true, "sensitive" => true}
        ],
        "output_schema" => %{"type" => "object", "required" => ["forged"]}
      })

      assert Runs.dispatch_mcp_action(facts, subject) == {:error, :target_contract_changed}

      refute Repo.exists?(MCPOperations.Operation)
      refute Repo.exists?(ActionRun)
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end
  end

  describe "list_runs_by_mcp_operation/2" do
    test "uses the subject account boundary" do
      %{subject: subject, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_324NN9NMDZ1T76NARWCKM5A0D6", [runner])

      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)

      assert {:ok, [listed]} =
               Runs.list_runs_by_mcp_operation(run.mcp_operation_record_id, subject)

      assert listed.id == run.id

      {_user, _account, foreign_subject} = Fixtures.Subjects.owner_subject()

      assert Runs.list_runs_by_mcp_operation(run.mcp_operation_record_id, foreign_subject) ==
               {:ok, []}
    end

    test "keeps operation history after the API key owner's runner access changes" do
      %{subject: subject, membership: membership, runners: [runner]} = mcp_fanout_fixture(["low"])
      facts = mcp_action_facts("op_314NN9NMDZ1T76NARWCKM5A0D6", [runner])

      assert {:ok, :created, [run]} = Runs.dispatch_mcp_action(facts, subject)

      assert {:ok, [_listed]} =
               Runs.list_runs_by_mcp_operation(run.mcp_operation_record_id, subject)

      Fixtures.Memberships.force_runner_access(
        membership,
        Emisar.Accounts.RunnerAccess.none()
      )

      assert {:ok, [listed_after_scope_change]} =
               Runs.list_runs_by_mcp_operation(run.mcp_operation_record_id, subject)

      assert listed_after_scope_change.id == run.id
    end
  end

  describe "list_unsettled_run_ids/2" do
    test "returns only visible non-terminal ids in one query" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      pending_run =
        Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, status: :pending)

      settled_run =
        Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, status: :success)

      {_other_owner, other_account, _other_subject} = Fixtures.Subjects.owner_subject()
      other_runner = Fixtures.Runners.create_runner(account_id: other_account.id)

      foreign_run =
        Fixtures.Runs.create_run(
          account_id: other_account.id,
          runner_id: other_runner.id,
          status: :pending
        )

      ids = [pending_run.id, settled_run.id, foreign_run.id]
      assert Runs.list_unsettled_run_ids(ids, subject) == {:ok, [pending_run.id]}
    end
  end

  describe "recheck_runbook_attempt/2" do
    test "fails closed for malformed and cross-account frozen targets" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runs.recheck_runbook_attempt(%{}, account.id) ==
               {:error, :runner_required}

      assert Runs.recheck_runbook_attempt(
               %{
                 runner_id: runner.id,
                 action_id: "linux.uptime",
                 requested_by_membership_id: Ecto.UUID.generate()
               },
               other_account.id
             ) == {:error, :runner_not_found}
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
      assert Runs.dispatch_run_for_account(
               base_attrs(account.id, runner.id, %{reason: "   "}),
               account.id
             ) == {:error, :reason_required}

      assert Runs.dispatch_run_for_account(
               %{runner_id: runner.id, reason: "x", source: "runbook", args: %{}},
               account.id
             ) == {:error, :action_required}

      assert Runs.dispatch_run_for_account(
               %{action_id: "linux.uptime", reason: "x", source: "runbook", args: %{}},
               account.id
             ) == {:error, :runner_required}
    end

    test "re-checks the initiating membership's runner scope — out-of-scope is refused", %{
      account: account,
      runner: runner
    } do
      # A durable caller threads `requested_by_membership_id`; if that membership's
      # runner scope no longer covers this runner, the attempt is refused.
      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      # Scope the membership to a group the runner is NOT in (scope_type is a
      # string — the team LV passes "group"/"runner").
      {:ok, access} = Emisar.Accounts.RunnerAccess.restricted(["nope"], [])
      Fixtures.Memberships.force_runner_access(membership, access)

      attrs =
        base_attrs(account.id, runner.id, %{requested_by_membership_id: membership.id})

      assert Runs.dispatch_run_for_account(attrs, account.id) == {:error, :runner_out_of_scope}
    end

    test "stops subjectless dispatch while the account is disabled", %{
      account: account,
      runner: runner
    } do
      support_subject = owner_subject_for(account)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 support_subject
               )

      assert Runs.dispatch_run_for_account(base_attrs(account.id, runner.id), account.id) ==
               {:error, :runner_not_found}
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
                 Catalog.observe_state(
                   runner,
                   mcp_state_payload(runner, mcp_action_descriptor(%{"risk" => risk}))
                 )

        runner
      end)

    pack_versions = Fixtures.Catalog.list_pack_versions(owner_subject.account.id)

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

  defp mcp_state_payload(runner, descriptor) do
    %{
      "hostname" => runner.hostname,
      "version" => runner.runner_version,
      "labels" => runner.labels,
      "packs" => %{"linux-core" => %{"version" => "1.0.0", "hash" => @mcp_pack_hash}},
      "actions" => [descriptor]
    }
  end

  defp mcp_action_descriptor(overrides) do
    Map.merge(
      %{
        "id" => "linux.uptime",
        "pack_id" => "linux-core",
        "title" => "Uptime",
        "kind" => "exec",
        "risk" => "low",
        "summary" => "Reports uptime",
        "description" => "Reports uptime",
        "side_effects" => [],
        "args" => [],
        "examples" => [],
        "search_terms" => []
      },
      overrides
    )
  end

  # A runner re-advertising a changed descriptor under the pack hash an operator
  # already trusted — the drift the dispatch gate exists to refuse. Arranged
  # through the real ingest so the stored row, digest included, is one a runner
  # could actually produce.
  defp readvertise_mcp_action(runner, overrides) do
    assert {:ok, _runner} =
             Catalog.observe_state(
               runner,
               mcp_state_payload(runner, mcp_action_descriptor(overrides))
             )
  end

  defp mcp_action_facts(operation_id, runners) do
    %{
      operation_id: operation_id,
      action_id: "linux.uptime",
      pack_ref: @mcp_pack_ref,
      runner_refs: mcp_runner_refs(runners),
      args: %{},
      args_raw: "{}",
      reason: "inspect uptime"
    }
  end

  defp mcp_runner_refs(runners) do
    Enum.map(runners, fn runner ->
      {:ok, runner_ref} = Emisar.Runners.public_ref(runner)
      runner_ref
    end)
  end

  # The bridge signs over the facts of the call it is about to make, so the
  # defaults here mirror `mcp_action_facts/2` and a test overrides only the one
  # fact it is bending.
  defp signed_mcp_attestation(facts, runners, overrides \\ []) do
    defaults = [
      action_id: facts.action_id,
      pack_ref: facts.pack_ref,
      args_raw: facts.args_raw,
      runner_refs: mcp_runner_refs(runners),
      reason: facts.reason,
      operation_id: facts.operation_id,
      portal_origin: @mcp_portal_origin
    ]

    Fixtures.Runs.signed_attestation(Keyword.merge(defaults, overrides))
  end

  defp signed_mcp_facts(facts, header) do
    Map.merge(facts, %{
      attestation_headers: [header],
      portal_origin: @mcp_portal_origin
    })
  end

  # The composed-batch API still takes fully-built target attrs; only the fixed
  # MCP action tool derives them from model-facing facts.
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

    test "refuses an authorized run when the executable becomes unavailable", %{
      account: account,
      runner: runner
    } do
      action =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "linux.uptime",
          primary_executable_available: true
        )

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      action
      |> Ecto.Changeset.change(
        primary_executable_available: false,
        missing_executable: "uptime"
      )
      |> Repo.update!()

      assert Runs.recheck_run_pack_trust(run.id) == {:error, :action_unavailable}
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
          "packs" => %{
            "linux-core" => %{
              "version" => "1.2.3",
              "hash" => Fixtures.Catalog.pack_hash("DRIFT")
            }
          },
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

      assert Runs.recheck_run_pack_trust(run.id) == {:error, :pack_untrusted}
    end

    test "refuses a packless run when the runner no longer advertises the action", %{
      account: account,
      runner: runner
    } do
      # No snapshotted hash still means no current trusted contract to bind the
      # approval to — a later same-id action is not the artifact under review.
      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "ghost.action",
          source: "operator",
          args: %{}
        })

      assert Runs.recheck_run_pack_trust(run.id) == {:error, :action_not_found}
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

      assert Runs.recheck_run_pack_trust(run.id) == {:error, :action_not_found}
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
      valid_until = DateTime.add(DateTime.utc_now(), 3_600, :second)

      %{attestation: attestation} =
        Fixtures.Runs.signed_attestation(issued_at: issued_at, valid_until: valid_until)

      account.id
      |> base_attrs(runner.id, %{attestation: attestation})
      |> Fixtures.Runs.create_signed_run()
    end

    test "a fresh signature passes", %{account: account, runner: runner} do
      run = signed_run(account, runner, DateTime.to_iso8601(DateTime.utc_now()))
      assert Runs.check_run_attestation_fresh(run.id) == :ok
    end

    test "a signature older than the window is refused as :attestation_stale", %{
      account: account,
      runner: runner
    } do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
      run = signed_run(account, runner, stale)
      assert Runs.check_run_attestation_fresh(run.id) == {:error, :attestation_stale}
    end

    test "an unsigned run for an enforcing runner fails closed", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.check_run_attestation_fresh(run.id) == {:error, :attestation_stale}
    end
  end

  describe "list_stale_dispatches/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)
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

  describe "count_pending_dispatches/0" do
    test "an empty queue is zero" do
      assert Runs.count_pending_dispatches() == 0
    end

    test "counts only pending runs, fleet-wide across accounts" do
      Fixtures.Runs.create_run(status: :pending)
      Fixtures.Runs.create_run(status: :pending)

      # Excluded from the backlog depth: sent (already handed to a runner),
      # pending_approval (blocked on a human, not a dispatch queue), and terminal.
      Fixtures.Runs.create_run(status: :sent)
      Fixtures.Runs.create_run(status: :pending_approval)
      Fixtures.Runs.create_run(status: :success)

      assert Runs.count_pending_dispatches() == 2
    end
  end

  describe "RunDispatchTimeout sweep (worker over list_stale_dispatches/1)" do
    setup do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = owner_subject_for(account)
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

      assert Emisar.Runs.Jobs.DispatchTimeout.execute([]) == :ok

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

      assert Emisar.Runs.Jobs.DispatchTimeout.execute([]) == :ok

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

      assert Runs.dispatch_queued_for_runner(runner.id) == :ok

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

      assert Runs.dispatch_queued_for_runner(runner.id) == :ok

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

      assert Runs.dispatch_queued_for_runner(runner.id) == :ok
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
            opts: %{"timeout_ms" => 30_000}
          })
        )

      assert Runs.dispatch_to_runner(run) == :ok

      assert_receive {:cloud_to_runner, first_generation, %{"type" => "run_action"} = original},
                     500

      successor = reconnect_runner(runner)
      assert Runs.resume_runs_for_runner(runner.id) == :ok

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
      assert Runs.dispatch_to_runner(run) == :ok
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      run
      |> Ecto.Changeset.change(status: :cancelling, reason_text: "operator requested stop")
      |> Repo.update!()

      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))

      successor = reconnect_runner(runner)
      assert Runs.resume_runs_for_runner(runner.id) == :ok

      assert_receive {:cloud_to_runner, generation,
                      %{"type" => "run_action", "request_id" => request_id}},
                     500

      assert_receive {:cloud_to_runner, ^generation,
                      %{"type" => "cancel", "request_id" => ^request_id} = frame},
                     500

      refute Map.has_key?(frame, "reason")

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
      assert Runs.dispatch_to_runner(run) == :ok
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

      assert Runs.mark_started_from_connection(
               account.id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               run.request_id
             ) == {:error, :not_dispatchable}
    end

    test "rejects a superseded lease without changing the run" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.dispatch_to_runner(run) == :ok
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500

      reconnect_runner(runner)

      assert Runs.mark_started_from_connection(
               account.id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               run.request_id
             ) == {:error, :connection_superseded}

      assert Runs.peek_run_by_id(run.id).status == :sent
    end
  end

  describe "list_running_runs/1" do
    test "bounds the batch so one tick cannot load the whole fleet" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      for _ <- 1..3 do
        Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, status: :running)
      end

      # DispatchTimeout loads this every 60s, fleet-wide: a wide outage parking
      # tens of thousands of runs made the tick outlast its own interval, so
      # timeouts stopped being enforced during the incident they exist for.
      assert length(Runs.list_running_runs(2)) == 2
    end

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

  describe "list_terminal_runbook_callbacks/1" do
    test "excludes terminal runs that do not belong to a waiting runbook item" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert {:ok, _finished} = Fixtures.Runs.finish(run, %{"status" => "success"})

      assert Runs.list_terminal_runbook_callbacks(50) == []
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

      assert Runs.dispatch_to_runner(run) == :ok
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
      assert Runs.dispatch_to_runner(run) == {:error, :not_dispatchable}
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end

    test "does not publish pending work after the account is disabled", %{
      account: account,
      runner: runner
    } do
      Emisar.Runners.subscribe_runner_transport(runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      support_subject = owner_subject_for(account)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 support_subject
               )

      assert Runs.dispatch_to_runner(run) == :ok
      refute_receive {:cloud_to_runner, _generation, _}, 100
      assert Runs.peek_run_by_id(run.id).status == :pending
    end

    test "leaves an offline run pending for the next connection", %{
      account: account,
      runner: runner
    } do
      {:ok, connected} =
        Emisar.Runners.disconnect_runner(
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

      assert Runs.dispatch_to_runner(run) == :ok
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

      assert Runs.dispatch_to_runner(run) == {:error, :not_dispatchable}
      refute_receive {:cloud_to_runner, _generation, _}, 100
    end
  end

  describe "ensure_run_initiator_authorized/2" do
    test "re-reads current membership access for the exact initiating runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.ensure_run_initiator_authorized(Repo, run) == :ok

      membership = Repo.get!(Emisar.Accounts.Membership, run.initiating_membership_id)
      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.none())

      assert Runs.ensure_run_initiator_authorized(Repo, run) ==
               {:error, :initiator_no_longer_authorized}
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
          "packs" => %{
            "custom" => %{"version" => "1.0", "hash" => Fixtures.Catalog.pack_hash("TAMPERED")}
          },
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
      assert Runs.redeliver_to_runner(run) == {:error, :pack_untrusted}
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
      refused_hash = Fixtures.Catalog.pack_hash("NOPE")
      assert Runs.peek_run_by_id(run.id).expected_pack_hash == refused_hash

      assert_receive {:cloud_to_runner, _generation, %{"expected_pack_hash" => ^refused_hash}},
                     500

      # The pack drifts to a NEW hash AND is re-trusted (trusted hash now TAMPERED).
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{
            "custom" => %{"version" => "1.0", "hash" => Fixtures.Catalog.pack_hash("TAMPERED")}
          },
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

      assert Runs.redeliver_to_runner(run) == {:error, :pack_untrusted}
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
          "packs" => %{
            "custom" => %{"version" => "1.0", "hash" => Fixtures.Catalog.pack_hash("NOPE")}
          },
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

      Emisar.Runs.subscribe_run(account.id, run.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok,
              %ActionRun{
                status: :cancelling,
                cancelled_at: nil,
                finished_at: nil,
                reason_text: "user pressed stop"
              }} =
               Runs.cancel_run(run, subject, "user pressed stop")

      # No "reason" on the wire: CancelMsg is envelope-only, so the runner
      # discards anything beyond it. The reason stays on the run record, which
      # is asserted above.
      assert_receive {:cloud_to_runner, _generation,
                      %{"type" => "cancel", "request_id" => request_id} = frame},
                     500

      refute Map.has_key?(frame, "reason")

      assert request_id == run.request_id
      assert Runs.peek_run_by_id(run.id).status == :cancelling

      # The exact run topic carries a render-ready struct.
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

      assert Runs.cancel_run(run, subject, "no rights") == {:error, :unauthorized}
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

      assert Runs.cancel_run(run_a, subject_b, "wrong account") == {:error, :not_found}
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

      assert Ecto.Multi.new()
             |> Runs.cancel_run_in_multi(sent.id, "too late")
             |> Repo.commit_multi() == {:error, :run_already_dispatched}

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

  describe "cancel_undispatched_runbook_attempts_in_multi/3" do
    test "is an idempotent empty transaction for an execution with no attempts" do
      execution_id = Ecto.UUID.generate()

      assert {:ok, changes} =
               Multi.new()
               |> Runs.cancel_undispatched_runbook_attempts_in_multi(
                 execution_id,
                 "execution halted"
               )
               |> Repo.commit_multi()

      assert changes[{:runbook_undispatched_ids, execution_id}] == []
      assert changes[{:runbook_pending_requests, execution_id}] == []
      assert changes[{:runbook_cancelled_attempts, execution_id}] == []
      assert changes[{:runbook_cancelled_requests, execution_id}] == []
    end
  end

  describe "after_undispatched_runbook_attempts_cancelled/2" do
    test "is a no-op when the enclosing transaction cancelled no attempts" do
      assert Runs.after_undispatched_runbook_attempts_cancelled(
               %{},
               Ecto.UUID.generate()
             ) == :ok
    end
  end

  describe "mark_errored/2" do
    test "transitions to :error with the provided message + finished_at" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)
      subject = owner_subject_for(account)
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      run = Runs.peek_run_by_id(run.id)

      assert {:ok, %ActionRun{status: :error, error_message: msg, finished_at: %DateTime{}}} =
               Runs.mark_errored(run, "runner was disconnected")

      assert msg =~ "disconnected"
    end
  end

  describe "build_runner_error/4" do
    test "keeps the socket's identities and bounds the runner-controlled diagnostics" do
      account_id = Ecto.UUID.generate()
      runner_id = Ecto.UUID.generate()

      attrs = %{
        code: String.duplicate("c", 200),
        message: String.duplicate("m", 900),
        request_id: "req-1"
      }

      command = Runs.build_runner_error(account_id, runner_id, attrs, %RequestContext{})

      assert command.account_id == account_id
      assert command.runner_id == runner_id
      assert String.length(command.code) == 100
      assert String.length(command.message) == 500
      assert command.request_id == "req-1"
    end

    test "drops a diagnostic that isn't a string instead of walking it into the domain" do
      attrs = %{code: %{"crafted" => true}, message: 42, request_id: ["not-an-id"]}

      command =
        Runs.build_runner_error(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          attrs,
          %RequestContext{}
        )

      assert command.code == nil
      assert command.message == nil
      assert command.request_id == nil
    end
  end

  describe "handle_runner_error/1" do
    test "requeues a cap-refused dispatch, audits it, and redelivers it after a slot opens" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      Runners.subscribe_runner_transport(runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      old_queued_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      run = run |> Ecto.Changeset.change(queued_at: old_queued_at) |> Repo.update!()

      assert Runs.dispatch_to_runner(run) == :ok
      assert_receive {:cloud_to_runner, _generation, %{"request_id" => request_id}}, 500
      assert request_id == run.request_id

      sent = Runs.peek_run_by_id(run.id)

      command =
        Runs.RunnerError.new(
          account.id,
          runner.id,
          %{code: "concurrency_cap_reached", request_id: run.request_id},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(command) == {:ok, :requeued}

      pending = Runs.peek_run_by_id(run.id)
      assert pending.status == :pending
      assert pending.sent_at == nil
      assert pending.runner_connection_generation == nil
      assert DateTime.compare(pending.queued_at, sent.queued_at) == :gt

      event = Repo.one(Audit.Event)
      assert event.event_type == "runner.error"
      assert event.target_id == runner.id
      assert event.payload["code"] == "concurrency_cap_reached"
      assert event.payload["request_id"] == run.request_id

      assert Runs.dispatch_queued_for_runner(runner.id) == :ok
      assert_receive {:cloud_to_runner, _generation, %{"request_id" => ^request_id}}, 500

      redelivered = Runs.peek_run_by_id(run.id)
      assert redelivered.status == :sent
      assert DateTime.compare(redelivered.sent_at, sent.sent_at) == :gt
    end

    test "audits an unrelated code but records nothing for a cap error naming no request" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.dispatch_to_runner(run) == :ok

      unrelated =
        Runs.RunnerError.new(
          account.id,
          runner.id,
          %{code: "exec_failed", message: "binary not found", request_id: run.request_id},
          %RequestContext{}
        )

      uncorrelated =
        Runs.RunnerError.new(
          account.id,
          runner.id,
          %{code: "concurrency_cap_reached"},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(unrelated) == {:ok, :not_applicable}
      assert Runs.handle_runner_error(uncorrelated) == {:ok, :request_not_found}

      assert Runs.peek_run_by_id(run.id).status == :sent
      assert Repo.one(Audit.Event).payload["code"] == "exec_failed"
    end

    test "records nothing for a cap refusal outside the runner's account" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      other_account = Fixtures.Accounts.create_account()
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.dispatch_to_runner(run) == :ok

      command =
        Runs.RunnerError.new(
          other_account.id,
          runner.id,
          %{code: "concurrency_cap_reached", request_id: run.request_id},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(command) == {:ok, :request_not_found}

      assert Runs.peek_run_by_id(run.id).status == :sent
      refute Repo.one(Audit.Event)
    end

    test "records nothing for another runner's request in the same account" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      peer = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.dispatch_to_runner(run) == :ok

      command =
        Runs.RunnerError.new(
          account.id,
          peer.id,
          %{code: "concurrency_cap_reached", request_id: run.request_id},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(command) == {:ok, :request_not_found}

      assert Runs.peek_run_by_id(run.id).status == :sent
      refute Repo.one(Audit.Event)
    end

    test "is idempotent for a duplicate cap error once the run is pending" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.dispatch_to_runner(run) == :ok

      command =
        Runs.RunnerError.new(
          account.id,
          runner.id,
          %{code: "concurrency_cap_reached", request_id: run.request_id},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(command) == {:ok, :requeued}
      requeued = Runs.peek_run_by_id(run.id)

      assert Runs.handle_runner_error(command) == {:ok, :already_pending}

      duplicate = Runs.peek_run_by_id(run.id)
      assert duplicate.status == :pending
      assert duplicate.queued_at == requeued.queued_at
      assert length(Repo.all(Audit.Event)) == 2
    end

    test "reports the status of a run that is no longer dispatchable" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.dispatch_to_runner(run) == :ok

      {:ok, _running} =
        Runs.mark_started_from_connection(
          account.id,
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          run.request_id
        )

      command =
        Runs.RunnerError.new(
          account.id,
          runner.id,
          %{code: "concurrency_cap_reached", request_id: run.request_id},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(command) == {:ok, {:not_dispatchable, :running}}

      assert Runs.peek_run_by_id(run.id).status == :running
      assert Repo.one(Audit.Event).event_type == "runner.error"
    end

    test "bounds the runner-controlled code and message it stores" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      command =
        Runs.RunnerError.new(
          account.id,
          runner.id,
          %{code: String.duplicate("c", 500), message: String.duplicate("m", 5_000)},
          %RequestContext{}
        )

      assert Runs.handle_runner_error(command) == {:ok, :not_applicable}

      event = Repo.one(Audit.Event)
      assert String.length(event.payload["code"]) == 100
      assert String.length(event.payload["message"]) == 500
    end

    test "returns the error and persists nothing when the audit row cannot be written" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert Runs.dispatch_to_runner(run) == :ok

      command =
        Runs.RunnerError.new(
          account.id,
          "not-a-runner-id",
          %{code: "exec_failed"},
          %RequestContext{}
        )

      assert {:error, changeset} = Runs.handle_runner_error(command)
      assert "is invalid" in errors_on(changeset).target_id

      refute Repo.one(Audit.Event)
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

      assert Runs.dispatch_to_runner(run) == :ok
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

      assert Runs.append_event(run, %{
               seq: 1,
               kind: "progress",
               stream: "stdout",
               payload: %{"chunk" => "ok\n"}
             }) == {:error, :duplicate_event}

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
      assert Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}}) ==
               {:error, :duplicate_event}
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
      assert Runs.append_event(finished, %{
               seq: 99,
               kind: "progress",
               payload: %{"chunk" => "x"}
             }) == {:error, :run_terminal}

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
      assert Runs.append_event(run, %{seq: 2, kind: "progress", payload: %{"chunk" => "b"}}) ==
               {:error, :progress_budget_exceeded}
    end

    test "refuses a chunk that would exceed the per-run byte budget", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      # Sitting on the byte ceiling, so any non-empty chunk tips it over.
      Fixtures.Runs.charge_progress_budget(run, bytes: 67_108_864)

      assert Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "x"}}) ==
               {:error, :progress_budget_exceeded}

      refute Repo.exists?(RunEvent)
    end

    test "append_event/2 with an unknown run id returns :unknown_run" do
      assert Runs.append_event(Repo.generate_id(), %{seq: 1, kind: "progress", payload: %{}}) ==
               {:error, :unknown_run}
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

      assert Runs.append_event_from_connection(
               sent.id,
               %{seq: 3, kind: "progress", payload: %{"line" => "stale"}},
               account.id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id
             ) == {:error, :connection_superseded}

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
        Runs.create_run(
          base_attrs(account.id, runner.id, %{
            status: :pending_approval,
            policy_decision: "require_approval"
          })
        )

      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      {:ok, parked} = Repo.update(Ecto.Changeset.change(parked, queued_at: past))

      assert {:ok,
              %{
                released: %ActionRun{
                  status: :pending,
                  queued_at: queued_at,
                  policy_decision: "require_approval"
                }
              }} =
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
      subject = owner_subject_for(account)

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
    test "persists bounded structured output and terminalizes hostile values" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      typed_schema = %{
        "type" => "object",
        "required" => ["ok"],
        "properties" => %{"ok" => %{"type" => "boolean"}},
        "additionalProperties" => false
      }

      typed_attrs = %{
        structured_output_expected: true,
        output_schema_snapshot: typed_schema
      }

      {:ok, valid_run} = Runs.create_run(base_attrs(account.id, runner.id, typed_attrs))

      assert {:ok, %ActionRun{status: :success, structured_output: %{"ok" => true}}} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{
                   "request_id" => valid_run.request_id,
                   "status" => "success",
                   "structured_output" => %{"ok" => true}
                 }
               )

      {:ok, hostile_run} = Runs.create_run(base_attrs(account.id, runner.id, typed_attrs))

      assert {:ok,
              %ActionRun{
                status: :validation_failed,
                structured_output: nil,
                error_message: "runner sent an invalid structured output value"
              }} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{
                   "request_id" => hostile_run.request_id,
                   "status" => "success",
                   "structured_output" => %{"value" => String.duplicate("x", 8_192)}
                 }
               )

      for hostile_output <- [
            Enum.reduce(1..16, %{"leaf" => true}, fn _index, child -> %{"next" => child} end),
            %{"values" => Enum.to_list(1..1_024)}
          ] do
        {:ok, hostile_run} = Runs.create_run(base_attrs(account.id, runner.id, typed_attrs))

        assert {:ok, %ActionRun{status: :validation_failed, structured_output: nil}} =
                 Runs.finalize_from_connection(
                   account.id,
                   runner.id,
                   runner.connection_generation,
                   runner.connection_lease_id,
                   %{
                     "request_id" => hostile_run.request_id,
                     "status" => "success",
                     "structured_output" => hostile_output
                   }
                 )
      end

      {:ok, mismatched_run} = Runs.create_run(base_attrs(account.id, runner.id, typed_attrs))

      assert {:ok,
              %ActionRun{
                status: :validation_failed,
                structured_output: nil,
                error_message: "runner structured output does not match the trusted schema"
              }} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{
                   "request_id" => mismatched_run.request_id,
                   "status" => "success",
                   "structured_output" => %{"ok" => "true"}
                 }
               )

      {:ok, missing_run} = Runs.create_run(base_attrs(account.id, runner.id, typed_attrs))

      assert {:ok,
              %ActionRun{
                status: :validation_failed,
                error_message: "runner omitted required structured output"
              }} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{"request_id" => missing_run.request_id, "status" => "success"}
               )

      {:ok, unexpected_run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok,
              %ActionRun{
                status: :validation_failed,
                error_message: "runner sent structured output for an untyped action"
              }} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{
                   "request_id" => unexpected_run.request_id,
                   "status" => "success",
                   "structured_output" => %{"ok" => true}
                 }
               )
    end

    test "drops structured output attached to a stronger execution failure" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :failed, structured_output: nil}} =
               Runs.finalize_from_connection(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 runner.connection_lease_id,
                 %{
                   "request_id" => run.request_id,
                   "status" => "failed",
                   "structured_output" => %{"untrusted" => true}
                 }
               )
    end

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

      assert Runs.finalize_from_connection(
               account.id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               %{"request_id" => sent.request_id, "status" => "success"}
             ) == {:error, :connection_superseded}

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

      assert Runs.finalize_from_connection(
               account.id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               %{"request_id" => "req_does_not_exist", "status" => "success"}
             ) == {:error, :unknown_request_id}
    end

    test "a runner cannot finalize another runner's run in the same account" do
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner_a.id))

      assert Runs.finalize_from_connection(
               account.id,
               runner_b.id,
               runner_b.connection_generation,
               runner_b.connection_lease_id,
               %{"request_id" => run.request_id, "status" => "success"}
             ) == {:error, :unknown_request_id}
    end

    test "requires a request id" do
      assert Runs.finalize_from_connection("account", "runner", 1, "lease", %{}) ==
               {:error, :missing_request_id}
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
               Runs.list_recent_events_for_run(run, 3, subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Runs.list_recent_events_for_run(run, 3, subject_b) == {:error, :not_found}
    end
  end

  describe "list_recent_events_for_runs/3" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "caps each run independently, orders tails, and fails closed for mixed access", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, first} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, second} = Runs.create_run(base_attrs(account.id, runner.id))

      for run <- [first, second], seq <- 1..4 do
        {:ok, _event} =
          Runs.append_event(run, %{
            seq: seq,
            kind: "progress",
            stream: if(seq == 4, do: "stderr", else: "stdout"),
            payload: %{"chunk" => "#{run.id}:#{seq}\n"}
          })
      end

      assert {:ok, events_by_run} =
               Runs.list_recent_events_for_runs([first.id, second.id], 2, subject)

      assert Enum.map(events_by_run[first.id], & &1.seq) == [3, 4]
      assert Enum.map(events_by_run[second.id], & &1.seq) == [3, 4]
      assert List.last(events_by_run[first.id]).stream == "stderr"

      {_other_owner, other_account, _other_subject} = Fixtures.Subjects.owner_subject()
      other_runner = Fixtures.Runners.create_runner(account_id: other_account.id)
      {:ok, hidden} = Runs.create_run(base_attrs(other_account.id, other_runner.id))

      assert Runs.list_recent_events_for_runs([first.id, hidden.id], 2, subject) ==
               {:error, :not_found}
    end

    test "denies a principal without run visibility", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.list_recent_events_for_runs([run.id], 2, no_permissions_subject(account)) ==
               {:error, :unauthorized}
    end

    test "refuses more run ids than the cap instead of raising", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      at_cap = List.duplicate(run.id, 256)

      assert {:ok, %{}} = Runs.list_recent_events_for_runs(at_cap, 2, subject)

      assert Runs.list_recent_events_for_runs([run.id | at_cap], 2, subject) ==
               {:error, :too_many_run_ids}
    end
  end

  describe "list_events_for_run_since/4" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "returns progress chunks from the seq (inclusive), chronologically", %{
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

      assert {:ok, [%RunEvent{seq: 3}, %RunEvent{seq: 4}, %RunEvent{seq: 5}], false} =
               Runs.list_events_for_run_since(run.id, 3, 1_000, subject)
    end

    test "caps at the byte budget and stays forward-lossless across the seq", %{
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
            payload: %{"chunk" => String.duplicate("a", 4)}
          })
      end

      # The budget is charged on the stored payload, not the chunk string, so
      # 32 bytes fits two 16-byte `{"chunk":"aaaa"}` rows; `more?` flags the cut.
      assert {:ok, [%RunEvent{seq: 1}, %RunEvent{seq: 2}], true} =
               Runs.list_events_for_run_since(run.id, 1, 32, subject)

      assert {:ok, [%RunEvent{seq: 3}, %RunEvent{seq: 4}], true} =
               Runs.list_events_for_run_since(run.id, 3, 32, subject)

      # The tail exhausts without repeating or skipping anything.
      assert {:ok, [%RunEvent{seq: 5}], false} =
               Runs.list_events_for_run_since(run.id, 5, 32, subject)
    end

    test "charges the payload, so a non-string chunk cannot make a page free", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      for seq <- 1..3 do
        {:ok, _} =
          Runs.append_event(run, %{
            seq: seq,
            kind: "progress",
            payload: %{"chunk" => %{"blob" => String.duplicate("a", 64)}}
          })
      end

      # Nothing requires the stored chunk to be a string. Charged on the decoded
      # chunk it read 0 bytes per event, so one page handed back every row a
      # hostile runner had banked.
      assert {:ok, [%RunEvent{seq: 1}], true} =
               Runs.list_events_for_run_since(run.id, 1, 32, subject)
    end

    test "always returns the first event, even past the budget", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, _} =
        Runs.append_event(run, %{
          seq: 1,
          kind: "progress",
          payload: %{"chunk" => String.duplicate("a", 10)}
        })

      # A budget smaller than the first chunk still ships it, so the cursor advances.
      assert {:ok, [%RunEvent{seq: 1}], false} =
               Runs.list_events_for_run_since(run.id, 1, 2, subject)
    end

    test "excludes non-progress events", %{account: account, runner: runner, subject: subject} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "out"}})
      {:ok, _} = Runs.append_event(run, %{seq: 2, kind: "transition", payload: %{}})

      {:ok, _} =
        Runs.append_event(run, %{seq: 3, kind: "progress", payload: %{"chunk" => "more"}})

      assert {:ok, [%RunEvent{seq: 1}, %RunEvent{seq: 3}], false} =
               Runs.list_events_for_run_since(run.id, 1, 1_000, subject)
    end

    test "returns an empty page at the end of output", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})

      assert Runs.list_events_for_run_since(run.id, 2, 1_000, subject) == {:ok, [], false}
    end

    test "refuses a cross-account subject", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Runs.list_events_for_run_since(run.id, 1, 1_000, subject_b) == {:error, :not_found}
    end
  end

  describe "count_progress_events_for_run/2" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "counts only persisted progress chunks", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})
      {:ok, _} = Runs.append_event(run, %{seq: 2, kind: "transition", payload: %{}})
      {:ok, _} = Runs.append_event(run, %{seq: 3, kind: "progress", payload: %{"chunk" => "b"}})

      assert Runs.count_progress_events_for_run(run.id, subject) == {:ok, 2}
    end

    test "refuses a cross-account subject", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Runs.count_progress_events_for_run(run.id, subject_b) == {:error, :not_found}
    end
  end

  describe "materialize_runbook_output/4" do
    test "returns only requested persisted sources within the account boundary" do
      account = Fixtures.Accounts.create_account()
      run = Fixtures.Runs.create_run(account_id: account.id, status: :success)

      run =
        run
        |> ActionRun.Changeset.transition(:success, %{
          output_complete: true,
          structured_output: %{"ready" => true}
        })
        |> Repo.update!()

      assert {:ok,
              %{
                "structured_output" => %{"ready" => true},
                "stdout" => nil,
                "stderr" => nil
              }} =
               Runs.materialize_runbook_output(
                 run.id,
                 account.id,
                 ["structured_output"],
                 1_024
               )

      assert Runs.materialize_runbook_output(
               run.id,
               Ecto.UUID.generate(),
               ["structured_output"],
               1_024
             ) == {:error, :not_found}
    end
  end

  describe "list_events_for_run_before/4" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner, subject: subject}
    end

    test "returns the most recent progress chunks before the seq, chronologically", %{
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

      assert {:ok, [%RunEvent{seq: 2}, %RunEvent{seq: 3}, %RunEvent{seq: 4}]} =
               Runs.list_events_for_run_before(run.id, 5, 3, subject)
    end

    test "returns an empty page at the start of output", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})

      assert Runs.list_events_for_run_before(run.id, 1, 10, subject) == {:ok, []}
    end

    test "refuses a cross-account subject", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"chunk" => "a"}})

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Runs.list_events_for_run_before(run.id, 5, 10, subject_b) == {:error, :not_found}
    end
  end

  describe "subscribe_account_runs/1" do
    test "the subscriber receives the account's run create/transition feed" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runs.subscribe_account_runs(account.id) == :ok

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert_receive {:run_updated, id}, 500
      assert id == run.id
    end

    test "a subscriber to account A does not receive account B's run feed (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

      assert Runs.subscribe_account_runs(account_a.id) == :ok

      {:ok, _run_b} = Runs.create_run(base_attrs(account_b.id, runner_b.id))
      refute_receive {:run_updated, _}, 200
    end

    test "a restricted same-account subscriber can dereference historical run ids" do
      account = Fixtures.Accounts.create_account()
      _database_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web_runner = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      subject = owner_subject_for(account)
      membership = Fixtures.Memberships.fetch_membership(account.id, subject.actor.id)
      {:ok, database_access} = Emisar.Accounts.RunnerAccess.restricted(["database"], [])
      Fixtures.Memberships.force_runner_access(membership, database_access)

      restricted_subject =
        Fixtures.Subjects.subject_for(subject.actor, account, role: subject.role)

      assert Runs.subscribe_account_runs(account.id) == :ok
      {:ok, run} = Runs.create_run(base_attrs(account.id, web_runner.id))
      assert_receive {:run_updated, run_id}, 500
      assert run_id == run.id
      assert {:ok, fetched} = Runs.fetch_run_by_id(run_id, restricted_subject)
      assert fetched.id == run.id
    end
  end

  describe "subscribe_run/2" do
    test "the subscriber receives that run's transitions and progress chunks" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.subscribe_run(run.account_id, run.id) == :ok

      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "x"}})
      assert_receive {:run_event, %RunEvent{seq: 1}}, 500

      assert Runs.dispatch_to_runner(run) == :ok
      assert_receive {:run_updated, %ActionRun{status: :sent}}, 500
    end

    test "a subscriber to one run does not receive another run's updates (per-run topic)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, watched} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, other} = Runs.create_run(base_attrs(account.id, runner.id))

      assert Runs.subscribe_run(watched.account_id, watched.id) == :ok

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
      assert Runs.unsubscribe_run(run.account_id, run.id) == :ok

      assert Runs.dispatch_to_runner(run) == :ok
      refute_receive {:run_updated, _}, 200
    end
  end

  describe "broadcast_cancelled_run/1" do
    test "broadcasts the run for the {:cancelled, run} shape" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Runs.subscribe_run(account.id, run.id)

      assert Runs.broadcast_cancelled_run({:cancelled, run}) == :ok

      assert_receive {:run_updated, %ActionRun{id: id, runner: %Emisar.Runners.Runner{}}}, 500
      assert id == run.id
    end

    test "is a no-op for the :noop / :no_run shapes (nothing to announce)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Runs.subscribe_account_runs(account.id)

      assert Runs.broadcast_cancelled_run({:noop, run}) == :ok
      assert Runs.broadcast_cancelled_run(:no_run) == :ok
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

  describe "role_can_dispatch_run?/1" do
    test "uses the canonical role permission table and rejects unknown values" do
      assert Runs.role_can_dispatch_run?(:owner)
      assert Runs.role_can_dispatch_run?(:operator)
      refute Runs.role_can_dispatch_run?(:viewer)
      refute Runs.role_can_dispatch_run?("operator")
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
    test "an account-less / actor-less subject gets zero rows (fail-closed fallback)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        ActionRun.Query.all()
        |> Runs.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end
  end

  defp drain_runs_queries(pid, queries \\ []) do
    receive do
      {:runs_repo_query, ^pid, query} -> drain_runs_queries(pid, [query | queries])
      {:runs_repo_query, _other_pid, _query} -> drain_runs_queries(pid, queries)
    after
      0 -> Enum.reverse(queries)
    end
  end
end
