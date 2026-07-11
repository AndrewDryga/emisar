defmodule Emisar.Runbooks.RunbookExecution.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.RunbookExecution

  @fields ~w[id account_id runbook_id initiating_membership_id requested_by_id api_key_id idempotency_key reason work_list]a

  def create(attrs) do
    %RunbookExecution{}
    |> cast(attrs, @fields)
    # `requested_by_id` is attribution-only and DB-nullable: an MCP-initiated
    # execution has an API-key actor, not a user, so it's nil there (audit
    # records the api_key actor, and `initiating_membership_id` is the real
    # authorization anchor). A user-initiated execution still sets it.
    |> validate_required([
      :id,
      :account_id,
      :runbook_id,
      :initiating_membership_id,
      :reason
    ])
    # Backstop for the `on_conflict` upsert in `create_execution`: a retried MCP
    # execute collapses on this index rather than double-running the runbook.
    |> unique_constraint([:api_key_id, :idempotency_key],
      name: :runbook_executions_api_key_idempotency_key_index
    )
  end
end
