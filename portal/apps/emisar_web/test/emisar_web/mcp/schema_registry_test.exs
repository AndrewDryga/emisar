defmodule EmisarWeb.MCP.SchemaRegistryTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.{ResponseBudget, SchemaRegistry}
  alias EmisarWeb.MCP.SchemaRegistry.Compiler

  @schema_path Path.expand("../../../../../../docs/mcp-api-schemas.json", __DIR__)
  @tool_names ~w(
    list_packs
    list_runners
    find_actions
    get_action
    run_action
    get_operation
    wait_for_run
    recent_runs
    list_runbooks
    get_runbook
    execute_runbook
    create_runbook_draft
  )

  test "publishes exactly the twelve normative descriptors in contract order" do
    tools = SchemaRegistry.tools()

    assert length(tools) == 12
    assert SchemaRegistry.tool_names() == @tool_names
    assert Enum.map(tools, & &1["name"]) == @tool_names

    expected_fields = ~w(annotations description inputSchema name title)
    assert Enum.all?(tools, &(Enum.sort(Map.keys(&1)) == expected_fields))
    assert tools == Enum.map(SchemaRegistry.contracts(), &Map.delete(&1, "outputSchema"))

    # The wire catalog stays lean: response schemas live in the internal
    # contracts, never in tools/list.
    assert byte_size(Jason.encode!(tools)) <= 32_768

    frame = %{
      jsonrpc: "2.0",
      id: String.duplicate("\0", ResponseBudget.max_request_id_bytes()),
      result: %{tools: tools}
    }

    assert {:ok, encoded} = ResponseBudget.encode_frame(frame)
    assert byte_size(encoded) <= ResponseBudget.max_frame_bytes()
  end

  test "pins model-facing descriptions for reasons, waits, and pack availability" do
    list_packs = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "list_packs"))
    run_action = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "run_action"))
    wait_for_run = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "wait_for_run"))

    assert list_packs["description"] ==
             "List operator-trusted exact pack refs observed on in-scope runners, with their bounded action catalogs. The all view includes trusted but currently unavailable deployments; packs without current trust are omitted."

    find_actions = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "find_actions"))

    assert find_actions["description"] ==
             "Search runnable actions across every in-scope runner by operational task. Pass the task as `query`; one search covers the whole fleet, so do not repeat it per runner. Returns only actions you can run right now, ranked, without argument schemas — call get_action once for the chosen action_id and pack_ref and it returns every compatible runner. The exact filters only narrow a known target; `query` is the normal path."

    assert find_actions["inputSchema"]["properties"]["limit"]["description"] ==
             "Maximum candidates to return, 1 through 15 (default 15). Omit unless you deliberately want fewer."

    assert get_in(find_actions, ["inputSchema", "$defs", "cursor", "description"]) =~
             "Opaque continuation token"

    assert get_in(run_action, ["inputSchema", "$defs", "reason", "description"]) ==
             "Human-readable justification for this action. Shown to human approvers and recorded in the audit log — state what you are doing and why (e.g. 'Restart stuck postgres on db-1 to clear a connection pileup'). A vague or placeholder reason slows approval."

    assert get_in(run_action, ["inputSchema", "$defs", "evidence", "description"]) ==
             "Optional: what you already observed that makes this action necessary — prior findings, error signatures, or the run ids you inspected. State it so approvers and the audit log see the basis. Not verified."

    assert get_in(run_action, ["inputSchema", "$defs", "expected", "description"]) ==
             "Optional: the outcome you expect if this action works — the hypothesis a follow-up check would confirm. Records what success looks like for approvers and the audit log. Not required and not verified."

    assert run_action["inputSchema"]["properties"]["wait"]["description"] ==
             "Maximum time to block before returning the current state, as a duration string: \"0\", \"30s\", or \"1500ms\"."

    assert get_in(wait_for_run, [
             "inputSchema",
             "$defs",
             "wait_for_run_arguments",
             "properties",
             "timeout",
             "description"
           ]) ==
             "Maximum time to block before returning the current state, as a duration string: \"0\", \"30s\", or \"1500ms\"."
  end

  test "omitted typed output requires one immediate wait continuation" do
    run_summary =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["$defs", "run_summary"])

    immediate =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["$defs", "next_wait_run_immediate"])

    assert %{"const" => "0"} =
             immediate
             |> get_in(["allOf"])
             |> List.last()
             |> get_in(["properties", "arguments", "properties", "timeout"])

    assert ["run_id", "timeout"] =
             immediate
             |> get_in(["allOf"])
             |> List.last()
             |> get_in(["properties", "arguments", "required"])

    refute get_in(immediate, ["allOf", Access.at(1), "properties", "arguments", "properties"])
           |> Map.has_key?("runbook_execution_id")

    omission_rule =
      Enum.find(
        run_summary["allOf"],
        &(&1["if"] == %{"required" => ["structured_output_omitted"]})
      )

    assert "next" in omission_rule["then"]["required"]

    assert omission_rule["then"]["properties"]["next"] == %{
             "$ref" => "#/$defs/next_wait_run_immediate"
           }
  end

  test "published contracts retain self-contained input and response schemas" do
    registry = @schema_path |> File.read!() |> Jason.decode!()

    Enum.each(SchemaRegistry.contracts(), fn contract ->
      expected =
        registry
        |> Map.fetch!("tools")
        |> Map.fetch!(contract["name"])
        |> Map.update!("inputSchema", &Compiler.bundle!(&1, registry))
        |> Map.update!("outputSchema", &Compiler.bundle!(&1, registry))
        |> Map.put("name", contract["name"])

      assert contract == expected
      assert_self_contained_schemas(contract)
    end)
  end

  test "invalid_args requires exact bounded validation details" do
    schema =
      SchemaRegistry.contracts()
      |> Enum.find(&(&1["name"] == "list_packs"))
      |> Map.fetch!("outputSchema")

    assert {:ok, schema} = JSONSchex.compile(schema, format_assertion: true)

    base = %{
      "ok" => false,
      "dispatch_started" => false,
      "error" => %{
        "code" => "invalid_args",
        "message" => "Invalid.",
        "retryable" => false
      }
    }

    assert {:error, _reason} = JSONSchex.validate(schema, base)

    details = %{
      "schema_version" => 1,
      "stage" => "arguments",
      "kind" => "type",
      "issues" => [%{"path" => "$.limit", "code" => "type"}]
    }

    valid = put_in(base, ["error", "details"], details)
    assert :ok = JSONSchex.validate(schema, valid)

    assert {:error, _reason} =
             JSONSchex.validate(
               schema,
               put_in(valid, ["error", "details"], Map.put(details, "extra", true))
             )

    assert {:error, _reason} =
             JSONSchex.validate(
               schema,
               put_in(valid, ["error", "details", "kind"], "attacker-kind")
             )

    too_many =
      Enum.map(1..9, fn index -> %{"path" => "$.field#{index}", "code" => "type"} end)

    assert {:error, _reason} =
             JSONSchex.validate(schema, put_in(valid, ["error", "details", "issues"], too_many))
  end

  test "schema bundling preserves references and includes only reachable definitions" do
    registry = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => %{
        "duration" => %{"type" => "string", "pattern" => "^[0-9]+s$"},
        "unused" => %{"type" => "boolean"}
      }
    }

    assert Compiler.bundle!(
             %{"$ref" => "#/$defs/duration", "default" => "60s"},
             registry
           ) == %{
             "$ref" => "#/$defs/duration",
             "$schema" => "https://json-schema.org/draft/2020-12/schema",
             "$defs" => %{
               "duration" => %{"type" => "string", "pattern" => "^[0-9]+s$"}
             },
             "default" => "60s"
           }
  end

  test "schema bundling rejects unresolved, external, and cyclic references" do
    assert_raise ArgumentError, ~r/unresolved MCP schema reference/, fn ->
      Compiler.bundle!(%{"$ref" => "#/$defs/missing"}, %{"$defs" => %{}})
    end

    assert_raise ArgumentError, ~r/must be an internal definition/, fn ->
      Compiler.bundle!(%{"$ref" => "https://example.com/schema.json"}, %{})
    end

    assert_raise ArgumentError, ~r/must be a string/, fn ->
      Compiler.bundle!(%{"$ref" => 42}, %{})
    end

    registry = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => %{
        "a" => %{"$ref" => "#/$defs/b"},
        "b" => %{"$ref" => "#/$defs/a"}
      }
    }

    assert_raise ArgumentError, ~r/cyclic MCP schema reference/, fn ->
      Compiler.bundle!(%{"$ref" => "#/$defs/a"}, registry)
    end
  end

  test "compilation rejects tool-set and descriptor-field drift" do
    path =
      Path.join(
        System.tmp_dir!(),
        "emisar-mcp-schema-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(path, Jason.encode!(%{"schema_version" => 1, "tools" => %{}}))

    assert_raise ArgumentError, ~r/tool set mismatch/, fn ->
      Compiler.compile!(path, ["only_tool"])
    end

    File.write!(
      path,
      Jason.encode!(%{"schema_version" => 1, "tools" => %{"only_tool" => %{}}})
    )

    assert_raise ArgumentError, ~r/has fields/, fn ->
      Compiler.compile!(path, ["only_tool"])
    end
  end

  defp assert_self_contained_schemas(tool) do
    Enum.each(~w(inputSchema outputSchema), fn field ->
      schema = Map.fetch!(tool, field)

      assert schema["type"] == "object"
      definitions = Map.get(schema, "$defs", %{})

      assert schema |> referenced_definitions() |> Enum.sort() ==
               definitions |> Map.keys() |> Enum.sort()

      assert schema == schema |> Jason.encode!() |> Jason.decode!()
    end)
  end

  defp referenced_definitions(%{} = value) do
    own =
      case value["$ref"] do
        "#/$defs/" <> name -> [name]
        nil -> []
      end

    Enum.reduce(value, own, fn {_key, child}, names ->
      referenced_definitions(child) ++ names
    end)
    |> Enum.uniq()
  end

  defp referenced_definitions(value) when is_list(value),
    do: value |> Enum.flat_map(&referenced_definitions/1) |> Enum.uniq()

  defp referenced_definitions(_value), do: []
end
