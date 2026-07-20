defmodule Emisar.Runs.ActionRunTest do
  use ExUnit.Case, async: true
  import Emisar.DataCase, only: [errors_on: 1]
  alias Emisar.Runs.ActionRun

  defp create_attrs(attrs) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        request_id: Emisar.Crypto.run_request_id(),
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
    @non_terminal [:pending, :pending_approval, :sent, :running, :cancelling]

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

    test "rejects a noncanonical request id" do
      changeset = ActionRun.Changeset.create(create_attrs(%{request_id: "req_x"}))

      refute changeset.valid?
      assert {"must be a canonical run request id", _} = changeset.errors[:request_id]
    end

    test "rejects an oversized operator reason before the DB string column does" do
      changeset = ActionRun.Changeset.create(create_attrs(%{reason: String.duplicate("x", 256)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :reason)
    end

    test "casts self-reported mcp_client_metadata" do
      metadata = %{"asset_tag" => "LT-4417"}
      changeset = ActionRun.Changeset.create(create_attrs(%{mcp_client_metadata: metadata}))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :mcp_client_metadata) == metadata
    end

    test "backstops an oversized mcp_client_metadata map" do
      huge = for i <- 1..500, into: %{}, do: {"k#{i}", String.duplicate("v", 100)}
      changeset = ActionRun.Changeset.create(create_attrs(%{mcp_client_metadata: huge}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :mcp_client_metadata)
    end

    test "requires a valid schema exactly when structured output is expected" do
      schema = %{"type" => "object"}

      valid =
        ActionRun.Changeset.create(
          create_attrs(%{
            structured_output_expected: true,
            output_schema_snapshot: schema
          })
        )

      assert valid.valid?

      assert Ecto.Changeset.get_field(valid, :output_schema_snapshot) == schema

      missing =
        ActionRun.Changeset.create(create_attrs(%{structured_output_expected: true}))

      refute missing.valid?
      assert {"is required for typed output", _} = missing.errors[:output_schema_snapshot]

      malformed =
        ActionRun.Changeset.create(
          create_attrs(%{
            structured_output_expected: true,
            output_schema_snapshot: %{"type" => "string"}
          })
        )

      refute malformed.valid?
      assert {"must be a valid output schema", _} = malformed.errors[:output_schema_snapshot]

      unexpected =
        ActionRun.Changeset.create(create_attrs(%{output_schema_snapshot: schema}))

      refute unexpected.valid?

      assert {"must be absent for untyped output", _} =
               unexpected.errors[:output_schema_snapshot]
    end

    test "accepts the canonical unsigned runner options envelope" do
      opts = %{
        "timeout" => 5_000_000_000,
        "max_stdout_bytes" => 65_536,
        "max_stderr_bytes" => 16_384
      }

      changeset = ActionRun.Changeset.create(create_attrs(%{opts: opts}))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :opts) == opts
    end

    test "rejects runner options the Go wire decoder cannot use" do
      invalid = [
        %{"timeout" => "5s"},
        %{"timeout" => 1.5},
        %{"timeout" => 0},
        %{"timeout" => -1},
        %{"timeout" => 9_223_372_036_854_775_808},
        %{"future" => 1},
        %{timeout: 1}
      ]

      for opts <- invalid do
        changeset = ActionRun.Changeset.create(create_attrs(%{opts: opts}))

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :opts)
      end
    end

    test "rejects nonempty runner options on an attested run" do
      attrs = %{
        attestation: %{"version" => "emisar-attestation-v4"},
        opts: %{"timeout" => 1}
      }

      changeset = ActionRun.Changeset.create(create_attrs(attrs))

      refute changeset.valid?
      assert {"must be empty for an attested run", _opts} = changeset.errors[:opts]
    end
  end

  describe "transition/3 size caps" do
    test "accepts normal runner result metadata" do
      changeset =
        ActionRun.Changeset.transition(transition_run(), :success, %{
          error_message: "exit status 1",
          executed_command: "uptime -p",
          event_id: "evt_123",
          local_audit_failed: true,
          emitted_stdout_sha256: String.duplicate("a", 64),
          emitted_stderr_sha256: String.duplicate("b", 64)
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :local_audit_failed)
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

    test "bounds executed commands by UTF-8 bytes" do
      exact = String.duplicate("x", 16_384)

      assert ActionRun.Changeset.transition(transition_run(), :success, %{executed_command: exact}).valid?

      oversized = String.duplicate("界", 5_462)

      changeset =
        ActionRun.Changeset.transition(transition_run(), :success, %{
          executed_command: oversized
        })

      refute changeset.valid?
      assert "is too large (max 16384 bytes)" in errors_on(changeset).executed_command
    end

    test "rejects oversized runner result string fields before the DB does" do
      for field <- [
            :reason_text,
            :event_id,
            :emitted_stdout_sha256,
            :emitted_stderr_sha256
          ] do
        changeset =
          ActionRun.Changeset.transition(transition_run(), :failed, %{
            field => String.duplicate("x", 256)
          })

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field)
      end
    end

    test "rejects negative byte/duration metadata from a hostile runner" do
      for field <- [:emitted_stdout_bytes, :emitted_stderr_bytes, :duration_ms] do
        changeset = ActionRun.Changeset.transition(transition_run(), :success, %{field => -1})

        refute changeset.valid?
        assert {"must be greater than or equal to %{number}", _} = changeset.errors[field]
      end
    end

    test "rejects runner result numbers outside their database column ranges" do
      overflows = [
        exit_code: 2_147_483_648,
        duration_ms: 2_147_483_648,
        emitted_stdout_bytes: 9_223_372_036_854_775_808,
        emitted_stderr_bytes: 9_223_372_036_854_775_808
      ]

      for {field, value} <- overflows do
        changeset = ActionRun.Changeset.transition(transition_run(), :success, %{field => value})

        refute changeset.valid?
        assert {"must be less than or equal to %{number}", _} = changeset.errors[field]
      end

      changeset =
        ActionRun.Changeset.transition(transition_run(), :failed, %{
          exit_code: -2_147_483_649
        })

      refute changeset.valid?
      assert {"must be greater than or equal to %{number}", _} = changeset.errors[:exit_code]
    end
  end
end
