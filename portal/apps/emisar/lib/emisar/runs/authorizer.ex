defmodule Emisar.Runs.Authorizer do
  @moduledoc """
  Authorization for action runs.

    * `dispatch_run_permission` — allowed to invoke `Runs.dispatch_run/2`.
    * `cancel_run_permission` — allowed to cancel a queued/running run.
    * `cancel_own_run_permission` — machine-only: an API key may withdraw its
      own undispatched run through `Runs.cancel_mcp_run/3`.
    * `view_runs_permission` — allowed to read run rows.

  Runner-side progress event writes (`Runs.append_event_from_connection/6`,
  `Runs.finalize_from_connection/5`) are internal helpers called from the
  runner socket process; they don't subject-flow so there's no dedicated
  permission for them.
  """
  use Emisar.Auth.ContextAuthorizer
  alias Emisar.Runs.ActionRun

  def dispatch_run_permission, do: build(ActionRun, :dispatch)
  def cancel_run_permission, do: build(ActionRun, :cancel)
  def cancel_own_run_permission, do: build(ActionRun, :cancel_own)
  def view_runs_permission, do: build(ActionRun, :view)

  @impl Emisar.Auth.ContextAuthorizer
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
    do: [dispatch_run_permission(), cancel_own_run_permission(), view_runs_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.ContextAuthorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: ActionRun.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: ActionRun.Query.none(queryable)
end
