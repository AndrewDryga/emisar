defmodule Emisar.Approvals.Grant.Changeset do
  use Emisar, :changeset
  alias Emisar.Approvals.Grant

  def create(attrs) do
    %Grant{}
    |> cast(attrs, [
      :account_id,
      :api_key_id,
      :action_id,
      :runner_id,
      :args_sha256,
      :granted_by_id,
      :granted_at,
      :expires_at,
      :max_uses,
      :uses_count,
      :last_used_at,
      :approval_request_id
    ])
    |> validate_required([:account_id, :api_key_id, :action_id, :granted_at])
  end

  def usage(%Grant{} = grant, now \\ DateTime.utc_now()) do
    change(grant,
      last_used_at: DateTime.truncate(now, :microsecond),
      uses_count: grant.uses_count + 1
    )
  end

  def revoke(%Grant{} = grant, by_user_id) do
    change(grant, revoked_at: now(), revoked_by_id: by_user_id)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
