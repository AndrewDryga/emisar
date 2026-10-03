defmodule Emisar.Auth.UserToken.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth.UserToken
  alias Emisar.{Crypto, Fixtures}

  describe "session/5 and sso_session/6 store only the digest and owner ids" do
    test "an email-code session carries its Member, workspace and browser digests, never a raw token" do
      member = Fixtures.Memberships.create_membership()
      {raw, digest} = Crypto.session_token()
      browser_digest = Crypto.hash("browser-id")

      assert {:ok, %UserToken{} = session} =
               member
               |> UserToken.Changeset.session(digest, browser_digest, %{ip_address: "::1"}, nil)
               |> Repo.insert()

      assert session.context == "session"
      assert session.auth_method == :magic_link
      assert session.account_id == member.account_id
      assert session.membership_id == member.id
      assert session.token == digest
      assert session.browser_digest == browser_digest
      assert session.metadata == %{"ip_address" => "::1"}
      assert is_nil(session.user_identity_id)
      assert is_nil(session.mfa_verified_at)
      refute inspect(session) =~ raw
      refute inspect(session) =~ Base.encode64(digest)
    end

    test "a verified factor binds the session to the Member's current enrollment" do
      member =
        Fixtures.Memberships.create_membership()
        |> Fixtures.Memberships.set_mfa_state(
          mfa_secret: "JBSWY3DPEHPK3PXP",
          mfa_enabled_at: ~U[2026-01-01 00:00:00.000000Z]
        )

      {_raw, digest} = Crypto.session_token()
      verified_at = DateTime.utc_now()

      assert {:ok, session} =
               member
               |> UserToken.Changeset.session(digest, Crypto.hash("b"), %{}, verified_at)
               |> Repo.insert()

      assert session.mfa_verified_at == verified_at
      assert session.mfa_enrollment_verified_at == member.mfa_enabled_at
      assert %DateTime{} = session.local_mfa_expires_at
    end

    test "an SSO session freezes the identity's subject and the provider's issuer" do
      account = Fixtures.Accounts.create_account(plan: "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      {_raw, digest} = Crypto.session_token()

      assert {:ok, session} =
               member
               |> UserToken.Changeset.sso_session(
                 digest,
                 Crypto.hash("b"),
                 %{},
                 identity,
                 provider
               )
               |> Repo.insert()

      assert session.auth_method == :sso
      assert session.user_identity_id == identity.id
      assert session.sso_issuer == provider.issuer
      assert session.sso_provider_identifier == identity.provider_identifier
      assert is_nil(session.mfa_verified_at)
    end

    test "the row shape is enforced: a session names its Member and its proof matches its method" do
      account = Fixtures.Accounts.create_account(plan: "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      session = fn ->
        {_raw, digest} = Crypto.session_token()
        UserToken.Changeset.session(member, digest, Crypto.hash("b"), %{}, nil)
      end

      assert {:error, changeset} =
               session.()
               |> Ecto.Changeset.change(membership_id: nil, account_id: nil)
               |> Repo.insert()

      assert "is invalid" in errors_on(changeset).membership_id

      # The proof shape is a database backstop no builder reaches: an SSO claim
      # without its frozen route, or a route on an email-code session, cannot
      # be stored at all.
      for forged <- [
            [auth_method: :sso],
            [user_identity_id: identity.id],
            [sso_issuer: provider.issuer]
          ] do
        assert_raise Ecto.ConstraintError, ~r/auth_user_tokens_session_proof_check/, fn ->
          session.() |> Ecto.Changeset.change(forged) |> Repo.insert()
        end
      end
    end
  end

  describe "sign_up/4 is the one owner-less row" do
    test "stores the address and intent, and refuses a second pending code for the address" do
      {_raw, digest} = Crypto.session_token()
      intent = %{account_name: "Acme", full_name: "Ada"}

      assert {:ok, code} =
               digest
               |> UserToken.Changeset.sign_up("Ada@Example.test", 5, intent)
               |> Repo.insert()

      assert code.context == "sign_up"
      assert is_nil(code.account_id)
      assert is_nil(code.membership_id)
      assert code.metadata == %{"account_name" => "Acme", "full_name" => "Ada"}

      {_raw, other_digest} = Crypto.session_token()

      assert {:error, changeset} =
               other_digest
               |> UserToken.Changeset.sign_up("ada@example.test", 5, intent)
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).sent_to
    end

    test "no other context may be owner-less" do
      {_raw, digest} = Crypto.session_token()
      member = Fixtures.Memberships.create_membership()

      assert {:error, changeset} =
               member
               |> UserToken.Changeset.magic_link(digest, 5)
               |> Ecto.Changeset.change(membership_id: nil, account_id: nil)
               |> Repo.insert()

      assert "is invalid" in errors_on(changeset).membership_id
    end
  end
end
