defmodule Emisar.InstallCommand do
  @moduledoc """
  Builds the privileged runner and MCP installer fetch commands under one
  initial-origin policy.

  Public and named initial origins require HTTPS. Plain HTTP exists only for
  local development and private self-hosting addressed by `localhost` or a
  literal loopback/private IP. The installers separately constrain their
  release API and artifact downloads to HTTPS.
  """

  @type error :: :invalid_base_url | :insecure_base_url

  # The origin install.sh assumes when EMISAR_URL is unset. A one-liner for this
  # origin omits the variable; anything else must carry it. Kept beside the
  # command builders so the two cannot drift from the installer's own default.
  @default_base_url "https://emisar.dev"

  @doc "The base URL the shipped installers default to."
  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @doc "Build the curl command that fetches one of the two shipped installers."
  @spec fetch(term(), :runner | :mcp) ::
          {:ok, String.t(), String.t()} | {:error, error()}
  def fetch(base_url, installer) when installer in [:runner, :mcp] do
    with {:ok, uri} <- origin(base_url),
         {:ok, curl} <- curl_for(uri) do
      base = URI.to_string(uri)
      script = if installer == :runner, do: "install.sh", else: "install-mcp.sh"
      fetch_url = shell_url("#{base}/#{script}", uri.host)
      {:ok, base, "#{curl} #{fetch_url}"}
    end
  end

  @doc "Validate an installer origin without building or minting anything."
  @spec validate_origin(term()) :: :ok | {:error, error()}
  def validate_origin(base_url) do
    with {:ok, uri} <- origin(base_url),
         {:ok, _curl} <- curl_for(uri) do
      :ok
    end
  end

  defp origin(base_url) when is_binary(base_url) do
    base = String.replace_suffix(base_url, "/", "")

    case URI.new(base) do
      {:ok, uri} ->
        if plain_origin?(uri), do: {:ok, uri}, else: {:error, :invalid_base_url}

      {:error, _part} ->
        {:error, :invalid_base_url}
    end
  end

  defp origin(_base_url), do: {:error, :invalid_base_url}

  defp plain_origin?(%URI{
         scheme: scheme,
         userinfo: nil,
         host: host,
         port: port,
         path: path,
         query: nil,
         fragment: nil
       })
       when scheme in ["http", "https"] and is_binary(host) and is_integer(port) and
              port in 1..65_535 and path in [nil, ""] do
    valid_host?(host)
  end

  defp plain_origin?(_uri), do: false

  defp valid_host?(host) do
    case canonical_ip(host) do
      {:ok, _ip} -> true
      :not_an_ip -> Regex.match?(~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/, host)
      :noncanonical_ip -> false
    end
  end

  defp curl_for(%URI{scheme: "https"}),
    do: {:ok, "curl -fsSL"}

  defp curl_for(%URI{scheme: "http", host: host}) do
    if private_http_host?(host) do
      {:ok, "curl -fsSL"}
    else
      {:error, :insecure_base_url}
    end
  end

  defp shell_url(url, host) do
    if String.contains?(host, ":"), do: "'#{url}'", else: url
  end

  defp private_http_host?(host) do
    downcased = String.downcase(host)

    downcased == "localhost" or String.ends_with?(downcased, ".localhost") or
      private_ip?(canonical_ip(host))
  end

  defp canonical_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        canonical = ip |> :inet.ntoa() |> to_string() |> String.downcase()

        if String.downcase(host) == canonical do
          {:ok, ip}
        else
          :noncanonical_ip
        end

      {:error, _reason} ->
        :not_an_ip
    end
  end

  defp private_ip?({:ok, {127, _, _, _}}), do: true
  defp private_ip?({:ok, {10, _, _, _}}), do: true
  defp private_ip?({:ok, {172, b, _, _}}) when b in 16..31, do: true
  defp private_ip?({:ok, {192, 168, _, _}}), do: true
  defp private_ip?({:ok, {0, 0, 0, 0, 0, 0, 0, 1}}), do: true

  defp private_ip?({:ok, {first, _, _, _, _, _, _, _}}),
    do: Bitwise.band(first, 0xFE00) == 0xFC00

  defp private_ip?(_ip), do: false
end
