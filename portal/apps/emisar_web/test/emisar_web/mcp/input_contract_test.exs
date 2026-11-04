defmodule EmisarWeb.MCP.InputContractTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.InputContract

  @pack_ref "operations@1.0.0/sha256:" <> String.duplicate("a", 64)
  @runner_ref "node~" <> String.duplicate("b", 32)

  test "rejects strings for published integer and boolean fields" do
    assert {:error, [%{path: "$.limit", code: "type"}]} =
             InputContract.validate("list_runners", %{"limit" => "50"})

    assert {:error, [%{path: "$.issues_only", code: "type"}]} =
             InputContract.validate("list_runners", %{"issues_only" => "true"})
  end

  test "rejects non-object arguments and normalizes schema-valid integral numbers" do
    assert {:error, [%{path: "$", code: "type"}]} = InputContract.validate("list_packs", false)
    assert {:ok, %{"limit" => 50}} = InputContract.validate("list_packs", %{"limit" => 50.0})
    assert {:ok, %{"limit" => 15}} = InputContract.validate("recent_runs", %{"limit" => 15.0})
  end

  test "bounds reason to the published 12-to-2000-character range" do
    action = valid_action_args(%{"reason" => "Check memory"})
    assert {:ok, _arguments} = InputContract.validate("run_action", action)

    action = valid_action_args(%{"reason" => "H"})

    assert {:error, [%{path: "$.reason", code: "min"}]} =
             InputContract.validate("run_action", action)

    action = valid_action_args(%{"reason" => String.duplicate("😀", 2_000)})
    assert {:ok, _arguments} = InputContract.validate("run_action", action)

    action = valid_action_args(%{"reason" => String.duplicate("😀", 2_001)})

    assert {:error, [%{path: "$.reason", code: "max_length"}]} =
             InputContract.validate("run_action", action)

    action = valid_action_args(%{"reason" => "   "})

    assert {:error,
            [
              %{path: "$.reason", code: "format"},
              %{path: "$.reason", code: "min"}
            ]} =
             InputContract.validate("run_action", action)
  end

  test "accepts the optional evidence/expected chain and bounds each" do
    action =
      valid_action_args(%{
        "evidence" => "prior run 0f9c showed disk at 98%",
        "expected" => "df reports under 80% after cleanup"
      })

    assert {:ok, arguments} = InputContract.validate("run_action", action)
    assert arguments["evidence"] == "prior run 0f9c showed disk at 98%"
    assert arguments["expected"] == "df reports under 80% after cleanup"

    over_evidence = valid_action_args(%{"evidence" => String.duplicate("e", 4_001)})

    assert {:error, [%{path: "$.evidence", code: "max_length"}]} =
             InputContract.validate("run_action", over_evidence)

    over_expected = valid_action_args(%{"expected" => String.duplicate("x", 2_001)})

    assert {:error, [%{path: "$.expected", code: "max_length"}]} =
             InputContract.validate("run_action", over_expected)

    blank_evidence = valid_action_args(%{"evidence" => "   "})

    assert {:error, [%{path: "$.evidence", code: "format"}]} =
             InputContract.validate("run_action", blank_evidence)
  end

  test "preserves specific JSONSchex size and uniqueness rules" do
    assert {:error, [%{path: "$.query", code: "max_length"}]} =
             InputContract.validate("list_runners", %{"query" => String.duplicate("x", 257)})

    runner_ref = @runner_ref

    assert {:error, [%{path: "$.runner_refs", code: "unique"}]} =
             InputContract.validate("list_runners", %{"runner_refs" => [runner_ref, runner_ref]})

    assert {:error, [%{path: "$.limit", code: "min"}]} =
             InputContract.validate("list_packs", %{"limit" => 0})
  end

  test "recent_runs accepts only a non-empty unique set of published statuses" do
    assert {:ok, %{"statuses" => ["failed", "refused"]}} =
             InputContract.validate("recent_runs", %{"statuses" => ["failed", "refused"]})

    assert {:error, [%{path: "$.statuses", code: "min"}]} =
             InputContract.validate("recent_runs", %{"statuses" => []})

    assert {:error, [%{path: "$.statuses", code: "unique"}]} =
             InputContract.validate("recent_runs", %{"statuses" => ["failed", "failed"]})

    assert {:error, [%{path: "$.statuses", code: "enum"}]} =
             InputContract.validate("recent_runs", %{"statuses" => ["failure"]})
  end

  test "unknown tools and root fields fail closed" do
    assert {:error, [%{path: "$", code: "schema"}]} =
             InputContract.validate("not_a_tool", %{})

    assert {:error, [%{path: "$.junk", code: "unknown"}]} =
             InputContract.validate("list_packs", %{"junk" => 1})
  end

  test "defers runbook definition details while preserving its published schema" do
    arguments = %{
      "title" => "Repair draft",
      "slug" => nil,
      "description" => nil,
      "definition" => %{"schema_version" => 1, "stages" => []}
    }

    assert {:ok, ^arguments} = InputContract.validate("create_runbook_draft", arguments)

    assert {:error, [%{path: "$.title", code: "type"}]} =
             InputContract.validate(
               "create_runbook_draft",
               Map.put(arguments, "title", false)
             )
  end

  test "exposes published root argument names for safe log paths" do
    assert MapSet.member?(InputContract.known_root_fields("list_packs"), "limit")
    assert MapSet.member?(InputContract.known_root_fields("run_action"), "action_id")
    assert InputContract.known_root_fields("not_a_tool") == MapSet.new()
  end

  # A mutually exclusive pair used to report `conflict` at `$` — "something
  # conflicts" with no way to tell what. A client that sent query WITH action_id
  # could not self-heal from that and abandoned find_actions for the rest of its
  # run, which cost a release certification.
  test "every cross-field rule moved out of tools/list is still refused" do
    run_id = "00000000-0000-4000-8000-000000000001"
    execution_id = "00000000-0000-4000-8000-000000000002"
    operation_id = "op_624NN9NMDZ1T76NARWCKM5A0D6"
    action_id = "linux.uptime"
    sha = String.duplicate("c", 64)
    reason = %{"reason" => "Check the runbook"}
    runbook_ref = "uptime@1"

    refused = [
      {"list_packs", %{"pack_id" => "ops", "pack_ref" => @pack_ref}},
      {"list_runners", %{"query" => "web", "runner_refs" => [@runner_ref]}},
      {"list_runners", %{"pack_id" => "ops", "pack_ref" => @pack_ref}},
      {"list_runners", %{"action_id" => action_id}},
      {"get_action",
       %{
         "action_id" => action_id,
         "pack_ref" => @pack_ref,
         "target" => "web",
         "runner_refs" => [@runner_ref]
       }},
      {"find_actions", %{"query" => "uptime", "action_id" => action_id}},
      {"find_actions", %{"pack_id" => "ops", "pack_ref" => @pack_ref}},
      {"find_actions", %{"target" => "web", "runner_refs" => [@runner_ref]}},
      {"wait_for_run", %{}},
      {"wait_for_run", %{"run_id" => run_id, "runbook_execution_id" => execution_id}},
      {"wait_for_run", %{"runbook_execution_id" => execution_id, "cursor" => "next"}},
      {"wait_for_run",
       %{"runbook_execution_id" => execution_id, "cursor" => "next", "timeout" => "1s"}},
      {"recent_runs", %{"operation_id" => operation_id, "action_id" => action_id}},
      {"recent_runs", %{"operation_id" => operation_id, "runner_ref" => @runner_ref}},
      {"recent_runs", %{"operation_id" => operation_id, "pack_ref" => @pack_ref}},
      {"recent_runs", %{"operation_id" => operation_id, "runbook_execution_id" => execution_id}},
      {"recent_runs", %{"step_id" => "check"}},
      {"execute_runbook", reason},
      {"execute_runbook", Map.merge(reason, %{"slug" => "uptime"})},
      {"execute_runbook", Map.merge(reason, %{"runbook_ref" => runbook_ref, "slug" => "uptime"})},
      {"execute_runbook", Map.merge(reason, %{"allow_draft" => true, "slug" => "uptime"})},
      {"execute_runbook",
       Map.merge(reason, %{
         "allow_draft" => true,
         "slug" => "uptime",
         "definition_sha256" => sha,
         "runbook_ref" => runbook_ref
       })}
    ]

    for {tool, arguments} <- refused do
      assert {:error, [_issue | _]} = InputContract.validate(tool, arguments),
             "#{tool} accepted #{inspect(arguments)}"
    end

    # Each value above is valid alone, so a refusal proves the combination rule.
    accepted = [
      {"list_packs", %{"pack_id" => "ops"}},
      {"list_packs", %{"pack_ref" => @pack_ref}},
      {"list_runners", %{"query" => "web"}},
      {"list_runners", %{"runner_refs" => [@runner_ref]}},
      {"get_action", %{"action_id" => action_id, "pack_ref" => @pack_ref, "target" => "web"}},
      {"find_actions", %{"query" => "uptime"}},
      {"find_actions", %{"action_id" => action_id}},
      {"recent_runs", %{"operation_id" => operation_id}},
      {"recent_runs", %{"action_id" => action_id, "runner_ref" => @runner_ref}},
      {"execute_runbook", Map.put(reason, "runbook_ref", runbook_ref)},
      {"wait_for_run", %{"run_id" => run_id}},
      {"wait_for_run",
       %{"runbook_execution_id" => execution_id, "cursor" => "n", "timeout" => "0"}},
      {"recent_runs", %{"step_id" => "check", "runbook_execution_id" => execution_id}},
      {"list_runners", %{"action_id" => action_id, "pack_ref" => @pack_ref}},
      {"execute_runbook",
       Map.merge(reason, %{"allow_draft" => true, "slug" => "uptime", "definition_sha256" => sha})}
    ]

    for {tool, arguments} <- accepted do
      assert {:ok, _arguments} = InputContract.validate(tool, arguments),
             "#{tool} refused #{inspect(arguments)}"
    end
  end

  test "a mutual-exclusion conflict names the fields that actually collide" do
    assert {:error, issues} =
             InputContract.validate("find_actions", %{
               "query" => "load average",
               "action_id" => "debugging.loadavg"
             })

    paths = Enum.map(issues, & &1.path)
    assert "$.query" in paths
    assert "$.action_id" in paths
    assert Enum.all?(issues, &(&1.code == "conflict"))

    # Only the pair the caller actually supplied is named — the schema declares
    # three exclusive groups, and reporting the other two would be noise.
    refute "$.pack_id" in paths
    refute "$.target" in paths

    # Either half alone stays valid: the fix reports the collision, it does not
    # invent one.
    assert {:ok, _} = InputContract.validate("find_actions", %{"query" => "load average"})

    assert {:ok, _} =
             InputContract.validate("find_actions", %{"action_id" => "debugging.loadavg"})
  end

  defp valid_action_args(overrides) do
    Map.merge(
      %{
        "action_id" => "demo.inspect",
        "pack_ref" => @pack_ref,
        "runner_refs" => [@runner_ref],
        "args" => %{},
        "reason" => "Inspect demo action"
      },
      overrides
    )
  end
end
