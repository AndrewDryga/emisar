defmodule Emisar.Runbooks.RunbookExecution do
  @moduledoc """
  One runbook invocation and its frozen authorization/preflight plan.

  Durable stage and item rows carry scheduling state; this row is the
  authorization anchor and terminal execution summary.
  """
  use Emisar, :schema

  schema "runbook_executions" do
    field :reason, :string

    field :kind, Ecto.Enum, values: [:published, :draft_test], default: :published

    field :status, Ecto.Enum,
      values: [:pending_approval, :active, :succeeded, :halted, :cancelled],
      default: :active

    field :completed_at, :utc_datetime_usec
    field :last_advanced_at, :utc_datetime_usec
    field :terminal_code, :string
    field :terminal_message, :string
    field :frozen_plan, :map, default: %{}
    field :inputs_raw, :binary
    field :inputs_sha256, :string
    # The exact definition dispatched. The runbook row now mutates on publish,
    # so it can no longer answer what this execution actually ran.
    field :definition, :map
    field :definition_sha256, :string
    # The release this ran, null for a draft test.
    field :runbook_version, :integer

    field :api_key_id, Ecto.UUID
    field :operation_id, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runbook, Emisar.Runbooks.Runbook, where: [deleted_at: nil]
    belongs_to :initiating_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]
    # api_key_id is already a field above; this reuses it so an MCP-dispatched
    # execution can name its accountable key owner without a second FK.
    belongs_to :api_key, Emisar.ApiKeys.ApiKey,
      foreign_key: :api_key_id,
      define_field: false,
      where: [deleted_at: nil]

    belongs_to :mcp_operation_record, Emisar.MCPOperations.Operation

    has_many :stages, Emisar.Runbooks.ExecutionStage
    has_many :items, Emisar.Runbooks.ExecutionItem
    has_one :approval_request, Emisar.Approvals.Request

    timestamps()
  end
end
