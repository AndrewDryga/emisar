defmodule Emisar.Runs.ActionRunTest do
  use ExUnit.Case, async: true

  alias Emisar.Runs.ActionRun

  describe "terminal?/1" do
    test "terminal statuses are terminal" do
      for s <- ~w(success failed error validation_failed unknown_action cancelled timed_out) do
        assert ActionRun.terminal?(s), "expected #{s} to be terminal"
      end
    end

    test "in-flight statuses are not terminal" do
      for s <- ~w(pending awaiting_approval sent running) do
        refute ActionRun.terminal?(s), "expected #{s} to be non-terminal"
      end
    end

    test "garbage input returns false" do
      refute ActionRun.terminal?(nil)
      refute ActionRun.terminal?("nonsense")
    end
  end

  describe "create_changeset/2" do
    test "requires account_id, runner_id, request_id, action_id" do
      cs = ActionRun.create_changeset(%ActionRun{}, %{})
      refute cs.valid?
      errors = Keyword.keys(cs.errors)
      assert :account_id in errors
      assert :runner_id in errors
      assert :request_id in errors
      assert :action_id in errors
    end

    test "rejects unknown source values" do
      cs =
        ActionRun.create_changeset(%ActionRun{}, %{
          account_id: Ecto.UUID.generate(),
          runner_id: Ecto.UUID.generate(),
          request_id: "req_x",
          action_id: "linux.uptime",
          source: "wat"
        })

      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:source]
    end
  end
end
