defmodule Emisar.Runbooks.RunbookExecution do
  @moduledoc """
  One runbook invocation: the durable authorization anchor for every wave it
  dispatches. Records the initiating membership and a FROZEN authorized
  work-list (`%{"step_index", "runner_id"}` per item, resolved once at the first
  wave) so a later wave — fired from a user-less continuation callback — can
  revalidate the membership + each runner instead of re-resolving group
  membership (which would silently pick up runners added mid-execution).
  """
  use Emisar, :schema

  schema "runbook_executions" do
    field :reason, :string
    # A row-less dispatch failure has no action run for the wave engine to
    # inspect, so it halts the execution here before a later wave can advance.
    field :status, Ecto.Enum, values: [:active, :halted], default: :active
    field :halted_at, :utc_datetime_usec

    # Frozen authorized work-list: the full step×runner set resolved at the
    # first wave. Each item is `%{"step_index" => i, "runner_id" => id}`; the
    # step's action/args are re-read from the immutable runbook version by index.
    field :work_list, {:array, :map}, default: []

    # MCP execute_runbook idempotency: a retried call carrying the same
    # `(api_key_id, idempotency_key)` returns THIS execution instead of minting
    # a fresh one that re-runs every step. Both nil on the user-initiated (web)
    # path — no api key, no key — so the partial unique index never engages.
    field :api_key_id, Ecto.UUID
    field :idempotency_key, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runbook, Emisar.Runbooks.Runbook, where: [deleted_at: nil]
    belongs_to :initiating_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
