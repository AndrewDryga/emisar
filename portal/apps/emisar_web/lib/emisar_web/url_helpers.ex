defmodule EmisarWeb.UrlHelpers do
  @moduledoc """
  Cross-LV helpers for URLs that operators copy/paste (install
  one-liners, MCP snippets). Resolves from `socket.host_uri` so dev
  (`http://localhost:4000`) and prod (`https://emisar.dev`) both
  produce a URL that targets THIS deployment, not a hardcoded host.
  """

  @fallback_url "https://emisar.dev"

  @doc """
  Returns the operator-facing base URL — `scheme://host[:port]` — for
  the LiveView socket. Falls back to a hardcoded production URL when
  the socket has no `host_uri` (e.g. tests that don't go through a
  real HTTP request).
  """
  def derive_base_url(%{host_uri: %URI{scheme: scheme, host: host, port: port}})
      when is_binary(host) do
    scheme = scheme || "http"
    "#{scheme}://#{host}#{port_suffix(scheme, port)}"
  end

  def derive_base_url(_), do: @fallback_url

  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"
end
