defmodule Emisar.Runs.RunEvent do
  @moduledoc """
  A streamed event for an action run: a progress chunk, a state
  transition note, a cancellation, an error envelope. Insertion is
  append-only; `seq` is dense within (run_id).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(progress transition error redaction_summary)

  schema "action_run_events" do
    field :seq, :integer
    field :kind, :string
    field :stream, :string
    field :payload, :map, default: %{}

    belongs_to :run, Emisar.Runs.ActionRun
    belongs_to :account, Emisar.Accounts.Account

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :account_id, :seq, :kind, :stream, :payload])
    |> validate_required([:run_id, :account_id, :seq, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:run_id, :seq])
  end

  def kinds, do: @kinds
end
