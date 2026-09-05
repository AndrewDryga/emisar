defmodule Emisar.Accounts.Membership.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.{Membership, RunnerAccess}

  @create_fields ~w[account_id user_id role directory_managed runner_access_mode runner_access_directory_managed
                    pack_access_mode pack_scope_pack_ids
                    directory_provider_id directory_authorization_pending_version
                    invited_by_id invitation_token_digest invitation_sent_to
                    invitation_email_changed_at invitation_accepted_at]a
  @update_fields ~w[role]a

  def create(attrs) do
    %Membership{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :user_id, :role])
    |> unique_constraint([:account_id, :user_id])
    |> put_access_the_role_carries()
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
    membership
    |> cast(attrs, @update_fields)
    |> put_access_the_role_carries()
  end

  def update_runner_access(%Membership{} = membership, %RunnerAccess{} = access) do
    membership
    |> put_runner_access(access)
    |> put_access_the_role_carries()
  end

  # Directory sync sets the role AND marks it directory-managed, so the operator
  # role-change path rejects a manual change to it (the lock is domain-owned, not
  # UI-only). `role` is a validated atom off the sync path.
  def sync_role(%Membership{} = membership, role) do
    membership
    |> change(role: role, directory_managed: true)
    |> put_access_the_role_carries()
  end

  def sync_authorization(
        %Membership{} = membership,
        role,
        %RunnerAccess{} = access,
        provider_id
      ) do
    membership
    |> change(role: role, directory_managed: true)
    |> put_runner_access(access)
    |> put_directory_authorization(provider_id)
    |> put_access_the_role_carries()
  end

  def sync_runner_authorization(
        %Membership{} = membership,
        %RunnerAccess{} = access,
        provider_id
      ) do
    membership
    |> put_runner_access(access)
    |> put_directory_authorization(provider_id)
    |> put_access_the_role_carries()
  end

  def delete(%Membership{} = membership), do: change(membership, deleted_at: DateTime.utc_now())

  def suspend(%Membership{} = membership, disabled_by_id) do
    change(membership, disabled_at: DateTime.utc_now(), disabled_by_id: disabled_by_id)
  end

  # Directory sync deactivated the member (SCIM active:false/DELETE) — mark the
  # suspension IdP-owned so a manual reinstate refuses; only the IdP reactivating
  # (or a re-provision) lifts it. The connection that placed it is stamped too:
  # without that, a suspension owned by a live directory was indistinguishable
  # from one whose directory had been deleted, and both reinstatement and the
  # cleanup that frees stranded members had to guess.
  def sync_suspend(%Membership{} = membership, provider_id) when is_binary(provider_id) do
    change(membership,
      disabled_at: DateTime.utc_now(),
      directory_suspended: true,
      directory_provider_id: provider_id
    )
  end

  # The directory's name for this member. An already-matching value is a no-op so
  # a re-sync writes nothing.
  def sync_display_name(%Membership{directory_display_name: name} = membership, name),
    do: {:noop, membership}

  def sync_display_name(%Membership{} = membership, display_name) do
    membership
    |> change(directory_display_name: display_name)
    |> validate_length(:directory_display_name, max: 255, count: :codepoints)
  end

  # Reinstating always clears the IdP-owned mark — a member back in is not
  # IdP-deactivated (a manual reinstate is only reachable when it's already false).
  def reinstate(%Membership{} = membership) do
    change(membership,
      disabled_at: nil,
      disabled_by_id: nil,
      directory_suspended: false
    )
  end

  def accept_invitation(%Membership{} = membership) do
    change(membership,
      invitation_token_digest: nil,
      invitation_sent_to: nil,
      invitation_email_changed_at: nil,
      invitation_accepted_at: DateTime.utc_now()
    )
  end

  def resend_invitation(
        %Membership{} = membership,
        token_digest,
        sent_to,
        %DateTime{} = email_changed_at
      )
      when is_binary(token_digest) and is_binary(sent_to) do
    change(membership,
      invitation_token_digest: token_digest,
      invitation_sent_to: sent_to,
      invitation_email_changed_at: email_changed_at,
      invitation_accepted_at: nil,
      inserted_at: DateTime.utc_now()
    )
  end

  defp put_runner_access(changeset, %RunnerAccess{} = access) do
    change(changeset,
      runner_access_mode: access.mode,
      pack_access_mode: access.pack_mode,
      pack_scope_pack_ids: access.pack_ids
    )
  end

  # Applying a sync clears the fail-closed marker; "authorization is current"
  # IS "pending is nil". The applied-version receipt this used to write was
  # compared by nothing and is gone.
  defp put_directory_authorization(changeset, provider_id) do
    change(changeset,
      runner_access_directory_managed: true,
      directory_provider_id: provider_id,
      directory_authorization_pending_version: nil
    )
  end

  # The last word on every membership write: a role that carries no runner reach
  # (the finance seat) carries no pack reach either, so BOTH dimensions land
  # cleared however the row was built — created, re-roled, access-edited, or
  # synced from a directory. It runs after the access is put, so a grant and a
  # role that contradict each other resolve to the role. Rewriting the matching
  # `user_runner_scopes` rows is `Accounts`' job in the same transaction; a pure
  # changeset cannot reach another table.
  defp put_access_the_role_carries(changeset) do
    role = get_field(changeset, :role)

    if Emisar.Auth.Role.carries_runner_access?(role),
      do: changeset,
      else: put_runner_access(changeset, RunnerAccess.none())
  end
end
