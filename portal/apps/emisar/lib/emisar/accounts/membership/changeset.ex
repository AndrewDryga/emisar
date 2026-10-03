defmodule Emisar.Accounts.Membership.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.{Membership, RunnerAccess}

  @create_fields ~w[account_id role display_name email directory_managed runner_access_mode runner_access_directory_managed
                    pack_access_mode pack_scope_pack_ids
                    directory_provider_id directory_authorization_pending_version
                    invited_by_membership_id invitation_token_digest
                    invitation_accepted_at]a
  @update_fields ~w[role]a

  def create(attrs) do
    %Membership{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :role])
    |> validate_profile()
    |> unique_constraint(:email, name: :account_memberships_account_id_email_index)
    |> foreign_key_constraint(:invited_by_membership_id)
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

  def profile(%Membership{} = membership, attrs) do
    membership
    |> cast(attrs, [:display_name])
    |> validate_profile()
  end

  defp validate_profile(changeset) do
    changeset
    |> validate_length(:display_name, max: 255, count: :codepoints)
    |> Emisar.EmailAddress.validate(:email)
  end

  def update_runner_access(%Membership{} = membership, %RunnerAccess{} = access) do
    membership
    |> put_runner_access(access)
    |> put_access_the_role_carries()
  end

  def update_role_and_access(%Membership{} = membership, role, %RunnerAccess{} = access) do
    membership
    |> update(%{role: role})
    |> put_runner_access(access)
    |> put_access_the_role_carries()
  end

  def return_to_directory(%Ecto.Changeset{} = changeset, version) do
    pending = max(get_field(changeset, :directory_authorization_pending_version) || 0, version)

    if is_binary(get_field(changeset, :directory_provider_id)) do
      changeset
      |> put_change(:directory_managed, true)
      |> put_change(:directory_authorization_pending_version, pending)
    else
      # An already-deleted provider cannot reconcile. Keep the explicit none
      # grant and suspension state, and return configuration to the account.
      changeset
      |> put_change(:directory_managed, false)
      |> put_change(:runner_access_directory_managed, false)
      |> put_change(:directory_authorization_pending_version, nil)
    end
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

  def suspend(%Membership{} = membership, disabled_by_membership_id) do
    membership
    |> change(
      disabled_at: DateTime.utc_now(),
      disabled_by_membership_id: disabled_by_membership_id
    )
    |> foreign_key_constraint(:disabled_by_membership_id)
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
  def sync_display_name(%Membership{display_name: name} = membership, name),
    do: {:noop, membership}

  def sync_display_name(%Membership{} = membership, display_name) do
    membership
    |> change(display_name: display_name)
    |> validate_length(:display_name, max: 255, count: :codepoints)
  end

  # Reinstating always clears the IdP-owned mark — a member back in is not
  # IdP-deactivated (a manual reinstate is only reachable when it's already false).
  def reinstate(%Membership{} = membership) do
    change(membership,
      disabled_at: nil,
      disabled_by_membership_id: nil,
      directory_suspended: false
    )
  end

  @doc """
  Accept an invitation with the name the invitee gave. Acceptance follows a
  proof of the invited inbox, so it also verifies the Member's address.
  """
  def accept_invitation_with_profile(%Membership{} = membership, attrs) do
    membership
    |> profile(attrs)
    |> validate_required([:display_name])
    |> put_invitation_accepted()
    |> put_change(:email_verified_at, DateTime.utc_now())
  end

  @doc """
  The owner Member a proved sign-up creates. Its address is verified: the code
  that creates it was proved at that address.
  """
  def sign_up_owner(attrs) do
    attrs
    |> Map.put(:role, :owner)
    |> create()
    |> validate_required([:email])
    |> put_change(:email_verified_at, DateTime.utc_now())
  end

  @doc """
  Turn the Member's TOTP on or off. `secret` and `enabled_at` both set enable
  it; both nil disable it. `recovery_codes` is the digest list, replaced every
  time so old codes never survive a toggle, and the replay stamp starts clean.
  """
  def mfa(%Membership{} = membership, secret, enabled_at, recovery_codes)
      when is_list(recovery_codes) do
    change(membership,
      mfa_secret: secret,
      mfa_enabled_at: enabled_at,
      mfa_recovery_codes: recovery_codes,
      mfa_last_used_at: nil
    )
  end

  @doc "Stamp the most recent accepted TOTP — the replay guard's 30-second bucket."
  def mfa_consumed(%Membership{} = membership, %DateTime{} = at),
    do: change(membership, mfa_last_used_at: at)

  @doc "Replace the stored recovery-code digests: one consumed, or a whole new set."
  def mfa_recovery_codes(%Membership{} = membership, codes) when is_list(codes),
    do: change(membership, mfa_recovery_codes: codes)

  @doc "Replace every recovery-code digest and consume the proving TOTP bucket together."
  def regenerated_mfa_recovery_codes(%Membership{} = membership, codes, %DateTime{} = at)
      when is_list(codes),
      do: change(membership, mfa_recovery_codes: codes, mfa_last_used_at: at)

  @doc """
  The pending owner a staff-created workspace starts with: an invitation to the
  owner's address. The address is verified only when the invitation is accepted.
  """
  def invited_owner(attrs) do
    attrs
    |> Map.put(:role, :owner)
    |> create()
    |> validate_required([:email, :invitation_token_digest])
  end

  defp put_invitation_accepted(changeset) do
    change(changeset,
      invitation_token_digest: nil,
      invitation_accepted_at: DateTime.utc_now()
    )
  end

  # A resend keeps the address the invitation was sent to: only that address
  # can accept it.
  def resend_invitation(%Membership{} = membership, token_digest)
      when is_binary(token_digest) do
    change(membership,
      invitation_token_digest: token_digest,
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

    cond do
      role == :owner -> put_runner_access(changeset, RunnerAccess.all())
      Emisar.Auth.Role.carries_runner_access?(role) -> changeset
      true -> put_runner_access(changeset, RunnerAccess.none())
    end
  end
end
