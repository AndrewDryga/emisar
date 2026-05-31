defmodule Emisar.Runs.Authorizer do
  @moduledoc """
  Authorization for action runs + per-run progress events.

    * `dispatch_run_permission` — allowed to invoke `Runs.dispatch_run/2`.
    * `cancel_run_permission` — allowed to cancel a queued/running run.
    * `view_runs_permission` — allowed to read run rows.
    * `report_run_progress_permission` — held by the runner socket to
      append progress events and final results to runs belonging to it.
  """
  use Emisar.Auth.Authorizer

  alias Emisar.Runs.{ActionRun, RunEvent}
  alias Emisar.Runners.Runner

  def dispatch_run_permission, do: build(ActionRun, :dispatch)
  def cancel_run_permission, do: build(ActionRun, :cancel)
  def view_runs_permission, do: build(ActionRun, :view)
  def report_run_progress_permission, do: build(RunEvent, :report)

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
    do: [report_run_progress_permission(), view_runs_permission()]

  def list_permissions_for_role(:system),
    do: [
      dispatch_run_permission(),
      cancel_run_permission(),
      view_runs_permission(),
      report_run_progress_permission()
    ]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  # Runner socket only sees its own runs — even within the account.
  def for_subject(queryable, %Subject{actor: %Runner{id: runner_id}}) do
    case query_source(queryable) do
      :action_runs -> ActionRun.Query.by_runner_id(queryable, runner_id)
      _ -> queryable
    end
  end

  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: ActionRun.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable

  defp query_source(%Ecto.Query{from: %{source: {table, _}}}), do: String.to_atom(table)
  defp query_source(_), do: nil
end
