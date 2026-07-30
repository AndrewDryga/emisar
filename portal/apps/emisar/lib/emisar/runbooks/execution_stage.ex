defmodule Emisar.Runbooks.ExecutionStage do
  @moduledoc "One durable barrier and concurrency scope in a runbook execution."
  use Emisar, :schema

  schema "runbook_execution_stages" do
    field :stage_id, :string
    field :position, :integer
    field :title, :string
    field :mode, Ecto.Enum, values: [:sequential, :parallel]
    field :max_parallel, :integer
    field :approval, Ecto.Enum, values: [:none, :required]

    field :status, Ecto.Enum,
      values: [:pending, :awaiting_approval, :active, :succeeded, :halted, :cancelled],
      default: :pending

    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :terminal_code, :string
    field :terminal_message, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runbook_execution, Emisar.Runbooks.RunbookExecution

    has_many :items, Emisar.Runbooks.ExecutionItem, foreign_key: :runbook_execution_stage_id

    has_one :approval_request, Emisar.Approvals.Request, foreign_key: :runbook_execution_stage_id

    timestamps()
  end
end
