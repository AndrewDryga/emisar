defmodule EmisarWeb.MfaQrTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MfaQr

  test "the manual setup key decodes to the same secret used by the QR" do
    secret = <<0, 1, 2, 255, 128, 0>>
    key = MfaQr.setup_key(secret)
    assert Base.decode32!(key, padding: false) == secret
    assert MfaQr.provisioning_uri("op@example.com", secret) =~ "?secret=#{key}&issuer=emisar"
    refute key =~ "="
  end

  test "encodes the account name in the provisioning URI" do
    assert MfaQr.provisioning_uri("op@example.com", "ABC234") ==
             "otpauth://totp/emisar:op%40example.com?secret=IFBEGMRTGQ&issuer=emisar"
  end

  test "email delimiters cannot alter the provisioning query" do
    uri = MfaQr.provisioning_uri("ops&issuer=other@example.com", "ABC234")

    assert uri ==
             "otpauth://totp/emisar:ops%26issuer%3Dother%40example.com?secret=IFBEGMRTGQ&issuer=emisar"
  end
end
