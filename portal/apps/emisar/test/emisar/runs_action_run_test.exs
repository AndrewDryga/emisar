defmodule Emisar.Runs.ActionRunTest do
  use ExUnit.Case, async: true
  alias Emisar.Runs.ActionRun

  describe "terminal?/1 (status transition matrix)" do
    @terminal [
      :success,
      :failed,
      :error,
      :validation_failed,
      :unknown_action,
      :cancelled,
      :timed_out,
      :refused,
      :denied
    ]
    @non_terminal [:pending, :pending_approval, :sent, :running]

    test "settled statuses are terminal (incl. :denied + :refused)" do
      for s <- @terminal do
        assert ActionRun.terminal?(s), "expected #{s} to be terminal"
      end
    end

    test "in-flight statuses are not terminal" do
      for s <- @non_terminal do
        refute ActionRun.terminal?(s), "expected #{s} to be non-terminal"
      end
    end

    test "the matrix classifies every status the schema defines" do
      defined = Ecto.Enum.values(ActionRun, :status)
      assert Enum.sort(@terminal ++ @non_terminal) == Enum.sort(defined)
    end

    test "garbage input returns false" do
      refute ActionRun.terminal?(nil)
      refute ActionRun.terminal?("nonsense")
    end
  end

  describe "create_changeset/2" do
    test "requires account_id, runner_id, request_id, action_id" do
      changeset = ActionRun.Changeset.create(%{})
      refute changeset.valid?
      errors = Keyword.keys(changeset.errors)
      assert :account_id in errors
      assert :runner_id in errors
      assert :request_id in errors
      assert :action_id in errors
    end

    test "rejects unknown source values" do
      changeset =
        ActionRun.Changeset.create(%{
          account_id: Ecto.UUID.generate(),
          runner_id: Ecto.UUID.generate(),
          request_id: "req_x",
          action_id: "linux.uptime",
          source: "wat"
        })

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:source]
    end
  end
end
