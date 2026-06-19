defmodule Emisar.Runbooks.RunbookExecution.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.RunbookExecution

  @fields ~w[id account_id runbook_id initiating_membership_id requested_by_id reason work_list]a

  def create(attrs) do
    %RunbookExecution{}
    |> cast(attrs, @fields)
    |> validate_required([
      :id,
      :account_id,
      :runbook_id,
      :initiating_membership_id,
      :requested_by_id,
      :reason
    ])
  end
end
