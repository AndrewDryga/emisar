defmodule Emisar.Runs.ActionRunTest do
  use ExUnit.Case, async: true
  alias Emisar.Runs.ActionRun

  defp create_attrs(attrs) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        request_id: "req_x",
        action_id: "linux.uptime",
        source: "operator"
      },
      attrs
    )
  end

  defp transition_run do
    %ActionRun{
      id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      runner_id: Ecto.UUID.generate(),
      request_id: "req_x",
      action_id: "linux.uptime",
      source: :operator,
      status: :running
    }
  end

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

    test "failure predicates classify every terminal non-success" do
      failures = @terminal -- [:success]

      assert Enum.sort(ActionRun.failure_statuses()) == Enum.sort(failures)
      assert Enum.all?(failures, &ActionRun.failure?/1)
      refute ActionRun.failure?(:success)
      refute ActionRun.failure?(:pending)
    end
  end

  describe "Query.filters/0" do
    test "offers every persisted status and source" do
      filters = ActionRun.Query.filters()

      status_values =
        filters
        |> Enum.find(&(&1.name == :status))
        |> Map.fetch!(:values)
        |> Enum.map(&elem(&1, 0))

      source_values =
        filters
        |> Enum.find(&(&1.name == :source))
        |> Map.fetch!(:values)
        |> Enum.map(&elem(&1, 0))

      expected_statuses =
        ActionRun |> Ecto.Enum.values(:status) |> Enum.map(&to_string/1) |> Enum.sort()

      expected_sources =
        ActionRun |> Ecto.Enum.values(:source) |> Enum.map(&to_string/1) |> Enum.sort()

      assert Enum.sort(status_values) == expected_statuses
      assert Enum.sort(source_values) == expected_sources
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
      changeset = ActionRun.Changeset.create(create_attrs(%{source: "wat"}))

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:source]
    end

    test "rejects an oversized operator reason before the DB string column does" do
      changeset = ActionRun.Changeset.create(create_attrs(%{reason: String.duplicate("x", 256)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :reason)
    end
  end

  describe "transition/3 size caps" do
    test "accepts normal runner result metadata" do
      changeset =
        ActionRun.Changeset.transition(transition_run(), :success, %{
          error_message: "exit status 1",
          executed_command: "uptime -p",
          event_id: "evt_123",
          stdout_sha256: String.duplicate("a", 64),
          stderr_sha256: String.duplicate("b", 64)
        })

      assert changeset.valid?
    end

    test "rejects oversized runner result text fields" do
      for field <- [:error_message, :executed_command] do
        changeset =
          ActionRun.Changeset.transition(transition_run(), :failed, %{
            field => String.duplicate("x", 16_385)
          })

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field)
      end
    end

    test "rejects oversized runner result string fields before the DB does" do
      for field <- [:reason_text, :event_id, :stdout_sha256, :stderr_sha256] do
        changeset =
          ActionRun.Changeset.transition(transition_run(), :failed, %{
            field => String.duplicate("x", 256)
          })

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field)
      end
    end
  end
end
