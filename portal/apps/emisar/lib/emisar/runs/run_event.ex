defmodule Emisar.Runs.RunEvent do
  @moduledoc """
  A streamed progress chunk for an action run, written by the runner
  socket's `action_progress` handler. Insertion is append-only; `seq`
  orders chunks within (run_id) and can have gaps where the runner dropped
  output. The other `kind` values are allowed by the enum but not written.
  """
  use Emisar, :schema

  schema "action_run_events" do
    field :seq, :integer
    field :kind, Ecto.Enum, values: [:progress, :transition, :error]
    field :stream, :string
    field :payload, :map, default: %{}

    belongs_to :run, Emisar.Runs.ActionRun
    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end
end
