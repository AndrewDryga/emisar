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

    test "accepts more than 32 steps within the shared safety envelope" do
      base_step = valid_definition() |> get_in(["stages", Access.at(0), "steps"]) |> hd()
      steps = Enum.map(1..40, &Map.put(base_step, "id", "observe_#{&1}"))
      definition = put_in(valid_definition(), ["stages", Access.at(0), "steps"], steps)

      assert byte_size(Jason.encode!(definition)) < Definition.limit!(:max_definition_bytes)
      assert {:ok, ^definition} = Definition.validate_draft(definition)
      assert {:ok, ^definition} = Definition.validate(definition)
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

    test "requires an explicit target selection mode" do
      definition =
        update_in(
          valid_definition(),
          ["stages", Access.at(0), "steps", Access.at(0), "targets"],
          &Map.delete(&1, "selection")
        )

      assert {:error, issues} = Definition.validate(definition)
      assert Enum.map(issues, & &1.path) == ["/stages/0/steps/0/targets/selection"]
    end

    test "one online runner accepts exactly one group and rejects every wider shape" do
      target_path = ["stages", Access.at(0), "steps", Access.at(0), "targets"]

      assert {:ok, _definition} =
               valid_definition()
               |> put_in(target_path, %{
                 "selection" => "random_one",
                 "refs" => ["group:edge"]
               })
               |> Definition.validate()

      for refs <- [
            ["runner:edge-1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
            ["group:edge", "group:database"]
          ] do
        assert {:error, issues} =
                 valid_definition()
                 |> put_in(target_path, %{"selection" => "random_one", "refs" => refs})
                 |> Definition.validate()

        assert Enum.any?(issues, &(&1.path == "/stages/0/steps/0/targets/refs"))
      end
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

    test "accepts JSON Pointer for every canonical source and text extractors for either stream" do
      extracts = [
        %{"type" => "json_pointer", "expression" => "/ready"},
        %{"type" => "contains", "expression" => "ready"},
        %{"type" => "grep", "expression" => "ready"},
        %{"type" => "regex", "expression" => "ready", "capture" => "0"}
      ]

      for source <- ~w(structured_output stdout stderr),
          extract <- extracts,
          source != "structured_output" or extract["type"] == "json_pointer" do
        definition =
          put_in(
            valid_definition(),
            ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
            [Map.put(output("ready", extract), "source", source)]
          )

        assert {:ok, ^definition} = Definition.validate(definition)
      end
    end

    test "rejects structured text extraction with an indexed actionable error" do
      for type <- ~w(contains grep regex) do
        extract = %{"type" => type, "expression" => "ready"}
        extract = if type == "regex", do: Map.put(extract, "capture", "0"), else: extract

        definition =
          put_in(
            valid_definition(),
            ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
            [Map.put(output("ready", extract), "source", "structured_output")]
          )

        assert {:error,
                [
                  %{
                    code: "invalid_definition",
                    path: "/stages/0/steps/0/outputs/0/extract/type",
                    message: "Structured output requires a JSON Pointer extractor."
                  }
                ]} = Definition.validate(definition)

        # An incomplete draft can be saved for repair, but cannot pass the
        # strict publication/execution contract above.
        assert {:ok, ^definition} = Definition.validate_draft(definition)
      end
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

  describe "digest/1" do
    test "is stable across object key order and changes with definition content" do
      definition = valid_definition()

      reordered =
        definition
        |> Enum.reverse()
        |> Map.new()
        |> update_in(["stages"], fn stages ->
          Enum.map(stages, &Map.new(Enum.reverse(&1)))
        end)

      digest = Definition.digest(definition)

      assert digest == Definition.digest(reordered)
      assert digest =~ ~r/^[0-9a-f]{64}$/

      refute digest ==
               definition
               |> Map.put("context_markdown", "Changed evidence instructions.")
               |> Definition.digest()
    end
  end

  describe "validate/1 schema refusals" do
    # JSON Schema reports every failed alternative of a union together, so a union here
    # blames fields that are fine for the alternative the author chose.
    test "the schema has no unions" do
      refute contains_union?(Definition.schema())
    end

    test "blame only the mistake" do
      step = "/stages/0/steps/0"
      wait = %{"interval_seconds" => 5, "timeout_seconds" => 60, "max_attempts" => 3}
      missing = "A required definition field is missing."
      unsupported = "This definition field is not supported."
      format = "Definition value has an invalid format."
      choices = "Definition value is not one of the supported choices."

      cases = [
        {%{"args" => %{"x" => %{"source" => "literal"}}}, [{"#{step}/args/x/value", missing}]},
        {%{"args" => %{"x" => %{"source" => "input"}}}, [{"#{step}/args/x/ref", missing}]},
        {%{"args" => %{"x" => %{"source" => "input", "ref" => "BAD REF"}}},
         [{"#{step}/args/x/ref", format}]},
        {%{"args" => %{"x" => %{"source" => "output", "ref" => "nodot"}}},
         [{"#{step}/args/x/ref", format}]},
        {%{"args" => %{"x" => %{"source" => "nope"}}}, [{"#{step}/args/x/source", choices}]},
        {%{"args" => %{"x" => %{"source" => "literal", "value" => 1, "ref" => "a"}}},
         [{"#{step}/args/x/ref", unsupported}]},
        {%{"args" => %{"x" => %{"source" => "input", "ref" => "host", "value" => 1}}},
         [{"#{step}/args/x/value", unsupported}]},
        {%{"outputs" => [output("o", %{"type" => "regex", "expression" => "a"})]},
         [{"#{step}/outputs/0/extract/capture", missing}]},
        {%{"outputs" => [output("o", %{"type" => "json_pointer"})]},
         [{"#{step}/outputs/0/extract/expression", missing}]},
        {%{
           "outputs" => [
             output("o", %{"type" => "contains", "expression" => "a", "capture" => "0"})
           ]
         }, [{"#{step}/outputs/0/extract/capture", unsupported}]},
        {%{"outputs" => [output("o", %{"type" => "nope", "expression" => "a"})]},
         [{"#{step}/outputs/0/extract/type", choices}]},
        {%{"wait" => %{wait | "interval_seconds" => 1}},
         [{"#{step}/wait/interval_seconds", "Definition number is below the allowed minimum."}]},
        {%{"wait" => "soon"}, [{"#{step}/wait", "Definition value has the wrong type."}]},
        {%{"wait" => Map.delete(wait, "max_attempts")}, [{"#{step}/wait/max_attempts", missing}]}
      ]

      for {changes, expected} <- cases do
        assert {:error, issues} = changes |> with_step() |> Definition.validate()
        assert Enum.map(issues, &{&1.path, &1.message}) == expected, inspect(changes)
      end
    end

    test "names the field that does not fit a stage or an input" do
      stage = hd(valid_definition()["stages"])

      assert {:error, [%{path: "/stages/0/max_parallel", message: "A required" <> _}]} =
               valid_definition()
               |> Map.put("stages", [%{stage | "mode" => "parallel"}])
               |> Definition.validate()

      assert {:error, [%{path: "/stages/0/max_parallel", message: "This definition field" <> _}]} =
               valid_definition()
               |> Map.put("stages", [Map.put(stage, "max_parallel", 2)])
               |> Definition.validate()

      assert {:error, [%{path: "/inputs/0/enum", message: "This definition field" <> _}]} =
               valid_definition()
               |> Map.put("inputs", [input("host", %{"enum" => ["a"]})])
               |> Definition.validate()
    end
  end

  test "schema and runtime limits have one machine-readable owner" do
    assert Definition.schema()["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    refute Map.has_key?(Definition.limits(), "max_steps")
    assert Definition.limit!(:default_stage_parallelism) == 5
  end

  defp contains_union?(%{} = schema) do
    Map.has_key?(schema, "oneOf") or Map.has_key?(schema, "anyOf") or
      Enum.any?(Map.values(schema), &contains_union?/1)
  end

  defp contains_union?(items) when is_list(items), do: Enum.any?(items, &contains_union?/1)
  defp contains_union?(_value), do: false

  defp with_step(changes) do
    update_in(
      valid_definition(),
      ["stages", Access.at(0), "steps", Access.at(0)],
      &Map.merge(&1, changes)
    )
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
              "targets" => %{"selection" => "all", "refs" => ["group:edge"]},
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
