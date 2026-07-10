defmodule EmisarWeb.MfaQrTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MfaQr

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
