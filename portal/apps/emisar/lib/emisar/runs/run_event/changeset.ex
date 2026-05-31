defmodule Emisar.Runs.RunEvent.Changeset do
  use Emisar, :changeset
  alias Emisar.Runs.RunEvent

  @kinds ~w(progress transition error redaction_summary)

  def create(attrs) do
    %RunEvent{}
    |> cast(attrs, [:run_id, :account_id, :seq, :kind, :stream, :payload])
    |> validate_required([:run_id, :account_id, :seq, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:run_id, :seq])
  end

  def kinds, do: @kinds
end
