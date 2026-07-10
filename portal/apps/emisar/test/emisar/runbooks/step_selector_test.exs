defmodule Emisar.Runbooks.StepSelectorTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.StepSelector

  describe "parse/1" do
    test "the current list shape returns {kind, values}" do
      assert StepSelector.parse(%{"group" => ["a", "b"]}) == {"group", ["a", "b"]}
      assert StepSelector.parse(%{"runner_id" => ["r1", "r2"]}) == {"runner_id", ["r1", "r2"]}
    end

    test "the older single-value shape becomes a one-element list" do
      assert StepSelector.parse(%{"group" => "prod"}) == {"group", ["prod"]}
      assert StepSelector.parse(%{"runner_id" => "r1"}) == {"runner_id", ["r1"]}
    end

    test "blank and whitespace-only entries are dropped" do
      assert StepSelector.parse(%{"group" => ["a", "", "  ", "b"]}) == {"group", ["a", "b"]}
      assert StepSelector.parse(%{"group" => ""}) == {"group", []}
      assert StepSelector.parse(%{"group" => "  "}) == {"group", []}
      assert StepSelector.parse(%{"runner_id" => []}) == {"runner_id", []}
    end

    test "non-string entries in the list are dropped" do
      assert StepSelector.parse(%{"group" => ["a", nil, 7]}) == {"group", ["a"]}
    end

    test "a selector cannot mix runner ids and groups" do
      selector = %{"runner_id" => ["r1"], "group" => ["prod"]}

      assert StepSelector.parse(selector) == {nil, []}
      assert StepSelector.empty?(selector)
    end

    test "an unrecognized, absent, or nil selector is {nil, []}" do
      assert StepSelector.parse(%{}) == {nil, []}
      assert StepSelector.parse(nil) == {nil, []}
      assert StepSelector.parse(%{"other" => ["x"]}) == {nil, []}
      assert StepSelector.parse("garbage") == {nil, []}
    end
  end

  describe "empty?/1" do
    test "true when there is no recognized kind" do
      assert StepSelector.empty?(%{})
      assert StepSelector.empty?(nil)
      assert StepSelector.empty?(%{"other" => ["x"]})
    end

    test "true when the kind is present but every value is blank" do
      assert StepSelector.empty?(%{"group" => []})
      assert StepSelector.empty?(%{"group" => ""})
      assert StepSelector.empty?(%{"group" => "  "})
      assert StepSelector.empty?(%{"runner_id" => ["", "  "]})
    end

    test "false when at least one non-blank value is present" do
      refute StepSelector.empty?(%{"group" => ["a"]})
      refute StepSelector.empty?(%{"group" => "prod"})
      refute StepSelector.empty?(%{"runner_id" => ["", "r1"]})
    end
  end
end
