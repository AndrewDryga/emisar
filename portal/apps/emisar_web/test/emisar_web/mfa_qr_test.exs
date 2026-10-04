defmodule EmisarWeb.MfaQrTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MfaQr

  test "the manual setup key decodes to the same secret used by the QR" do
    secret = <<0, 1, 2, 255, 128, 0>>
    key = MfaQr.setup_key(secret)
    assert Base.decode32!(key, padding: false) == secret

    assert MfaQr.provisioning_uri("Acme", "op@example.com", secret) =~
             "?secret=#{key}&issuer=emisar"

    refute key =~ "="
  end

  test "names the workspace and the Member in the authenticator entry" do
    assert MfaQr.provisioning_uri("Acme Ops", "op@example.com", "ABC234") ==
             "otpauth://totp/emisar:Acme%20Ops%20%28op%40example.com%29?secret=IFBEGMRTGQ&issuer=emisar"
  end

  test "workspace and email delimiters cannot alter the provisioning query" do
    uri = MfaQr.provisioning_uri("Ops&issuer=evil", "ops&issuer=other@example.com", "ABC234")

    assert uri ==
             "otpauth://totp/emisar:Ops%26issuer%3Devil%20%28ops%26issuer%3Dother%40example.com%29?secret=IFBEGMRTGQ&issuer=emisar"
  end

  test "a 255-emoji name still renders a scannable code with the whole secret" do
    secret = :crypto.strong_rand_bytes(20)
    uri = MfaQr.provisioning_uri("Acme", String.duplicate("😀", 255), secret)

    assert uri =~ "?secret=#{MfaQr.setup_key(secret)}&issuer=emisar"
    assert MfaQr.svg(uri) =~ "<svg"
  end
end
