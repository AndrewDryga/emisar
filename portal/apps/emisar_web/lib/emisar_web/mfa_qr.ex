defmodule EmisarWeb.MfaQr do
  @moduledoc """
  TOTP provisioning helpers shared by the MFA enrollment surfaces
  (ProfileLive's voluntary setup and MfaSetupLive's enforced
  interstitial): the `otpauth://` URI an authenticator app understands
  and its QR rendering.
  """

  @issuer "emisar"

  def setup_key(secret) when is_binary(secret), do: Base.encode32(secret, padding: false)

  @doc """
  The `otpauth://` URI for one Member's factor. The factor belongs to one Member
  in one workspace, so the authenticator entry names both:
  `emisar:<Workspace> (<email or name>)`.
  """
  def provisioning_uri(account_name, member_label, secret)
      when is_binary(account_name) and is_binary(member_label) and is_binary(secret) do
    encoded = setup_key(secret)
    label = encoded_label("#{account_name} (#{member_label})")
    "otpauth://totp/#{@issuer}:#{label}?secret=#{encoded}&issuer=#{@issuer}"
  end

  # A QR code holds at most 2,952 bytes and a name may be 255 characters of
  # four-byte emoji, which percent-encode to 3,060. The label is only what the
  # authenticator app shows, so it gives up characters from its end until it
  # fits; the secret and issuer never do.
  @max_label_bytes 512

  defp encoded_label(text) do
    encoded = URI.encode(text, &URI.char_unreserved?/1)

    if byte_size(encoded) <= @max_label_bytes,
      do: encoded,
      else: text |> String.graphemes() |> Enum.drop(-1) |> Enum.join() |> encoded_label()
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
