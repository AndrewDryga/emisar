defmodule Emisar.MfaEnforcementTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, RequestContext}
  alias Emisar.Accounts.Account
  alias Emisar.Fixtures

  describe "update_account/3 (require_mfa)" do
    test "owner can enable; flips the column" do
      user = Fixtures.Users.create_user()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          user
        )

      refute account.settings.require_mfa
      owner_subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {user, _codes} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), owner_subject)
      owner_subject = Fixtures.Subjects.subject_for(user, account, mfa: true)

      {:ok, account} =
        Accounts.update_account(account, %{settings: %{require_mfa: true}}, owner_subject)

      assert account.settings.require_mfa

      {:ok, account} =
        Accounts.update_account(account, %{settings: %{require_mfa: false}}, owner_subject)

      refute account.settings.require_mfa
    end

    test "an operator is rejected (owners + admins manage security settings)" do
      owner = Fixtures.Users.create_user()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          owner
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      operator_user = Fixtures.Users.create_user()

      {:ok, %{membership: m, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: operator_user.email,
            role: "operator",
            runner_access_mode: "all"
          ),
          owner_subject
        )

      {:ok, _} = Accounts.mark_invitation_accepted(m, token, operator_user)
      operator_subject = Fixtures.Subjects.subject_for(operator_user, account, role: :operator)

      assert Accounts.update_account(
               account,
               %{settings: %{require_mfa: true}},
               operator_subject
             ) == {:error, :unauthorized}
    end
  end

  describe "require_mfa for a Member without a personal login" do
    test "it links a personal login first, then meets the requirement with local TOTP" do
      account = Fixtures.Accounts.create_account(plan: "team")
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

      member = Fixtures.Memberships.create_unlinked_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        )

      donor_raw = Fixtures.Auth.create_member_session_token!(member, identity)
      {:ok, donor} = Auth.fetch_session_by_token(donor_raw)
      unlinked = Fixtures.Subjects.unlinked_member_subject(member, donor_raw)
      assert Accounts.ensure_account_compliant(account, unlinked) == {:error, :mfa_required}

      user = Fixtures.Users.create_user()

      link = %{
        account_id: account.id,
        membership_id: member.id,
        identity_id: identity.id,
        donor_token_id: donor.id
      }

      assert {:ok, %{token_id: token_id, nonce: nonce}} =
               Auth.request_magic_link(user, %RequestContext{}, member_link: link)

      assert_received {:email, sent}
      [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      assert {:ok, _user} = Auth.verify_magic_link(token_id, secret, nonce)

      assert {:ok, _user, raw, {:linked, _account}, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 token_id,
                 nil,
                 %RequestContext{},
                 donor.token
               )

      {:ok, session} = Auth.fetch_session_by_token(raw)
      linked = Fixtures.Subjects.subject_for(user, account, session: session)
      assert Accounts.ensure_account_compliant(account, linked) == {:error, :mfa_required}

      {:ok, user, _codes} =
        Fixtures.Users.enroll_mfa(Auth.generate_mfa_secret(), linked, session_token: raw)

      {:ok, session} = Auth.fetch_session_by_token(raw)
      proved = Fixtures.Subjects.subject_for(user, account, session: session)
      assert proved.mfa
      assert Accounts.ensure_account_compliant(account, proved) == :ok
    end
  end

  describe "require_mfa default" do
    test "new accounts default to require_mfa: false (signup never blocks)" do
      user = Fixtures.Users.create_user()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Fresh", slug: "fresh-#{System.unique_integer()}", plan: "free"},
          user
        )

      assert account.settings.require_mfa == false
      assert %Account{} = account
    end
  end
end
