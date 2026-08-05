defmodule Emisar.OAuth.ClientMetadataDocument do
  @moduledoc """
  Resolves an OAuth Client ID Metadata Document (CIMD) — the MCP-preferred
  client registration mechanism that replaces deprecated Dynamic Client
  Registration. The client identifies itself by an HTTPS URL; the authorization
  server fetches that URL and reads the client's metadata from it.

  That makes this the one place emisar dereferences a caller-supplied URL. The
  authorization endpoint that reaches it requires a signed-in operator and is
  rate limited, so this is not an open relay — but the URL is still chosen by
  the caller, so the module is written as an SSRF boundary first and a JSON
  fetcher second:

    * the URL must be `https`, carry a path component, and carry no fragment,
      userinfo, or non-default credentials-bearing shape;
    * every address the host resolves to must be publicly routable — a single
      private, loopback, link-local (including the cloud metadata address),
      unique-local, or reserved answer rejects the whole fetch, so a split
      A/AAAA answer cannot smuggle an internal target past a public one;
    * redirects are never followed, because the first hop is the only URL whose
      address set was validated;
    * the response must be JSON, arrives under a hard byte cap enforced while
      streaming, and is bounded by a short timeout.

  The address check PINS the connection: `validate_destination/1` returns the one
  address it approved, and the fetch dials exactly that. It used to return `:ok`
  and let the HTTP client resolve again, which is a rebinding window — a record
  with a zero TTL could point somewhere else between the two lookups.

  That is why this calls Mint directly rather than going through Finch: Mint
  takes both an address to dial and a `:hostname` to present for SNI and to
  verify the certificate against, and Finch has no per-request hook for it.
  Nothing about TLS is relaxed — the hostname check still runs, against the name
  in the URL, and a certificate that does not verify fails the fetch.

  The document is re-fetched on each authorization rather than cached. The spec
  only asks that caching respect HTTP cache headers; always reading the live
  document means a client that rotates or revokes a redirect URI takes effect
  immediately, and authorization is a human-initiated, rate-limited flow, so the
  request volume is negligible.
  """

  @required_fields ~w(client_id client_name redirect_uris)

  @max_document_bytes 64 * 1024
  @timeout_ms 5_000

  @doc """
  Fetch and validate the metadata document published at `url`.

  Returns the decoded document on success. Every failure is a single opaque
  `{:error, reason}` for the caller to map to `invalid_client`; the reasons are
  distinct for logging, never for telling the caller which internal host
  answered.
  """
  @spec fetch(String.t()) :: {:ok, map()} | {:error, atom()}
  def fetch(url) when is_binary(url) do
    with :ok <- validate_url(url),
         {:ok, address} <- validate_destination(url),
         {:ok, body} <- get(url, address),
         {:ok, document} <- decode(body) do
      validate(document, url)
    end
  end

  def fetch(_url), do: {:error, :invalid_client_id}

  @doc """
  True when `client_id` is shaped like a Client ID Metadata Document URL rather
  than a server-minted DCR identifier. Used to pick the registration mechanism
  before any network work happens.
  """
  @spec metadata_url?(term()) :: boolean()
  def metadata_url?(client_id) when is_binary(client_id),
    do: String.starts_with?(client_id, "https://")

  def metadata_url?(_client_id), do: false

  # -- URL shape ------------------------------------------------------

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" and is_binary(path) and path != "" and path != "/" ->
        :ok

      _ ->
        {:error, :invalid_client_id}
    end
  end

  # -- SSRF boundary --------------------------------------------------

  # Resolve the host ourselves and judge every answer before the request goes
  # out. A hostname that resolves to any non-public address is refused outright.
  # Returns the ONE address the fetch will connect to, not just `:ok`.
  #
  # That is the whole fix: the check used to filter the answer and then let the
  # HTTP client resolve again, so a record with a zero TTL could point somewhere
  # else between the two lookups. Handing the approved address to the fetch
  # closes the window — the connection goes exactly where the check looked.
  #
  # `nil` means "resolve normally", which is the dev/test loopback path below.
  defp validate_destination(url) do
    host = URI.parse(url).host

    if allow_private_hosts?() do
      {:ok, nil}
    else
      case resolve(host) do
        {:ok, [_ | _] = addresses} ->
          # Every answer must be public — a split A/AAAA reply cannot smuggle an
          # internal target past a public one — and then the first is the one we
          # commit to.
          if Enum.all?(addresses, &public_address?/1),
            do: {:ok, hd(addresses)},
            else: {:error, :blocked_destination}

        _ ->
          {:error, :unresolvable_host}
      end
    end
  end

  # Dev and test serve their metadata documents from loopback, which the SSRF
  # boundary otherwise refuses. Deployment config only, defaulting to false —
  # production never sets it, and nothing tenant- or request-supplied can reach
  # it.
  defp allow_private_hosts? do
    :emisar
    |> Emisar.Config.get_env(__MODULE__, [])
    |> Keyword.get(:allow_private_hosts, false) == true
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    v4 = :inet.getaddrs(charlist, :inet)
    v6 = :inet.getaddrs(charlist, :inet6)

    case {v4, v6} do
      {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
      {{:ok, a}, _} -> {:ok, a}
      {_, {:ok, b}} -> {:ok, b}
      _ -> {:error, :nxdomain}
    end
  end

  # An IPv4-mapped or NAT64-embedded IPv6 address carries a v4 target in its low
  # 32 bits; judge the embedded address rather than the wrapper.
  defp public_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: public_address?(embedded_v4(ab, cd))

  defp public_address?({0x64, 0xFF9B, 0, 0, 0, 0, ab, cd}),
    do: public_address?(embedded_v4(ab, cd))

  defp public_address?({a, b, c, d}), do: public_v4?(a, b, c, d)
  defp public_address?({a, b, _c, _d, _e, _f, _g, _h}), do: public_v6?(a, b)
  defp public_address?(_address), do: false

  defp embedded_v4(ab, cd),
    do: {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}

  defp public_v4?(0, _b, _c, _d), do: false
  defp public_v4?(10, _b, _c, _d), do: false
  defp public_v4?(127, _b, _c, _d), do: false
  defp public_v4?(100, b, _c, _d) when b in 64..127, do: false
  defp public_v4?(169, 254, _c, _d), do: false
  defp public_v4?(172, b, _c, _d) when b in 16..31, do: false
  defp public_v4?(192, 0, 0, _d), do: false
  defp public_v4?(192, 0, 2, _d), do: false
  defp public_v4?(192, 168, _c, _d), do: false
  defp public_v4?(198, b, _c, _d) when b in 18..19, do: false
  defp public_v4?(198, 51, 100, _d), do: false
  defp public_v4?(203, 0, 113, _d), do: false
  defp public_v4?(a, _b, _c, _d) when a >= 224, do: false
  defp public_v4?(_a, _b, _c, _d), do: true

  # Unspecified/loopback (::, ::1) collapse to a leading 0 group with the rest
  # zero, which `embedded_v4` already rejects; the remaining families are
  # unique-local (fc00::/7), link-local (fe80::/10), multicast (ff00::/8), and
  # the documentation range.
  defp public_v6?(0, _b), do: false
  defp public_v6?(a, _b) when Bitwise.band(a, 0xFE00) == 0xFC00, do: false
  defp public_v6?(a, _b) when Bitwise.band(a, 0xFFC0) == 0xFE80, do: false
  defp public_v6?(a, _b) when Bitwise.band(a, 0xFF00) == 0xFF00, do: false
  defp public_v6?(0x2001, 0xDB8), do: false
  defp public_v6?(_a, _b), do: true

  # -- Fetch ----------------------------------------------------------

  # Connects to the address `validate_destination/1` approved, carrying the URL's
  # hostname for SNI and certificate verification. Mint takes both — an address
  # to dial and a `:hostname` to present and verify against — which is why this
  # calls Mint directly rather than through Finch, whose per-request API has no
  # hook for it. Nothing about TLS verification is relaxed: the hostname check
  # still runs, against the name in the URL.
  #
  # Streamed, so an oversized body is abandoned mid-flight rather than read into
  # memory first, and a redirect is refused outright: only this URL's address was
  # validated, so following a hop would leave the boundary.
  defp get(url, address) do
    uri = URI.parse(url)
    port = uri.port || 443

    connect_opts = [
      transport_opts: [timeout: @timeout_ms],
      mode: :passive
    ]

    # nil address is the dev/test loopback path, where the host is dialled by
    # name because there is nothing to pin it against.
    {target, opts} =
      case address do
        nil -> {uri.host, connect_opts}
        address -> {address, Keyword.put(connect_opts, :hostname, uri.host)}
      end

    case Mint.HTTP.connect(:https, target, port, opts) do
      {:ok, conn} -> stream_document(conn, uri)
      {:error, _reason} -> {:error, :document_unavailable}
    end
  end

  defp stream_document(conn, uri) do
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    headers = [{"accept", "application/json"}, {"host", uri.host}]

    try do
      with {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, headers, nil),
           {:ok, conn, {status, body}} <- receive_document(conn, ref, {nil, ""}) do
        Mint.HTTP.close(conn)
        if status == 200, do: {:ok, body}, else: {:error, :document_unavailable}
      else
        {:error, _conn, _reason} -> {:error, :document_unavailable}
        {:error, _reason} -> {:error, :document_unavailable}
      end
    catch
      {:document, reason} -> {:error, reason}
    end
  end

  defp receive_document(conn, ref, acc) do
    case Mint.HTTP.recv(conn, 0, @timeout_ms) do
      {:ok, conn, responses} ->
        case Enum.reduce(responses, {:cont, acc}, &collect_response(&1, &2, ref)) do
          {:done, acc} -> {:ok, conn, acc}
          {:cont, acc} -> receive_document(conn, ref, acc)
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  defp collect_response({:status, ref, status}, {:cont, acc}, ref),
    do: {:cont, collect({:status, status}, acc)}

  defp collect_response({:headers, ref, headers}, {:cont, acc}, ref),
    do: {:cont, collect({:headers, headers}, acc)}

  defp collect_response({:data, ref, chunk}, {:cont, acc}, ref),
    do: {:cont, collect({:data, chunk}, acc)}

  defp collect_response({:done, ref}, {:cont, acc}, ref), do: {:done, acc}
  defp collect_response(_response, state, _ref), do: state

  defp collect({:status, status}, {_status, body}), do: {status, body}

  defp collect({:headers, headers}, acc) do
    if json_headers?(headers), do: acc, else: throw({:document, :invalid_content_type})
  end

  defp collect({:data, chunk}, {status, body}) do
    body = body <> chunk
    if byte_size(body) > @max_document_bytes, do: throw({:document, :document_too_large})
    {status, body}
  end

  defp collect(_event, acc), do: acc

  defp json_headers?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "content-type" and
        value |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
          "application/json"
    end)
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> {:ok, document}
      _ -> {:error, :invalid_document}
    end
  end

  # -- Document contract ----------------------------------------------

  @doc """
  Validate a decoded metadata document against the URL it was published at.

  The document's own `client_id` MUST equal that URL; without the check any
  site could publish a document claiming another client's identity. Exposed
  separately from `fetch/1` so the contract is testable without a network.
  """
  @spec validate(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def validate(%{} = document, url) do
    with :ok <- require_fields(document),
         :ok <- check(document["client_id"] == url, :client_id_mismatch),
         :ok <- check(is_binary(document["client_name"]), :invalid_document),
         :ok <- check(redirect_uris?(document["redirect_uris"]), :invalid_document) do
      {:ok, document}
    end
  end

  defp require_fields(document) do
    if Enum.all?(@required_fields, &Map.has_key?(document, &1)),
      do: :ok,
      else: {:error, :missing_required_fields}
  end

  defp redirect_uris?([_ | _] = uris), do: Enum.all?(uris, &is_binary/1)
  defp redirect_uris?(_uris), do: false

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
