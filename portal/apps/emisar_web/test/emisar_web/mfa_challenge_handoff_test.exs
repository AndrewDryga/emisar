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
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert {:ok, ^proof} = proof |> MfaChallengeHandoff.sign() |> MfaChallengeHandoff.verify()
      assert Auth.mfa_proof_membership_id(proof) == member.id
    end

    test "a forged, malformed, or non-binary handoff is refused" do
      assert MfaChallengeHandoff.verify("not-a-real-token") == {:error, :invalid}
      assert MfaChallengeHandoff.verify(nil) == {:error, :invalid}

      assert MfaChallengeHandoff.verify(%{membership_id: Ecto.UUID.generate()}) ==
               {:error, :invalid}
    end

    test "a handoff signed under a different salt does not verify" do
      forged =
        Phoenix.Token.sign(EmisarWeb.Endpoint, "some other salt", %{membership_id: "whoever"})

      assert MfaChallengeHandoff.verify(forged) == {:error, :invalid}
    end
  end
end
