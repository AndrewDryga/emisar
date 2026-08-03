defmodule Emisar.Runbooks.AuthoringTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.{Authoring, Definition}

  describe "build_v1/1" do
    test "builds one canonical definition covering every strict v1 authoring feature" do
      command =
        command(
          context_markdown: "## Before you run\n\nConfirm the incident.",
          inputs: [
            input(%{
              id: "environment",
              description: "Deployment environment",
              type: "enum",
              enum_values: [
                %{value: "staging", default?: false},
                %{value: "production", default?: true}
              ]
            }),
            input(%{
              id: "threshold",
              description: "Maximum lag",
              type: "number",
              required?: false,
              default: "2.5",
              minimum: "0",
              maximum: "30"
            })
          ],
          stages: [
            stage(%{
              id: "inspect",
              title: "Inspect replicas",
              mode: "parallel",
              max_parallel: "4",
              steps: [
                step(%{
                  id: "inspect_replica",
                  pack_id: "postgres",
                  action: "postgres.replication.inspect",
                  target_refs: ["group:postgres"],
                  args: [
                    argument(%{name: "environment", source: "input", ref: "environment"}),
                    argument(%{
                      name: "verbose",
                      type: "boolean",
                      source: "literal",
                      value: "true"
                    }),
                    argument(%{name: "dropped", source: "omit", value: "ignored"})
                  ],
                  outputs: [
                    output(%{id: "lag", expression: "/lag_seconds"}),
                    output(%{
                      id: "leader",
                      source: "stdout",
                      extract_type: "regex",
                      expression: "leader=([a-z0-9-]+)",
                      capture: "1"
                    })
                  ],
                  success: [
                    %{output: "lag", operator: "less_than", value: "2.5"},
                    %{output: "leader", operator: "matches", value: ~s("^[a-z]")}
                  ],
                  wait: %{
                    enabled?: true,
                    interval_seconds: "10",
                    timeout_seconds: "120",
                    max_attempts: "12"
                  }
                })
              ]
            }),
            stage(%{
              id: "confirm",
              title: "Confirm recovery",
              steps: [
                step(%{
                  id: "confirm_leader",
                  pack_id: "postgres",
                  action: "postgres.primary.confirm",
                  target_refs: ["runner:db-1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
                  args: [
                    argument(%{
                      name: "expected",
                      source: "output",
                      ref: "inspect_replica.leader"
                    })
                  ]
                })
              ]
            })
          ]
        )

      definition = Authoring.build_v1(command)

      assert definition == %{
               "schema_version" => 1,
               "context_markdown" => "## Before you run\n\nConfirm the incident.",
               "inputs" => [
                 %{
                   "id" => "environment",
                   "description" => "Deployment environment",
                   "type" => "enum",
                   "required" => true,
                   "sensitive" => false,
                   "enum" => ["staging", "production"],
                   "default" => "production"
                 },
                 %{
                   "id" => "threshold",
                   "description" => "Maximum lag",
                   "type" => "number",
                   "required" => false,
                   "sensitive" => false,
                   "default" => 2.5,
                   "minimum" => 0.0,
                   "maximum" => 30.0
                 }
               ],
               "stages" => [
                 %{
                   "id" => "inspect",
                   "title" => "Inspect replicas",
                   "mode" => "parallel",
                   "max_parallel" => 4,
                   "steps" => [
                     %{
                       "id" => "inspect_replica",
                       "pack" => %{"id" => "postgres"},
                       "action" => "postgres.replication.inspect",
                       "targets" => %{"selection" => "all", "refs" => ["group:postgres"]},
                       "args" => %{
                         "environment" => %{"source" => "input", "ref" => "environment"},
                         "verbose" => %{"source" => "literal", "value" => true}
                       },
                       "outputs" => [
                         %{
                           "id" => "lag",
                           "source" => "structured_output",
                           "sensitive" => false,
                           "extract" => %{
                             "type" => "json_pointer",
                             "expression" => "/lag_seconds"
                           }
                         },
                         %{
                           "id" => "leader",
                           "source" => "stdout",
                           "sensitive" => false,
                           "extract" => %{
                             "type" => "regex",
                             "expression" => "leader=([a-z0-9-]+)",
                             "capture" => "1"
                           }
                         }
                       ],
                       "success" => [
                         %{"output" => "lag", "operator" => "less_than", "value" => 2.5},
                         %{"output" => "leader", "operator" => "matches", "value" => "^[a-z]"}
                       ],
                       "wait" => %{
                         "interval_seconds" => 10,
                         "timeout_seconds" => 120,
                         "max_attempts" => 12
                       }
                     }
                   ]
                 },
                 %{
                   "id" => "confirm",
                   "title" => "Confirm recovery",
                   "mode" => "sequential",
                   "steps" => [
                     %{
                       "id" => "confirm_leader",
                       "pack" => %{"id" => "postgres"},
                       "action" => "postgres.primary.confirm",
                       "targets" => %{
                         "selection" => "all",
                         "refs" => ["runner:db-1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
                       },
                       "args" => %{
                         "expected" => %{
                           "source" => "output",
                           "ref" => "inspect_replica.leader"
                         }
                       },
                       "outputs" => [],
                       "success" => [],
                       "wait" => nil
                     }
                   ]
                 }
               ]
             }

      assert {:ok, ^definition} = Definition.validate(definition)
    end

    test "keeps an invalid typed default so the validator explains it at its exact path" do
      command =
        command(
          inputs: [
            input(%{
              id: "count",
              description: "Observations",
              type: "integer",
              default: "not-a-number"
            }),
            input(%{id: "ratio", description: "Lag ratio", type: "number", default: "1.2.3"}),
            input(%{id: "verbose", description: "Chatty", type: "boolean", default: "yes"})
          ],
          stages: [stage(%{steps: [step(%{})]})]
        )

      definition = Authoring.build_v1(command)

      assert get_in(definition, ["inputs", Access.at(0), "default"]) == "not-a-number"
      assert get_in(definition, ["inputs", Access.at(1), "default"]) == "1.2.3"
      assert get_in(definition, ["inputs", Access.at(2), "default"]) == "yes"

      assert {:error, issues} = Definition.validate(definition)
      paths = MapSet.new(issues, & &1.path)

      assert "/inputs/0/default" in paths
      assert "/inputs/1/default" in paths
      assert "/inputs/2/default" in paths
    end

    test "keeps malformed numeric and JSON tokens instead of dropping them" do
      command =
        command(
          inputs: [input(%{id: "label", description: "Label", min_length: "many"})],
          stages: [
            stage(%{
              mode: "parallel",
              max_parallel: "lots",
              steps: [
                step(%{
                  args: [argument(%{name: "payload", source: "literal", value: "{oops"})],
                  wait: %{
                    enabled?: true,
                    interval_seconds: "soon",
                    timeout_seconds: "120",
                    max_attempts: "12"
                  }
                })
              ]
            })
          ]
        )

      definition = Authoring.build_v1(command)
      step = get_in(definition, ["stages", Access.at(0), "steps", Access.at(0)])

      assert get_in(definition, ["inputs", Access.at(0), "min_length"]) == "many"
      assert get_in(definition, ["stages", Access.at(0), "max_parallel"]) == "lots"
      assert step["args"] == %{"payload" => %{"source" => "literal", "value" => "{oops"}}
      assert step["wait"]["interval_seconds"] == "soon"

      assert {:error, issues} = Definition.validate(definition)
      paths = MapSet.new(issues, & &1.path)

      assert "/inputs/0/min_length" in paths
      assert "/stages/0/max_parallel" in paths
      assert "/stages/0/steps/0/wait/interval_seconds" in paths
    end

    test "omits every default when an input is sensitive" do
      command =
        command(
          inputs: [
            input(%{id: "secret", type: "boolean", sensitive?: true, default: "true"}),
            input(%{
              id: "environment",
              type: "enum",
              sensitive?: true,
              enum_values: [
                %{value: "staging", default?: false},
                %{value: "production", default?: true}
              ]
            })
          ]
        )

      inputs = Authoring.build_v1(command)["inputs"]

      refute Map.has_key?(Enum.at(inputs, 0), "default")
      refute Map.has_key?(Enum.at(inputs, 1), "default")
      assert Enum.at(inputs, 1)["enum"] == ["staging", "production"]
    end

    test "drops a disabled wait and an unset extract capture" do
      command =
        command(
          stages: [
            stage(%{
              steps: [
                step(%{
                  outputs: [output(%{id: "lag", capture: "3"})],
                  success: [%{output: "lag", operator: "equals", value: ""}]
                })
              ]
            })
          ]
        )

      step = get_in(Authoring.build_v1(command), ["stages", Access.at(0), "steps", Access.at(0)])

      assert step["wait"] == nil

      assert step["outputs"] == [
               %{
                 "id" => "lag",
                 "source" => "structured_output",
                 "sensitive" => false,
                 "extract" => %{"type" => "json_pointer", "expression" => ""}
               }
             ]

      assert step["success"] == [%{"output" => "lag", "operator" => "equals"}]
    end
  end

  describe "sync_argument/2" do
    test "binds a required argument, omits an optional one, and routes a sensitive one" do
      required = Authoring.sync_argument(spec("path", type: "path", required: true), nil)
      optional = Authoring.sync_argument(spec("count", type: "integer"), nil)
      sensitive = Authoring.sync_argument(spec("token", required: true, sensitive: true), nil)

      assert required.source == "literal"
      assert required.required?
      assert optional.source == "omit"
      refute optional.required?
      assert sensitive.source == "input"
      assert sensitive.sensitive?
    end

    test "seeds a new binding from the descriptor default" do
      text = Authoring.sync_argument(spec("path", type: "path", default: "/var/lib"), nil)
      json = Authoring.sync_argument(spec("limits", required: true, default: %{"cpu" => 2}), nil)

      assert text.value == "/var/lib"
      assert json.value == ~s({"cpu":2})
    end

    test "moves a sensitive argument off a literal the operator had typed" do
      existing = %{
        name: "token",
        type: "string",
        required?: true,
        sensitive?: false,
        source: "literal",
        value: "hunter2",
        ref: "token"
      }

      synced = Authoring.sync_argument(spec("token", required: true, sensitive: true), existing)

      assert synced.source == "input"
      assert synced.ref == "token"
    end

    test "decodes a saved untyped literal back into the descriptor's text field" do
      existing = %{
        name: "path",
        type: "json",
        required?: false,
        sensitive?: false,
        source: "literal",
        value: ~s("/var/lib/postgresql"),
        ref: ""
      }

      synced = Authoring.sync_argument(spec("path", type: "path", required: true), existing)

      assert synced.type == "path"
      assert synced.required?
      assert synced.value == "/var/lib/postgresql"
    end
  end

  defp command(overrides),
    do: Map.merge(%{context_markdown: "", inputs: [], stages: []}, Map.new(overrides))

  defp input(overrides) do
    Map.merge(
      %{
        id: "value",
        description: "",
        type: "string",
        required?: true,
        sensitive?: false,
        default: "",
        enum_values: [],
        minimum: "",
        maximum: "",
        min_length: "",
        max_length: ""
      },
      overrides
    )
  end

  defp stage(overrides) do
    Map.merge(
      %{
        id: "stage",
        title: "Run actions",
        mode: "sequential",
        max_parallel: "5",
        steps: []
      },
      overrides
    )
  end

  defp step(overrides) do
    Map.merge(
      %{
        id: "step",
        pack_id: "linux-core",
        action: "linux.uptime",
        target_selection: "all",
        target_refs: ["group:default"],
        args: [],
        outputs: [],
        success: [],
        wait: %{
          enabled?: false,
          interval_seconds: "10",
          timeout_seconds: "120",
          max_attempts: "12"
        }
      },
      overrides
    )
  end

  defp argument(overrides) do
    Map.merge(
      %{
        name: "",
        type: "json",
        required?: false,
        sensitive?: false,
        source: "omit",
        value: "",
        ref: ""
      },
      overrides
    )
  end

  defp output(overrides) do
    Map.merge(
      %{
        id: "",
        source: "structured_output",
        sensitive?: false,
        extract_type: "json_pointer",
        expression: "",
        capture: "0"
      },
      overrides
    )
  end

  defp spec(name, overrides) do
    Enum.reduce(overrides, %{"name" => name}, fn {key, value}, spec ->
      Map.put(spec, Atom.to_string(key), value)
    end)
  end
end
