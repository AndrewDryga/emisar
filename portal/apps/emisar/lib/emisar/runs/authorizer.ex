defmodule Emisar.Runs.Authorizer do
  @moduledoc """
  Authorization for action runs.

    * `dispatch_run_permission` — allowed to invoke `Runs.dispatch_run/2`.
    * `cancel_run_permission` — allowed to cancel a queued/running run.
    * `view_runs_permission` — allowed to read run rows.

  Runner-side progress event writes (`Runs.append_event/2`,
  `Runs.finalize_from_result/2`) are internal helpers called from the
  runner socket process; they don't subject-flow so there's no
  dedicated permission for them.
  """
  use Emisar.Auth.Authorizer
  alias Emisar.Runs.ActionRun
  alias Emisar.Runners

  def dispatch_run_permission, do: build(ActionRun, :dispatch)
  def cancel_run_permission, do: build(ActionRun, :cancel)
  def view_runs_permission, do: build(ActionRun, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [
      dispatch_run_permission(),
      cancel_run_permission(),
      view_runs_permission()
    ]

  def list_permissions_for_role(:operator),
    do: [dispatch_run_permission(), cancel_run_permission(), view_runs_permission()]

  def list_permissions_for_role(:viewer),
    do: [view_runs_permission()]

  def list_permissions_for_role(:api_client),
    do: [dispatch_run_permission(), view_runs_permission()]

  def list_permissions_for_role(:runner),
    do: [view_runs_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  # Runner socket only sees its own runs — even within the account.
  def for_subject(queryable, %Subject{actor: %Runners.Runner{id: runner_id}}) do
    case query_source(queryable) do
      :action_runs -> ActionRun.Query.by_runner_id(queryable, runner_id)
      _ -> queryable
    end
  end

  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: ActionRun.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
