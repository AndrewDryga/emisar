defmodule Emisar.SSO.IssuerUrl do
  @moduledoc """
  Validates an operator-supplied OIDC issuer URL before we fetch its discovery
  document. The issuer is attacker-influenceable — a `manage_sso` admin types it —
  and both the "Test connection" capstone and every real login fetch
  `<issuer>/.well-known/openid-configuration` from the portal's egress, so an
  unguarded issuer is an SSRF primitive (cloud metadata, loopback, internal
  RFC-1918 hosts). We require https and reject hosts that are a loopback / private /
  link-local / unique-local / metadata IP literal, or `localhost`.

  A hostname that *resolves* to an internal IP isn't blocked here — pre-resolving
  is TOCTOU-prone (rebinding between check and fetch). The outbound request verifies
  the peer cert + hostname against the system CA store, so reaching an internal
  service additionally needs a valid public cert for that name; that residual risk
  is accepted for a trusted, paid-plan, `manage_sso`-gated action.
  """

  @doc """
  Check an issuer URL. `{:ok, issuer}` when it's a fetchable https URL whose host
  isn't a blocked SSRF target; `{:error, :invalid_issuer}` (not https, or no host)
  or `{:error, :blocked_issuer}` (a private/loopback/metadata target) otherwise.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid_issuer | :blocked_issuer}
  def validate(issuer) when is_binary(issuer) do
    case URI.parse(issuer) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        if blocked_host?(host), do: {:error, :blocked_issuer}, else: {:ok, issuer}

      _ ->
        {:error, :invalid_issuer}
    end
  end

  def validate(_issuer), do: {:error, :invalid_issuer}

  defp blocked_host?(host) do
    host = String.downcase(host)

    cond do
      host == "localhost" -> true
      String.ends_with?(host, ".localhost") -> true
      true -> blocked_ip_literal?(host)
    end
  end

  defp blocked_ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> blocked_ip?(ip)
      # A hostname (not an IP literal): TLS peer/hostname verification + the
      # operator-trust gate handle it; we don't pre-resolve (TOCTOU).
      {:error, _} -> false
    end
  end

  # IPv4
  defp blocked_ip?({0, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  # IPv6
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped (::ffff:a.b.c.d) — re-check the embedded v4 address.
  defp blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: blocked_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp blocked_ip?({h, _, _, _, _, _, _, _}) when h >= 0xFC00 and h <= 0xFDFF, do: true
  defp blocked_ip?({h, _, _, _, _, _, _, _}) when h >= 0xFE80 and h <= 0xFEBF, do: true
  defp blocked_ip?(_ip), do: false
end
