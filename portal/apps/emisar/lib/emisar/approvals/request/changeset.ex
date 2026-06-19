defmodule Emisar.Approvals.Request.Changeset do
  use Emisar, :changeset
  alias Emisar.Approvals.Request

  def create(attrs) do
    %Request{}
    |> cast(attrs, [
      :account_id,
      :run_id,
      :requested_by_id,
      :requested_at,
      :reason,
      :context,
      :expires_at,
      :min_approvals,
      :allow_self_approval
    ])
    |> validate_required([:account_id, :run_id, :requested_at])
    # One request per run — the standalone insert maps a duplicate to a clean
    # changeset error; the atomic dispatch path upserts on this index instead.
    |> unique_constraint(:run_id)
  end
end
