defmodule Emisar.Approvals.Request.Changeset do
  use Emisar, :changeset
  alias Emisar.Approvals.Request

  @statuses ~w(pending approved denied expired)

  def create(attrs) do
    %Request{}
    |> cast(attrs, [
      :account_id,
      :run_id,
      :requested_by_id,
      :requested_at,
      :reason,
      :context,
      :expires_at
    ])
    |> validate_required([:account_id, :run_id, :requested_at])
  end

  def decide(%Request{} = req, status, decided_by_id, reason \\ nil) do
    req
    |> change(
      status: to_string(status),
      decided_by_id: decided_by_id,
      decided_at: DateTime.utc_now(),
      decision_reason: reason
    )
    |> validate_inclusion(:status, @statuses)
  end

  def expire(%Request{} = req) do
    req
    |> change(status: "expired", decided_at: DateTime.utc_now())
  end

  def statuses, do: @statuses
end
