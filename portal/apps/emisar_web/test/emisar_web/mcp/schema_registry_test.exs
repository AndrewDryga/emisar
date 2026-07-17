defmodule EmisarWeb.MCP.SchemaRegistryTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.SchemaRegistry
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

    assert byte_size(Jason.encode!(tools)) <= 32_768
  end

  test "pins model-facing descriptions for reasons, waits, and pack availability" do
    list_packs = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "list_packs"))
    run_action = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "run_action"))
    wait_for_run = Enum.find(SchemaRegistry.tools(), &(&1["name"] == "wait_for_run"))

    assert list_packs["description"] ==
             "List packs observed on in-scope runners, with their bounded action catalogs. Returns the executable capabilities you can run right now."

    assert run_action["inputSchema"]["properties"]["reason"]["description"] ==
             "Human-readable justification for this action. Shown to human approvers and recorded in the audit log — state what you are doing and why (e.g. 'Restart stuck postgres on db-1 to clear a connection pileup'). A vague or placeholder reason slows approval."

    assert run_action["inputSchema"]["properties"]["wait"]["description"] ==
             "Maximum time to block before returning the current state."

    assert wait_for_run["inputSchema"]["allOf"]
           |> List.first()
           |> get_in(["properties", "timeout", "description"]) ==
             "Maximum time to block before returning the current state."
  end

  test "complete internal contracts retain self-contained response schemas" do
    registry = @schema_path |> File.read!() |> Jason.decode!()

    Enum.each(SchemaRegistry.contracts(), fn contract ->
      expected =
        registry
        |> Map.fetch!("tools")
        |> Map.fetch!(contract["name"])
        |> Compiler.resolve!(registry)
        |> Map.put("name", contract["name"])

      assert contract == expected
      assert_self_contained_schemas(contract)
    end)
  end

  test "reference resolution preserves sibling schema keywords" do
    registry = %{
      "$defs" => %{
        "duration" => %{"type" => "string", "pattern" => "^[0-9]+s$"}
      }
    }

    assert Compiler.resolve!(
             %{"$ref" => "#/$defs/duration", "default" => "60s"},
             registry
           ) == %{
             "type" => "string",
             "pattern" => "^[0-9]+s$",
             "default" => "60s"
           }
  end

  test "reference resolution rejects unresolved, external, and cyclic references" do
    assert_raise ArgumentError, ~r/unresolved MCP schema reference/, fn ->
      Compiler.resolve!(%{"$ref" => "#/$defs/missing"}, %{"$defs" => %{}})
    end

    assert_raise ArgumentError, ~r/must be internal/, fn ->
      Compiler.resolve!(%{"$ref" => "https://example.com/schema.json"}, %{})
    end

    assert_raise ArgumentError, ~r/must be a string/, fn ->
      Compiler.resolve!(%{"$ref" => 42}, %{})
    end

    registry = %{
      "$defs" => %{
        "a" => %{"$ref" => "#/$defs/b"},
        "b" => %{"$ref" => "#/$defs/a"}
      }
    }

    assert_raise ArgumentError, ~r/cyclic MCP schema reference/, fn ->
      Compiler.resolve!(%{"$ref" => "#/$defs/a"}, registry)
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
      refute contains_key?(schema, "$ref")
      refute contains_key?(schema, "$defs")
      assert schema == schema |> Jason.encode!() |> Jason.decode!()
    end)
  end

  defp contains_key?(%{} = value, key) do
    Map.has_key?(value, key) or
      Enum.any?(value, fn {_key, child} -> contains_key?(child, key) end)
  end

  defp contains_key?(value, key) when is_list(value),
    do: Enum.any?(value, &contains_key?(&1, key))

  defp contains_key?(_value, _key), do: false
end
