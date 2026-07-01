defmodule Emisar.Accounts.Membership.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Membership

  @create_fields ~w[account_id user_id role invited_by_id invitation_token_digest invitation_accepted_at]a
  @update_fields ~w[role invitation_accepted_at]a

  def create(attrs) do
    %Membership{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :user_id, :role])
    |> unique_constraint([:account_id, :user_id])
  end

  # Born suspended: SSO provisions a user the IdP created as deactivated
  # (`active: false`) already `disabled_at`, so they never hold access.
  def create_suspended(attrs) do
    attrs |> create() |> put_change(:disabled_at, DateTime.utc_now())
  end

  def update(%Membership{} = membership, attrs) do
    cast(membership, attrs, @update_fields)
  end

  # Directory sync sets the role AND marks it directory-managed, so the operator
  # role-change path rejects a manual change to it (the lock is domain-owned, not
  # UI-only). `role` is a validated atom off the sync path.
  def sync_role(%Membership{} = membership, role),
    do: change(membership, role: role, directory_managed: true)

  # Return role control to operators — SCIM disabled for the provider.
  def clear_directory_managed(%Membership{} = membership),
    do: change(membership, directory_managed: false)

  def delete(%Membership{} = membership), do: change(membership, deleted_at: DateTime.utc_now())

  def suspend(%Membership{} = membership), do: change(membership, disabled_at: DateTime.utc_now())
  def reinstate(%Membership{} = membership), do: change(membership, disabled_at: nil)

  def accept_invitation(%Membership{} = membership) do
    change(membership, invitation_token_digest: nil, invitation_accepted_at: DateTime.utc_now())
  end

  def resend_invitation(%Membership{} = membership, token_digest) when is_binary(token_digest) do
    change(membership,
      invitation_token_digest: token_digest,
      invitation_accepted_at: nil,
      inserted_at: DateTime.utc_now()
    )
  end
end
