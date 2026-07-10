defmodule Emisar.InvitationTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Fixtures

  defp inviter_subject(account) do
    inviter = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

    {inviter, Fixtures.Subjects.subject_for(inviter, account, role: :owner)}
  end

  describe "invite_user_to_account/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      %{account: account, subject: subject}
    end

    test "creates a placeholder user for a brand-new email", %{subject: subject} do
      assert {:ok,
              %{
                membership: membership,
                user: invitee,
                invitation_token: token
              }} = Accounts.invite_user_to_account("new@example.test", "admin", subject)

      assert invitee.email == "new@example.test"
      assert is_binary(token)
      assert byte_size(token) > 16
      assert membership.role == :admin
      # Only the digest is at rest — a DB leak must not expose the live link.
      assert membership.invitation_token_digest == Emisar.Crypto.user_invite_token_digest(token)
      refute membership.invitation_token_digest == token
      assert is_nil(membership.invitation_accepted_at)
    end

    test "reuses an existing user when the email already exists", %{subject: subject} do
      existing = Fixtures.Users.create_user(email: "alice@example.test")

      assert {:ok, %{user: invitee}} =
               Accounts.invite_user_to_account("alice@example.test", "operator", subject)

      assert invitee.id == existing.id
    end

    test "trims the email; the citext column owns case-insensitive identity", %{subject: subject} do
      assert {:ok, %{user: invitee}} =
               Accounts.invite_user_to_account(
                 "  HELLO@Example.Test  ",
                 "viewer",
                 subject
               )

      # Stored as typed (whitespace trimmed) — no app-side downcase.
      assert invitee.email == "HELLO@Example.Test"

      # A differently-cased invite resolves to the SAME user row: the
      # unique citext index is the guarantee, not normalization.
      other_account = Fixtures.Accounts.create_account()
      {_inviter, other_subject} = inviter_subject(other_account)

      assert {:ok, %{user: same_user}} =
               Accounts.invite_user_to_account("hello@example.test", "viewer", other_subject)

      assert same_user.id == invitee.id
    end

    test "rolls back when the user already belongs to the account", %{
      account: account,
      subject: subject
    } do
      existing = Fixtures.Users.create_user()

      _existing_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: existing.id)

      assert {:error, :already_member} =
               Accounts.invite_user_to_account(existing.email, "admin", subject)
    end
  end

  describe "fetch_invitation_by_token/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership, invitation_token: token, user: invitee}} =
        Accounts.invite_user_to_account("bob@example.test", "admin", subject)

      %{membership: membership, token: token, invitee: invitee, account: account}
    end

    test "preloads are caller-driven: opted-in assocs load, the default loads none", %{
      token: token,
      account: account,
      invitee: invitee
    } do
      assert {:ok, membership} =
               Accounts.fetch_invitation_by_token(token, preload: [:account, :user])

      assert membership.account.id == account.id
      assert membership.user.id == invitee.id

      # Without the opt the row comes back bare — callers that only need
      # the membership itself pay for no joins.
      assert {:ok, bare} = Accounts.fetch_invitation_by_token(token)
      assert %Ecto.Association.NotLoaded{} = bare.account
      assert %Ecto.Association.NotLoaded{} = bare.user
    end

    test "returns :not_found for an unknown token" do
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token("bogus")
    end

    test "returns :not_found for nil / empty token (no leaky scan)" do
      # the lookup's head requires a non-empty binary
      # (`is_binary(token) and byte_size(token) > 0`); a nil or "" token falls to
      # the catch-all `:not_found` clause rather than scanning. So an empty token
      # param can never resolve an invite — the accept LV mount turns that
      # `:not_found` into the cause-neutral bounce to /sign_in.
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(nil)
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token("")
    end

    test "an expired invitation no longer resolves", %{membership: membership, token: token} do
      # inserted_at IS the invite time (re-invites insert fresh rows) —
      # backdate it past the validity window.
      nine_days_ago = DateTime.add(DateTime.utc_now(), -9 * 24 * 3600, :second)
      {:ok, _} = membership |> Ecto.Changeset.change(inserted_at: nine_days_ago) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(token)
    end

    # the 7-day window (Membership.Query.invitation_not_expired).
    test "an invite just inside 7 days still resolves", %{membership: membership, token: token} do
      almost_seven = DateTime.add(DateTime.utc_now(), -(7 * 24 * 3600 - 3600), :second)
      {:ok, _} = membership |> Ecto.Changeset.change(inserted_at: almost_seven) |> Repo.update()

      assert {:ok, _} = Accounts.fetch_invitation_by_token(token)
    end

    test "an invite just past 7 days no longer resolves", %{membership: membership, token: token} do
      just_over_seven = DateTime.add(DateTime.utc_now(), -(7 * 24 * 3600 + 3600), :second)

      {:ok, _} =
        membership |> Ecto.Changeset.change(inserted_at: just_over_seven) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(token)
    end
  end

  describe "mark_invitation_accepted/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      invitee = Fixtures.Users.create_user()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(invitee.email, "viewer", subject)

      %{membership: membership, invitee: invitee}
    end

    test "in-place accept burns the token; a replay is :not_found", %{
      membership: membership,
      invitee: invitee
    } do
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, invitee)
      assert accepted.invitation_accepted_at
      assert is_nil(accepted.invitation_token_digest)

      # The stale struct replayed: the fresh row is no longer pending.
      assert {:error, :not_found} = Accounts.mark_invitation_accepted(membership, invitee)
    end

    test "a different signed-in user cannot burn the invitation", %{membership: membership} do
      bystander = Fixtures.Users.create_user()

      assert {:error, :unauthorized} = Accounts.mark_invitation_accepted(membership, bystander)
    end
  end

  describe "accept_invitation/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account("carol@example.test", "operator", subject)

      %{membership: membership}
    end

    test "sets the user's full_name, confirms, clears the token", %{
      membership: membership
    } do
      attrs = %{"full_name" => "Carol"}

      assert {:ok, %{user: user, membership: accepted_membership}} =
               Accounts.accept_invitation(membership, attrs)

      assert user.full_name == "Carol"
      # Accepting the invite proves email ownership — the user is confirmed and
      # signs in by magic link (no password is set).
      assert user.confirmed_at
      assert is_nil(accepted_membership.invitation_token_digest)
      assert accepted_membership.invitation_accepted_at
    end

    test "a second accept with the same (stale) membership loses — first wins", %{
      membership: membership
    } do
      assert {:ok, %{user: user}} =
               Accounts.accept_invitation(membership, %{"full_name" => "Carol"})

      # A second link holder submits after the token is burnt: judged on
      # the locked fresh row, it must fail — and crucially must NOT have
      # overwritten the winner's full_name.
      assert {:error, :not_found} =
               Accounts.accept_invitation(membership, %{"full_name" => "Mallory"})

      assert {:ok, %{full_name: "Carol"}} = Emisar.Users.fetch_user_by_id(user.id)
    end
  end
end
