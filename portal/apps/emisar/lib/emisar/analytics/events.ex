defmodule Emisar.Analytics.Events do
  @moduledoc """
  Per-event product-analytics builders for domain milestones — the
  Mixpanel counterpart to `Emisar.Audit.Events` and `Emisar.Telemetry`.
  Each takes the domain struct(s), derives the `distinct_id` (the acting
  user when there is one, else an `account:<id>` handle so account-level
  usage stays queryable without a person), builds a flat property map,
  and fires through `Emisar.Analytics`.

  Called from a context's **post-commit** seam (an `after_commit` hook or
  right after `{:ok, …}`) — never inside the transaction, so a
  rolled-back action never emits a phantom event. `account_id` rides every
  event as a property regardless of `distinct_id`.
  """

  alias Emisar.Analytics
  alias Emisar.Approvals
  alias Emisar.Runners
  alias Emisar.Runs

  # -- Runs ------------------------------------------------------------

  @doc "The value moment — a gated action was dispatched to a runner."
  def action_dispatched(%Runs.ActionRun{} = run) do
    Analytics.track("action_dispatched", run_distinct_id(run), %{
      "action_id" => run.action_id,
      "runner_id" => run.runner_id,
      "source" => to_string(run.source),
      "requires_approval" => run.requires_approval,
      "account_id" => run.account_id
    })
  end

  @doc "Outcome — a run reached a terminal status (success/failure/denied/…)."
  def run_finished(%Runs.ActionRun{} = run) do
    Analytics.track("run_finished", run_distinct_id(run), %{
      "status" => to_string(run.status),
      "duration_ms" => run.duration_ms,
      "source" => to_string(run.source),
      "account_id" => run.account_id
    })
  end

  # -- Runners ---------------------------------------------------------

  @doc "Activation — a runner's socket came online."
  def runner_connected(%Runners.Runner{} = runner) do
    Analytics.track("runner_connected", account_distinct_id(runner.account_id), %{
      "runner_id" => runner.id,
      "runner_version" => runner.runner_version,
      "account_id" => runner.account_id
    })
  end

  # -- Approvals -------------------------------------------------------

  @doc "Engagement — a human approval request reached a terminal decision."
  def approval_decided(%Approvals.Request{} = request) do
    Analytics.track("approval_decided", account_distinct_id(request.account_id), %{
      "decision" => to_string(request.status),
      "approver_id" => request.decided_by_id,
      "account_id" => request.account_id
    })
  end

  # -- distinct_id resolution -----------------------------------------

  # Operator-initiated runs attribute to the user (so dispatch + outcome
  # share a distinct_id); MCP/agent runs have no person → the account.
  defp run_distinct_id(%Runs.ActionRun{requested_by_id: user_id}) when is_binary(user_id),
    do: user_id

  defp run_distinct_id(%Runs.ActionRun{account_id: account_id}),
    do: account_distinct_id(account_id)

  defp account_distinct_id(account_id), do: "account:" <> account_id
end
