defmodule Emisar.RevokePreAcceptanceCredentialsTest do
  use Emisar.DataCase, async: false
  alias Emisar.{ApiKeys, Crypto, Fixtures, Repo, RequestContext}
  alias Emisar.Repo.Migrations.PreserveAcceptedInvitationCredentials
  alias Emisar.Repo.Migrations.RestoreAcceptedInvitationCredentials
  alias Emisar.Repo.Migrations.RevokeInvitationCredentials

  for {module, file} <- [
        {PreserveAcceptedInvitationCredentials,
         "20261018235959_preserve_accepted_invitation_credentials.exs"},
        {RevokeInvitationCredentials, "20261019000001_revoke_invitation_credentials.exs"},
        {RestoreAcceptedInvitationCredentials,
         "20261019000002_restore_accepted_invitation_credentials.exs"}
      ] do
    unless Code.ensure_loaded?(module) do
      Code.require_file(Path.expand("../../priv/repo/migrations/#{file}", __DIR__))
    end
  end

  test "the forward repair revokes pending credentials without touching accepted members" do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.membership_subject(membership)

    {_bad_raw, bad_key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

    {_good_raw, good_key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

    bad_grant = approved_grant(subject, "claude-code")
    good_grant = approved_grant(subject, "cursor")

    pending_user = Fixtures.Users.create_user()

    pending_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: pending_user.id,
        role: "operator"
      )

    pending_subject = Fixtures.Subjects.membership_subject(pending_membership)

    {_pending_raw, pending_key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        created_by_id: pending_user.id
      )

    pending_grant = approved_grant(pending_subject, "vscode")
    mark_pending(pending_membership)

    direct_user = Fixtures.Users.create_user()
    direct_account = Fixtures.Accounts.create_account()

    direct_membership =
      Fixtures.Memberships.create_membership(
        account_id: direct_account.id,
        user_id: direct_user.id,
        role: "owner"
      )

    direct_subject = Fixtures.Subjects.membership_subject(direct_membership)

    {_direct_raw, direct_key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: direct_account.id,
        created_by_id: direct_user.id
      )

    direct_grant = approved_grant(direct_subject, "codex")
    accepted_at = DateTime.utc_now()

    membership
    |> Ecto.Changeset.change(invitation_accepted_at: accepted_at)
    |> Repo.update!()

    PreserveAcceptedInvitationCredentials.preserve!(Repo)

    assert %{num_rows: 1} = Repo.query!(RevokeInvitationCredentials.api_key_repair_sql())

    assert %{num_rows: 1} =
             Repo.query!(RevokeInvitationCredentials.device_grant_repair_sql())

    RestoreAcceptedInvitationCredentials.restore!(Repo)

    assert Repo.reload!(membership).invitation_accepted_at == accepted_at
    assert is_nil(Repo.reload!(bad_key).revoked_at)
    assert is_nil(Repo.reload!(good_key).revoked_at)
    assert Repo.reload!(pending_key).revoked_at
    assert is_nil(Repo.reload!(direct_key).revoked_at)
    assert Repo.reload!(bad_grant).status == :approved
    assert Repo.reload!(good_grant).status == :approved
    assert Repo.reload!(pending_grant).status == :denied
    assert Repo.reload!(direct_grant).status == :approved
  end

  defp approved_grant(subject, client) do
    {:ok, _device_code, _user_code, pending_grant} =
      ApiKeys.open_device_grant([client], %RequestContext{})

    {:ok, grant} = ApiKeys.approve_device_grant(pending_grant, subject)
    grant
  end

  defp mark_pending(membership) do
    {_token, digest} = Crypto.user_invite_token()

    membership
    |> Ecto.Changeset.change(invitation_token_digest: digest, invitation_accepted_at: nil)
    |> Repo.update!()
  end
end
