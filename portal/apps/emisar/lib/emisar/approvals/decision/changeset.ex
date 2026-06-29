defmodule Emisar.Approvals.Decision.Changeset do
  use Emisar, :changeset
  alias Emisar.Approvals.Decision

  @fields ~w[decision decided_at]a

  def create(account_id, request_id, decider_id, attrs) do
    %Decision{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:request_id, request_id)
    |> put_change(:decider_id, decider_id)
    |> validate_required([:account_id, :request_id, :decider_id, :decision, :decided_at])
    # The DB unique index is the distinctness invariant: a second vote by the
    # same operator on the same request hits it and maps to :already_decided.
    |> unique_constraint([:request_id, :decider_id],
      name: :approval_decisions_request_id_decider_id_index
    )
  end
end
