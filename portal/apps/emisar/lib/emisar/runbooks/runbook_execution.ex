defmodule Emisar.Runbooks.RunbookExecution do
  @moduledoc """
  One runbook invocation and its frozen authorization/preflight plan.

  Durable stage and item rows carry scheduling state; this row is the
  authorization anchor and terminal execution summary.
  """
  use Emisar, :schema

  schema "runbook_executions" do
    field :reason, :string

    field :status, Ecto.Enum,
      values: [:pending_approval, :active, :succeeded, :halted, :cancelled],
      default: :active

    field :halted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_advanced_at, :utc_datetime_usec
    field :terminal_code, :string
    field :terminal_message, :string
    field :frozen_plan, :map, default: %{}
    field :inputs_raw, :binary
    field :inputs_sha256, :string
    field :sensitive_input_names, {:array, :string}, default: []

    field :api_key_id, Ecto.UUID
    field :operation_id, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runbook, Emisar.Runbooks.Runbook, where: [deleted_at: nil]
    belongs_to :initiating_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :mcp_operation_record, Emisar.MCPOperations.Operation

    has_many :stages, Emisar.Runbooks.ExecutionStage
    has_many :items, Emisar.Runbooks.ExecutionItem
    has_one :approval_request, Emisar.Approvals.Request

    timestamps()
  end
end
