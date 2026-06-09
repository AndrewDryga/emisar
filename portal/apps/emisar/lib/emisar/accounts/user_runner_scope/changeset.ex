defmodule Emisar.Accounts.UserRunnerScope.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.UserRunnerScope

  def create(membership_id, scope_type, scope_value)
      when is_binary(membership_id) and is_binary(scope_type) and is_binary(scope_value) do
    %UserRunnerScope{}
    |> cast(
      %{membership_id: membership_id, scope_type: scope_type, scope_value: scope_value},
      [:membership_id, :scope_type, :scope_value]
    )
    |> validate_required([:membership_id, :scope_type, :scope_value])
    |> validate_length(:scope_value, min: 1, max: 255)
    |> unique_constraint([:membership_id, :scope_type, :scope_value],
      name: :user_runner_scopes_unique
    )
  end
end
