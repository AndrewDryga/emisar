defmodule EmisarWeb.RunStatuses do
  @moduledoc "The single source of the one-line operator meaning for each run status — consumed by the console status tooltip and the /docs/runs status table."

  # Ordered `status_atom => {label, meaning}`, row-for-row with the /docs/runs
  # status table. The atoms are the `Emisar.Runs.ActionRun` `:status` enum values;
  # `meaning/1` raises on any status not listed here, so a new enum value can't
  # silently render a blank tooltip.
  @statuses [
    pending:
      {"Pending",
       "Queued for the runner. If the runner is offline, the run waits for it to reconnect."},
    pending_approval:
      {"Pending approval",
       "Waiting for manual approval required by policy. If approval is denied or expires, the run is cancelled."},
    sent: {"Sent", "Sent to the runner; waiting for it to acknowledge the action."},
    running: {"Running", "The runner is executing the action. Output appears as it arrives."},
    cancelling:
      {"Cancelling",
       "Cancellation was requested. Waiting for the runner to confirm whether the action stopped."},
    success:
      {"Success",
       "The runner reported success. Any required structured output passed validation."},
    failed: {"Failed", "The action ran and exited non-zero."},
    error:
      {"Error",
       "The run couldn't complete or its final result wasn't received. Check the recorded error."},
    timed_out: {"Timed out", "The action ran past its time limit and the runner stopped it."},
    validation_failed:
      {"Validation failed", "The action's structured output didn't match its required format."},
    unknown_action: {"Unknown action", "The runner doesn't have this action installed."},
    refused:
      {"Refused",
       "The runner rejected the action during its trust or security checks. The action didn't run."},
    denied:
      {"Denied",
       "Policy blocked the action before it reached the runner. Check the matching rule and reason."},
    cancelled:
      {"Cancelled",
       "The run was cancelled before it started or stopped by the runner. Check the recorded reason."}
  ]

  @doc "The ordered `{label, meaning}` pairs, in /docs/runs status-table order."
  def all, do: Keyword.values(@statuses)

  @doc "The ordered `{status_atom, {label, meaning}}` entries — the /docs/runs table renders the console's own status badge from the atom."
  def entries, do: @statuses

  @doc "The operator-facing label for a run `status` atom; raises `KeyError` on an unknown status so drift is loud."
  def label(status), do: @statuses |> Keyword.fetch!(status) |> elem(0)

  @doc "The one-line operator meaning for a run `status` atom; raises `KeyError` on an unknown status so drift is loud."
  def meaning(status), do: @statuses |> Keyword.fetch!(status) |> elem(1)
end
