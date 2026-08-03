defmodule EmisarWeb.MfaChallengeHandoffTest do
  @moduledoc """
  The handoff carries the opaque proof `Auth.verify_mfa_challenge/3` returned
  from `MfaChallengeLive` to the controller that can set the session cookie.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth
  alias EmisarWeb.MfaChallengeHandoff

  describe "sign/1 + verify/1" do
    test "a verified proof round-trips unchanged" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, ^proof} = proof |> MfaChallengeHandoff.sign() |> MfaChallengeHandoff.verify()
      assert Auth.mfa_proof_user_id(proof) == user.id
    end

    test "a forged, malformed, or non-binary handoff is refused" do
      assert {:error, :invalid} = MfaChallengeHandoff.verify("not-a-real-token")
      assert {:error, :invalid} = MfaChallengeHandoff.verify(nil)
      assert {:error, :invalid} = MfaChallengeHandoff.verify(%{user_id: Ecto.UUID.generate()})
    end

    test "a handoff signed under a different salt does not verify" do
      forged = Phoenix.Token.sign(EmisarWeb.Endpoint, "some other salt", %{user_id: "whoever"})

      assert {:error, :invalid} = MfaChallengeHandoff.verify(forged)
    end
  end
end
