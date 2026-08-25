defmodule Emisar.SSO.IssuerUrl do
  @moduledoc """
  Validates an operator-supplied OIDC issuer URL before we fetch its discovery
  document. The issuer is attacker-influenceable — a `manage_sso` admin types it —
  and both the "Test connection" capstone and every real login fetch
  `<issuer>/.well-known/openid-configuration` from the portal's egress, so an
  unguarded issuer is an SSRF primitive (cloud metadata, loopback, internal
  RFC-1918 hosts). We require https and reject hosts that are a loopback / private /
  link-local / unique-local / metadata IP literal, or `localhost`. Credentials,
  query parameters, and fragments are refused because they are not part of an
  OIDC issuer identifier and can carry secrets into fetches and audit history.

  Hostnames are intentionally not resolved during this URL-shape check: a second
  lookup at fetch time would create a rebinding window. `Emisar.SSO.OIDC.Guard`
  resolves the name at CONNECT time, applies the shared public-address policy,
  and dials that exact approved address while the HTTP client still verifies the
  certificate against the requested hostname.
  """

  alias Emisar.PublicAddress

  @doc """
  Check an issuer URL. `{:ok, issuer}` when it's a fetchable https URL whose host
  isn't a blocked SSRF target; `{:error, :invalid_issuer}` (not https, no host,
  or credentials/query/fragment present) or `{:error, :blocked_issuer}` (a
  private/loopback/metadata target) otherwise.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid_issuer | :blocked_issuer}
  def validate(issuer) when is_binary(issuer) do
    case validate_url(issuer, false) do
      :ok -> {:ok, issuer}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_issuer), do: {:error, :invalid_issuer}

  @doc """
  Check an endpoint the DISCOVERY DOCUMENT handed us. It has the same HTTPS,
  public-host, no-credentials policy as the issuer. A fixed query string is
  allowed because OAuth endpoints may define one; fragments remain invalid.

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
    validate_url(url, true)
  end

  def validate_endpoint(_url), do: {:error, :invalid_issuer}

  defp validate_url(url, allow_query?) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: query,
        fragment: nil
      }
      when is_binary(host) and host != "" ->
        cond do
          not allow_query? and not is_nil(query) -> {:error, :invalid_issuer}
          blocked_host?(host) -> {:error, :blocked_issuer}
          true -> :ok
        end

      _ ->
        {:error, :invalid_issuer}
    end
  end

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
      {:ok, ip} -> not PublicAddress.global_unicast?(ip)
      # Hostnames are resolved, judged, and pinned by the connect-time Guard; URL
      # validation deliberately does not perform a weaker preflight lookup.
      {:error, _} -> false
    end
  end
end
