defmodule EmisarWeb.RunbookDraftTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.Definition
  alias EmisarWeb.RunbookDraft

  test "round-trips every strict v1 authoring feature without another representation" do
    definition = %{
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
          "minimum" => 0,
          "maximum" => 30
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
              "targets" => %{"refs" => ["group:postgres"]},
              "args" => %{
                "environment" => %{"source" => "input", "ref" => "environment"},
                "verbose" => %{"source" => "literal", "value" => true}
              },
              "outputs" => [
                %{
                  "id" => "lag",
                  "source" => "structured_output",
                  "sensitive" => false,
                  "extract" => %{"type" => "json_pointer", "expression" => "/lag_seconds"}
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
                "refs" => ["runner:db-1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
              },
              "args" => %{
                "expected" => %{"source" => "output", "ref" => "inspect_replica.leader"}
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
    assert definition |> RunbookDraft.from_definition() |> RunbookDraft.definition() == definition
  end

  test "keeps malformed typed values intact so the canonical validator can explain them" do
    draft =
      RunbookDraft.new()
      |> Map.put("inputs", [
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "count",
          "description" => "Number of observations",
          "type" => "integer",
          "default" => "not-a-number"
        })
      ])
      |> put_in(["stages", Access.at(0), "steps", Access.at(0)], %{
        RunbookDraft.step()
        | "id" => "inspect",
          "pack_id" => "linux-core",
          "action" => "linux.uptime",
          "target_refs" => ["group:default"]
      })

    definition = RunbookDraft.definition(draft)

    assert get_in(definition, ["inputs", Access.at(0), "default"]) == "not-a-number"
    assert {:error, issues} = Definition.validate(definition)
    assert Enum.any?(issues, &(&1.path == "/inputs/0/default"))
  end

  test "omits every default when an input is sensitive" do
    draft =
      RunbookDraft.new()
      |> Map.put("inputs", [
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "secret",
          "type" => "boolean",
          "sensitive" => "true",
          "default" => "true"
        }),
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "environment",
          "type" => "enum",
          "sensitive" => "true",
          "enum_values" => [
            RunbookDraft.enum_value("staging"),
            RunbookDraft.enum_value("production", true)
          ]
        })
      ])

    inputs = RunbookDraft.definition(draft)["inputs"]

    refute Map.has_key?(Enum.at(inputs, 0), "default")
    refute Map.has_key?(Enum.at(inputs, 1), "default")
  end

  test "descriptor-synced arguments produce typed bindings and omit disabled optional values" do
    required =
      RunbookDraft.sync_argument(
        %{"name" => "path", "type" => "path", "required" => true, "sensitive" => false},
        nil
      )

    optional =
      RunbookDraft.sync_argument(
        %{"name" => "count", "type" => "integer", "required" => false, "sensitive" => false},
        nil
      )

    sensitive =
      RunbookDraft.sync_argument(
        %{"name" => "token", "type" => "string", "required" => true, "sensitive" => true},
        nil
      )

    draft =
      RunbookDraft.new()
      |> put_in(
        ["stages", Access.at(0), "steps", Access.at(0), "args"],
        [
          %{required | "value" => "/var/lib/postgresql"},
          %{optional | "value" => "3"},
          %{sensitive | "ref" => "token"}
        ]
      )

    bindings =
      draft
      |> RunbookDraft.definition()
      |> get_in(["stages", Access.at(0), "steps", Access.at(0), "args"])

    assert bindings == %{
             "path" => %{"source" => "literal", "value" => "/var/lib/postgresql"},
             "token" => %{"source" => "input", "ref" => "token"}
           }
  end

  test "fingerprint tracks persisted semantics and ignores map insertion order" do
    draft = RunbookDraft.new()
    reordered = Map.new(Enum.reverse(Map.to_list(draft)))

    assert RunbookDraft.fingerprint(draft) == RunbookDraft.fingerprint(reordered)

    changed = put_in(draft, ["stages", Access.at(0), "title"], "Different")
    refute RunbookDraft.fingerprint(draft) == RunbookDraft.fingerprint(changed)
  end
end
