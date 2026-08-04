defmodule EmisarWeb.RunbookDraftTest do
  use ExUnit.Case, async: true
  alias Emisar.{Fixtures, Runbooks}
  alias EmisarWeb.{RunbookDraft, RunbookEditorCatalog}

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
                "selection" => "all",
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

    assert {:ok, ^definition} = Runbooks.validate_definition(definition)

    rebuilt =
      definition
      |> RunbookDraft.from_definition()
      |> RunbookDraft.command()
      |> Runbooks.Authoring.build_v1()

    assert rebuilt == definition
  end

  test "a loaded argument binding is descriptor-resynchronized without double-quoting a literal" do
    definition = %{
      "schema_version" => 1,
      "context_markdown" => "",
      "inputs" => [],
      "stages" => [
        %{
          "id" => "stage",
          "title" => "Run actions",
          "mode" => "sequential",
          "steps" => [
            %{
              "id" => "step",
              "pack" => %{"id" => "linux-core"},
              "action" => "linux.tail",
              "targets" => %{"selection" => "all", "refs" => ["group:default"]},
              "args" => %{"path" => %{"source" => "literal", "value" => "/var/log/syslog"}},
              "outputs" => [],
              "success" => [],
              "wait" => nil
            }
          ]
        }
      ]
    }

    draft = RunbookDraft.from_definition(definition)
    step = get_in(draft, ["stages", Access.at(0), "steps", Access.at(0)])
    loaded = hd(step["args"])

    assert loaded["value"] == ~s("/var/log/syslog")
    assert loaded["required"] == ""
    assert loaded["sensitive"] == ""

    catalog =
      Fixtures.Runbooks.build_editor_projection(
        [%{group: "default"}],
        [
          %{
            pack_id: "linux-core",
            action_id: "linux.tail",
            descriptor: %{
              "title" => "Tail",
              "risk" => "low",
              "args_schema" => %{
                "args" => [
                  %{"name" => "path", "type" => "path", "required" => true, "sensitive" => false}
                ]
              }
            }
          }
        ]
      )

    synced = hd(RunbookEditorCatalog.sync_step(step, step, catalog)["args"])

    assert synced == %{
             "name" => "path",
             "type" => "path",
             "required" => "true",
             "sensitive" => "false",
             "source" => "literal",
             "value" => "/var/log/syslog",
             "ref" => ""
           }
  end

  test "a composite scalar reaches the typed command as compact JSON text" do
    input = %{RunbookDraft.input() | "id" => "count", "default" => %{"a" => [1]}}
    success = %{RunbookDraft.success() | "output" => "lag", "value" => [1, 2]}

    draft =
      RunbookDraft.new()
      |> Map.put("inputs", [input])
      |> put_in(["stages", Access.at(0), "steps", Access.at(0), "success"], [success])

    command = RunbookDraft.command(draft)

    assert [%{id: "count", default: ~s({"a":[1]})}] = command.inputs
    assert [%{output: "lag", value: "[1,2]"}] = hd(hd(command.stages).steps).success

    definition = Runbooks.Authoring.build_v1(command)

    assert get_in(definition, ["inputs", Access.at(0), "default"]) == ~s({"a":[1]})
  end

  test "a malformed browser row falls back to its bounded default shape" do
    command = RunbookDraft.command(%{RunbookDraft.new() | "inputs" => ["not-a-row"]})

    assert [%{id: "", type: "string", default: ""}] = command.inputs
  end

  test "fingerprint tracks persisted semantics and ignores map insertion order" do
    draft = RunbookDraft.new()
    reordered = Map.new(Enum.reverse(Map.to_list(draft)))

    assert RunbookDraft.fingerprint(draft) == RunbookDraft.fingerprint(reordered)

    changed = put_in(draft, ["stages", Access.at(0), "title"], "Different")
    refute RunbookDraft.fingerprint(draft) == RunbookDraft.fingerprint(changed)
  end
end
