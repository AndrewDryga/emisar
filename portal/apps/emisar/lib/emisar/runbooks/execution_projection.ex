defmodule Emisar.Runbooks.ExecutionProjection do
  @moduledoc """
  Deterministic, redaction-safe facts for one already-authorized execution result.

  `Runbooks.fetch_execution_result/2` did the fetch and both authorization
  gates, so this module is pure: it orders stages and items, pairs each item
  with its latest attempt, resolves the status an item inherits from its stage
  or execution, and states the one blocking cause.

  Value safety is decided here, once. An output is public only where exactly one
  declaration claims that id and marks it `sensitive: false`; a missing,
  duplicated, or malformed declaration reads as sensitive. Every other value —
  and the expected value of a condition reading it — is redacted before a
  console or MCP caller can render, hash, or size it. Stored evidence
  contributes status only; its recorded actual and expected values are never
  carried forward.
  """
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, RunbookExecution}
  alias Emisar.Runs

  @redacted "[REDACTED]"
  @waitable_statuses [:pending_approval, :active]
  @terminal_statuses [:succeeded, :halted, :cancelled]

  defstruct [:execution, stages: []]

  @type blocking :: %{
          code: String.t(),
          message: String.t(),
          stage_id: String.t() | nil,
          step_id: String.t() | nil,
          runner_ref: String.t() | nil
        }

  @type execution :: %{
          status: atom(),
          waitable?: boolean(),
          terminal?: boolean(),
          blocking: blocking() | nil
        }

  @type output :: %{
          output_id: String.t() | nil,
          source: String.t() | nil,
          sensitive: boolean(),
          status: String.t(),
          value: term()
        }

  @type condition :: %{
          output: String.t() | nil,
          operator: String.t() | nil,
          sensitive: boolean(),
          expected: term(),
          status: String.t()
        }

  @type evidence :: %{
          kind: String.t() | nil,
          output: String.t() | nil,
          operator: String.t() | nil,
          status: String.t()
        }

  @type item :: %{
          id: String.t(),
          step_id: String.t(),
          runner_ref: String.t(),
          target_selection: atom(),
          target_group: String.t() | nil,
          action_id: String.t(),
          pack_ref: String.t(),
          pack_hash: String.t(),
          risk: String.t() | nil,
          status: atom(),
          attempt_count: non_neg_integer(),
          wait: map() | nil,
          wait_started_at: DateTime.t() | nil,
          next_attempt_at: DateTime.t() | nil,
          terminal_code: String.t() | nil,
          terminal_message: String.t() | nil,
          outputs: [output()],
          output_count: non_neg_integer(),
          conditions: [condition()],
          condition_count: non_neg_integer(),
          evidence: [evidence()],
          latest_attempt: Runs.ActionRun.t() | nil
        }

  @type stage :: %{
          stage_id: String.t(),
          title: String.t(),
          position: non_neg_integer(),
          mode: atom(),
          max_parallel: pos_integer() | nil,
          status: atom(),
          items: [item()]
        }

  @type t :: %__MODULE__{execution: execution(), stages: [stage()]}

  @doc "Projects one authorized execution result into ordered, redaction-safe facts."
  @spec build(map()) :: t()
  def build(%{execution: %RunbookExecution{} = execution, latest_attempts: latest_attempts}) do
    attempts = Map.new(latest_attempts, &{&1.runbook_execution_item_id, &1})
    stages = Enum.sort_by(execution.stages, & &1.position)
    items = Enum.sort_by(execution.items, &{&1.stage_position, &1.step_position, &1.runner_ref})
    items_by_stage = Enum.group_by(items, & &1.runbook_execution_stage_id)

    %__MODULE__{
      execution: execution_facts(execution, stages, items),
      stages:
        Enum.map(stages, fn stage ->
          stage_facts(stage, Map.get(items_by_stage, stage.id, []), execution, attempts)
        end)
    }
  end

  defp execution_facts(%RunbookExecution{} = execution, stages, items) do
    %{
      status: execution.status,
      waitable?: execution.status in @waitable_statuses,
      terminal?: execution.status in @terminal_statuses,
      blocking: blocking(execution, stages, items)
    }
  end

  # Precedence follows what actually stopped the run: the recorded terminal
  # cause first, then a held approval, then the one item still observing. Every
  # branch judges persisted statuses, so an inherited status never invents a
  # second cause for the same halt.
  defp blocking(%RunbookExecution{terminal_code: code} = execution, stages, items)
       when is_binary(code) do
    stage = Enum.find(stages, &(&1.status in [:halted, :cancelled]))
    item = Enum.find(items, &(&1.status in [:failed, :cancelled]))

    terminal_blocking(item, execution, stage)
  end

  defp blocking(%RunbookExecution{status: :pending_approval}, _stages, _items) do
    %{
      code: "approval_required",
      message: "Runbook execution approval is required.",
      stage_id: nil,
      step_id: nil,
      runner_ref: nil
    }
  end

  defp blocking(%RunbookExecution{}, stages, items) do
    case Enum.find(items, &(&1.status == :waiting)) do
      nil ->
        nil

      %ExecutionItem{} = item ->
        %{
          code: "waiting",
          message: "A success condition is waiting for another observation.",
          stage_id: item_stage_id(stages, item),
          step_id: item.step_id,
          runner_ref: item.runner_ref
        }
    end
  end

  defp terminal_blocking(nil, %RunbookExecution{} = execution, stage) do
    %{
      code: execution.terminal_code,
      message: execution.terminal_message || "Execution halted.",
      stage_id: stage_id(stage),
      step_id: nil,
      runner_ref: nil
    }
  end

  defp terminal_blocking(%ExecutionItem{} = item, _execution, stage) do
    %{
      code: item.terminal_code || "action_failed",
      message: item.terminal_message || "A runbook item did not succeed.",
      stage_id: stage_id(stage),
      step_id: item.step_id,
      runner_ref: item.runner_ref
    }
  end

  defp item_stage_id(stages, %ExecutionItem{} = item) do
    stages |> Enum.find(&(&1.id == item.runbook_execution_stage_id)) |> stage_id()
  end

  defp stage_id(nil), do: nil
  defp stage_id(%ExecutionStage{} = stage), do: stage.stage_id

  defp stage_facts(%ExecutionStage{} = stage, items, %RunbookExecution{} = execution, attempts) do
    %{
      stage_id: stage.stage_id,
      title: stage.title,
      position: stage.position,
      mode: stage.mode,
      max_parallel: stage.max_parallel,
      status: stage.status,
      items: Enum.map(items, &item_facts(&1, stage, execution, attempts))
    }
  end

  defp item_facts(
         %ExecutionItem{} = item,
         %ExecutionStage{} = stage,
         %RunbookExecution{} = execution,
         attempts
       ) do
    public_ids = public_output_ids(item.output_plan)

    %{
      id: item.id,
      step_id: item.step_id,
      runner_ref: item.runner_ref,
      target_selection: item.target_selection,
      target_group: item.target_group,
      action_id: item.action_id,
      pack_ref: item.pack_ref,
      pack_hash: item.pack_hash,
      risk: item.risk,
      status: effective_status(item, stage, execution),
      attempt_count: item.attempt_count,
      wait: item.wait,
      wait_started_at: item.wait_started_at,
      next_attempt_at: item.next_attempt_at,
      terminal_code: item.terminal_code,
      terminal_message: item.terminal_message,
      outputs: output_facts(item, public_ids),
      output_count: length(item.output_plan),
      conditions: condition_facts(item, public_ids),
      condition_count: length(item.success_plan),
      evidence: evidence_facts(item),
      latest_attempt: Map.get(attempts, item.id)
    }
  end

  # A pending item inherits its scope's outcome, halt before cancellation: what
  # the operator must act on is the halt, even where a cancellation followed it.
  defp effective_status(
         %ExecutionItem{status: :pending},
         %ExecutionStage{status: :halted},
         _exec
       ),
       do: :halted

  defp effective_status(%ExecutionItem{status: :pending}, _stage, %RunbookExecution{
         status: :halted
       }),
       do: :halted

  defp effective_status(
         %ExecutionItem{status: :pending},
         %ExecutionStage{status: :cancelled},
         _exec
       ),
       do: :cancelled

  defp effective_status(%ExecutionItem{status: :pending}, _stage, %RunbookExecution{
         status: :cancelled
       }),
       do: :cancelled

  defp effective_status(%ExecutionItem{status: :pending}, _stage, _execution), do: :queued

  # A halt (e.g. a denied approval) marks undispatched items failed with zero
  # attempts. The operator's question is exactly "did anything execute?", so say
  # what happened: it did not run.
  defp effective_status(%ExecutionItem{status: :failed, attempt_count: 0}, _stage, _execution),
    do: :not_run

  defp effective_status(%ExecutionItem{status: status}, _stage, _execution), do: status

  # An id is public only where exactly one declaration claims it and says so
  # with a real boolean; a duplicated, conflicting, or malformed declaration
  # cannot prove a value is safe to show.
  defp public_output_ids(output_plan) do
    output_plan
    |> Enum.group_by(&Map.get(&1, "id"))
    |> Enum.filter(&declared_public?/1)
    |> MapSet.new(&elem(&1, 0))
  end

  defp declared_public?({id, [declaration]}) when is_binary(id),
    do: Map.get(declaration, "sensitive") === false

  defp declared_public?({_id, _declarations}), do: false

  defp output_facts(%ExecutionItem{} = item, public_ids) do
    statuses = extraction_statuses(item.success_evidence)

    Enum.map(item.output_plan, fn declaration ->
      id = declaration["id"]
      public? = MapSet.member?(public_ids, id)

      %{
        output_id: id,
        source: declaration["source"],
        sensitive: not public?,
        status: Map.get(statuses, id) || "pending",
        value: output_value(item.outputs, id, public?)
      }
    end)
  end

  defp extraction_statuses(evidence) do
    for %{"kind" => "extraction"} = row <- evidence, into: %{}, do: {row["output"], row["status"]}
  end

  defp output_value(outputs, id, true), do: Map.get(outputs, id)
  defp output_value(_outputs, _id, false), do: @redacted

  defp condition_facts(%ExecutionItem{} = item, public_ids) do
    rows = Enum.filter(item.success_evidence, &(&1["kind"] == "condition"))

    item.success_plan
    |> Enum.with_index()
    |> Enum.map(fn {condition, index} ->
      public? = MapSet.member?(public_ids, condition["output"])
      row = Enum.at(rows, index, %{})

      %{
        output: condition["output"],
        operator: condition["operator"],
        sensitive: not public?,
        expected: expected_value(condition, public?),
        status: row["status"] || "pending"
      }
    end)
  end

  defp expected_value(condition, true), do: condition["value"]
  defp expected_value(_condition, false), do: @redacted

  defp evidence_facts(%ExecutionItem{} = item) do
    Enum.map(item.success_evidence, fn row ->
      %{
        kind: row["kind"],
        output: row["output"],
        operator: row["operator"],
        status: evidence_status(row, item.status)
      }
    end)
  end

  # A condition that has not passed while the item is still observing has not
  # failed — the next observation may still meet it.
  defp evidence_status(%{"kind" => "condition", "status" => "failed"}, :waiting), do: "not met"

  defp evidence_status(%{"status" => status}, _item_status) when is_binary(status), do: status

  defp evidence_status(_row, _item_status), do: "pending"
end
