defmodule Emisar.SSO.DirectoryGroupMember.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.DirectoryGroupMember

  @fields ~w[external_group_id user_identity_id]a

  def create(account_id, provider_id, attrs) do
    %DirectoryGroupMember{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :external_group_id, :user_identity_id])
    |> unique_constraint([:provider_id, :external_group_id, :user_identity_id],
      name: :directory_group_members_membership_index
    )
  end

  def delete(%DirectoryGroupMember{} = member),
    do: change(member, deleted_at: DateTime.utc_now())
end
