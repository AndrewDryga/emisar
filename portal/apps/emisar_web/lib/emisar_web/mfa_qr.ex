defmodule EmisarWeb.MfaQr do
  @moduledoc """
  TOTP provisioning helpers shared by the MFA enrollment surfaces
  (ProfileLive's voluntary setup and MfaSetupLive's enforced
  interstitial): the `otpauth://` URI an authenticator app understands
  and its QR rendering.
  """

  @issuer "emisar"

  def provisioning_uri(email, secret) when is_binary(email) and is_binary(secret) do
    encoded = Base.encode32(secret, padding: false)
    label = URI.encode(email, &URI.char_unreserved?/1)
    "otpauth://totp/#{@issuer}:#{label}?secret=#{encoded}&issuer=#{@issuer}"
  end

  # `viewbox: true` (singular w/o explicit width) emits a viewBox-only
  # SVG whose intrinsic size collapses to 0 in some browsers — render
  # both attributes so it works everywhere. 240px = comfortable scan
  # distance on a phone camera held a foot from the screen.
  def svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 240, background_color: "#ffffff", color: "#000000")
  end
end
