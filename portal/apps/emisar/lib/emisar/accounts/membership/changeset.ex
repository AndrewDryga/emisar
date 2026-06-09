defmodule Emisar.Accounts.Membership.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Membership

  @create_fields ~w[account_id user_id role invited_by_id invitation_token invitation_accepted_at]a
  @update_fields ~w[role invitation_accepted_at]a

  def create(attrs) do
    %Membership{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :user_id, :role])
    |> unique_constraint([:account_id, :user_id])
  end

  def update(%Membership{} = m, attrs) do
    cast(m, attrs, @update_fields)
  end

  def delete(%Membership{} = m), do: change(m, deleted_at: now())

  def suspend(%Membership{} = m), do: change(m, disabled_at: now())
  def reinstate(%Membership{} = m), do: change(m, disabled_at: nil)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
