defmodule Emisar.MfaEnforcementTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth}
  alias Emisar.Fixtures

  describe "update_account/3 (require_mfa)" do
    test "an enrolled owner can enable it and flips the column" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      refute account.settings.require_mfa

      {owner, _codes} =
        Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), owner_subject)

      owner_subject = Fixtures.Subjects.subject_for(owner, mfa: true)

      {:ok, account} =
        Accounts.update_account(account, %{settings: %{require_mfa: true}}, owner_subject)

      assert account.settings.require_mfa

      {:ok, account} =
        Accounts.update_account(account, %{settings: %{require_mfa: false}}, owner_subject)

      refute account.settings.require_mfa
    end

    test "an operator is rejected (owners + admins manage security settings)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      operator_subject = Fixtures.Subjects.subject_for(operator)

      assert Accounts.update_account(
               account,
               %{settings: %{require_mfa: true}},
               operator_subject
             ) == {:error, :unauthorized}

      refute Repo.reload!(account).settings.require_mfa
    end
  end

  describe "ensure_account_compliant/2 (require_mfa)" do
    test "an SSO-only Member is held back until it enrolls, through its IdP" do
      account = Fixtures.Accounts.create_account(plan: "team")
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

      member =
        Fixtures.Memberships.create_membership(account_id: account.id, email_verified?: false)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      sso =
        Fixtures.Subjects.subject_for(member, auth_method: :sso, user_identity_id: identity.id)

      assert Accounts.ensure_account_compliant(account, sso) == {:error, :mfa_required}
      # No verified address, so the inbox code is not a way in; the IdP is.
      assert {:ok, %{enrollment_proof: :sso}} = Auth.mfa_facts(sso)
      assert Auth.issue_mfa_enrollment_code(sso) == {:error, :email_unavailable}
    end

    test "a Member with a verified address meets the requirement with the inbox code and TOTP" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      member = Fixtures.Memberships.create_membership(account_id: account.id)
      raw = Fixtures.Auth.create_session_token!(member)
      subject = Fixtures.Subjects.subject_for(member, session: raw)

      assert Accounts.ensure_account_compliant(account, subject) == {:error, :mfa_required}

      {:ok, member, _codes} =
        Fixtures.Memberships.enroll_mfa(Auth.generate_mfa_secret(), subject, session_token: raw)

      proved = Fixtures.Subjects.subject_for(member, session: raw)
      assert proved.mfa
      assert Accounts.ensure_account_compliant(account, proved) == :ok
    end
  end
end
