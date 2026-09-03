defmodule Emisar.RevokePreAcceptanceCredentialsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, ApiKeys, Crypto, Fixtures, Repo, RequestContext}
  alias Emisar.ApiKeys.{ApiKey, DeviceGrant}
  alias Emisar.Repo.Migrations.RevokeInvitationCredentials

  unless Code.ensure_loaded?(RevokeInvitationCredentials) do
    Code.require_file(
      Path.expand(
        "../../priv/repo/migrations/20261019000001_revoke_invitation_credentials.exs",
        __DIR__
      )
    )
  end

  test "the forward repair revokes every ambiguous credential on an accepted invitation" do
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

    assert %{num_rows: 3} = Repo.query!(RevokeInvitationCredentials.api_key_repair_sql())

    assert %{num_rows: 3} =
             Repo.query!(RevokeInvitationCredentials.device_grant_repair_sql())

    assert Repo.reload!(bad_key).revoked_at
    assert Repo.reload!(good_key).revoked_at
    assert Repo.reload!(pending_key).revoked_at
    assert is_nil(Repo.reload!(direct_key).revoked_at)
    assert Repo.reload!(bad_grant).status == :denied
    assert Repo.reload!(good_grant).status == :denied
    assert Repo.reload!(pending_grant).status == :denied
    assert Repo.reload!(direct_grant).status == :approved

    assert %{num_rows: 0} = Repo.query!(RevokeInvitationCredentials.api_key_repair_sql())

    assert %{num_rows: 0} =
             Repo.query!(RevokeInvitationCredentials.device_grant_repair_sql())
  end

  test "the database rejects an old API-key writer while an invitation is pending" do
    {user, account, membership, _subject} = member_with_subject()
    mark_pending(membership)
    {_raw, prefix, hash} = Crypto.mint("emk-", 12)

    changeset =
      ApiKey.Changeset.create(
        account.id,
        user.id,
        membership.id,
        prefix,
        hash,
        %{name: "old writer"}
      )

    assert_raise Postgrex.Error, ~r/unresolved invitation cannot mint an API key/, fn ->
      Repo.insert!(changeset)
    end
  end

  test "the database rejects an old device-approval writer while an invitation is pending" do
    {user, account, membership, _subject} = member_with_subject()

    {:ok, _device_code, _user_code, grant} =
      ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

    mark_pending(membership)

    assert_raise Postgrex.Error, ~r/unresolved invitation cannot approve a device grant/, fn ->
      grant
      |> DeviceGrant.Changeset.approve(account.id, user.id, membership.id)
      |> Repo.update!()
    end
  end

  test "the database revokes credentials on any transition out of pending" do
    {user, account, membership, subject} = member_with_subject()

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

    grant = approved_grant(subject, "claude-code")
    mark_pending(membership)

    Repo.query!(
      """
      UPDATE account_memberships
      SET invitation_accepted_at = NOW(),
          updated_at = NOW()
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(membership.id)]
    )

    assert Repo.reload!(key).revoked_at
    assert Repo.reload!(grant).status == :denied
    refute Accounts.membership_invitation_pending?(Repo.reload!(membership))
  end

  defp approved_grant(subject, client) do
    {:ok, _device_code, _user_code, pending_grant} =
      ApiKeys.open_device_grant([client], %RequestContext{})

    {:ok, grant} = ApiKeys.approve_device_grant(pending_grant, subject)
    grant
  end

  defp member_with_subject do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    {user, account, membership, Fixtures.Subjects.membership_subject(membership)}
  end

  defp mark_pending(membership) do
    {_token, digest} = Crypto.user_invite_token()

    membership
    |> Ecto.Changeset.change(invitation_token_digest: digest, invitation_accepted_at: nil)
    |> Repo.update!()
  end
end
