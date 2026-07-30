defmodule Emisar.Approvals.Request.Changeset do
  use Emisar, :changeset
  alias Emisar.Approvals.Request

  def create(attrs) do
    %Request{}
    |> cast(attrs, [
      :account_id,
      :run_id,
      :runbook_execution_id,
      :requested_by_id,
      :requested_at,
      :reason,
      :evidence,
      :expected,
      :context,
      :expires_at,
      :min_approvals,
      :allow_self_approval
    ])
    |> validate_required([
      :account_id,
      :requested_at,
      :min_approvals,
      :allow_self_approval
    ])
    |> validate_exactly_one_target()
    |> validate_number(:min_approvals,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: Emisar.Policies.max_min_approvals()
    )
    # One request per run — the standalone insert maps a duplicate to a clean
    # changeset error; the atomic dispatch path upserts on this index instead.
    |> unique_constraint(:run_id, name: :approval_requests_run_id_index)
    |> unique_constraint(:runbook_execution_id,
      name: :approval_requests_runbook_execution_index
    )
    |> check_constraint(:run_id, name: :approval_requests_exactly_one_target_check)
  end

  defp validate_exactly_one_target(changeset) do
    case {get_field(changeset, :run_id), get_field(changeset, :runbook_execution_id)} do
      {run_id, nil} when is_binary(run_id) -> changeset
      {nil, execution_id} when is_binary(execution_id) -> changeset
      _other -> add_error(changeset, :run_id, "must identify exactly one approval target")
    end
  end
end
