defmodule Emisar.Catalog.CommandPreviewCorpusTest do
  @moduledoc """
  The approval-page command renderer against the corpus the runner's renderer
  reads too. `CommandPreview` is a hand port of `expressions.RenderArgv` +
  `engine.redactedInvocation`: the operator approves the line this module
  renders, and the runner executes the line that module renders. Each side had
  only ever been tested on its own; `dev/command-corpus/cases.json` is the one
  set of inputs and outputs both must agree on, and
  `runner/internal/engine/command_corpus_test.go` is the other half.
  """
  use ExUnit.Case, async: true
  alias Emisar.Catalog.CommandPreview
  alias Emisar.Catalog.PublishedRegistry.Action
  alias Emisar.RawJSON

  @corpus Path.expand("../../../../../../dev/command-corpus/cases.json", __DIR__)

  test "every shared case renders the runner's exact command line" do
    cases = @corpus |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
    assert cases != []

    for %{"name" => name, "why" => why} = case <- cases do
      action = %Action{
        id: "pack.action",
        title: "Action",
        kind: "exec",
        risk: "low",
        command: %{binary: case["binary"], argv: case["argv"]},
        args: case["specs"]
      }

      # Decode the arguments the way the dispatch path does: exact number
      # tokens survive, never a re-spelled float.
      {:ok, args} = RawJSON.decode_object(case["args"])

      assert CommandPreview.render(action, args) == {:ok, case["want"]},
             "#{name}: #{why}"
    end
  end
end
