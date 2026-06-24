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

  alias Emisar.Accounts
  alias Emisar.Analytics
  alias Emisar.Approvals
  alias Emisar.Auth.Subject
  alias Emisar.Catalog
  alias Emisar.Policies
  alias Emisar.Runbooks
  alias Emisar.Runners
  alias Emisar.Runs
  alias Emisar.Users

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

  # -- Catalog ---------------------------------------------------------

  @doc "Engagement — an operator trusted a pack version (committed to a capability)."
  def pack_trusted(%Catalog.PackVersion{} = pack_version, %Subject{} = subject) do
    Analytics.track("pack_trusted", subject_distinct_id(subject), %{
      "pack_id" => pack_version.pack_id,
      "version" => pack_version.version,
      "account_id" => pack_version.account_id
    })
  end

  # -- Policies --------------------------------------------------------

  @doc "Engagement — an operator changed a policy (configured the gate)."
  def policy_updated(%Policies.Policy{} = policy, %Subject{} = subject) do
    Analytics.track("policy_updated", subject_distinct_id(subject), %{
      "scope_type" => to_string(policy.scope_type),
      "account_id" => policy.account_id
    })
  end

  # -- Runbooks --------------------------------------------------------

  @doc "Engagement — a runbook was published."
  def runbook_published(%Runbooks.Runbook{} = runbook, %Subject{} = subject) do
    Analytics.track("runbook_published", subject_distinct_id(subject), %{
      "runbook_id" => runbook.id,
      "version" => runbook.version,
      "account_id" => runbook.account_id
    })
  end

  # -- Accounts --------------------------------------------------------

  @doc "Team growth — a member was invited to the account."
  def member_invited(%Accounts.Membership{} = membership, %Subject{} = subject) do
    Analytics.track("member_invited", subject_distinct_id(subject), %{
      "role" => to_string(membership.role),
      "account_id" => membership.account_id
    })
  end

  # -- distinct_id resolution -----------------------------------------

  # Operator actions attribute to the acting user; an actor-less or
  # non-user subject falls back to the account handle.
  defp subject_distinct_id(%Subject{actor: %Users.User{id: id}}), do: id

  defp subject_distinct_id(%Subject{account: %Accounts.Account{id: id}}),
    do: account_distinct_id(id)

  # Operator-initiated runs attribute to the user (so dispatch + outcome
  # share a distinct_id); MCP/agent runs have no person → the account.
  defp run_distinct_id(%Runs.ActionRun{requested_by_id: user_id}) when is_binary(user_id),
    do: user_id

  defp run_distinct_id(%Runs.ActionRun{account_id: account_id}),
    do: account_distinct_id(account_id)

  defp account_distinct_id(account_id), do: "account:" <> account_id
end
