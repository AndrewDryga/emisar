defmodule Emisar.Runbooks.DefinitionDiffTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.DefinitionDiff

  describe "build/2" do
    test "returns no hunks when the two definitions are identical" do
      definition = definition()

      assert DefinitionDiff.build(definition, definition) == %DefinitionDiff{
               hunks: [],
               truncated?: false
             }
    end

    test "ignores key order, because identity is the canonical text" do
      reordered = %{
        "stages" => definition()["stages"],
        "inputs" => definition()["inputs"],
        "context_markdown" => definition()["context_markdown"],
        "schema_version" => definition()["schema_version"]
      }

      assert DefinitionDiff.build(definition(), reordered).hunks == []
    end

    test "pairs the removed line with its replacement and keeps surrounding context" do
      changed = put_in(definition(), ["context_markdown"], "Inspect the fleet twice.")

      assert %DefinitionDiff{hunks: [hunk], truncated?: false} =
               DefinitionDiff.build(definition(), changed)

      assert {:del, deleted} = Enum.find(hunk, &match?({:del, _line}, &1))
      assert {:ins, inserted} = Enum.find(hunk, &match?({:ins, _line}, &1))
      assert deleted =~ "Inspect before changing anything."
      assert inserted =~ "Inspect the fleet twice."

      # Context lines place the change inside its object rather than showing a
      # bare replaced pair.
      assert Enum.any?(hunk, &match?({:eq, _line}, &1))
    end

    test "splits distant changes into separate hunks and drops the unchanged span between" do
      changed =
        definition()
        |> put_in(["context_markdown"], "Changed at the top.")
        |> put_in(["stages", Access.at(0), "title"], "Changed at the bottom")

      assert %DefinitionDiff{hunks: [first, second]} =
               DefinitionDiff.build(definition(), changed)

      assert Enum.any?(first, &match?({:ins, _line}, &1))
      assert Enum.any?(second, &match?({:ins, _line}, &1))

      emitted = length(first) + length(second)

      total =
        definition() |> Emisar.CanonicalJSON.encode_pretty!() |> String.split("\n") |> length()

      assert emitted < total
    end

    test "caps a very large change and says the diff was cut" do
      wide = put_in(definition(), ["stages"], Enum.map(1..200, &stage("stage-#{&1}")))

      assert %DefinitionDiff{hunks: hunks, truncated?: true} =
               DefinitionDiff.build(definition(), wide)

      assert hunks != []
      assert hunks |> Enum.map(&length/1) |> Enum.sum() == 400
    end
  end

  defp definition do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect before changing anything.",
      "inputs" => [],
      "stages" => [stage("inspect")]
    }
  end

  defp stage(id) do
    %{
      "id" => id,
      "title" => "Inspect",
      "mode" => "sequential",
      "steps" => [
        %{
          "id" => "observe",
          "pack" => %{"id" => "linux-core"},
          "action" => "linux.uptime",
          "targets" => %{"selection" => "all", "refs" => ["group:edge"]},
          "args" => %{},
          "outputs" => [],
          "success" => [],
          "wait" => nil
        }
      ]
    }
  end
end
