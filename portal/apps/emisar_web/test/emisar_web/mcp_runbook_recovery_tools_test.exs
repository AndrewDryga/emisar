defmodule EmisarWeb.MCPRunbookRecoveryToolsTest do
  use EmisarWeb.ConnCase, async: true
  import EmisarWeb.MCPContractAssertions
  alias Emisar.{ApiKeys, Approvals, Audit, Catalog, Crypto, Repo, Runbooks, Runners, Runs}
  alias Emisar.MCPOperations.Operation
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, Runbook, RunbookExecution}
  alias Emisar.Runs.ActionRun
  alias EmisarWeb.MCP.{ResponseBudget, RunbookContract, RunbookTools, SchemaRegistry}

  @hash "sha256:" <> String.duplicate("b", 64)
  @pack_ref "operations@1.0.0/#{@hash}"
  @typed_output_schema %{"type" => "object"}

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

  test "published limit types reject string forms", %{conn: conn} do
    for {tool, limit} <- [{"recent_runs", "50"}, {"list_runbooks", "10"}] do
      invalid = call(conn, tool, %{"limit" => limit})

      assert invalid["error"]["message"] ==
               "Tool arguments do not match the published input schema."

      assert invalid["error"]["details"] == %{
               "schema_version" => 1,
               "stage" => "arguments",
               "kind" => "type",
               "issues" => [%{"path" => "$.limit", "code" => "type"}]
             }
    end

    assert call(conn, "recent_runs", %{"limit" => 50})["runs"] == []
    assert call(conn, "list_runbooks", %{"limit" => 10})["runbooks"] == []
  end

  test "execute_runbook requires boolean draft consent", %{conn: conn} do
    invalid =
      call(conn, "execute_runbook", %{
        "runbook_ref" => "database-health@1",
        "allow_draft" => "true",
        "reason" => "Do not coerce draft consent"
      })

    assert invalid["error"]["details"] == %{
             "schema_version" => 1,
             "stage" => "arguments",
             "kind" => "type",
             "issues" => [%{"path" => "$.allow_draft", "code" => "type"}]
           }
  end

  test "list_runbooks rejects a constructed cursor with restart guidance", %{conn: conn} do
    stale = call(conn, "list_runbooks", %{"cursor" => "not-a-cursor"})

    assert stale["error"]["code"] == "invalid_cursor"

    assert stale["error"]["message"] =~
             "call list_runbooks again with the same arguments and no cursor"
  end

  test "wait_for_run rejects a constructed runbook output cursor", %{conn: conn} do
    rejected =
      call(conn, "wait_for_run", %{
        "runbook_execution_id" => Ecto.UUID.generate(),
        "cursor" => "irrelevant",
        "timeout" => "0"
      })

    assert rejected["error"]["code"] == "invalid_cursor"
    assert rejected["error"]["message"] =~ "outputs_next"
  end

  test "transaction-time runbook contract failures do not expose hidden reasons" do
    for reason <- [
          :action_contract_changed,
          :action_not_found,
          :action_unavailable,
          :incomplete_contract,
          :not_found,
          :pack_ref_mismatch,
          :pack_retired,
          :pack_untrusted,
          :runner_not_found,
          :runner_out_of_scope,
          :target_contract_changed
        ] do
      result = RunbookTools.execution_failure(reason)

      assert result.error.code == "runbook_not_found"
      assert result.error.message == "No live runbook has that exact ref."

      if reason in [:pack_untrusted, :pack_retired] do
        refute Jason.encode!(result) =~ Atom.to_string(reason)
      end
    end

    # A superseded release is not a hidden reason: the runbook exists, the
    # caller may read it, and naming the live one is the whole remedy.
    superseded = RunbookTools.execution_failure(:not_live)
    assert superseded.error.code == "not_live"
    assert superseded.error.message =~ "list_runbooks shows what is"

    generic = RunbookTools.execution_failure(:unexpected_internal_reason)
    assert generic.error.code == "execution_failed"
    assert generic.error.message == "The runbook could not be started."
    refute Jason.encode!(generic) =~ "unexpected_internal_reason"

    capacity = RunbookTools.execution_failure(:runbook_capacity_exceeded)
    assert capacity.error.code == "runbook_capacity_exceeded"
    assert capacity.error.retryable
    assert capacity.error.message =~ "1,024 active runbook items"
  end

  test "every recent_runs schema fault identifies its kind and field", %{
    conn: conn
  } do
    unknown = call(conn, "recent_runs", %{"limits" => 10})
    assert unknown["error"]["details"]["kind"] == "unknown"
    assert %{"path" => "$.limits", "code" => "unknown"} in unknown["error"]["details"]["issues"]

    scope = call(conn, "recent_runs", %{"scope" => "all"})
    assert scope["error"]["details"]["kind"] == "enum"
    assert %{"path" => "$.scope", "code" => "enum"} in scope["error"]["details"]["issues"]

    ref = call(conn, "recent_runs", %{"runner_ref" => "not-a-ref"})
    assert ref["error"]["details"]["kind"] == "format"

    assert %{"path" => "$.runner_ref", "code" => "format"} in ref["error"]["details"]["issues"]

    orphan_step = call(conn, "recent_runs", %{"step_id" => "check"})
    assert orphan_step["error"]["details"]["kind"] == "missing"

    assert %{"path" => "$.runbook_execution_id", "code" => "required"} in orphan_step["error"][
             "details"
           ]["issues"]

    combined =
      call(conn, "recent_runs", %{
        "operation_id" => "op_324NN9NMDZ1T76NARWCKM5A0D6",
        "runner_ref" => "db-primary~" <> String.duplicate("a", 32)
      })

    assert combined["error"]["details"]["kind"] == "conflict"
    assert combined["error"]["details"]["issues"] == [%{"path" => "$", "code" => "conflict"}]
  end

  test "an unpublished change names the release it does not replace yet, everywhere", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    runbook = publish_runbook!(subject, "database-health", %{"runner_id" => [runner.id]})
    live_sha = Runbooks.definition_digest(runbook.definition)

    settled = call(conn, "get_runbook", %{"slug" => "database-health"})["runbook"]
    assert settled["runbook_ref"] == "database-health@1"
    assert settled["draft_definition_sha256"] == nil

    revised_definition = Map.put(runbook.definition, "context_markdown", "Revised.")

    draft =
      call(conn, "update_runbook_draft", %{
        "slug" => "database-health",
        "definition_sha256" => live_sha,
        "title" => "Database health revised",
        "description" => nil,
        "definition" => revised_definition
      })

    draft_sha = Runbooks.definition_digest(revised_definition)
    assert draft["slug"] == "database-health"
    assert draft["definition_sha256"] == draft_sha
    assert draft["live_ref"] == "database-health@1"

    # One entry per runbook now carries both sides, so a model cannot read its
    # own unpublished change as what production runs.
    assert [listed] = call(conn, "list_runbooks", %{})["runbooks"]
    assert listed["slug"] == "database-health"

    assert listed["live"] == %{
             "runbook_ref" => "database-health@1",
             "definition_sha256" => live_sha
           }

    assert listed["draft"] == %{"definition_sha256" => draft_sha}

    live = call(conn, "get_runbook", %{"slug" => "database-health"})["runbook"]
    assert live["definition_sha256"] == live_sha
    assert live["draft_definition_sha256"] == draft_sha

    fetched =
      call(conn, "get_runbook", %{"slug" => "database-health", "status" => "draft"})["runbook"]

    assert fetched["definition_sha256"] == draft_sha
    assert fetched["live_ref"] == "database-health@1"

    recovered = call(conn, "get_operation", %{"operation_id" => draft["operation_id"]})
    assert recovered["operation"]["live_ref"] == "database-health@1"
    assert recovered["operation"]["definition_sha256"] == draft_sha
  end

  test "an oversized runbook stays listed and is named oversized, never missing", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    runbook = publish_runbook!(subject, "database-health", %{"runner_id" => [runner.id]})

    Fixtures.Runbooks.oversize_runbook_description(
      runbook,
      RunbookContract.max_projection_bytes()
    )

    # Discovery keeps it: a size limit is not a reason to hide that the runbook
    # exists, and dropping it left the operator's own live runbook absent from
    # the list with nothing said.
    assert [listed] = call(conn, "list_runbooks", %{})["runbooks"]
    assert listed["slug"] == "database-health"
    assert listed["live"]["runbook_ref"] == "database-health@1"
    assert listed["available"] == false
    assert listed["unavailable_reason"] =~ "console"
    assert listed["step_count"] == 1

    # And fetching it says what is actually wrong, instead of denying it exists.
    fetched = call(conn, "get_runbook", %{"slug" => "database-health"})

    assert fetched["error"]["code"] == "runbook_too_large"
    assert fetched["error"]["message"] =~ "#{RunbookContract.max_projection_bytes()} byte limit"
    refute fetched["error"]["message"] =~ "No live runbook"
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

    assert [
             %{
               "slug" => "database-health",
               "step_count" => 1,
               "live" => %{"runbook_ref" => "database-health@1"},
               "draft" => nil
             }
           ] = listed["runbooks"]

    fetched = call(conn, "get_runbook", %{"slug" => "database-health"})

    assert %{
             "id" => "check",
             "action" => "operations.health",
             "pack" => %{"id" => "operations"},
             "targets" => %{"selection" => "all", "refs" => ["runner:" <> ^runner_ref]}
           } = get_in(fetched, ["runbook", "definition", "stages", Access.at(0), "steps"]) |> hd()

    draft_args = %{
      "title" => "Check database fleet",
      "slug" => nil,
      "description" => nil,
      "definition" =>
        runbook_definition(%{"selection" => "all", "refs" => ["runner:" <> runner_ref]})
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
          "runbook_ref" => "#{runbook.slug}@#{runbook.live_version}",
          "reason" => "Verify database health"
        }
      )

    execute_operation = execution["operation_id"]
    assert_receive {:cloud_to_runner, _generation, _payload}, 500
    execution_id = execution["execution"]["runbook_execution_id"]

    assert execution["execution"]["kind"] == "published"

    assert execution["execution"]["definition_sha256"] ==
             Runbooks.definition_digest(runbook.definition)

    assert [
             %{
               "stage_id" => "inspect",
               "items" => [
                 %{
                   "step_id" => "check",
                   "runner_ref" => ^runner_ref,
                   "attempt_count" => 1
                 }
               ]
             }
           ] = execution["execution"]["stages"]

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

    assert waited_execution["execution"]["status"] == "succeeded"
    refute Map.has_key?(waited_execution["execution"], "next")

    # A settled execution never spends its wait window: terminal is a domain
    # fact, not something the deadline discovers.
    started_at = System.monotonic_time(:millisecond)

    settled =
      call(conn, "wait_for_run", %{"runbook_execution_id" => execution_id, "timeout" => "5s"})

    assert settled["execution"]["status"] == "succeeded"
    assert System.monotonic_time(:millisecond) - started_at < 5_000

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

  test "one list names every runbook, and only the live side is readable by default", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    published = publish_runbook!(subject, "database-health", %{"runner_id" => [runner.id]})
    draft = draft_runbook!(subject, "cache-health", %{"runner_id" => [runner.id]})
    draft_hash = Runbooks.definition_digest(draft.draft_definition)
    live_hash = Runbooks.definition_digest(published.definition)

    listed = call(conn, "list_runbooks", %{})["runbooks"]

    assert [
             %{
               "slug" => "cache-health",
               "live" => nil,
               "draft" => %{"definition_sha256" => ^draft_hash}
             },
             %{
               "slug" => "database-health",
               "live" => %{
                 "runbook_ref" => "database-health@1",
                 "definition_sha256" => ^live_hash
               },
               "draft" => nil
             }
           ] = listed

    hidden = call(conn, "get_runbook", %{"slug" => "cache-health"})
    assert hidden["error"]["code"] == "runbook_not_found"

    fetched = call(conn, "get_runbook", %{"slug" => "cache-health", "status" => "draft"})

    assert fetched["runbook"]["status"] == "draft"
    assert fetched["runbook"]["draft_id"] == draft.id
    assert fetched["runbook"]["definition_sha256"] == draft_hash
    assert fetched["runbook"]["live_ref"] == nil

    as_draft = call(conn, "get_runbook", %{"slug" => "database-health", "status" => "draft"})
    assert as_draft["error"]["code"] == "draft_not_found"
  end

  test "update_runbook_draft rewrites the one draft in place and refuses stale edits", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    draft = draft_runbook!(subject, "cache-health", %{"runner_id" => [runner.id]})
    first_hash = Runbooks.definition_digest(draft.draft_definition)

    revised_definition =
      subject
      |> target_refs(%{"runner_id" => [runner.id]})
      |> runbook_definition()
      |> Map.put("context_markdown", "Verify the cache fleet.")

    revision_args = %{
      "slug" => "cache-health",
      "definition_sha256" => first_hash,
      "title" => "Cache health revised",
      "description" => nil,
      "definition" => revised_definition
    }

    stale_hash =
      call(
        conn,
        "update_runbook_draft",
        Map.put(revision_args, "definition_sha256", String.duplicate("0", 64))
      )

    assert stale_hash["error"]["code"] == "draft_changed"

    # A slug that does not resolve is NOT a stale read. Both used to answer
    # draft_changed — "fetch it again before editing" — for a runbook with
    # nothing to fetch, while get_runbook answered runbook_not_found for the
    # same slug. Two contradictory answers about one object make a model retry
    # the useless one.
    missing =
      call(conn, "update_runbook_draft", Map.put(revision_args, "slug", "no-such-runbook"))

    assert missing["error"]["code"] == "runbook_not_found"

    revised = call(conn, "update_runbook_draft", revision_args)

    assert revised["slug"] == "cache-health"
    assert revised["status"] == "draft"
    assert revised["live_ref"] == nil
    # The runbook itself is the draft, so editing it never mints a second row.
    assert revised["draft_id"] == draft.id

    assert revised["definition_sha256"] == Runbooks.definition_digest(revised_definition)

    assert call(conn, "update_runbook_draft", revision_args) == revised

    recovered = call(conn, "get_operation", %{"operation_id" => revised["operation_id"]})

    assert recovered["operation"]["kind"] == "runbook_draft"
    assert recovered["operation"]["slug"] == "cache-health"
    assert recovered["operation"]["definition_sha256"] == revised["definition_sha256"]

    # The hash the first edit was written against is now what someone else read.
    stale_base = call(conn, "update_runbook_draft", Map.put(revision_args, "title", "Stale edit"))

    assert stale_base["error"]["code"] == "draft_changed"
    assert Repo.aggregate(Runbook, :count) == 1
  end

  test "get_operation returns a typed error after its draft is published", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    draft = draft_runbook!(subject, "cache-health", %{"runner_id" => [runner.id]})

    revised =
      call(conn, "update_runbook_draft", %{
        "slug" => "cache-health",
        "definition_sha256" => Runbooks.definition_digest(draft.draft_definition),
        "title" => draft.title,
        "description" => draft.description,
        "definition" => draft.draft_definition
      })

    draft |> Repo.reload!() |> Fixtures.Runbooks.publish_runbook()

    recovered = call(conn, "get_operation", %{"operation_id" => revised["operation_id"]})

    assert recovered["error"]["code"] == "operation_incomplete"
    assert recovered["error"]["message"] =~ "durable resource is unavailable"
  end

  test "execute_runbook tests the exact draft it consented to and recovers by operation", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    :ok = Runners.subscribe_runner_transport(runner)
    draft = draft_runbook!(subject, "cache-health", %{"runner_id" => [runner.id]})
    draft_hash = Runbooks.definition_digest(draft.draft_definition)

    args = %{
      "slug" => "cache-health",
      "allow_draft" => true,
      "definition_sha256" => draft_hash,
      "reason" => "Verify the draft before publishing"
    }

    stale =
      call(conn, "execute_runbook", Map.put(args, "definition_sha256", String.duplicate("0", 64)))

    assert stale["error"]["code"] == "draft_changed"

    tested = call(conn, "execute_runbook", args)
    execution_id = tested["execution"]["runbook_execution_id"]

    assert tested["execution"]["kind"] == "draft_test"
    assert tested["execution"]["definition_sha256"] == draft_hash
    # A draft never became a release, so the slug alone names what ran.
    assert tested["execution"]["runbook_ref"] == "cache-health"
    assert_receive {:cloud_to_runner, _generation, _payload}, 500

    replayed = call(conn, "execute_runbook", args)
    assert replayed["execution"]["runbook_execution_id"] == execution_id
    refute_receive {:cloud_to_runner, _generation, _payload}, 100

    recovered = call(conn, "get_operation", %{"operation_id" => tested["operation_id"]})

    assert recovered["operation"]["kind"] == "runbook_draft_test"
    assert recovered["operation"]["runbook_execution_id"] == execution_id
    assert recovered["operation"]["definition_sha256"] == draft_hash
    assert recovered["operation"]["runbook_ref"] == "cache-health"

    assert Repo.aggregate(RunbookExecution, :count) == 1
  end

  test "another account's key can neither read nor execute this draft", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "db-primary")
    draft = draft_runbook!(subject, "cache-health", %{"runner_id" => [runner.id]})
    draft_hash = Runbooks.definition_digest(draft.draft_definition)
    foreign_conn = foreign_key_conn()

    assert call(foreign_conn, "list_runbooks", %{})["runbooks"] == []

    foreign_read =
      call(foreign_conn, "get_runbook", %{"slug" => "cache-health", "status" => "draft"})

    assert foreign_read["error"]["code"] == "draft_not_found"

    foreign_test =
      call(foreign_conn, "execute_runbook", %{
        "slug" => "cache-health",
        "allow_draft" => true,
        "definition_sha256" => draft_hash,
        "reason" => "Borrow another tenant's draft"
      })

    assert foreign_test["error"]["code"] == "draft_changed"
    refute Repo.exists?(RunbookExecution)

    # The owning account still sees its own draft.
    assert [%{"slug" => "cache-health", "draft" => %{"definition_sha256" => ^draft_hash}}] =
             call(conn, "list_runbooks", %{})["runbooks"]
  end

  test "no runbook publish or delete tool is exposed", %{conn: conn} do
    refute Enum.any?(SchemaRegistry.tool_names(), &(&1 =~ ~r/publish|delete/))

    Enum.each(~w(publish_runbook publish_runbook_draft delete_runbook), fn name ->
      body =
        conn
        |> rpc("tools/call", %{"name" => name, "arguments" => %{}})
        |> json_response(200)

      assert get_in(body, ["result", "structuredContent", "error", "code"]) == "unknown_tool"
    end)
  end

  test "models revise one runbook in place and explicitly test its unpublished change", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "draft-test")
    :ok = Runners.subscribe_runner_transport(runner)
    runner_ref = runner_ref(runner)

    published =
      publish_runbook!(subject, "database-health", %{"runner_id" => [runner.id]})

    fetched = call(conn, "get_runbook", %{"slug" => "database-health"})
    live_hash = fetched["runbook"]["definition_sha256"]

    revised_definition =
      runbook_definition(%{"selection" => "all", "refs" => ["runner:" <> runner_ref]})
      |> Map.put("context_markdown", "Inspect the database fleet, then report the evidence.")

    revision_args = %{
      "slug" => "database-health",
      "definition_sha256" => live_hash,
      "title" => "Database health review",
      "description" => "Working revision",
      "definition" => revised_definition
    }

    revised =
      call(
        conn,
        "update_runbook_draft",
        revision_args,
        "op_424NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert revised["slug"] == published.slug
    assert revised["status"] == "draft"
    assert revised["live_ref"] == "database-health@1"
    draft_hash = revised["definition_sha256"]

    assert call(conn, "update_runbook_draft", revision_args, "op_424NN9NMDZ1T76NARWCKM5A0D6") ==
             revised

    assert [
             %{
               "slug" => "database-health",
               "live" => %{
                 "runbook_ref" => "database-health@1",
                 "definition_sha256" => ^live_hash
               },
               "draft" => %{"definition_sha256" => ^draft_hash}
             }
           ] = call(conn, "list_runbooks", %{})["runbooks"]

    inspected = call(conn, "get_runbook", %{"slug" => "database-health", "status" => "draft"})

    assert inspected["runbook"]["draft_id"] == revised["draft_id"]
    assert inspected["runbook"]["definition_sha256"] == draft_hash

    stale_revision =
      call(
        conn,
        "update_runbook_draft",
        revision_args,
        "op_524NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert stale_revision["error"]["code"] == "draft_changed"

    # The live side still runs release 1's content; the unpublished change is
    # reachable only through explicit consent.
    live_execution =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "database-health@1", "reason" => "Run what is published"},
        "op_624NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert live_execution["execution"]["kind"] == "published"
    assert live_execution["execution"]["definition_sha256"] == live_hash
    assert_receive {:cloud_to_runner, _generation, _payload}, 500

    test_args = %{
      "slug" => "database-health",
      "allow_draft" => true,
      "definition_sha256" => draft_hash,
      "reason" => "Validate the working revision"
    }

    tested =
      call(conn, "execute_runbook", test_args, "op_724NN9NMDZ1T76NARWCKM5A0D6")

    execution_id = tested["execution"]["runbook_execution_id"]
    assert tested["execution"]["kind"] == "draft_test"
    assert tested["execution"]["definition_sha256"] == draft_hash
    assert_receive {:cloud_to_runner, _generation, _payload}, 500

    replayed =
      call(conn, "execute_runbook", test_args, "op_724NN9NMDZ1T76NARWCKM5A0D6")

    assert replayed["execution"]["runbook_execution_id"] == execution_id
    refute_receive {:cloud_to_runner, _generation, _payload}, 100

    recovered =
      call(conn, "get_operation", %{"operation_id" => "op_724NN9NMDZ1T76NARWCKM5A0D6"})

    assert recovered["operation"]["kind"] == "runbook_draft_test"
    assert recovered["operation"]["runbook_execution_id"] == execution_id
    assert recovered["operation"]["definition_sha256"] == draft_hash

    conflicting_retry =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "database-health@1", "reason" => "Validate the working revision"},
        "op_724NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert conflicting_retry["error"]["code"] == "operation_conflict"
    assert Repo.aggregate(Operation, :count) == 3
  end

  test "an older release is refused by name rather than redirected to current content", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "release-history")

    republished =
      subject
      |> publish_runbook!("database-health", %{"runner_id" => [runner.id]})
      |> Fixtures.Runbooks.publish_runbook()

    assert republished.live_version == 2

    superseded =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "database-health@1", "reason" => "Run the old release"},
        "op_524NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert superseded["error"]["code"] == "not_live"
    assert superseded["error"]["message"] =~ "list_runbooks shows what is"
    refute Repo.exists?(RunbookExecution)
  end

  test "typed input values bind safely and participate in replay identity", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    service_arg = %{
      "name" => "service",
      "type" => "string",
      "required" => true,
      "sensitive" => true
    }

    runner = setup_runner!(account, subject, "typed-input", action: action([service_arg]))
    :ok = Runners.subscribe_runner_transport(runner)

    input = %{
      "id" => "service",
      "description" => "Service name",
      "type" => "string",
      "required" => true,
      "sensitive" => true
    }

    runbook =
      publish_runbook!(
        subject,
        "typed-input",
        %{"runner_id" => [runner.id]},
        inputs: [input],
        args: %{"service" => %{"source" => "input", "ref" => "service"}}
      )

    operation_id = "op_124NN9NMDZ1T76NARWCKM5A0D6"
    secret = "billing-api"

    args = %{
      "runbook_ref" => "#{runbook.slug}@#{runbook.live_version}",
      "reason" => "Verify one service",
      "input_values" => %{"service" => secret}
    }

    executed = call(conn, "execute_runbook", args, operation_id)
    execution_id = executed["execution"]["runbook_execution_id"]
    refute Jason.encode!(executed) =~ secret
    assert_receive {:cloud_to_runner, _generation, _payload}, 500

    replayed = call(conn, "execute_runbook", args, operation_id)
    assert replayed["execution"]["runbook_execution_id"] == execution_id
    refute_receive {:cloud_to_runner, _generation, _payload}, 100

    conflict =
      call(
        conn,
        "execute_runbook",
        put_in(args, ["input_values", "service"], "payments-api"),
        operation_id
      )

    assert conflict["error"]["code"] == "operation_conflict"

    assert {:ok, [stored_run]} = Runs.list_runs_by_runbook_execution(execution_id, subject)
    assert Jason.decode!(stored_run.args_raw) == %{"service" => secret}
  end

  test "execution recovery exposes extracted outputs and condition evidence", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    output_schema = %{
      "type" => "object",
      "required" => ["ready"],
      "additionalProperties" => false,
      "properties" => %{"ready" => %{"type" => "boolean"}}
    }

    runner =
      setup_runner!(account, subject, "output-evidence",
        action: action([], output_schema: output_schema)
      )

    :ok = Runners.subscribe_runner_transport(runner)

    output = %{
      "id" => "ready",
      "source" => "structured_output",
      "sensitive" => false,
      "extract" => %{"type" => "json_pointer", "expression" => "/ready"}
    }

    condition = %{"output" => "ready", "operator" => "equals", "value" => true}

    _runbook =
      publish_runbook!(
        subject,
        "output-evidence",
        %{"runner_id" => [runner.id]},
        outputs: [output],
        success: [condition]
      )

    executed =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "output-evidence@1", "reason" => "Confirm the service is healthy"},
        "op_224NN9NMDZ1T76NARWCKM5A0D6"
      )

    execution_id = executed["execution"]["runbook_execution_id"]
    assert_receive {:cloud_to_runner, _generation, _payload}, 500
    assert {:ok, [run]} = Runs.list_runs_by_runbook_execution(execution_id, subject)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    recovered =
      call(conn, "wait_for_run", %{
        "runbook_execution_id" => execution_id,
        "timeout" => "0"
      })

    assert recovered["execution"]["status"] == "succeeded"

    item =
      recovered
      |> get_in(["execution", "stages", Access.at(0), "items"])
      |> hd()

    assert item["outputs"] == [
             %{
               "output_id" => "ready",
               "sensitive" => false,
               "source" => "structured_output",
               "status" => "extracted",
               "value" => true
             }
           ]

    assert item["conditions"] == [
             %{
               "expected" => true,
               "operator" => "equals",
               "output" => "ready",
               "status" => "passed"
             }
           ]

    refute Map.has_key?(recovered["execution"], "outputs_next")
  end

  test "oversized terminal outputs drain through outputs_next without changing small results", %{
    conn: conn,
    account: account,
    membership: membership
  } do
    runner = Fixtures.Runners.create_runner(account_id: account.id, name: "output-pages")

    runbook =
      Fixtures.Runbooks.create_runbook(account_id: account.id)
      |> Fixtures.Runbooks.publish_runbook()

    value = String.duplicate("v", 8_000)

    public_outputs =
      Enum.map(0..63, fn index ->
        %{id: "value-#{index}", value: value <> Integer.to_string(index), sensitive: false}
      end)

    secret = "never-return-this-secret"
    output_specs = public_outputs ++ [%{id: "secret", value: secret, sensitive: true}]

    execution =
      Fixtures.Runbooks.create_execution_with_outputs(runbook, runner, output_specs,
        initiating_membership_id: membership.id
      )

    response =
      rpc(conn, "tools/call", %{
        "name" => "wait_for_run",
        "arguments" => %{"runbook_execution_id" => execution.id, "timeout" => "0"}
      })

    assert byte_size(response.resp_body) <= ResponseBudget.max_frame_bytes()
    recovered = response |> json_response(200) |> get_in(["result", "structuredContent"])
    assert_valid_tool_result("wait_for_run", recovered)

    continuation = recovered["execution"]["outputs_next"]
    assert continuation["tool"] == "wait_for_run"

    {outputs, frames} = drain_execution_outputs!(conn, continuation, [], 0)

    assert frames > 1
    assert length(outputs) == 65
    assert Enum.map(outputs, & &1["output_id"]) == Enum.map(output_specs, & &1.id)
    assert Enum.map(Enum.take(outputs, 64), & &1["value"]) == Enum.map(public_outputs, & &1.value)
    refute Jason.encode!(outputs) =~ secret
    assert List.last(outputs)["value"] == "[REDACTED]"

    foreign = call(foreign_key_conn(), "wait_for_run", continuation["arguments"])
    assert foreign["error"]["code"] == "invalid_cursor"
  end

  test "a full projection shows a value only where the frozen plan proves it public", %{
    subject: subject
  } do
    secret = "billing-api-token"

    result =
      projected_result(
        item_status: :succeeded,
        attempt_count: 1,
        output_plan: [
          %{"id" => "ready", "source" => "structured_output", "sensitive" => false},
          %{"id" => "token", "source" => "stdout", "sensitive" => true}
        ],
        success_plan: [
          %{"output" => "ready", "operator" => "equals", "value" => true},
          %{"output" => "token", "operator" => "equals", "value" => secret}
        ],
        # A stored value is never the authority — the declaration is.
        outputs: %{"ready" => true, "token" => secret},
        success_evidence: [
          %{"kind" => "extraction", "output" => "ready", "status" => "extracted"},
          %{"kind" => "extraction", "output" => "token", "status" => "extracted"},
          %{"kind" => "condition", "output" => "ready", "status" => "passed", "actual" => true},
          %{"kind" => "condition", "output" => "token", "status" => "passed", "actual" => secret}
        ]
      )

    assert {:ok, payload} = RunbookTools.project_execution(result, subject)
    refute Jason.encode!(payload) =~ secret

    item = payload.stages |> hd() |> Map.fetch!(:items) |> hd()
    refute item.output_values_omitted

    assert item.outputs == [
             %{
               output_id: "ready",
               source: "structured_output",
               sensitive: false,
               status: "extracted",
               value: true
             },
             %{
               output_id: "token",
               source: "stdout",
               sensitive: true,
               status: "extracted",
               value: "[REDACTED]"
             }
           ]

    assert item.conditions == [
             %{output: "ready", operator: "equals", expected: true, status: "passed"},
             %{output: "token", operator: "equals", expected: "[REDACTED]", status: "passed"}
           ]

    assert_valid_tool_result("execute_runbook", wire_execution(payload))
  end

  test "a downgraded projection hashes the public value and keeps the redacted one", %{
    subject: subject
  } do
    secret = "billing-api-token"
    oversized = String.duplicate("a", 600_000)

    result =
      projected_result(
        item_status: :succeeded,
        attempt_count: 1,
        output_plan: [
          %{"id" => "public", "source" => "stdout", "sensitive" => false},
          %{"id" => "token", "source" => "stdout", "sensitive" => true}
        ],
        success_plan: [
          %{"output" => "public", "operator" => "contains", "value" => "a"},
          %{"output" => "token", "operator" => "equals", "value" => secret}
        ],
        outputs: %{"public" => oversized, "token" => secret},
        success_evidence: [
          %{"kind" => "extraction", "output" => "public", "status" => "extracted"},
          %{"kind" => "extraction", "output" => "token", "status" => "extracted"}
        ]
      )

    assert {:ok, payload} = RunbookTools.project_execution(result, subject)
    encoded = Jason.encode!(payload)
    refute encoded =~ secret
    refute encoded =~ oversized

    item = payload.stages |> hd() |> Map.fetch!(:items) |> hd()
    assert item.output_values_omitted

    assert [
             %{output_id: "public", value: %{omitted: true, encoded_bytes: bytes, sha256: sha}},
             %{output_id: "token", value: "[REDACTED]"}
           ] = item.outputs

    assert bytes == byte_size(Jason.encode!(oversized))
    assert sha == Crypto.hash_hex(Jason.encode!(oversized))
    assert [%{expected: nil}, %{expected: "[REDACTED]"}] = item.conditions
    assert_valid_tool_result("execute_runbook", wire_execution(payload))
  end

  test "inherited and never-dispatched item statuses stay inside the published enum", %{
    subject: subject
  } do
    for {execution_status, stage_status, item_status, attempt_count, wire_status} <- [
          {:active, :active, :pending, 0, "pending"},
          {:halted, :halted, :pending, 0, "pending"},
          {:cancelled, :cancelled, :pending, 0, "cancelled"},
          {:halted, :halted, :failed, 0, "failed"},
          {:active, :active, :waiting, 1, "waiting"},
          {:succeeded, :succeeded, :succeeded, 1, "succeeded"}
        ] do
      result =
        projected_result(
          status: execution_status,
          stage_status: stage_status,
          item_status: item_status,
          attempt_count: attempt_count
        )

      assert {:ok, payload} = RunbookTools.project_execution(result, subject)
      item = payload.stages |> hd() |> Map.fetch!(:items) |> hd()

      assert item.status == wire_status
      assert payload.status == to_string(execution_status)
      assert_valid_tool_result("execute_runbook", wire_execution(payload))
    end
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
    assert Enum.any?(listed["runbooks"], &(&1["live"]["runbook_ref"] == "partial-fleet@1"))
  end

  test "draft creation derives an absent slug through the shared runbook rule", %{conn: conn} do
    targets = %{"selection" => "all", "refs" => ["group:fleet"]}

    absent_args = %{
      "title" => "Check Database Fleet!",
      "slug" => nil,
      "description" => nil,
      "definition" => runbook_definition(targets)
    }

    absent = call(conn, "create_runbook_draft", absent_args)

    assert absent["ok"]
    assert absent["slug"] == "check-database-fleet"
    assert call(conn, "create_runbook_draft", absent_args) == absent

    blank =
      call(conn, "create_runbook_draft", %{
        "title" => "Rotate Standby Nodes",
        "slug" => "   ",
        "description" => nil,
        "definition" => runbook_definition(targets)
      })

    assert blank["slug"] == "rotate-standby-nodes"

    explicit =
      call(conn, "create_runbook_draft", %{
        "title" => "Drain Edge Nodes",
        "slug" => "edge-drain",
        "description" => nil,
        "definition" => runbook_definition(targets)
      })

    assert explicit["slug"] == "edge-drain"
    assert Repo.aggregate(Runbooks.Runbook, :count) == 3
  end

  test "draft creation rejects an invalid canonical definition before reserving an operation", %{
    conn: conn
  } do
    audit_count = Repo.aggregate(Audit.Event, :count)

    result =
      call(conn, "create_runbook_draft", %{
        "title" => "Invalid draft",
        "slug" => nil,
        "description" => nil,
        "definition" => definition_with_21_binding_issues()
      })

    refute result["ok"]
    assert result["error"]["code"] == "invalid_runbook"
    assert result["error"]["message"] == "The draft has 21 definition issues."

    assert %{
             "issue_count" => 21,
             "issues_truncated" => false,
             "issues" => issues
           } = result["error"]["details"]

    assert length(issues) == 21

    for step_index <- 0..5 do
      base = "/stages/3/steps/#{step_index}/args/project"
      assert Enum.any?(issues, &(&1["path"] == "#{base}/ref"))
      assert Enum.any?(issues, &(&1["path"] == "#{base}/source"))
      assert Enum.any?(issues, &(&1["path"] == "#{base}/value"))
    end

    base = "/stages/5/steps/1/args/organization"
    assert Enum.any?(issues, &(&1["path"] == "#{base}/ref"))
    assert Enum.any?(issues, &(&1["path"] == "#{base}/source"))
    assert Enum.any?(issues, &(&1["path"] == "#{base}/value"))

    assert Enum.all?(issues, &(&1["code"] == "invalid_definition"))
    assert Enum.all?(issues, &(is_binary(&1["message"]) and &1["message"] != ""))
    refute Repo.exists?(Operation)
    refute Repo.exists?(Runbooks.Runbook)
    assert Repo.aggregate(Audit.Event, :count) == audit_count
  end

  test "draft creation bounds a complete definition issue report", %{conn: conn} do
    audit_count = Repo.aggregate(Audit.Event, :count)

    result =
      call(conn, "create_runbook_draft", %{
        "title" => "Invalid large draft",
        "slug" => nil,
        "description" => nil,
        "definition" => definition_with_66_binding_issues()
      })

    refute result["ok"]
    assert result["error"]["code"] == "invalid_runbook"

    assert %{
             "issue_count" => 66,
             "issues_truncated" => true,
             "issues" => issues
           } = result["error"]["details"]

    assert length(issues) == 64
    refute Repo.exists?(Operation)
    refute Repo.exists?(Runbooks.Runbook)
    assert Repo.aggregate(Audit.Event, :count) == audit_count
  end

  test "discovery keeps fan-out separate from bounded stage parallelism", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    _runners = Enum.map(1..17, &setup_runner!(account, subject, "wide-#{&1}", group: "wide"))
    _runbook = publish_runbook!(subject, "wide-book", %{"group" => ["wide"]})

    listed = call(conn, "list_runbooks", %{})
    assert Enum.any?(listed["runbooks"], &(&1["live"]["runbook_ref"] == "wide-book@1"))

    fetched = call(conn, "get_runbook", %{"slug" => "wide-book"})
    assert fetched["runbook"]["summary"]["stage_count"] == 1

    assert get_in(fetched, ["runbook", "definition", "stages", Access.at(0), "max_parallel"]) ==
             16

    refute Repo.exists?(Operation)
  end

  test "runbook discovery and execution hide steps whose pack trust was revoked", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "revoked-pack-host")
    _runbook = publish_runbook!(subject, "revoked-pack-book", %{"runner_id" => [runner.id]})

    assert [%{"live" => %{"runbook_ref" => "revoked-pack-book@1"}}] =
             call(conn, "list_runbooks", %{})["runbooks"]

    [trusted] = Fixtures.Catalog.list_pack_versions(subject.account.id)
    assert {:ok, _revoked} = Catalog.revoke_pack_version_trust(trusted.id, subject)

    assert call(conn, "list_runbooks", %{})["runbooks"] == []

    fetched = call(conn, "get_runbook", %{"slug" => "revoked-pack-book"})
    assert fetched["error"]["code"] == "runbook_not_found"

    draft =
      call(conn, "create_runbook_draft", %{
        "title" => "Revoked pack draft",
        "slug" => nil,
        "description" => nil,
        "definition" =>
          runbook_definition(%{
            "selection" => "all",
            "refs" => ["runner:" <> runner_ref(runner)]
          })
      })

    assert draft["ok"]

    executed =
      call(
        conn,
        "execute_runbook",
        %{"runbook_ref" => "revoked-pack-book@1", "reason" => "Inspect host"},
        "op_324NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert executed["error"]["code"] == "pack_unavailable"
    assert executed["error"]["path"] == "/stages/0/steps/0/pack"
    assert executed["dispatch_started"] == false
    assert Repo.aggregate(Operation, :count) == 1
    assert {:ok, [], _meta} = Runs.list_runs(subject)
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

    {:ok, db_access} = Emisar.Accounts.RunnerAccess.restricted(["db"], [])
    Fixtures.Memberships.force_runner_access(membership, db_access)

    listed = call(conn, "list_runbooks", %{})
    assert Enum.map(listed["runbooks"], & &1["slug"]) == ["visible-book"]

    hidden = call(conn, "get_runbook", %{"slug" => "hidden-book"})
    assert hidden["error"]["code"] == "runbook_not_found"

    Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())

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
    assert length(second["runs"]) == 15
    assert is_binary(second["next_cursor"])

    {run_ids, pages} = walk_recent_pages(conn, nil, MapSet.new(), 0)
    assert MapSet.size(run_ids) == 64
    assert pages == 1

    wrong_query =
      call(conn, "recent_runs", %{
        "scope" => "account",
        "cursor" => first["next_cursor"]
      })

    assert wrong_query["error"]["code"] == "invalid_cursor"

    assert wrong_query["error"]["message"] =~
             "call recent_runs again with the same arguments and no cursor"

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

  test "recent history filters exact statuses and binds their set to the cursor", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "status-history")
    failed = create_mcp_history_run!(account, runner, key, 1, %{status: :failed})
    refused = create_mcp_history_run!(account, runner, key, 2, %{status: :refused})
    success = create_mcp_history_run!(account, runner, key, 3, %{status: :success})

    first =
      call(conn, "recent_runs", %{
        "statuses" => ["refused", "failed"],
        "limit" => 1
      })

    assert [first_run] = first["runs"]
    assert first_run["run_id"] in [failed.id, refused.id]
    refute first_run["run_id"] == success.id
    assert is_binary(first["next_cursor"])

    second =
      call(conn, "recent_runs", %{
        "statuses" => ["failed", "refused"],
        "limit" => 1,
        "cursor" => first["next_cursor"]
      })

    assert [second_run] = second["runs"]

    assert MapSet.new([first_run["run_id"], second_run["run_id"]]) ==
             MapSet.new([failed.id, refused.id])

    mismatch =
      call(conn, "recent_runs", %{
        "statuses" => ["failed"],
        "limit" => 1,
        "cursor" => first["next_cursor"]
      })

    assert mismatch["error"]["code"] == "invalid_cursor"
  end

  test "execution summaries remain complete after runner scope is narrowed", %{
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
    {:ok, db_access} = Emisar.Accounts.RunnerAccess.restricted(["db"], [])
    Fixtures.Memberships.force_runner_access(membership, db_access)

    recovered = call(conn, "get_operation", %{"operation_id" => operation_id})
    assert recovered["operation"]["runbook_execution_id"] == execution_id

    waited =
      call(conn, "wait_for_run", %{
        "runbook_execution_id" => execution_id,
        "timeout" => "0"
      })

    assert waited["execution"]["runbook_execution_id"] == execution_id

    history = call(conn, "recent_runs", %{"runbook_execution_id" => execution_id})

    assert MapSet.new(history["runs"], & &1["runner_ref"]) ==
             MapSet.new([runner_ref(db), runner_ref(web)])
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
        %{"runbook_ref" => "wait-health@1", "reason" => "Wait for health"},
        "op_524NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert_receive {:cloud_to_runner, _generation, _payload}, 500
    execution_id = execution["execution"]["runbook_execution_id"]
    {:ok, [run]} = Runs.list_runs_by_runbook_execution(execution_id, subject)
    test_pid = self()

    finish_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
        # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
        Process.sleep(50)

        Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 5})
      end)

    started_at = System.monotonic_time(:millisecond)
    result = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "5s"})
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert {:ok, _finished} = Task.await(finish_task)
    assert result["run"]["status"] == "success"
    assert elapsed < 1_500
  end

  test "wait_for_run seeds an output-tail cursor on a live run's next", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-seed")
    run = create_mcp_history_run!(account, runner, key, 1)

    snapshot = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]

    assert snapshot["next"]["tool"] == "wait_for_run"
    assert snapshot["next"]["arguments"]["run_id"] == run.id
    assert snapshot["next"]["arguments"]["timeout"] == "60s"
    assert is_binary(snapshot["next"]["arguments"]["cursor"])
  end

  test "wait_for_run tails output forward, coalescing streams and never repeating", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-forward")
    run = create_mcp_history_run!(account, runner, key, 1)

    append_progress!(run, 1, "stdout", "line-1\n")
    append_progress!(run, 2, "stdout", "line-2\n")
    append_progress!(run, 3, "stderr", "warn\n")
    append_progress!(run, 4, "stdout", "line-4\n")

    first =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => seed_cursor!(conn, run),
        "timeout" => "0"
      })["run"]

    assert first["output"] == [
             %{"stream" => "stdout", "text" => "line-1\nline-2\n"},
             %{"stream" => "stderr", "text" => "warn\n"},
             %{"stream" => "stdout", "text" => "line-4\n"}
           ]

    assert first["next"]["arguments"]["timeout"] == "60s"
    refute Map.has_key?(first, "stdout")

    # Following the returned cursor after more output returns only the new chunk.
    append_progress!(run, 5, "stdout", "line-5\n")

    second =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => first["next"]["arguments"]["cursor"],
        "timeout" => "0"
      })["run"]

    assert second["output"] == [%{"stream" => "stdout", "text" => "line-5\n"}]
  end

  test "wait_for_run tail returns an empty delta and keeps waiting while live", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-empty")
    run = create_mcp_history_run!(account, runner, key, 1)
    append_progress!(run, 1, "stdout", "only\n")

    first =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => seed_cursor!(conn, run),
        "timeout" => "0"
      })["run"]

    again =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => first["next"]["arguments"]["cursor"],
        "timeout" => "0"
      })["run"]

    assert again["output"] == []
    assert again["next"]["arguments"]["timeout"] == "60s"
  end

  test "wait_for_run rejects an invalid or foreign output cursor", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-reject")
    run = create_mcp_history_run!(account, runner, key, 1)
    other = create_mcp_history_run!(account, runner, key, 2)
    seed = seed_cursor!(conn, run)

    garbage =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => "not-a-cursor",
        "timeout" => "0"
      })

    assert garbage["error"]["code"] == "invalid_cursor"

    assert garbage["error"]["message"] =~
             "call wait_for_run again with just the run_id and no cursor"

    # A cursor minted for `run` is bound to it and rejected against `other`.
    foreign =
      call(conn, "wait_for_run", %{"run_id" => other.id, "cursor" => seed, "timeout" => "0"})

    assert foreign["error"]["code"] == "invalid_cursor"
  end

  test "wait_for_run tail wakes on a new output chunk instead of waiting for recheck", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-wake")
    run = create_mcp_history_run!(account, runner, key, 1)
    append_progress!(run, 1, "stdout", "first\n")

    first =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => seed_cursor!(conn, run),
        "timeout" => "0"
      })["run"]

    cursor = first["next"]["arguments"]["cursor"]
    test_pid = self()

    progress_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
        # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
        Process.sleep(50)
        append_progress!(run, 2, "stdout", "second\n")
      end)

    started_at = System.monotonic_time(:millisecond)

    tailed =
      call(conn, "wait_for_run", %{"run_id" => run.id, "cursor" => cursor, "timeout" => "5s"})[
        "run"
      ]

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert %Runs.RunEvent{} = Task.await(progress_task)
    assert tailed["output"] == [%{"stream" => "stdout", "text" => "second\n"}]
    assert elapsed < 1_500
  end

  test "wait_for_run tail drains a finished run then ends with no next", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-drain")
    run = create_mcp_history_run!(account, runner, key, 1)
    append_progress!(run, 1, "stdout", "done\n")
    seed = seed_cursor!(conn, run)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{
               "status" => "success",
               "exit_code" => 0,
               "progress_chunks" => 1
             })

    drained =
      call(conn, "wait_for_run", %{"run_id" => run.id, "cursor" => seed, "timeout" => "0"})["run"]

    assert drained["status"] == "success"
    assert drained["output"] == [%{"stream" => "stdout", "text" => "done\n"}]
    refute Map.has_key?(drained, "next")
  end

  test "wait_for_run tail bounds every frame and continues losslessly", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-bounded")
    run = create_mcp_history_run!(account, runner, key, 1)
    chunk = String.duplicate("x", 8_192)
    for seq <- 1..40, do: append_progress!(run, seq, "stdout", chunk)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 40})

    {drained, frames} = drain_tail!(conn, run, seed_cursor!(conn, run), "", 0)

    # The 320 KiB backlog spans model-sized frames and reconstructs every byte
    # in order, with nothing repeated.
    assert frames > 1
    assert drained == String.duplicate(chunk, 40)
  end

  test "a finished run whose preview omitted output offers a drain cursor", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "drain-finished")
    run = create_mcp_history_run!(account, runner, key, 1)
    for seq <- 1..35, do: append_progress!(run, seq, "stdout", "line-#{seq}\n")

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 35})

    summary = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]

    # Terminal, but the bounded preview could not show everything — so the
    # summary hands back a start cursor to drain the rest immediately.
    assert summary["next"]["arguments"]["timeout"] == "0"
    assert is_binary(summary["next"]["arguments"]["cursor"])

    {drained, _frames} =
      drain_tail!(conn, run, summary["next"]["arguments"]["cursor"], "", 0)

    assert drained == Enum.map_join(1..35, &"line-#{&1}\n")
  end

  test "a finished run whose output fit the preview offers no continuation", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "drain-complete")
    run = create_mcp_history_run!(account, runner, key, 1)
    for seq <- 1..3, do: append_progress!(run, seq, "stdout", "line-#{seq}\n")

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 3})

    summary = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]

    # Everything persisted is already in the preview: nothing left to fetch.
    refute Map.has_key?(summary, "next")
  end

  test "a finished run whose events were pruned offers no dead continuation", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "drain-pruned")
    run = create_mcp_history_run!(account, runner, key, 1)
    for seq <- 1..35, do: append_progress!(run, seq, "stdout", "line-#{seq}\n")

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 35})

    # Event retention runs ahead of run retention, so a finished run's rows can be
    # gone while its counters remain. The drain offer is derived from what the
    # preview actually read, so a pruned run yields no continuation to nowhere.
    Repo.delete_all(Emisar.Runs.RunEvent)

    summary = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]
    refute Map.has_key?(summary, "next")
  end

  test "a runner-capped finished run offers no drain when the preview showed everything", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "drain-runner-capped")
    run = create_mcp_history_run!(account, runner, key, 1)
    append_progress!(run, 1, "stdout", "capped\n")

    # The RUNNER hit its own output cap: the bytes beyond it were never persisted,
    # so there is nothing to drain even though the summary reports truncation.
    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{
               "status" => "success",
               "progress_chunks" => 1,
               "truncated_stdout" => true
             })

    summary = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]

    assert summary["truncated_stdout"]
    refute Map.has_key?(summary, "next")
  end

  test "a pruned fragmented event surfaces as a gap, not silence", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-pruned-fragment")
    run = create_mcp_history_run!(account, runner, key, 1)
    append_progress!(run, 1, "stdout", String.duplicate("x", 250_000))
    append_progress!(run, 2, "stdout", "after\n")
    seed = seed_cursor!(conn, run)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 2})

    first =
      call(conn, "wait_for_run", %{"run_id" => run.id, "cursor" => seed, "timeout" => "0"})["run"]

    # Mid-event position, then retention removes the event it points into.
    cursor = first["next"]["arguments"]["cursor"]
    Repo.delete_all(Emisar.Runs.RunEvent.Query.by_seq_before(Emisar.Runs.RunEvent.Query.all(), 2))

    resumed =
      call(conn, "wait_for_run", %{"run_id" => run.id, "cursor" => cursor, "timeout" => "0"})[
        "run"
      ]

    # The remainder of event 1 is gone. That must read as INCOMPLETE output, not
    # as a clean continuation that silently skipped bytes.
    assert resumed["output_complete"] == false
    assert tail_text(resumed) == "after\n"
  end

  test "a drain whose remaining whole events were pruned ends flagged, not clean", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-pruned-whole")
    run = create_mcp_history_run!(account, runner, key, 1)
    chunk = String.duplicate("x", 8_192)
    for seq <- 1..40, do: append_progress!(run, seq, "stdout", chunk)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 40})

    # The terminal summary seeds a drain that owes all 40 events.
    seed =
      call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]["next"][
        "arguments"
      ]["cursor"]

    first = call(conn, "wait_for_run", %{"run_id" => run.id, "cursor" => seed, "timeout" => "0"})

    # Mid-drain, retention removes every remaining WHOLE event — an offset-zero
    # boundary, so no single event is left half-delivered.
    Repo.delete_all(Emisar.Runs.RunEvent)

    resumed =
      call(conn, "wait_for_run", %{
        "run_id" => run.id,
        "cursor" => first["run"]["next"]["arguments"]["cursor"],
        "timeout" => "0"
      })["run"]

    # The drain still owed events it can no longer serve. That must end as
    # INCOMPLETE output, never as a clean finish that silently skipped them.
    assert resumed["output"] == []
    assert resumed["output_complete"] == false
    refute Map.has_key?(resumed, "next")
  end

  test "a live run's buffered backlog returns immediately instead of long-polling", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-live-backlog")
    run = create_mcp_history_run!(account, runner, key, 1)
    append_progress!(run, 1, "stdout", "already-here\n")

    seed = seed_cursor!(conn, run)

    # The run stays LIVE and no new event arrives during the call — yet output
    # past the cursor already exists, so a 60s wait must return it at once.
    started_at = System.monotonic_time(:millisecond)

    tailed =
      call(conn, "wait_for_run", %{"run_id" => run.id, "cursor" => seed, "timeout" => "5s"})[
        "run"
      ]

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert tail_text(tailed) == "already-here\n"
    assert elapsed < 1_500
  end

  test "a quote-heavy event stays within the transport frame", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-quotes")
    run = create_mcp_history_run!(account, runner, key, 1)

    # A quote costs 2 bytes in structuredContent and 4 more inside the mirrored,
    # re-escaped text block. Its own encoded size therefore badly understates the
    # assembled frame: sized by that estimate this single chunk ships whole and
    # blows the 512 KiB ceiling. The budget must measure the real frame.
    chunk = String.duplicate("\"", 102_386)
    append_progress!(run, 1, "stdout", chunk)
    seed = seed_cursor!(conn, run)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 1})

    {drained, frames} = drain_tail!(conn, run, seed, "", 0)

    assert drained == chunk
    assert frames > 1
  end

  test "run_action seeds a followable output cursor on its live run", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    runner = setup_runner!(account, subject, "run-action-seed")
    :ok = Runners.subscribe_runner_transport(runner)

    observe_catalog!(
      runner,
      %{"operations" => %{"version" => "1.0.0", "hash" => @hash}},
      [action()]
    )

    trust_all!(subject)

    dispatched =
      call(
        conn,
        "run_action",
        %{
          "action_id" => "operations.health",
          "pack_ref" => @pack_ref,
          "runner_refs" => [runner_ref(runner)],
          "args" => %{},
          "reason" => "Seed the output tail",
          "wait" => "0"
        },
        "op_624NN9NMDZ1T76NARWCKM5A0D6"
      )

    assert_receive {:cloud_to_runner, _generation, _payload}, 500
    assert [summary] = dispatched["runs"]
    cursor = get_in(summary, ["next", "arguments", "cursor"])

    # The dispatch response itself must carry a usable start cursor — this is the
    # primary "dispatch then stream" path, and only an end-to-end call proves the
    # tail scope is actually threaded through dispatch.
    assert is_binary(cursor)

    append_progress!(summary["run_id"], 1, "stdout", "seeded\n")

    tailed =
      call(conn, "wait_for_run", %{
        "run_id" => summary["run_id"],
        "cursor" => cursor,
        "timeout" => "0"
      })["run"]

    assert tail_text(tailed) == "seeded\n"
  end

  test "wait_for_run tail fragments a single oversized event across frames losslessly", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-fragment")
    run = create_mcp_history_run!(account, runner, key, 1)
    chunk = String.duplicate("x", 250_000)
    append_progress!(run, 1, "stdout", chunk)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 1})

    {drained, frames} = drain_tail!(conn, run, seed_cursor!(conn, run), "", 0)

    # One event larger than a model page is split and reconstructed exactly.
    assert frames > 1
    assert drained == chunk
  end

  test "an escape-heavy event never overruns the transport frame", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-escapes")
    run = create_mcp_history_run!(account, runner, key, 1)

    # Control characters encode as \uXXXX — 6 bytes each — so 40 KiB of raw
    # output is ~240 KiB encoded, and the frame mirrors the payload twice. Shipped
    # whole this would exceed the 512 KiB transport ceiling, so the budget must
    # measure the ESCAPED form and fragment.
    chunk = String.duplicate("\u0001", 40_000)
    append_progress!(run, 1, "stdout", chunk)
    seed = seed_cursor!(conn, run)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 1})

    {drained, frames} = drain_tail!(conn, run, seed, "", 0)

    assert drained == chunk
    assert frames > 1
  end

  test "a compact-JSON backlog never overruns the transport frame", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "tail-compact-json")
    run = create_mcp_history_run!(account, runner, key, 1)

    # The realistic worst case the frame-estimate bug escaped through: compact JSON
    # is almost half quotes and backslashes, and the frame re-escapes those TWICE —
    # once in structuredContent, again in the mirrored text block. This ~165 KiB
    # chunk stays under the 256 KiB per-event ingestion cap, but mirrored and
    # double-escaped it assembles a frame far past 512 KiB if shipped whole; the
    # budget must measure the real frame and fragment it across hops.
    segment = ~s({"k":"v","a":["b","c"],"p":"a\\b"})
    chunk = String.duplicate(segment, 5_000)
    append_progress!(run, 1, "stdout", chunk)
    seed = seed_cursor!(conn, run)

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{"status" => "success", "progress_chunks" => 1})

    {drained, frames} = drain_tail!(conn, run, seed, "", 0)

    # Every hop returned a real run (an overrun would come back as response_too_large),
    # the cursor advanced each hop, and the fragments reconstruct the input byte-exactly.
    assert drained == chunk
    assert frames > 1
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

  test "run summaries omit silent streams and complete-output accounting", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "silent-stream-summary")
    stdout_only_run = create_mcp_history_run!(account, runner, key, 1)
    gappy_run = create_mcp_history_run!(account, runner, key, 2)

    assert {:ok, _event} =
             Runs.append_event(stdout_only_run, %{
               seq: 1,
               kind: "progress",
               stream: "stdout",
               payload: %{"chunk" => "Datacenter: dc1\n"}
             })

    assert {:ok, _finished} =
             Fixtures.Runs.finish(stdout_only_run, %{
               "status" => "success",
               "exit_code" => 0,
               "progress_chunks" => 1,
               "emitted_stdout_bytes" => 16,
               "emitted_stderr_bytes" => 0
             })

    assert {:ok, _finished} =
             Fixtures.Runs.finish(gappy_run, %{
               "status" => "success",
               "progress_chunks" => 3,
               "dropped_progress_chunks" => 2
             })

    stdout_only_summary =
      call(conn, "wait_for_run", %{"run_id" => stdout_only_run.id, "timeout" => "0"})["run"]

    gappy_summary =
      call(conn, "wait_for_run", %{"run_id" => gappy_run.id, "timeout" => "0"})["run"]

    assert stdout_only_summary["stdout"] == "Datacenter: dc1\n"
    assert stdout_only_summary["emitted_stdout_bytes"] == 16
    assert stdout_only_summary["truncated_stdout"] == false
    refute Map.has_key?(stdout_only_summary, "stderr")
    refute Map.has_key?(stdout_only_summary, "emitted_stderr_bytes")
    refute Map.has_key?(stdout_only_summary, "truncated_stderr")
    refute Map.has_key?(stdout_only_summary, "output_complete")
    refute Map.has_key?(stdout_only_summary, "emitted_stdout_sha256")
    refute Map.has_key?(stdout_only_summary, "emitted_stderr_sha256")

    assert gappy_summary["output_complete"] == false
    refute Map.has_key?(gappy_summary, "stdout")
    refute Map.has_key?(gappy_summary, "stderr")
  end

  test "recent history states a terminal failure by status, never by the recorded cause", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "failure-summary")
    failed_run = create_mcp_history_run!(account, runner, key, 1)
    successful_run = create_mcp_history_run!(account, runner, key, 2)
    cause = "reserve failed for €dmin@db1: " <> String.duplicate("runner detail ", 100)

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

    # `status` carries the outcome. The derived `error_message` was a 1:1
    # restatement of it in frozen English, so it went — the point of this test
    # is that the runner's own text never reaches a model.
    assert failed_summary["status"] == "failed"
    assert successful_summary["status"] == "success"
    refute Jason.encode!(summaries) =~ "€dmin@db1"
    refute Map.has_key?(failed_summary, "error_message")
  end

  test "recent history returns typed output intact and omits it under the aggregate budget", %{
    conn: conn,
    account: account,
    subject: subject,
    key: key
  } do
    runner = setup_runner!(account, subject, "typed-summary")

    typed_run =
      create_mcp_history_run!(account, runner, key, 1, %{
        structured_output_expected: true,
        output_schema_snapshot: @typed_output_schema
      })

    assert {:ok, _finished} =
             Fixtures.Runs.finish(typed_run, %{
               "status" => "success",
               "structured_output" => %{"count" => 7, "status" => "ok"}
             })

    typed_summary =
      conn
      |> call("recent_runs", %{})
      |> Map.fetch!("runs")
      |> Enum.find(&(&1["run_id"] == typed_run.id))

    assert typed_summary["structured_output"] == %{"count" => 7, "status" => "ok"}
    refute Map.has_key?(typed_summary, "structured_output_omitted")
    refute Map.has_key?(typed_summary, "next")

    for index <- 2..17 do
      run =
        create_mcp_history_run!(account, runner, key, index, %{
          structured_output_expected: true,
          output_schema_snapshot: @typed_output_schema
        })

      assert {:ok, _finished} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "structured_output" => %{"value" => String.duplicate("x", 5_000)}
               })
    end

    summaries = call(conn, "recent_runs", %{"limit" => 50})["runs"]
    omitted = Enum.filter(summaries, &(&1["structured_output_omitted"] == true))

    assert length(omitted) == 16
    assert Enum.all?(omitted, &(not Map.has_key?(&1, "structured_output")))

    assert Enum.all?(omitted, fn summary ->
             summary["next"] == %{
               "tool" => "wait_for_run",
               "arguments" => %{"run_id" => summary["run_id"], "timeout" => "0"}
             }
           end)

    [first | _rest] = omitted
    recovered = call(conn, "wait_for_run", first["next"]["arguments"])["run"]

    assert recovered["structured_output"] == %{"value" => String.duplicate("x", 5_000)}
    refute Map.has_key?(recovered, "structured_output_omitted")
    refute Map.has_key?(recovered, "next")
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

    for summary <- [default_summary, explicit_summary, generic_summary] do
      assert summary["status"] == "denied"
      refute Map.has_key?(summary, "error_message")
    end

    assert approval_summary["status"] == "cancelled"

    encoded = Jason.encode!(summaries)
    refute encoded =~ secret
    refute encoded =~ "block-critical"
    refute encoded =~ "critical-risk actions"
    refute encoded =~ "change freeze"
  end

  test "wait_for_run rejects a deadline above the repeatable 60-second window", %{conn: conn} do
    result =
      call(conn, "wait_for_run", %{
        "run_id" => Ecto.UUID.generate(),
        "timeout" => "61s"
      })

    assert result["error"]["code"] == "invalid_args"
    assert result["error"]["details"]["kind"] == "format"

    assert result["error"]["details"]["issues"] == [
             %{"path" => "$.timeout", "code" => "format"}
           ]
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

  test "an execution waiting on approval publishes its wait continuation", %{
    conn: conn,
    account: account,
    user: user,
    subject: subject
  } do
    rules = %{
      "schema_version" => 2,
      "defaults" => %{
        "low" => "allow",
        "medium" => "allow",
        "high" => "require_approval",
        "critical" => "require_approval"
      },
      "overrides" => [],
      "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
    }

    Fixtures.Policies.create_policy(
      account_id: account.id,
      created_by_id: user.id,
      rules: rules
    )

    runner =
      setup_runner!(account, subject, "approval-node", action: Map.put(action(), "risk", "high"))

    runbook = publish_runbook!(subject, "gated-health", %{"runner_id" => [runner.id]})

    execution =
      call(conn, "execute_runbook", %{
        "runbook_ref" => "#{runbook.slug}@#{runbook.live_version}",
        "reason" => "Check the gated fleet"
      })

    execution_id = execution["execution"]["runbook_execution_id"]
    assert execution["execution"]["status"] == "pending_approval"

    wait_next = %{
      "tool" => "wait_for_run",
      "arguments" => %{"runbook_execution_id" => execution_id, "timeout" => "60s"}
    }

    assert execution["execution"]["next"] == wait_next

    waited =
      call(conn, "wait_for_run", %{"runbook_execution_id" => execution_id, "timeout" => "0"})

    assert waited["execution"]["status"] == "pending_approval"
    assert waited["execution"]["next"] == wait_next

    # A held execution is still waitable, so a real window stays open instead
    # of returning immediately as though approval were a terminal state.
    started_at = System.monotonic_time(:millisecond)

    held =
      call(conn, "wait_for_run", %{
        "runbook_execution_id" => execution_id,
        "timeout" => "500ms"
      })

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert held["execution"]["status"] == "pending_approval"
    assert held["execution"]["next"] == wait_next
    assert elapsed >= 300
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

  defp append_progress!(run, seq, stream, chunk) do
    assert {:ok, event} =
             Runs.append_event(run, %{
               seq: seq,
               kind: "progress",
               stream: stream,
               payload: %{"chunk" => chunk}
             })

    event
  end

  defp seed_cursor!(conn, run) do
    snapshot = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})["run"]
    snapshot["next"]["arguments"]["cursor"]
  end

  defp tail_text(run), do: Enum.map_join(run["output"], & &1["text"])

  # Follow the tail's `next` to completion, asserting every frame comes back as a
  # real run (a frame that overran the transport ceiling would return an error
  # instead). Returns the reassembled output and the frame count.
  defp drain_tail!(conn, run, cursor, acc, frames) when frames < 100 do
    response =
      rpc(conn, "tools/call", %{
        "name" => "wait_for_run",
        "arguments" => %{"run_id" => run.id, "cursor" => cursor, "timeout" => "0"}
      })

    assert byte_size(response.resp_body) <= ResponseBudget.max_model_page_frame_bytes()
    result = response |> json_response(200) |> get_in(["result", "structuredContent"])
    assert_valid_tool_result("wait_for_run", result)

    summary = result["run"] || flunk("tail frame did not return a run: #{inspect(result)}")
    acc = acc <> tail_text(summary)

    case get_in(summary, ["next", "arguments", "cursor"]) do
      nil -> {acc, frames + 1}
      next_cursor -> drain_tail!(conn, run, next_cursor, acc, frames + 1)
    end
  end

  defp drain_tail!(_conn, _run, _cursor, _acc, _frames),
    do: flunk("output tail did not drain within 100 frames")

  defp drain_execution_outputs!(conn, continuation, outputs, frames) when frames < 100 do
    response =
      rpc(conn, "tools/call", %{
        "name" => continuation["tool"],
        "arguments" => continuation["arguments"]
      })

    assert byte_size(response.resp_body) <= ResponseBudget.max_model_page_frame_bytes()
    payload = response |> json_response(200) |> get_in(["result", "structuredContent"])
    assert_valid_tool_result("wait_for_run", payload)
    page = payload["execution_outputs"]
    assert page["returned_count"] == length(page["outputs"])

    assert page["total_count"] ==
             length(outputs) + page["returned_count"] + page["remaining_count"]

    outputs = outputs ++ page["outputs"]

    case page["next"] do
      nil ->
        assert page["remaining_count"] == 0
        {outputs, frames + 1}

      next ->
        assert page["remaining_count"] > 0
        drain_execution_outputs!(conn, next, outputs, frames + 1)
    end
  end

  defp drain_execution_outputs!(_conn, _continuation, _outputs, _frames),
    do: flunk("runbook outputs did not drain within 100 frames")

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

  # The projection is pure, so unpersisted rows reach the value-safety and
  # status-mapping branches a dispatched execution cannot reproduce.
  defp projected_result(opts) do
    stage = %ExecutionStage{
      id: Ecto.UUID.generate(),
      stage_id: "inspect",
      title: "Inspect",
      position: 0,
      mode: :parallel,
      max_parallel: 16,
      status: Keyword.get(opts, :stage_status, :active)
    }

    item = %ExecutionItem{
      id: Ecto.UUID.generate(),
      runbook_execution_stage_id: stage.id,
      stage_position: 0,
      step_id: "check",
      step_position: 0,
      runner_ref: "db-primary~" <> String.duplicate("a", 32),
      target_selection: "all",
      action_id: "operations.health",
      pack_ref: @pack_ref,
      pack_hash: @hash,
      risk: "low",
      status: Keyword.get(opts, :item_status, :pending),
      attempt_count: Keyword.get(opts, :attempt_count, 0),
      output_plan: Keyword.get(opts, :output_plan, []),
      success_plan: Keyword.get(opts, :success_plan, []),
      outputs: Keyword.get(opts, :outputs, %{}),
      success_evidence: Keyword.get(opts, :success_evidence, [])
    }

    execution = %RunbookExecution{
      id: Ecto.UUID.generate(),
      runbook_version: 1,
      status: Keyword.get(opts, :status, :active),
      stages: [%{stage | items: [item]}],
      items: [item]
    }

    %{
      execution: execution,
      runbook: %Runbook{slug: "database-health", live_version: 1},
      latest_attempts: []
    }
  end

  # A synthetic projection carries no MCP operation, so a schema-valid
  # placeholder stands in for the id when checking the wire contract.
  defp wire_execution(payload) do
    %{"ok" => true, "operation_id" => "op_01J0E11D8Q1W7SM4R5T3Y6V9PA", "execution" => payload}
    |> Jason.encode!()
    |> Jason.decode!()
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
      [Keyword.get(opts, :action, action())]
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
    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)
  end

  defp publish_runbook!(subject, slug, selector, opts \\ []) do
    subject
    |> draft_runbook!(slug, selector, opts)
    |> Fixtures.Runbooks.publish_runbook()
  end

  defp draft_runbook!(subject, slug, selector, opts \\ []) do
    {:ok, draft} =
      Runbooks.create_runbook(
        %{
          "title" => String.replace(slug, "-", " "),
          "slug" => slug,
          "draft_definition" => runbook_definition(target_refs(subject, selector), opts)
        },
        subject
      )

    draft
  end

  defp target_refs(subject, %{"runner_id" => ids}) do
    {:ok, runners} = Runners.list_all_runners_for_account(subject)

    refs =
      runners
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map(&("runner:" <> runner_ref(&1)))

    %{"selection" => "all", "refs" => refs}
  end

  defp target_refs(_subject, %{"group" => groups}),
    do: %{"selection" => "all", "refs" => Enum.map(groups, &("group:" <> &1))}

  defp foreign_key_conn do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, _key} = ApiKeys.create_key(%{name: "foreign-tools", kind: :mcp}, subject)
    authorize(build_conn(), raw)
  end

  defp runbook_definition(targets, opts \\ []) do
    %{
      "schema_version" => 1,
      "context_markdown" => "Verify the selected fleet.",
      "inputs" => Keyword.get(opts, :inputs, []),
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "parallel",
          "max_parallel" => 16,
          "steps" => [
            %{
              "id" => "check",
              "pack" => %{"id" => "operations"},
              "action" => "operations.health",
              "targets" => targets,
              "args" => Keyword.get(opts, :args, %{}),
              "outputs" => Keyword.get(opts, :outputs, []),
              "success" => Keyword.get(opts, :success, []),
              "wait" => Keyword.get(opts, :wait)
            }
          ]
        }
      ]
    }
  end

  defp definition_with_21_binding_issues do
    stages =
      Enum.map(0..5, fn stage_index ->
        steps =
          case stage_index do
            3 ->
              Enum.map(
                0..5,
                &definition_step("project_#{&1}", %{
                  "project" => %{"source" => "project"}
                })
              )

            5 ->
              [
                definition_step("organization_preflight"),
                definition_step("organization_check", %{
                  "organization" => %{"source" => "organization"}
                })
              ]

            _other ->
              [definition_step("step_#{stage_index}")]
          end

        %{
          "id" => "stage_#{stage_index}",
          "title" => "Stage #{stage_index + 1}",
          "mode" => "sequential",
          "steps" => steps
        }
      end)

    %{
      "schema_version" => 1,
      "context_markdown" => "",
      "inputs" => [],
      "stages" => stages
    }
  end

  defp definition_with_66_binding_issues do
    steps =
      Enum.map(
        0..21,
        &definition_step("project_#{&1}", %{
          "project" => %{"source" => "project"}
        })
      )

    %{
      "schema_version" => 1,
      "context_markdown" => "",
      "inputs" => [],
      "stages" => [
        %{
          "id" => "large_invalid_stage",
          "title" => "Large invalid stage",
          "mode" => "sequential",
          "steps" => steps
        }
      ]
    }
  end

  defp definition_step(id, args \\ %{}) do
    %{
      "id" => id,
      "pack" => %{"id" => "operations"},
      "action" => "operations.health",
      "targets" => %{"selection" => "all", "refs" => ["group:default"]},
      "args" => args,
      "outputs" => [],
      "success" => [],
      "wait" => nil
    }
  end

  defp runner_ref(runner),
    do: "#{runner.name}~#{binary_part(Crypto.hash_hex(runner.external_id), 0, 32)}"

  defp action(args \\ [], opts \\ []) do
    action = %{
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

    case Keyword.fetch(opts, :output_schema) do
      {:ok, output_schema} -> Map.put(action, "output_schema", output_schema)
      :error -> action
    end
  end
end
