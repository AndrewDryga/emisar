defmodule Emisar.Runs.RunEvent.Changeset do
  use Emisar, :changeset
  alias Emisar.Runs.RunEvent

  def create(attrs) do
    %RunEvent{}
    |> cast(attrs, [:run_id, :account_id, :seq, :kind, :stream, :payload])
    |> validate_required([:run_id, :account_id, :seq, :kind])
    |> unique_constraint([:run_id, :seq])
  end
end
