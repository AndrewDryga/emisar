defmodule EmisarWeb.MCP.RunbookContractTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks
  alias EmisarWeb.MCP.RunbookContract

  describe "project/1" do
    test "keeps metadata separate and projects the canonical definition losslessly" do
      definition = valid_definition()

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        version: 3,
        title: "Inspect fleet",
        description: "Confirm the fleet is ready.",
        definition: definition
      }

      assert {:ok, projection} = RunbookContract.project(runbook)

      assert projection == %{
               runbook_ref: "inspect-fleet@3",
               title: "Inspect fleet",
               description: "Confirm the fleet is ready.",
               definition: definition,
               summary: %{input_count: 1, stage_count: 1, step_count: 1}
             }
    end

    test "preserves nullable description" do
      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        version: 1,
        title: "Inspect fleet",
        description: nil,
        definition: valid_definition()
      }

      assert {:ok, %{description: nil}} = RunbookContract.project(runbook)
    end

    test "fails closed when the stored definition is not canonical" do
      runbook = %Runbooks.Runbook{
        slug: "legacy",
        version: 1,
        title: "Legacy",
        definition: %{"steps" => []}
      }

      assert RunbookContract.project(runbook) == {:error, :incomplete_contract}
    end
  end

  defp valid_definition do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect before changing anything.",
      "inputs" => [
        %{
          "id" => "host",
          "description" => "Host to inspect",
          "type" => "string",
          "required" => true,
          "sensitive" => false
        }
      ],
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
              "outputs" => [],
              "success" => [],
              "wait" => nil
            }
          ]
        }
      ]
    }
  end
end
