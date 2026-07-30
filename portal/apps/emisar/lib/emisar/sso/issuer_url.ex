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

  @doc """
  Check an endpoint the DISCOVERY DOCUMENT handed us, under the same policy as
  the issuer itself.

  Validating only the issuer stopped short of the actual fetches: a perfectly
  ordinary public HTTPS issuer can return a discovery document whose `jwks_uri`
  or `token_endpoint` points at `http://127.0.0.1`, an RFC-1918 address, or the
  cloud metadata service — and the worker GETs the JWKS and POSTs the token
  exchange to whatever it was handed. The issuer being trustworthy is not the
  same claim as its document being trustworthy.

  `:undefined`/`nil` is an absent OPTIONAL endpoint, which is not a target.
  """
  @spec validate_endpoint(term()) :: :ok | {:error, :invalid_issuer | :blocked_issuer}
  def validate_endpoint(nil), do: :ok
  def validate_endpoint(:undefined), do: :ok

  def validate_endpoint(url) when is_list(url),
    do: url |> IO.iodata_to_binary() |> validate_endpoint()

  def validate_endpoint(url) when is_binary(url) do
    case validate(url) do
      {:ok, _url} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_endpoint(_url), do: {:error, :invalid_issuer}

  @doc """
  Is this a peer address we may open a connection to?

  The URL policy above deliberately does not resolve hostnames — pre-resolving is
  TOCTOU-prone. This is the other half, asked at CONNECT time by
  `Emisar.SSO.OIDC.Guard` about an address it has just resolved and is about to
  dial. Same address ranges, one definition.
  """
  @spec address_allowed?(:inet.ip_address()) :: boolean()
  def address_allowed?(address) when is_tuple(address), do: not blocked_ip?(address)

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

  # An ALLOW policy over global unicast, not a denylist. A denylist grew holes —
  # 100.64.0.0/10 (carrier NAT, and Alibaba's 100.100.100.200 metadata endpoint),
  # 198.18.0.0/15 benchmarking fabric, multicast and reserved space all fell
  # through to allowed, which contradicts the boundary this module claims to draw.
  # Anything not provably a public address is refused.
  #
  # IPv4 special-purpose ranges, per the IANA registry.
  defp blocked_ip?({0, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({100, b, _, _}) when b in 64..127, do: true
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_ip?({192, 0, 0, _}), do: true
  defp blocked_ip?({192, 0, 2, _}), do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({198, b, _, _}) when b in 18..19, do: true
  defp blocked_ip?({198, 51, 100, _}), do: true
  defp blocked_ip?({203, 0, 113, _}), do: true
  # Multicast, and everything from 240/4 up including the broadcast address.
  defp blocked_ip?({a, _, _, _}) when a >= 224, do: true

  # IPv6. Only global unicast (2000::/3) is allowed, which refuses the unspecified
  # and loopback addresses, unique-local, link-local, multicast, and the
  # transition ranges — 6to4 and NAT64 can both encode an internal v4 address.
  defp blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: blocked_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  # 64:ff9b::/96 NAT64 — the embedded v4 address decides.
  defp blocked_ip?({0x64, 0xFF9B, 0, 0, 0, 0, a, b}),
    do: blocked_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  # 2002::/16 6to4 — likewise; the v4 address sits in the next two groups.
  defp blocked_ip?({0x2002, a, b, _, _, _, _, _}),
    do: blocked_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp blocked_ip?({h, _, _, _, _, _, _, _}) when h >= 0x2000 and h <= 0x3FFF, do: false
  defp blocked_ip?({_, _, _, _, _, _, _, _}), do: true

  defp blocked_ip?(_ip), do: false
end
