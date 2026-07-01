defmodule Emisar.RunsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Approvals, Repo, RequestContext, Runs}
  alias Emisar.Fixtures
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

  defp deny_all_rules do
    %{
      "schema_version" => 2,
      "defaults" => %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"},
      "overrides" => []
    }
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

      assert Keyword.has_key?(changeset.errors, :args)
    end

    test "second insert with same (api_key_id, idempotency_key) returns {:replay, original}", %{
      account: account,
      runner: runner
    } do
      # Closes the TOCTOU race in dispatch_run: the pre-flight peek is a
      # best-effort optimization; the unique index `(api_key_id,
      # idempotency_key)` is the actual correctness guarantee. When two
      # racing callers both miss the peek and try to insert, one wins
      # the index and the other gets back the winner's row instead of a
      # confusing constraint changeset.
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      attrs =
        base_attrs(account.id, runner.id, %{
          source: "mcp",
          api_key_id: key.id,
          idempotency_key: "idem-#{System.unique_integer([:positive])}"
        })

      assert {:ok, %ActionRun{} = original} = Runs.create_run(attrs)
      assert {:replay, %ActionRun{id: replayed_id}} = Runs.create_run(attrs)

      assert replayed_id == original.id
    end

    test "a different idempotency_key on the same api_key inserts a second row", %{
      account: account,
      runner: runner
    } do
      # Sanity-check the unique index isn't overreaching: same key, new
      # idempotency_key → new row, not a replay.
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      attrs1 =
        base_attrs(account.id, runner.id, %{
          source: "mcp",
          api_key_id: key.id,
          idempotency_key: "idem-a"
        })

      attrs2 = %{attrs1 | source: "mcp"} |> Map.put(:idempotency_key, "idem-b")

      assert {:ok, %ActionRun{id: a_id}} = Runs.create_run(attrs1)
      assert {:ok, %ActionRun{id: b_id}} = Runs.create_run(attrs2)

      refute a_id == b_id
    end

    test "two calls with nil idempotency_key never replay (null != null in unique index)", %{
      account: account,
      runner: runner
    } do
      # Without an Idempotency-Key the unique constraint is partial
      # (`where idempotency_key IS NOT NULL`), so two non-MCP calls don't
      # accidentally collide. Run_id is the only uniqueness gate, and
      # `Runs.generate_request_id/0` produces UUIDs so collisions are
      # essentially impossible.
      attrs = base_attrs(account.id, runner.id)

      assert {:ok, %ActionRun{id: a_id}} = Runs.create_run(attrs)
      assert {:ok, %ActionRun{id: b_id}} = Runs.create_run(attrs)

      refute a_id == b_id
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
      assert_receive {:cloud_to_runner, %{"type" => "run_action", "action_id" => "linux.uptime"}},
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

    test "an MCP key can't dispatch an action outside its action_scope — DOMAIN-enforced" do
      # The key's per-action allow-list is enforced in the domain, not only at the
      # MCP boundary — a key scoped to linux.reboot can't run linux.uptime here.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, action_scope: ["linux.reboot"])

      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:error, :action_not_in_key_scope} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "an MCP key can't dispatch to a runner outside its runner_filter — DOMAIN-enforced" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      other = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, runner_filter: [other.id])

      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:error, :runner_not_in_key_scope} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "an MCP key scoped to the action + runner dispatches normally" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: account.id,
          action_scope: ["linux.uptime"],
          runner_filter: [runner.id]
        )

      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, :running, %ActionRun{}} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "audits only the policy decision + terminal outcome, decision first" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      types = events |> Enum.filter(&(&1.subject_id == run.id)) |> Enum.map(& &1.event_type)

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
      {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])

      success =
        Enum.find(events, &(&1.subject_id == run.id and &1.event_type == "action_run.success"))

      assert success.ip_address == "203.0.113.7"
      assert success.user_agent == "Codex-CLI/1.0"
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

      assert_receive {:cloud_to_runner, payload}, 500
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
            "overrides" => []
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
            ]
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
      types = events |> Enum.filter(&(&1.subject_id == run.id)) |> Enum.map(& &1.event_type)
      assert "action_run.pending_approval" in types
      refute "policy.evaluated" in types
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
      assert_receive {:cloud_to_runner, payload}, 500
      assert payload["attestation"] == attestation
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

      # Persisted args come back byte-equal after the jsonb round-trip…
      assert Repo.reload!(run).args == rich_args
      # …and the wire envelope carries them verbatim.
      assert_receive {:cloud_to_runner, payload}, 500
      assert payload["args"] == rich_args
    end

    test "a portal-originated run carries no attestation on the wire" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, _run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
      assert_receive {:cloud_to_runner, payload}, 500
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
      assert blocked.subject_kind == "runner"
      assert blocked.subject_id == runner.id
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

      assert Keyword.has_key?(changeset.errors, :args)

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

    test "a previously-denied dispatch replays to the same deny tuple, audited once" do
      # An MCP-sourced dispatch carrying an api_key + idempotency_key replays the
      # cached :denied row back into the deny tuple via replay_outcome, not a
      # running run. The deny is logged exactly once (the replay path runs no audit).
      deny_high = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "deny",
          "medium" => "deny",
          "high" => "deny",
          "critical" => "deny"
        },
        "overrides" => []
      }

      {subject, attrs} = replayable_dispatch(deny_high)

      assert {:error, :denied_by_policy, reason} = Runs.dispatch_run(attrs, subject)
      assert {:error, :denied_by_policy, ^reason} = Runs.dispatch_run(attrs, subject)

      # Exactly one denied run row and one action_run.denied audit row — the
      # replay re-shaped the original, it didn't dispatch or re-audit. The
      # audit-logging diet dropped the separate policy.evaluated row, so the
      # action_run.denied terminal row IS the denial's audit trail (#2: a denial
      # is always audited exactly once — never zero rows).
      assert {:ok, [%ActionRun{status: :denied}], _} = Runs.list_recent_runs(subject, limit: 50)

      denied =
        Repo.all(Emisar.Audit.Event) |> Enum.filter(&(&1.event_type == "action_run.denied"))

      assert length(denied) == 1
    end

    test "a previously-parked dispatch replays to the same pending_approval tuple" do
      # Replaying a previously-PARKED dispatch re-shapes the cached
      # :pending_approval row to the same {:ok, :pending_approval, run} (the
      # request to long-poll), and never files a second request or pushes a
      # second envelope.
      approval_high = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "allow",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => []
      }

      {subject, attrs} = replayable_dispatch(approval_high)

      assert {:ok, :pending_approval, %ActionRun{id: id}} = Runs.dispatch_run(attrs, subject)
      assert {:ok, :pending_approval, %ActionRun{id: ^id}} = Runs.dispatch_run(attrs, subject)

      # One parked run, one pending request — the replay didn't re-file.
      assert {:ok, [%ActionRun{status: :pending_approval}], _} =
               Runs.list_recent_runs(subject, limit: 50)

      assert {:ok, [_one], _} = Approvals.list_pending_approval_requests(subject)

      # …and no second run_action envelope was ever pushed (it never dispatched).
      refute_receive {:cloud_to_runner, _}, 100
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

    # An MCP-sourced dispatch carrying an api_key + idempotency_key, against an
    # online runner that advertises the action under `policy`. Returns
    # subject/attrs so a test can replay the same dispatch.
    defp replayable_dispatch(policy_rules) do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")
      Emisar.Runners.subscribe_runner_transport(runner)
      _ = Fixtures.Policies.create_policy(account_id: account.id, rules: policy_rules)

      attrs =
        base_attrs(account.id, runner.id, %{
          source: "mcp",
          api_key_id: key.id,
          idempotency_key: "idem-#{System.unique_integer([:positive])}"
        })

      {subject, attrs}
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
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
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

    test "passes when the runner no longer advertises the action (nothing to dispatch to)", %{
      account: account,
      runner: runner
    } do
      # when the runner no longer advertises the action mid approval-window
      # (offline / pack unloaded), recheck returns :ok: there is nothing live to
      # ship the wrong bytes to, so the gate doesn't block. The drift-to-:pending
      # threat is the OTHER clause above; the dispatch itself then fails to reach
      # a live action.
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
      {:ok, run} =
        Runs.create_run(
          base_attrs(account.id, runner.id, %{attestation: %{"issued_at" => issued_at}})
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

    test "an unsigned run passes — the gate only applies to signed dispatch", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert :ok = Runs.check_run_attestation_fresh(run.id)
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

    test "worker times out a stale run whose runner is offline", %{
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

      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(ActionRun, run.id)
      assert reloaded.status == :error
      assert reloaded.error_message =~ "offline"
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

      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})

      assert Repo.get!(ActionRun, run.id).status == :sent
    end
  end

  describe "redispatch_inflight_for_runner/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "re-dispatches the runner's in-flight :pending and :sent runs", %{
      account: account,
      runner: runner
    } do
      {:ok, sent} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, sent} = Runs.mark_sent(sent)
      # Backdate sent_at so a re-dispatch's fresh mark_sent jumps it forward.
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      sent = sent |> Ecto.Changeset.change(sent_at: past) |> Repo.update!()

      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))
      assert pending.status == :pending

      assert :ok = Runs.redispatch_inflight_for_runner(runner.id)

      resent = Runs.peek_run_by_id(sent.id)
      assert resent.status == :sent
      assert DateTime.compare(resent.sent_at, sent.sent_at) == :gt
      assert Runs.peek_run_by_id(pending.id).status == :sent
    end

    test "leaves :running, terminal, and other-runner runs untouched (no double-exec)", %{
      account: account,
      runner: runner
    } do
      other = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, running} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.mark_sent(running)
      {:ok, running} = Runs.mark_running(running)

      {:ok, other_sent} = Runs.create_run(base_attrs(account.id, other.id))
      {:ok, other_sent} = Runs.mark_sent(other_sent)

      assert :ok = Runs.redispatch_inflight_for_runner(runner.id)

      # A :running run is excluded by the [:pending, :sent] filter — never re-sent.
      reloaded_running = Runs.peek_run_by_id(running.id)
      assert reloaded_running.status == :running
      assert DateTime.compare(reloaded_running.sent_at, running.sent_at) == :eq

      # Another runner's in-flight run is out of scope — untouched.
      reloaded_other = Runs.peek_run_by_id(other_sent.id)
      assert DateTime.compare(reloaded_other.sent_at, other_sent.sent_at) == :eq
    end
  end

  describe "list_running_runs/0" do
    test "returns only in-flight rows" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.mark_sent(running)
      {:ok, running} = Runs.mark_running(running)

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
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
      assert Runs.peek_run_by_id(run.id).status == :sent
    end

    test "refuses to publish a run that's no longer dispatchable (closes the publish-before-mark_sent hole)",
         %{account: account, runner: runner} do
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      # The run reaches a terminal state (e.g. cancelled) before delivery.
      {:ok, _} = run |> Ecto.Changeset.change(status: :cancelled) |> Repo.update()

      # The envelope is published BEFORE mark_sent, so the status guard must
      # block it HERE — nothing should reach the runner.
      assert {:error, :not_dispatchable} = Runs.dispatch_to_runner(run)
      refute_receive {:cloud_to_runner, _}, 100
    end

    test "a pack drifting to pending after authorization is refused at send, not shipped hash-less",
         %{account: account} do
      {_user, owner_account, subject} = Fixtures.Subjects.owner_subject()
      _ = account
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
              "args" => []
            }
          ]
        })

      # Redelivery must NOT ship a hash-less envelope — it refuses the run.
      assert {:error, :pack_untrusted} = Runs.dispatch_to_runner(run)
      assert Runs.peek_run_by_id(run.id).status == :refused
    end

    test "ships the hash snapshotted at authorization, not a re-read after re-trust (MAJOR-5)" do
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
      assert_receive {:cloud_to_runner, %{"expected_pack_hash" => "sha256:NOPE"}}, 500

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
              "args" => []
            }
          ]
        })

      {:ok, [drifted], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(drifted.id, subject)

      # Redelivery ships the ORIGINAL snapshot (NOPE), never the new trusted hash.
      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, %{"expected_pack_hash" => "sha256:NOPE"}}, 500
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
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      assert {:ok, ^finished} = Runs.cancel_run(finished, subject, "no need")
    end

    test "cancelling a running run transitions to :cancelled + broadcasts", %{
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

      Emisar.Runs.subscribe_account_runs(account.id)

      assert {:ok, %ActionRun{status: :cancelled, cancelled_at: %DateTime{}}} =
               Runs.cancel_run(run, subject, "user pressed stop")

      # Payload contract: runner is preloaded so subscribers (e.g.
      # RunDetailLive's meta strip) can render `runner.name` without
      # tripping over `%Ecto.Association.NotLoaded{}`.
      assert_receive {:run_updated,
                      %ActionRun{status: :cancelled, runner: %Emisar.Runners.Runner{}}},
                     500
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
            "overrides" => []
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

      {:ok, run} = Runs.mark_sent(run)

      assert {:ok, %ActionRun{} = cancelled} = Runs.cancel_run(run, subject, "user pressed stop")
      assert cancelled.reason_text == "user pressed stop"
      assert cancelled.reason == "operator why"
      assert is_nil(cancelled.error_message)
    end
  end

  describe "mark_sent/1" do
    test "moves :pending → :sent and stamps sent_at" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert run.status == :pending

      assert {:ok, %ActionRun{status: :sent, sent_at: %DateTime{}}} = Runs.mark_sent(run)
    end

    test "is a no-op on an already-terminal run (never re-opens it)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      assert {:ok, _} = Runs.mark_sent(finished)
      assert Runs.peek_run_by_id(run.id).status == :success
    end
  end

  describe "mark_running/1" do
    test "moves :sent → :running and stamps started_at" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, sent} = Runs.mark_sent(run)

      assert {:ok, %ActionRun{status: :running, started_at: %DateTime{}}} =
               Runs.mark_running(sent)
    end
  end

  describe "mark_cancelled/2" do
    test "moves a non-terminal run → :cancelled, stamping cancelled_at + reason_text" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, sent} = Runs.mark_sent(run)

      assert {:ok,
              %ActionRun{
                status: :cancelled,
                cancelled_at: %DateTime{},
                finished_at: %DateTime{},
                reason_text: "operator cancelled"
              }} = Runs.mark_cancelled(sent, "operator cancelled")
    end

    test "a late result holding a stale struct can't overwrite the cancelled status" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, sent} = Runs.mark_sent(run)

      # An operator cancel lands while the runner's result is in flight…
      {:ok, cancelled} = Runs.mark_cancelled(sent, "operator cancelled")
      assert cancelled.status == :cancelled

      # …and the late result arrives still holding the PRE-cancel struct.
      # The locked re-read must keep the run final instead of letting the
      # stale writer flip cancelled → success.
      assert {:ok, _} = Runs.mark_finished(sent, %{"status" => "success"})
      assert Runs.peek_run_by_id(run.id).status == :cancelled
    end
  end

  describe "cancel_run_in_multi/3" do
    test "composes the cancel into a caller's transaction, landing {:cancelled, run} in changes" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _sent} = Runs.mark_sent(run)

      assert {:ok, %{run_cancel: {:cancelled, %ActionRun{status: :cancelled} = cancelled}}} =
               Ecto.Multi.new()
               |> Runs.cancel_run_in_multi(run.id, "composed cancel")
               |> Repo.commit_multi()

      assert cancelled.id == run.id
      assert cancelled.reason_text == "composed cancel"
      assert Runs.peek_run_by_id(run.id).status == :cancelled
    end

    test "an already-terminal run yields {:noop, run} — no transition, no audit row" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

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

      assert {:ok, %ActionRun{status: :error, error_message: msg, finished_at: %DateTime{}}} =
               Runs.mark_errored(run, "runner was disconnected")

      assert msg =~ "disconnected"
    end
  end

  describe "mark_finished/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "walks the valid sequence pending → sent → running → success", %{
      account: account,
      runner: runner
    } do
      # the valid forward path pending → sent → running → success, each
      # transition stamping its own timestamp. The terminal flip is the only
      # one that's final.
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert run.status == :pending

      {:ok, sent} = Runs.mark_sent(run)
      assert sent.status == :sent
      assert %DateTime{} = sent.sent_at

      {:ok, running} = Runs.mark_running(sent)
      assert running.status == :running
      assert %DateTime{} = running.started_at

      {:ok, finished} = Runs.mark_finished(running, %{"status" => "success", "duration_ms" => 4})
      assert finished.status == :success
      assert %DateTime{} = finished.finished_at
      assert ActionRun.terminal?(:success)
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
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      assert finished.status == :success

      # A duplicate result, a stray mark_sent, and a stray mark_running are all
      # idempotent no-ops — none re-advances a settled run.
      assert {:ok, _} = Runs.mark_finished(finished, %{"status" => "failed"})
      assert {:ok, _} = Runs.mark_sent(finished)
      assert {:ok, _} = Runs.mark_running(finished)
      assert Runs.peek_run_by_id(run.id).status == :success
    end

    test "a failed result writes error_message only; reason_text stays nil", %{
      account: account,
      runner: runner
    } do
      {:ok, run} =
        Runs.create_run(base_attrs(account.id, runner.id, %{reason: "operator why"}))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
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
        {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 5})
      end)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      failed = Enum.find(events, &(&1.event_type == "runbook.step_dispatch_failed"))

      assert failed, "expected a runbook.step_dispatch_failed audit row"
      assert failed.subject_kind == "runbook"
      assert failed.subject_id == runbook.id
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
        {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 5})
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
      {:ok, sent} = Runs.mark_sent(run)

      assert {:ok, %RunEvent{seq: 1}} =
               Runs.append_event(sent, %{seq: 1, kind: "progress", payload: %{"line" => "go"}})

      assert Runs.peek_run_by_id(run.id).status == :running
    end

    test "a chunk for an already-finalized run is dropped without re-opening it", %{
      account: account,
      runner: runner
    } do
      # a progress chunk that arrives AFTER the run reached a terminal state is
      # persisted as a benign event but never resurrects the run: the :sent →
      # :running flip in append_event/2 only fires from :sent, so a finished run
      # stays finished. No error, no resurrection.
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      assert finished.status == :success

      # A late chunk lands — it appends (the appender doesn't gate on terminal),
      # but the status guard means it can't flip a terminal run back to :running.
      assert {:ok, %RunEvent{seq: 99}} =
               Runs.append_event(finished, %{
                 seq: 99,
                 kind: "progress",
                 payload: %{"chunk" => "x"}
               })

      assert Runs.peek_run_by_id(run.id).status == :success
    end

    test "append_event/2 with an unknown run id returns :unknown_run" do
      assert {:error, :unknown_run} =
               Runs.append_event(Repo.generate_id(), %{seq: 1, kind: "progress", payload: %{}})
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
      {:ok, sent} = Runs.mark_sent(run)

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

  describe "finalize_from_result/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, runner: runner}
    end

    test "success result transitions the run", %{account: account, runner: runner} do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :success}} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => run.request_id,
                 "status" => "success",
                 "exit_code" => 0,
                 "duration_ms" => 12
               })
    end

    test "persists executed_command and carries it into the audit event", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :success, executed_command: "uptime -p"}} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => run.request_id,
                 "status" => "success",
                 "exit_code" => 0,
                 "executed_command" => "uptime -p"
               })

      # The terminal run audit event records what actually ran.
      event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.subject_id == run.id and &1.event_type == "action_run.success"))

      assert event.payload["executed_command"] == "uptime -p"
    end

    test "a refusal's human `error` sentence is surfaced as error_message, not the terse code", %{
      account: account,
      runner: runner
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      # A signature/pack refusal carries both: a terse `reason` code and a human
      # `error` sentence. The operator must see the sentence.
      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
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
          Runs.finalize_from_result(runner.id, %{"request_id" => run.request_id, "status" => wire})

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
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "failed",
          "reason" => "exit status 1"
        })

      assert finished.error_message == "exit status 1"
    end

    test "unknown request_id returns {:error, :unknown_request_id}", %{runner: runner} do
      assert {:error, :unknown_request_id} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => "req_does_not_exist",
                 "status" => "success"
               })
    end

    test "a runner cannot finalize another runner's run in the same account", %{account: account} do
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner_a.id))

      assert {:error, :unknown_request_id} =
               Runs.finalize_from_result(runner_b.id, %{
                 "request_id" => run.request_id,
                 "status" => "success"
               })
    end

    test "an unrecognized result status defaults to :failed", %{account: account, runner: runner} do
      # an unrecognized result-status string defaults to :failed rather than
      # crashing or inventing a status (the mapping table's fail-safe fallback;
      # a compromised/buggy runner can't mint a new state).
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :failed}} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => run.request_id,
                 "status" => "totally-made-up-status"
               })
    end

    test "with no request_id returns :missing_request_id" do
      assert {:error, :missing_request_id} = Runs.finalize_from_result("runner-123", %{})
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

  describe "subscribe_run/2" do
    test "the subscriber receives that run's transitions and progress chunks" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.subscribe_run(run.account_id, run.id)

      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "x"}})
      assert_receive {:run_event, %RunEvent{seq: 1}}, 500

      {:ok, _} = Runs.mark_sent(run)
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
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      :ok = Runs.subscribe_run(run.account_id, run.id)
      assert :ok = Runs.unsubscribe_run(run.account_id, run.id)

      {:ok, _} = Runs.mark_sent(run)
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
