defmodule Emisar.Runs.RunEvent do
  @moduledoc """
  A streamed event for an action run: a progress chunk, a state
  transition note, a cancellation, an error envelope. Insertion is
  append-only; `seq` is dense within (run_id).
  """
  use Emisar, :schema

  schema "action_run_events" do
    field :seq, :integer
    field :kind, :string
    field :stream, :string
    field :payload, :map, default: %{}

    belongs_to :run, Emisar.Runs.ActionRun
    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end

  def kinds, do: Emisar.Runs.RunEvent.Changeset.kinds()
end
