defmodule Emisar.Accounts.Membership.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Membership

  @roles ~w(owner admin operator viewer)

  def create(attrs) do
    %Membership{}
    |> cast(attrs, [
      :account_id,
      :user_id,
      :role,
      :invited_by_id,
      :invitation_token,
      :invitation_accepted_at
    ])
    |> validate_required([:account_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:account_id, :user_id])
  end

  def update(%Membership{} = m, attrs) do
    m
    |> cast(attrs, [:role, :invitation_accepted_at])
    |> validate_inclusion(:role, @roles)
  end

  def delete(%Membership{} = m), do: change(m, deleted_at: now())

  def suspend(%Membership{} = m), do: change(m, disabled_at: now())
  def reinstate(%Membership{} = m), do: change(m, disabled_at: nil)

  def roles, do: @roles

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
