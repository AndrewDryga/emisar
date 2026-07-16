defmodule EmisarWeb.MCPRunbookRecoveryToolsTest do
  use EmisarWeb.ConnCase, async: true
  import EmisarWeb.MCPContractAssertions
  alias Emisar.{ApiKeys, Approvals, Catalog, Crypto, Repo, Runbooks, Runners, Runs}
  alias Emisar.MCPOperations.Operation
  alias Emisar.Runs.ActionRun
  alias EmisarWeb.MCP.ResponseBudget

  @hash "sha256:" <> String.duplicate("b", 64)
  @pack_ref "operations@1.0.0/#{@hash}"

  setup %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    _policy = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {:ok, raw, key} = ApiKeys.create_key(%{name: "fixed-tools", kind: :mcp}, subject)

    {:ok,
     conn: authorize(conn, raw),
     account: account,
     user: user,
     subject: subject,
     membership: membership,
     key: key,
     raw: raw}
  end

  test "native runbook mutations, recovery, and immediate waits share one contract", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    :ok = Runners.subscribe_runner_transport(runner)
    runner_ref = runner_ref(runner)
    runbook = publish_runbook!(subject, "database-health", %{"runner_id" => [runner.id]})

    listed = call(conn, "list_runbooks", %{})
    assert [%{"runbook_ref" => "database-health@1", "step_count" => 1}] = listed["runbooks"]

    fetched = call(conn, "get_runbook", %{"runbook_ref" => "database-health@1"})

    assert %{
             "step_id" => "check",
             "action_id" => "operations.health",
             "pack_ref" => @pack_ref,
             "runner_selector" => %{"runner_refs" => [^runner_ref]}
           } = hd(fetched["runbook"]["steps"])

    refute Map.has_key?(hd(fetched["runbook"]["steps"]), "depends_on")

    draft_args = %{
      "title" => "Check database fleet",
      "steps" => [
        %{
          "step_id" => "check",
          "action_id" => "operations.health",
          "pack_ref" => @pack_ref,
          "args" => %{},
          "runner_selector" => %{"runner_refs" => [runner_ref]}
        }
      ]
    }

    draft = call(conn, "create_runbook_draft", draft_args)
    draft_operation = draft["operation_id"]

    observe_catalog!(runner, %{}, [])
    replayed_draft = call(conn, "create_runbook_draft", draft_args)
    assert replayed_draft == draft

    observe_catalog!(
      runner,
      %{"operations" => %{"version" => "1.0.0", "hash" => @hash}},
      [action()]
    )

    trust_all!(subject)

    recovered_draft = call(conn, "get_operation", %{"operation_id" => draft_operation})
    assert recovered_draft["operation"]["draft_id"] == draft["draft_id"]

    execution =
      call(
        conn,
        "execute_runbook",
        %{
          "runbook_ref" => "#{runbook.slug}@#{runbook.version}",
          "reason" => "Verify database health"
        }
      )

    execute_operation = execution["operation_id"]
    assert_receive {:cloud_to_runner, _generation, _payload}, 500
    assert execution["execution"]["run_count"] == nil
    execution_id = execution["execution"]["runbook_execution_id"]

    assert [%{"run_count" => 1, "status_counts" => status_counts}] =
             execution["execution"]["steps"]

    assert Enum.sum(Map.values(status_counts)) == 1

    assert {:ok, _deleted} = Runbooks.delete_runbook(runbook, subject)

    replayed_execution =
      call(
        conn,
        "execute_runbook",
        %{
          "runbook_ref" => "database-health@1",
          "reason" => "Verify database health"
        }
      )

    assert replayed_execution["execution"]["runbook_execution_id"] == execution_id
    refute_receive {:cloud_to_runner, _generation, _payload}, 100

    recovered_execution = call(conn, "get_operation", %{"operation_id" => execute_operation})
    assert recovered_execution["operation"]["runbook_execution_id"] == execution_id

    history = call(conn, "recent_runs", %{"runbook_execution_id" => execution_id})
    assert [%{"runbook_execution_id" => ^execution_id, "run_id" => run_id}] = history["runs"]

    waited_run = call(conn, "wait_for_run", %{"run_id" => run_id, "timeout" => "0"})
    assert waited_run["run"]["run_id"] == run_id

    {:ok, [stored_run]} = Runs.list_runs_by_runbook_execution(execution_id, subject)

    {:ok, _finished} =
      Fixtures.Runs.finish(stored_run, %{"status" => "success", "duration_ms" => 7})

    waited_execution =
      call(conn, "wait_for_run", %{
        "runbook_execution_id" => execution_id,
        "timeout" => "0"
      })

    assert waited_execution["execution"]["status"] == "success"
    refute Map.has_key?(waited_execution["execution"], "next")

    rejected_wait =
      call(
        conn,
        "execute_runbook",
        %{
          "runbook_ref" => "database-health@1",
          "reason" => "Do not ignore this field",
          "wait" => "0"
        },
        "op_324NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert rejected_wait["error"]["code"] == "invalid_args"

    assert Repo.aggregate(Operation, :count) == 2
  end

  test "console-authored and seeded runbooks without pack refs list and execute via MCP", %{
    conn: conn,
    account: account,
    subject: subject,
    user: user
  } do
    runner = setup_runner!(account, subject, "edge-primary", group: "edge-web")
    :ok = Runners.subscribe_runner_transport(runner)

    editor_conn = log_in_user(build_conn(), user)
    {:ok, lv, _html} = live(editor_conn, ~p"/app/#{account}/runbooks/new")

    render_change(lv, "meta_change", %{"title" => "Console edge health", "slug" => "console-edge"})

    render_change(lv, "step_change", %{
      "index" => "0",
      "step_id" => "check",
      "action_id" => "operations.health",
      "selector_kind" => "group",
      "selector_values" => ["edge-web"]
    })

    assert {:error, {:live_redirect, _}} = render_click(lv, "publish", %{})
    assert [%{slug: "console-edge"} = console_runbook] = Repo.all(Emisar.Runbooks.Runbook)

    seeded_runbook =
      publish_runbook!(subject, "seeded-edge", %{"group" => ["edge-web"]},
        include_pack_ref: false
      )

    listed = call(conn, "list_runbooks", %{})
    listed_refs = Enum.map(listed["runbooks"], & &1["runbook_ref"])
    assert Enum.sort(listed_refs) == ["console-edge@1", "seeded-edge@1"]

    for runbook_ref <- ["console-edge@1", "seeded-edge@1"] do
      fetched = call(conn, "get_runbook", %{"runbook_ref" => runbook_ref})
      assert [%{"pack_ref" => @pack_ref}] = fetched["runbook"]["steps"]
    end

    console_execution =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "console-edge@1", "reason" => "Check the edge host"},
        "op_424NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert console_execution["ok"]
    assert_receive {:cloud_to_runner, _generation, _payload}, 500

    seeded_execution =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "seeded-edge@1", "reason" => "Check the seeded host"},
        "op_624NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert seeded_execution["ok"]
    assert_receive {:cloud_to_runner, _generation, _payload}, 500

    assert console_runbook.definition["steps"] |> hd() |> Map.has_key?("pack_ref") == false
    assert seeded_runbook.definition["steps"] |> hd() |> Map.has_key?("pack_ref") == false
  end

  test "a group runbook stays listable when one member is offline", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    _connected = setup_runner!(account, subject, "fleet-connected", group: "fleet")

    offline =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "fleet-offline",
        group: "fleet",
        connected?: false
      )

    observe_catalog!(
      offline,
      %{"operations" => %{"version" => "1.0.0", "hash" => @hash}},
      [action()]
    )

    trust_all!(subject)
    _runbook = publish_runbook!(subject, "partial-fleet", %{"group" => ["fleet"]})

    listed = call(conn, "list_runbooks", %{})
    assert Enum.any?(listed["runbooks"], &(&1["runbook_ref"] == "partial-fleet@1"))
  end

  test "draft creation rejects invalid step arguments before reserving an operation", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = Fixtures.Runners.create_runner(account_id: account.id, name: "required-args")

    observe_catalog!(
      runner,
      %{"operations" => %{"version" => "1.0.0", "hash" => @hash}},
      [action([%{"name" => "service", "type" => "string", "required" => true}])]
    )

    trust_all!(subject)

    result =
      call(conn, "create_runbook_draft", %{
        "title" => "Invalid draft",
        "steps" => [
          %{
            "step_id" => "check",
            "action_id" => "operations.health",
            "pack_ref" => @pack_ref,
            "args" => %{},
            "runner_selector" => %{"runner_refs" => [runner_ref(runner)]}
          }
        ]
      })

    refute result["ok"]
    assert result["error"]["code"] == "invalid_runbook"
    refute Repo.exists?(Operation)
  end

  test "all runbook tools hide and refuse a published selector over the MCP blast radius", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    _runners = Enum.map(1..17, &setup_runner!(account, subject, "wide-#{&1}", group: "wide"))
    _runbook = publish_runbook!(subject, "wide-book", %{"group" => ["wide"]})

    listed = call(conn, "list_runbooks", %{})
    refute Enum.any?(listed["runbooks"], &(&1["runbook_ref"] == "wide-book@1"))

    fetched = call(conn, "get_runbook", %{"runbook_ref" => "wide-book@1"})
    assert fetched["error"]["code"] == "runbook_not_found"

    executed =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "wide-book@1", "reason" => "Must remain bounded"},
        "op_324NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert executed["error"]["code"] == "runbook_not_found"
    refute Repo.exists?(Operation)
  end

  test "runbook reads and execution fail closed for hidden or signed-only targets", %{
    conn: conn,
    account: account,
    subject: subject,
    membership: membership
  } do
    visible = setup_runner!(account, subject, "visible", group: "db")

    signed =
      setup_runner!(account, subject, "signed", group: "restricted", enforce_signatures: true)

    _visible_runbook = publish_runbook!(subject, "visible-book", %{"runner_id" => [visible.id]})
    _hidden_runbook = publish_runbook!(subject, "hidden-book", %{"runner_id" => [signed.id]})

    assert {:ok, :ok} = Runners.replace_runner_scopes(membership, [{"group", "db"}], subject)

    listed = call(conn, "list_runbooks", %{})
    assert Enum.map(listed["runbooks"], & &1["runbook_ref"]) == ["visible-book@1"]

    hidden = call(conn, "get_runbook", %{"runbook_ref" => "hidden-book@1"})
    assert hidden["error"]["code"] == "runbook_not_found"

    assert {:ok, :ok} = Runners.replace_runner_scopes(membership, [], subject)

    rejected =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "hidden-book@1", "reason" => "Inspect signed host"},
        "op_324NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert rejected["error"]["code"] == "signed_runbook_unsupported"
    assert rejected["dispatch_started"] == false
    refute Repo.exists?(Operation)
  end

  test "recent history paginates at fifteen and survives credential rotation", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runners = Enum.map(1..16, &setup_runner!(account, subject, "fleet-#{&1}", group: "fleet"))

    _runbook = publish_runbook!(subject, "fleet-health", %{"group" => ["fleet"]})
    operation_ids = ~w(
      op_424NN9NMDZ1T76NARWCKM5A0D6
      op_425NN9NMDZ1T76NARWCKM5A0D6
      op_426NN9NMDZ1T76NARWCKM5A0D6
      op_427NN9NMDZ1T76NARWCKM5A0D6
    )

    executions =
      Enum.map(
        operation_ids,
        &call(
          conn,
          "execute_runbook",
          %{"runbook_ref" => "fleet-health@1", "reason" => "Verify the fleet"},
          &1
        )
      )

    operation_id = hd(operation_ids)
    execution = hd(executions)

    execution_id = execution["execution"]["runbook_execution_id"]
    first = call(conn, "recent_runs", %{})
    assert length(first["runs"]) == 15
    assert is_binary(first["next_cursor"])

    second = call(conn, "recent_runs", %{"cursor" => first["next_cursor"]})
    assert length(second["runs"]) == 5
    assert second["next_cursor"] == nil

    wrong_query =
      call(conn, "recent_runs", %{
        "scope" => "account",
        "cursor" => first["next_cursor"]
      })

    assert wrong_query["error"]["code"] == "invalid_cursor"

    {:ok, successor_raw, _successor} = ApiKeys.rotate_api_key(key, subject)
    successor_conn = authorize(build_conn(), successor_raw)

    recovered = call(successor_conn, "get_operation", %{"operation_id" => operation_id})
    assert recovered["operation"]["runbook_execution_id"] == execution_id
    assert length(call(successor_conn, "recent_runs", %{})["runs"]) == 15

    {:ok, independent_raw, _independent} =
      ApiKeys.create_key(%{name: "independent", kind: :mcp}, subject)

    independent_conn = authorize(build_conn(), independent_raw)
    missing = call(independent_conn, "get_operation", %{"operation_id" => operation_id})
    assert missing["error"]["code"] == "operation_not_found"
    assert call(independent_conn, "recent_runs", %{})["runs"] == []
    assert length(call(independent_conn, "recent_runs", %{"scope" => "account"})["runs"]) == 15

    assert length(runners) == 16
  end

  test "execution summaries fail atomically after runner scope is narrowed", %{
    conn: conn,
    account: account,
    subject: subject,
    membership: membership
  } do
    db = setup_runner!(account, subject, "scope-db", group: "db")
    web = setup_runner!(account, subject, "scope-web", group: "web")

    _runbook =
      publish_runbook!(subject, "scope-health", %{"runner_id" => [db.id, web.id]})

    operation_id = "op_624NN9NMDZ1T76NARWCKM5A0D6"

    execution =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "scope-health@1", "reason" => "Verify scoped execution"},
        operation_id
      )

    execution_id = execution["execution"]["runbook_execution_id"]
    assert {:ok, :ok} = Runners.replace_runner_scopes(membership, [{"group", "db"}], subject)

    recovered = call(conn, "get_operation", %{"operation_id" => operation_id})
    assert recovered["operation"]["runbook_execution_id"] == execution_id

    hidden =
      call(conn, "wait_for_run", %{
        "runbook_execution_id" => execution_id,
        "timeout" => "0"
      })

    assert hidden["error"]["code"] == "run_not_found"

    history = call(conn, "recent_runs", %{"runbook_execution_id" => execution_id})
    assert [%{"runner_ref" => runner_ref}] = history["runs"]
    assert runner_ref == runner_ref(db)
    refute Jason.encode!(history) =~ runner_ref(web)
  end

  test "recent history shares one UTF-8-safe output budget across every run", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runners =
      Enum.map(1..3, &setup_runner!(account, subject, "output-#{&1}", group: "output"))

    _runbook = publish_runbook!(subject, "output-preview", %{"group" => ["output"]})

    execution =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "output-preview@1", "reason" => "Inspect bounded output"},
        "op_724NN9NMDZ1T76NARWCKM5A0D6"
      )

    execution_id = execution["execution"]["runbook_execution_id"]
    {:ok, runs} = Runs.list_runs_by_runbook_execution(execution_id, subject)
    chunk = String.duplicate("🙂", 5_000)

    Enum.each(runs, fn run ->
      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 stream: "stdout",
                 payload: %{"chunk" => chunk}
               })

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 2,
                 kind: "progress",
                 stream: "stderr",
                 payload: %{"chunk" => chunk}
               })
    end)

    history = call(conn, "recent_runs", %{"runbook_execution_id" => execution_id})
    assert length(history["runs"]) == length(runners)

    preview_bytes =
      Enum.reduce(history["runs"], 0, fn run, total ->
        assert String.valid?(run["stdout"])
        assert String.valid?(run["stderr"])
        assert run["truncated_stdout"]
        assert run["truncated_stderr"]
        total + byte_size(run["stdout"]) + byte_size(run["stderr"])
      end)

    assert preview_bytes <= 65_536
  end

  test "recent history pages on the final mirrored frame size", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "escape-heavy")
    chunk = String.duplicate("\\", 2_000)

    Enum.each(1..100, fn index ->
      run = create_mcp_history_run!(account, runner, key, index)

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 stream: "stdout",
                 payload: %{"chunk" => chunk}
               })

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 2,
                 kind: "progress",
                 stream: "stderr",
                 payload: %{"chunk" => chunk}
               })
    end)

    {run_ids, pages} = walk_recent_pages(conn, nil, MapSet.new(), 0)
    assert MapSet.size(run_ids) == 100
    assert pages > 1
  end

  test "wait_for_run wakes on a committed state change instead of waiting for recheck", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "wait-target")
    :ok = Runners.subscribe_runner_transport(runner)
    _runbook = publish_runbook!(subject, "wait-health", %{"runner_id" => [runner.id]})

    execution =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "wait-health@1", "reason" => "Wait test"},
        "op_524NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert_receive {:cloud_to_runner, _generation, _payload}, 500
    execution_id = execution["execution"]["runbook_execution_id"]
    {:ok, [run]} = Runs.list_runs_by_runbook_execution(execution_id, subject)
    test_pid = self()

    Task.start(fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
      # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
      Process.sleep(50)
      {:ok, _finished} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 5})
    end)

    started_at = System.monotonic_time(:millisecond)
    result = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "5s"})
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert result["run"]["status"] == "success"
    assert elapsed < 1_500
  end

  test "run summaries expose local audit failure only when it occurred", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "audit-summary")
    failed_audit_run = create_mcp_history_run!(account, runner, key, 1)
    healthy_audit_run = create_mcp_history_run!(account, runner, key, 2)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(failed_audit_run, %{
               "status" => "success",
               "local_audit_failed" => true
             })

    assert {:ok, _finished} = Fixtures.Runs.finish(healthy_audit_run, %{"status" => "success"})

    failed_summary =
      call(conn, "wait_for_run", %{"run_id" => failed_audit_run.id, "timeout" => "0"})

    healthy_summary =
      call(conn, "wait_for_run", %{"run_id" => healthy_audit_run.id, "timeout" => "0"})

    assert failed_summary["run"]["local_audit_failed"]
    refute Map.has_key?(healthy_summary["run"], "local_audit_failed")
  end

  test "recent history exposes a terminal failure cause only when recorded", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "failure-summary")
    failed_run = create_mcp_history_run!(account, runner, key, 1)
    successful_run = create_mcp_history_run!(account, runner, key, 2)
    cause = "runner could not durably reserve this dispatch; action was not executed"

    assert {:ok, _finished} =
             Fixtures.Runs.finish(failed_run, %{
               "status" => "failed",
               "exit_code" => -1,
               "duration_ms" => 0,
               "error" => cause
             })

    assert {:ok, _finished} = Fixtures.Runs.finish(successful_run, %{"status" => "success"})

    summaries = call(conn, "recent_runs", %{})["runs"]
    failed_summary = Enum.find(summaries, &(&1["run_id"] == failed_run.id))
    successful_summary = Enum.find(summaries, &(&1["run_id"] == successful_run.id))

    assert failed_summary["error_message"] == cause
    refute Map.has_key?(successful_summary, "error_message")
  end

  test "recent runs byte-bound terminal failure causes without breaking UTF-8", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "bounded-failure-summary")
    run = create_mcp_history_run!(account, runner, key, 1)
    cause = String.duplicate("€", 600)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{
               "status" => "failed",
               "error" => cause
             })

    summary =
      conn
      |> call("recent_runs", %{})
      |> Map.fetch!("runs")
      |> Enum.find(&(&1["run_id"] == run.id))

    preview = summary["error_message"]
    assert byte_size(preview) <= 1_024
    assert String.valid?(preview)
    assert String.ends_with?(preview, "...")
    refute preview == cause
  end

  test "recent history explains policy denials and approval rejections without operator input", %{
    conn: conn,
    account: account,
    subject: subject,
    user: user,
    key: key
  } do
    runner = setup_runner!(account, subject, "denial-summary")
    secret = "password=do-not-echo"

    default_denied_run =
      create_mcp_history_run!(account, runner, key, 1, %{
        status: :denied,
        policy_decision: "deny",
        policy_reason: "Default for critical-risk actions",
        reason: secret
      })

    explicit_denied_run =
      create_mcp_history_run!(account, runner, key, 2, %{
        status: :denied,
        policy_decision: "deny",
        policy_reason: "Override: block-critical " <> String.duplicate("policy-rule-", 18),
        matched_rules: ["block-critical"]
      })

    generic_denied_run =
      create_mcp_history_run!(account, runner, key, 3, %{
        status: :denied,
        policy_decision: "deny",
        policy_reason: nil
      })

    approval_run =
      create_mcp_history_run!(account, runner, key, 4, %{
        status: :pending_approval,
        policy_decision: "require_approval",
        policy_reason: "Default for high-risk actions"
      })

    {:ok, request} = Approvals.create_request(approval_run, user.id, "needs review")

    assert {:ok, {%{status: :denied}, %{status: :cancelled}}} =
             Approvals.deny_request(request, subject, "not during the change freeze")

    summaries = call(conn, "recent_runs", %{})["runs"]
    default_summary = Enum.find(summaries, &(&1["run_id"] == default_denied_run.id))
    explicit_summary = Enum.find(summaries, &(&1["run_id"] == explicit_denied_run.id))
    generic_summary = Enum.find(summaries, &(&1["run_id"] == generic_denied_run.id))
    approval_summary = Enum.find(summaries, &(&1["run_id"] == approval_run.id))

    assert default_summary["error_message"] ==
             "Denied by policy: Default for critical-risk actions"

    assert String.starts_with?(
             explicit_summary["error_message"],
             "Denied by policy: Override: block-critical"
           )

    assert generic_summary["error_message"] ==
             "Denied by policy: no specific policy reason was recorded."

    assert approval_summary["error_message"] == "approval denied: not during the change freeze"
    refute Jason.encode!(summaries) =~ secret

    assert byte_size(explicit_summary["error_message"]) <= 1_024
    assert String.valid?(explicit_summary["error_message"])
  end

  test "wait_for_run rejects a deadline above the repeatable 60-second window", %{conn: conn} do
    result =
      call(conn, "wait_for_run", %{
        "run_id" => Ecto.UUID.generate(),
        "timeout" => "61s"
      })

    assert result["error"]["code"] == "invalid_args"
    assert result["error"]["message"] =~ "60s"
  end

  test "wait_for_run rejects timeout values outside the public grammar", %{conn: conn} do
    for timeout <- ["15", "1m", "01s", "61s", "60001ms"] do
      result =
        call(conn, "wait_for_run", %{
          "run_id" => Ecto.UUID.generate(),
          "timeout" => timeout
        })

      assert result["error"]["code"] == "invalid_args", timeout
    end
  end

  defp authorize(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp call(conn, name, arguments, operation_id \\ nil) do
    conn =
      if operation_id,
        do: put_req_header(conn, "emisar-operation-id", operation_id),
        else: conn

    result =
      conn
      |> rpc("tools/call", %{"name" => name, "arguments" => arguments})
      |> json_response(200)
      |> get_in(["result", "structuredContent"])

    assert_valid_tool_result(name, result)
  end

  defp rpc(conn, method, params) do
    body = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp/rpc", Jason.encode!(body))
  end

  defp create_mcp_history_run!(account, runner, key, index, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          account_id: account.id,
          runner_id: runner.id,
          request_id: Emisar.Crypto.run_request_id(),
          action_id: "operations.health",
          source: :mcp,
          status: :pending,
          api_key_id: key.id,
          operation_id: "op_024NN9NMDZ1T76NARWCKM5A0D6",
          pack_ref: @pack_ref,
          runner_ref: runner_ref(runner),
          reason: "History budget #{index}"
        },
        Map.new(overrides)
      )

    attrs |> ActionRun.Changeset.create() |> Repo.insert!()
  end

  defp walk_recent_pages(conn, cursor, seen, page_count) do
    args = if cursor, do: %{"limit" => 100, "cursor" => cursor}, else: %{"limit" => 100}
    response = rpc(conn, "tools/call", %{"name" => "recent_runs", "arguments" => args})
    assert byte_size(response.resp_body) <= ResponseBudget.max_frame_bytes()

    payload = response |> json_response(200) |> get_in(["result", "structuredContent"])
    assert_valid_tool_result("recent_runs", payload)

    page_ids = payload["runs"] |> Enum.map(& &1["run_id"]) |> MapSet.new()
    assert MapSet.disjoint?(seen, page_ids)
    seen = MapSet.union(seen, page_ids)

    case payload["next_cursor"] do
      nil -> {seen, page_count + 1}
      next_cursor -> walk_recent_pages(conn, next_cursor, seen, page_count + 1)
    end
  end

  defp setup_runner!(account, subject, name, opts \\ []) do
    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: name,
        group: Keyword.get(opts, :group, "default"),
        enforce_signatures: Keyword.get(opts, :enforce_signatures, false)
      )

    observe_catalog!(
      runner,
      %{"operations" => %{"version" => "1.0.0", "hash" => @hash}},
      [action()]
    )

    trust_all!(subject)
    runner
  end

  defp observe_catalog!(runner, packs, actions) do
    payload = %{
      "hostname" => runner.hostname,
      "version" => runner.runner_version,
      "labels" => runner.labels,
      "enforce_signatures" => runner.enforce_signatures,
      "packs" => packs,
      "actions" => actions
    }

    payload =
      if runner.enforce_signatures,
        do: Map.put(payload, "max_attestation_age_seconds", 86_400),
        else: payload

    assert {:ok, _runner} = Catalog.observe_state(runner, payload)
  end

  defp trust_all!(subject) do
    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)
  end

  defp publish_runbook!(subject, slug, selector, opts \\ []) do
    step = %{
      "id" => "check",
      "action_id" => "operations.health",
      "args" => %{},
      "runner_selector" => selector
    }

    step =
      if Keyword.get(opts, :include_pack_ref, true),
        do: Map.put(step, "pack_ref", @pack_ref),
        else: step

    {:ok, draft} =
      Runbooks.create_runbook(
        %{
          "title" => String.replace(slug, "-", " "),
          "name" => slug,
          "slug" => slug,
          "definition" => %{
            "steps" => [step]
          }
        },
        subject
      )

    {:ok, published} = Runbooks.publish(draft, subject)
    published
  end

  defp runner_ref(runner),
    do: "#{runner.name}~#{binary_part(Crypto.hash_hex(runner.external_id), 0, 32)}"

  defp action(args \\ []) do
    %{
      "id" => "operations.health",
      "pack_id" => "operations",
      "title" => "Check health",
      "kind" => "exec",
      "risk" => "low",
      "summary" => "Checks service health.",
      "description" => "Checks service health.",
      "side_effects" => [],
      "args" => args,
      "examples" => [],
      "search_terms" => ["health"]
    }
  end
end
