defmodule EmisarWeb.OIDCIdentityHandoffTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.OIDCIdentityHandoff

  test "round-trips only a signed map" do
    payload = %{
      actor_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      provider_id: Ecto.UUID.generate(),
      purpose: :link,
      proof: "proof"
    }

    handoff = OIDCIdentityHandoff.sign(payload)

    assert OIDCIdentityHandoff.verify(handoff) == {:ok, payload}
    assert OIDCIdentityHandoff.verify(handoff <> "tampered") == {:error, :invalid}
    assert OIDCIdentityHandoff.verify(nil) == {:error, :invalid}
  end

  test "leaves a signed map's semantic validation to the controller" do
    handoff = OIDCIdentityHandoff.sign(%{not: "an identity handoff"})

    assert {:ok, %{not: "an identity handoff"}} = OIDCIdentityHandoff.verify(handoff)
  end
end
