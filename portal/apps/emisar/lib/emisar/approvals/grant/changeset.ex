defmodule Emisar.Approvals.Grant.Changeset do
  use Emisar, :changeset
  alias Emisar.Approvals.Grant

  def create(attrs) do
    %Grant{}
    |> cast(attrs, [
      :account_id,
      :api_key_id,
      :action_id,
      :pack_ref,
      :runner_id,
      :args_sha256,
      :granted_by_membership_id,
      :granted_at,
      :expires_at,
      :max_uses,
      :uses_count,
      :last_used_at,
      :approval_request_id
    ])
    |> validate_required([
      :account_id,
      :api_key_id,
      :action_id,
      :pack_ref,
      :granted_at,
      :granted_by_membership_id
    ])
    |> foreign_key_constraint(:granted_by_membership_id)
  end

  def revoke(%Grant{} = grant, by_membership_id) do
    grant
    |> change(revoked_at: DateTime.utc_now(), revoked_by_membership_id: by_membership_id)
    |> foreign_key_constraint(:revoked_by_membership_id)
  end
end
