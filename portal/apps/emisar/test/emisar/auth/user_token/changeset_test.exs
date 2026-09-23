defmodule Emisar.Auth.UserToken.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth.UserToken
  alias Emisar.{Crypto, Fixtures}

  describe "member_session/4" do
    test "only an SSO session with no personal or local-factor proof omits the personal login" do
      account = Fixtures.Accounts.create_account(plan: "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      membership = Fixtures.Memberships.create_unlinked_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          membership: membership
        )

      member_session = fn ->
        {_raw, digest} = Crypto.session_token()
        UserToken.Changeset.member_session(digest, %{}, nil, identity.id)
      end

      assert {:ok, %UserToken{user_id: nil, context: "session", auth_method: :sso}} =
               Repo.insert(member_session.())

      now = DateTime.utc_now()

      for forged <- [
            [context: "magic_link"],
            [auth_method: :magic_link],
            [personal_proved_at: now],
            [mfa_enrollment_verified_at: now]
          ] do
        assert {:error, changeset} =
                 member_session.() |> Ecto.Changeset.change(forged) |> Repo.insert()

        assert "is invalid" in errors_on(changeset).user_id
      end
    end
  end
end
