defmodule Emisar.Accounts.Membership.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Membership

  @create_fields ~w[account_id user_id role directory_managed runner_access_mode runner_access_directory_managed
                    directory_provider_id directory_authorization_version directory_authorization_pending_version
                    invited_by_id invitation_token_digest invitation_accepted_at]a
  @update_fields ~w[role invitation_accepted_at]a

  def create(attrs) do
    %Membership{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :user_id, :role])
    |> unique_constraint([:account_id, :user_id])
  end

  # Born suspended: SSO provisions a user the IdP created as deactivated
  # (`active: false`) already `disabled_at` — the IdP owns the suspension, so mark
  # it `directory_suspended` too (a manual reinstate can't lift an IdP deactivation).
  def create_suspended(attrs) do
    attrs
    |> create()
    |> put_change(:disabled_at, DateTime.utc_now())
    |> put_change(:directory_suspended, true)
  end

  def update(%Membership{} = membership, attrs) do
    cast(membership, attrs, @update_fields)
  end

  def update_runner_access(%Membership{} = membership, mode),
    do: change(membership, runner_access_mode: mode)

  # Directory sync sets the role AND marks it directory-managed, so the operator
  # role-change path rejects a manual change to it (the lock is domain-owned, not
  # UI-only). `role` is a validated atom off the sync path.
  def sync_role(%Membership{} = membership, role),
    do: change(membership, role: role, directory_managed: true)

  def sync_authorization(%Membership{} = membership, role, mode, provider_id, version) do
    change(membership,
      role: role,
      directory_managed: true,
      runner_access_mode: mode,
      runner_access_directory_managed: true,
      directory_provider_id: provider_id,
      directory_authorization_version: version,
      directory_authorization_pending_version: nil
    )
  end

  def sync_runner_authorization(%Membership{} = membership, mode, provider_id, version) do
    change(membership,
      runner_access_mode: mode,
      runner_access_directory_managed: true,
      directory_provider_id: provider_id,
      directory_authorization_version: version,
      directory_authorization_pending_version: nil
    )
  end

  def mark_authorization_pending(%Membership{} = membership, provider_id, version) do
    change(membership,
      directory_provider_id: provider_id,
      directory_authorization_pending_version: version
    )
  end

  # Return role control to operators — SCIM disabled for the provider.
  def clear_directory_managed(%Membership{} = membership) do
    change(membership,
      directory_managed: false,
      runner_access_directory_managed: false,
      directory_provider_id: nil,
      directory_authorization_pending_version: nil
    )
  end

  def delete(%Membership{} = membership), do: change(membership, deleted_at: DateTime.utc_now())

  def suspend(%Membership{} = membership), do: change(membership, disabled_at: DateTime.utc_now())

  # Directory sync deactivated the member (SCIM active:false/DELETE) — mark the
  # suspension IdP-owned so a manual reinstate refuses; only the IdP reactivating
  # (or a re-provision) lifts it.
  def sync_suspend(%Membership{} = membership),
    do: change(membership, disabled_at: DateTime.utc_now(), directory_suspended: true)

  # Reinstating always clears the IdP-owned mark — a member back in is not
  # IdP-deactivated (a manual reinstate is only reachable when it's already false).
  def reinstate(%Membership{} = membership),
    do: change(membership, disabled_at: nil, directory_suspended: false)

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
