defmodule EmisarWeb.RunStatusesTest do
  use ExUnit.Case, async: true
  alias Emisar.Runs
  alias EmisarWeb.RunStatuses

  describe "all/0" do
    test "returns the ordered {label, meaning} pairs, first and last pinned, at the exact count" do
      pairs = RunStatuses.all()

      assert List.first(pairs) ==
               {"Pending",
                "Created and queued. Waiting to be handed to its runner — or waiting for an offline runner to reconnect."}

      assert List.last(pairs) ==
               {"Cancelled",
                "You, or a denied approval, pulled the run back. The reason is recorded."}

      assert length(pairs) == 14
    end
  end

  describe "label/1" do
    test "returns the operator-facing label for a known status" do
      assert RunStatuses.label(:failed) == "Failed"
    end

    test "every ActionRun :status enum value maps to a non-empty label" do
      for status <- Ecto.Enum.values(Runs.ActionRun, :status) do
        label = RunStatuses.label(status)
        assert is_binary(label)
        assert label != ""
      end
    end

    test "raises KeyError on an unknown status" do
      assert_raise KeyError, fn -> RunStatuses.label(:nonexistent) end
    end
  end

  describe "meaning/1" do
    test "returns the one-line meaning for a known status" do
      assert RunStatuses.meaning(:failed) == "The action ran and exited non-zero."
    end

    test "every ActionRun :status enum value maps to a non-empty meaning" do
      for status <- Ecto.Enum.values(Runs.ActionRun, :status) do
        meaning = RunStatuses.meaning(status)
        assert is_binary(meaning)
        assert meaning != ""
      end
    end

    test "raises KeyError on an unknown status" do
      assert_raise KeyError, fn -> RunStatuses.meaning(:nonexistent) end
    end
  end
end
