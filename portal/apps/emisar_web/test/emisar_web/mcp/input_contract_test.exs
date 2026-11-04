defmodule EmisarWeb.MCP.InputContractTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.{InputContract, SchemaRegistry}
  alias EmisarWeb.MCP.SchemaRegistry.Compiler

  @pack_ref "operations@1.0.0/sha256:" <> String.duplicate("a", 64)
  @runner_ref "node~" <> String.duplicate("b", 32)
  @samples %{
    "action_id" => "linux.uptime",
    "cursor" => "next",
    "definition" => %{},
    "definition_sha256" => String.duplicate("c", 64),
    "operation_id" => "op_624NN9NMDZ1T76NARWCKM5A0D6",
    "pack_id" => "ops",
    "pack_ref" => @pack_ref,
    "reason" => "Check the runbook",
    "run_id" => "00000000-0000-4000-8000-000000000001",
    "runbook_execution_id" => "00000000-0000-4000-8000-000000000002",
    "runbook_ref" => "uptime@1",
    "runner_ref" => @runner_ref,
    "runner_refs" => [@runner_ref],
    "slug" => "uptime",
    "step_id" => "check",
    "timeout" => "0",
    "wait" => "0"
  }

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

  # A mutually exclusive pair used to report `conflict` at `$` — "something
  # conflicts" with no way to tell what. A client that sent query WITH action_id
  # could not self-heal from that and abandoned find_actions for the rest of its
  # run, which cost a release certification.
  test "a conflict names the supplied arguments on every tool with such a rule" do
    run_id = "00000000-0000-4000-8000-000000000001"
    execution_id = "00000000-0000-4000-8000-000000000002"
    operation_id = "op_624NN9NMDZ1T76NARWCKM5A0D6"
    action_id = "linux.uptime"
    sha = String.duplicate("c", 64)
    reason = %{"reason" => "Check the runbook"}
    runbook_ref = "uptime@1"

    cases = [
      {"list_packs", %{"pack_id" => "ops", "pack_ref" => @pack_ref}, ~w($.pack_id $.pack_ref)},
      {"list_runners", %{"query" => "web", "runner_refs" => [@runner_ref]},
       ~w($.query $.runner_refs)},
      {"list_runners", %{"pack_id" => "ops", "pack_ref" => @pack_ref}, ~w($.pack_id $.pack_ref)},
      # Two separate collisions in one call are both named.
      {"list_runners",
       %{
         "query" => "web",
         "runner_refs" => [@runner_ref],
         "pack_id" => "ops",
         "pack_ref" => @pack_ref
       }, ~w($.pack_id $.pack_ref $.query $.runner_refs)},
      # The valid action_id and pack_ref pair stays out of it.
      {"get_action",
       %{
         "action_id" => action_id,
         "pack_ref" => @pack_ref,
         "target" => "web",
         "runner_refs" => [@runner_ref]
       }, ~w($.runner_refs $.target)},
      {"wait_for_run", %{"run_id" => run_id, "runbook_execution_id" => execution_id},
       ~w($.run_id $.runbook_execution_id)},
      {"recent_runs", %{"operation_id" => operation_id, "action_id" => action_id},
       ~w($.action_id $.operation_id)},
      {"recent_runs",
       %{"operation_id" => operation_id, "action_id" => action_id, "runner_ref" => @runner_ref},
       ~w($.action_id $.operation_id $.runner_ref)},
      {"execute_runbook", Map.merge(reason, %{"runbook_ref" => runbook_ref, "slug" => "uptime"}),
       ~w($.runbook_ref $.slug)},
      # allow_draft's value is what selects the rule, so it is not one of the collisions.
      {"execute_runbook",
       Map.merge(reason, %{
         "allow_draft" => false,
         "runbook_ref" => runbook_ref,
         "slug" => "uptime"
       }), ~w($.runbook_ref $.slug)},
      {"execute_runbook",
       Map.merge(reason, %{
         "allow_draft" => true,
         "slug" => "uptime",
         "definition_sha256" => sha,
         "runbook_ref" => runbook_ref
       }), ~w($.definition_sha256 $.runbook_ref $.slug)}
    ]

    for {tool, arguments, paths} <- cases do
      assert {:error, issues} = InputContract.validate(tool, arguments)

      assert issues |> Enum.map(& &1.path) |> Enum.sort() == paths,
             "#{tool} named #{inspect(issues)} for #{inspect(Map.keys(arguments))}"

      assert Enum.all?(issues, &(&1.code == "conflict"))
    end
  end

  # Each alternative's failures used to be reported together, so this also asked for
  # run_id, and adding run_id is a conflict.
  test "a run_id is never asked for alongside runbook_execution_id" do
    execution = %{
      "runbook_execution_id" => "00000000-0000-4000-8000-000000000002",
      "cursor" => "next"
    }

    assert {:error, [%{path: "$.timeout", code: "required"}]} =
             InputContract.validate("wait_for_run", execution)

    assert {:error, [%{path: "$.timeout"}]} =
             InputContract.validate("wait_for_run", Map.put(execution, "timeout", "1s"))

    assert {:ok, _} = InputContract.validate("wait_for_run", Map.put(execution, "timeout", "0"))
  end

  test "a refusal states everything wrong across the whole call" do
    run_id = @samples["run_id"]
    execution_id = @samples["runbook_execution_id"]
    reason = %{"reason" => "Check the runbook"}
    draft = %{"title" => "Draft", "slug" => nil, "description" => nil, "definition" => %{}}

    ids = ["conflict $.run_id", "conflict $.runbook_execution_id"]

    cases = [
      # Exactly one is needed, so neither is required on its own.
      {"wait_for_run", %{}, ["one_of $.run_id", "one_of $.runbook_execution_id"]},
      {"wait_for_run", %{"cursor" => "next"},
       ["one_of $.run_id", "one_of $.runbook_execution_id"]},
      # A missing argument that would collide with a supplied one names that one too.
      {"list_runners", %{"action_id" => "linux.uptime", "pack_id" => "ops"},
       ["conflict $.pack_id", "required $.pack_ref"]},
      {"execute_runbook", Map.put(reason, "slug", "uptime"),
       ["conflict $.slug", "required $.runbook_ref"]},
      {"execute_runbook",
       Map.merge(reason, %{"allow_draft" => true, "runbook_ref" => "uptime@1"}),
       ["conflict $.runbook_ref", "required $.definition_sha256", "required $.slug"]},
      {"recent_runs", %{"operation_id" => @samples["operation_id"], "step_id" => "check"},
       ["conflict $.operation_id", "conflict $.step_id", "required $.runbook_execution_id"]},
      # A collision is not hidden behind another problem.
      {"get_action", %{"target" => "web", "runner_refs" => [@runner_ref]},
       [
         "conflict $.runner_refs",
         "conflict $.target",
         "required $.action_id",
         "required $.pack_ref"
       ]},
      {"list_runners", %{"query" => "web", "runner_refs" => [@runner_ref], "limit" => "many"},
       ["conflict $.query", "conflict $.runner_refs", "type $.limit"]},
      {"find_actions", %{"query" => "uptime", "action_id" => "linux.uptime", "nope" => 1},
       ["conflict $.action_id", "conflict $.query", "unknown $.nope"]},
      {"wait_for_run", %{"run_id" => "nope", "runbook_execution_id" => execution_id},
       ids ++ ["format $.run_id"]},
      {"wait_for_run",
       %{"run_id" => run_id, "runbook_execution_id" => execution_id, "cursor" => "next"},
       ids ++ ["required $.timeout"]},
      # A value is judged only against what it could be.
      {"wait_for_run",
       %{"runbook_execution_id" => execution_id, "cursor" => "next", "timeout" => "1s"},
       ["enum $.timeout"]},
      {"create_runbook_draft", %{draft | "slug" => "BAD SLUG"}, ["format $.slug"]},
      {"create_runbook_draft", %{draft | "slug" => 7}, ["type $.slug"]},
      {"create_runbook_draft", %{draft | "description" => String.duplicate("a", 4097)},
       ["max_length $.description"]}
    ]

    for {tool, arguments, expected} <- cases do
      assert {:error, issues} = InputContract.validate(tool, arguments)

      assert issues |> Enum.map(&"#{&1.code} #{&1.path}") |> Enum.sort() == Enum.sort(expected),
             "#{tool} with #{inspect(Map.keys(arguments))}"
    end
  end

  # Nothing in JSON Schema stops a refusal asking for what can only be refused next, so
  # walk every combination of every tool's arguments and follow each refusal.
  test "following any refusal can reach an accepted call" do
    for contract <- SchemaRegistry.contracts() do
      tool = contract["name"]
      schema = contract["inputSchema"]
      expanded = Compiler.expand!(schema, schema)
      properties = Compiler.root_properties(expanded)
      groups = Compiler.exclusive_groups(expanded)

      for names <- subsets(Map.keys(properties)) do
        arguments = Map.new(names, &{&1, sample_argument(&1, properties)})
        collisions = Enum.filter(groups, &MapSet.subset?(&1, MapSet.new(names)))

        case InputContract.validate(tool, arguments) do
          {:ok, _} ->
            assert collisions == [], "#{tool} accepted #{inspect(names)} against a conflict rule"

          {:error, issues} ->
            named = issue_arguments(issues, "conflict")

            assert Enum.all?(collisions, &(&1 |> Enum.all?(fn field -> field in named end))),
                   "#{tool} hid a conflict in #{inspect(names)}: #{inspect(issues)}"

            assert follows_to_accepted_call?(tool, arguments, issues, properties),
                   "#{tool} with #{inspect(names)} cannot follow #{inspect(issues)}"
        end
      end
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

  defp follows_to_accepted_call?(tool, arguments, issues, properties) do
    conflicting = issue_arguments(issues, "conflict")
    removals = if conflicting == [], do: [[]], else: subsets(conflicting) -- [[]]

    choices =
      case issue_arguments(issues, "one_of") do
        [] -> [[]]
        alternatives -> Enum.map(alternatives, &[&1])
      end

    add = issue_arguments(issues, "required")

    Enum.any?(for(removal <- removals, choice <- choices, do: {removal, choice}), fn {removal,
                                                                                      choice} ->
      next =
        arguments
        |> Map.drop(removal)
        |> Map.merge(Map.new(add ++ choice, &{&1, sample_argument(&1, properties)}))

      match?({:ok, _}, InputContract.validate(tool, next))
    end)
  end

  defp issue_arguments(issues, code) do
    for %{code: ^code, path: "$." <> argument} <- issues, do: argument
  end

  defp subsets(items) do
    Enum.reduce(items, [[]], fn item, sets -> sets ++ Enum.map(sets, &[item | &1]) end)
  end

  defp sample_argument(name, properties) do
    schema = Map.fetch!(properties, name)

    cond do
      Map.has_key?(@samples, name) -> @samples[name]
      Map.has_key?(schema, "enum") -> hd(schema["enum"])
      schema["type"] == "array" -> [hd(schema["items"]["enum"])]
      schema["type"] == "boolean" -> true
      schema["type"] == "integer" -> 5
      schema["type"] == "object" -> %{}
      true -> "text"
    end
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
