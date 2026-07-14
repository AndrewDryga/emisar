defmodule Emisar.MCPOperations.Operation do
  @moduledoc """
  One bridge mutation identity owned by an API-key rotation lineage.

  The row is the authority for replay and recovery. Child runs, executions,
  and drafts are resources of this operation, not competing idempotency stores.
  """
  use Emisar, :schema

  schema "mcp_operations" do
    field :credential_lineage_id, Ecto.UUID
    field :operation_id, :string

    field :tool, Ecto.Enum, values: [:run_action, :execute_runbook, :create_runbook_draft]

    field :fingerprint, :string
    field :action_id, :string
    field :pack_ref, :string
    field :resource_id, Ecto.UUID
    field :resource_ref, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end
end
