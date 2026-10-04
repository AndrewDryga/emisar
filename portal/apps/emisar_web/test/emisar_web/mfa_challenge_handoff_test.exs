defmodule EmisarWeb.MfaChallengeHandoffTest do
  @moduledoc """
  The handoff carries the opaque proof `Auth.verify_mfa_challenge/3` returned
  from `MfaChallengeLive` to the controller that can set the session cookie.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth
  alias EmisarWeb.MfaChallengeHandoff

  describe "sign/2 + verify/1" do
    test "a verified proof round-trips unchanged with the code it was earned on" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      token_id = Ecto.UUID.generate()

      assert {:ok, {^proof, ^token_id}} =
               proof |> MfaChallengeHandoff.sign(token_id) |> MfaChallengeHandoff.verify()

      assert Auth.mfa_proof_membership_id(proof) == member.id
    end

    test "a handoff that names no verified code is refused" do
      bare_proof = Phoenix.Token.sign(EmisarWeb.Endpoint, "mfa signin handoff", "proof")
      assert MfaChallengeHandoff.verify(bare_proof) == {:error, :invalid}
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
