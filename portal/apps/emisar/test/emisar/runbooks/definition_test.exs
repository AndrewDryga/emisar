defmodule Emisar.Runbooks.DefinitionTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.Definition

  describe "decode_json/1" do
    test "accepts one bounded canonical JSON document" do
      definition = valid_definition()

      assert {:ok, ^definition} = definition |> Jason.encode!() |> Definition.decode_json()
    end

    test "rejects malformed, oversized, and structurally invalid JSON" do
      assert {:error, [%{code: "invalid_json"}]} = Definition.decode_json("{")

      oversized = String.duplicate(" ", Definition.limit!(:max_definition_bytes) + 1)

      assert {:error, [%{message: message}]} = Definition.decode_json(oversized)
      assert message =~ "byte limit"

      assert {:error, [%{path: "/stages"}]} =
               %{"schema_version" => 1, "context_markdown" => "", "inputs" => []}
               |> Jason.encode!()
               |> Definition.decode_json()
    end
  end

  describe "validate/1" do
    test "accepts the one explicit v1 shape" do
      assert {:ok, definition} = Definition.validate(valid_definition())
      assert definition["schema_version"] == 1
    end

    test "rejects aliases and unknown fields with deterministic JSON Pointer errors" do
      definition =
        valid_definition()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "pack_ref"], "linux@1.0.0")

      assert {:error, issues} = Definition.validate(definition)

      assert Enum.map(issues, &{&1.code, &1.path}) == [
               {"invalid_definition", "/stages/0/steps/0/pack_ref"}
             ]
    end

    test "rejects unknown schema versions explicitly" do
      definition = Map.put(valid_definition(), "schema_version", 2)

      assert {:error, [%{code: "unsupported_schema_version", path: "/schema_version"}]} =
               Definition.validate(definition)
    end

    test "rejects duplicate input, stage, step, and output IDs" do
      first_stage = hd(valid_definition()["stages"])
      duplicate_step = first_stage["steps"] |> hd() |> put_in(["outputs"], [output("ready")])

      definition =
        valid_definition()
        |> Map.put("inputs", [input("host"), input("host")])
        |> Map.put("stages", [
          first_stage
          |> Map.put("steps", [
            put_in(hd(first_stage["steps"]), ["outputs"], [output("ready"), output("ready")]),
            duplicate_step
          ]),
          first_stage
        ])

      assert {:error, issues} = Definition.validate(definition)

      assert Enum.map(issues, & &1.path) == [
               "/inputs/1/id",
               "/stages/0/steps/0/outputs/1/id",
               "/stages/0/steps/1/id",
               "/stages/1/id",
               "/stages/1/steps/0/id"
             ]
    end

    test "pack selection has one canonical id and rejects author-facing versions" do
      definition =
        put_in(
          valid_definition(),
          ["stages", Access.at(0), "steps", Access.at(0), "pack", "requirement"],
          "~> 1.4.0"
        )

      assert {:error, issues} = Definition.validate(definition)
      assert Enum.map(issues, & &1.path) == ["/stages/0/steps/0/pack/requirement"]
    end

    test "enforces typed input constraints and forbids sensitive defaults" do
      definition =
        valid_definition()
        |> Map.put("inputs", [
          input("host"),
          input("count", %{
            "type" => "integer",
            "minimum" => 10,
            "maximum" => 1,
            "min_length" => 2
          }),
          input("token", %{"sensitive" => true, "default" => "secret"})
        ])

      assert {:error, issues} = Definition.validate(definition)

      assert Enum.map(issues, & &1.path) == [
               "/inputs/1/maximum",
               "/inputs/1/min_length",
               "/inputs/2/default"
             ]
    end

    test "requires input and output bindings to resolve in an earlier stage" do
      definition =
        valid_definition()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "args"],
          %{
            "missing" => %{"source" => "input", "ref" => "not_declared"},
            "future" => %{"source" => "output", "ref" => "observe.ready"}
          }
        )

      assert {:error, issues} = Definition.validate(definition)

      assert Enum.map(issues, &{&1.code, &1.path}) == [
               {"invalid_binding", "/stages/0/steps/0/args/future/ref"},
               {"invalid_binding", "/stages/0/steps/0/args/missing/ref"}
             ]
    end

    test "requires success conditions to use declared outputs and typed values" do
      definition =
        valid_definition()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "success"],
          [
            %{"output" => "missing", "operator" => "equals", "value" => true},
            %{"output" => "ready", "operator" => "greater_than", "value" => "1"},
            %{"output" => "ready", "operator" => "one_of", "value" => []},
            %{"output" => "ready", "operator" => "matches", "value" => "("}
          ]
        )

      assert {:error, issues} = Definition.validate(definition)
      assert length(issues) == 4
      assert Enum.all?(issues, &(&1.code == "invalid_definition"))
    end

    test "validates JSON pointers, bounded regexes, and wait arithmetic" do
      definition =
        valid_definition()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
          [
            output("bad_pointer", %{"type" => "json_pointer", "expression" => "state"}),
            output("bad_regex", %{"type" => "regex", "expression" => "(", "capture" => "0"})
          ]
        )
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "wait"],
          %{"interval_seconds" => 30, "timeout_seconds" => 60, "max_attempts" => 4}
        )
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "success"], [])

      assert {:error, issues} = Definition.validate(definition)

      assert Enum.map(issues, & &1.path) == [
               "/stages/0/steps/0/outputs/0/extract/expression",
               "/stages/0/steps/0/outputs/1/extract/expression",
               "/stages/0/steps/0/wait/timeout_seconds"
             ]
    end

    test "enforces encoded and UTF-8 byte limits from the machine schema" do
      max_markdown = Definition.limit!(:max_context_markdown_bytes)

      definition =
        Map.put(
          valid_definition(),
          "context_markdown",
          String.duplicate("🙂", div(max_markdown, 2))
        )

      assert {:error, issues} = Definition.validate(definition)
      assert Enum.any?(issues, &(&1.path == "/context_markdown"))
    end
  end

  describe "validate_draft/1" do
    test "accepts an incomplete canonical draft within the shared safety envelope" do
      draft =
        valid_definition()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "action"], "")

      assert {:ok, ^draft} = Definition.validate_draft(draft)
      assert {:error, _issues} = Definition.validate(draft)
    end

    test "rejects oversized and unsupported drafts before persistence" do
      oversized =
        valid_definition()
        |> Map.put(
          "context_markdown",
          String.duplicate("x", Definition.limit!(:max_context_markdown_bytes) + 1)
        )

      assert {:error, [%{path: "/context_markdown"}]} = Definition.validate_draft(oversized)

      unsupported = Map.put(valid_definition(), "schema_version", 2)

      assert {:error, [%{code: "unsupported_schema_version"}]} =
               Definition.validate_draft(unsupported)
    end

    test "rejects noncanonical nested shapes even when they fit the byte budget" do
      malformed = Map.put(valid_definition(), "stages", [%{"steps" => "not-a-list"}])

      assert {:error, [%{message: "Draft must use the canonical runbook object structure."}]} =
               Definition.validate_draft(malformed)
    end
  end

  test "schema and runtime limits have one machine-readable owner" do
    assert Definition.schema()["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert Definition.limit!(:max_steps) == 32
    assert Definition.limit!(:default_stage_parallelism) == 5
  end

  defp valid_definition do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect before changing anything.",
      "inputs" => [input("host")],
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "sequential",
          "steps" => [
            %{
              "id" => "observe",
              "pack" => %{"id" => "linux-core"},
              "action" => "linux.uptime",
              "targets" => %{"refs" => ["group:edge"]},
              "args" => %{"host" => %{"source" => "input", "ref" => "host"}},
              "outputs" => [output("ready")],
              "success" => [%{"output" => "ready", "operator" => "equals", "value" => true}],
              "wait" => nil
            }
          ]
        }
      ]
    }
  end

  defp input(id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "description" => "A typed input",
        "type" => "string",
        "required" => true,
        "sensitive" => false
      },
      extra
    )
  end

  defp output(id, extract \\ %{"type" => "contains", "expression" => "ready"}) do
    %{
      "id" => id,
      "source" => "stdout",
      "sensitive" => false,
      "extract" => extract
    }
  end
end
