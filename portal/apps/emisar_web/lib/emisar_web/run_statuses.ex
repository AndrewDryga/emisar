defmodule EmisarWeb.RunStatuses do
  @moduledoc "The single source of the one-line operator meaning for each run status — consumed by the console status tooltip and the /docs/runs status table."

  # Ordered `status_atom => {label, meaning}`, row-for-row with the /docs/runs
  # status table. The atoms are the `Emisar.Runs.ActionRun` `:status` enum values;
  # `meaning/1` raises on any status not listed here, so a new enum value can't
  # silently render a blank tooltip.
  @statuses [
    pending:
      {"Pending",
       "Created and queued. Waiting to be handed to its runner — or waiting for an offline runner to reconnect."},
    pending_approval:
      {"Pending approval",
       "Policy required a human approval. The run is held until an approver decides; a denial cancels it."},
    sent: {"Sent", "Handed to the runner over its connection, not yet acknowledged."},
    running:
      {"Running", "The runner acknowledged the dispatch and is executing. Output is streaming."},
    cancelling:
      {"Cancelling",
       "You asked to cancel an in-flight run. Waiting for the runner to stop and report its final outcome."},
    success:
      {"Success",
       "The action ran and the runner reported success. Any declared structured output validated."},
    failed: {"Failed", "The action ran and exited non-zero."},
    error:
      {"Error",
       "The run could not complete — its runner went offline, was disabled or removed, dropped mid-run, or never acknowledged the send before the dispatch timeout. The reason is on the run."},
    timed_out: {"Timed out", "The action ran past its time limit and the runner stopped it."},
    validation_failed:
      {"Validation failed",
       "The runner's structured output did not match the action's declared output schema."},
    unknown_action:
      {"Unknown action", "The runner reported it does not have the dispatched action."},
    refused:
      {"Refused",
       "The runner rejected the dispatch on a pre-execution trust check — a bad, missing, or stale signature, a pack-hash mismatch, or a local admission block. Nothing executed."},
    denied:
      {"Denied",
       "Policy rejected the dispatch at creation. The run was never sent to a runner; the matched rule and reason are recorded."},
    cancelled:
      {"Cancelled", "You, or a denied approval, pulled the run back. The reason is recorded."}
  ]

  @doc "The ordered `{label, meaning}` pairs, in /docs/runs status-table order."
  def all, do: Keyword.values(@statuses)

  @doc "The one-line operator meaning for a run `status` atom; raises `KeyError` on an unknown status so drift is loud."
  def meaning(status), do: @statuses |> Keyword.fetch!(status) |> elem(1)
end
