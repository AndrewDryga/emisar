defmodule EmisarWeb.URLHelpers do
  @moduledoc """
  Cross-LV helpers for URLs that operators copy/paste (install
  one-liners, MCP snippets). Resolves from `socket.host_uri` so dev
  (`http://localhost:4000`) and prod (`https://emisar.dev`) both
  produce a URL that targets THIS deployment, not a hardcoded host.
  """
  alias Emisar.InstallCommand

  @fallback_url "https://emisar.dev"

  @doc """
  Returns the operator-facing base URL — `scheme://host[:port]` — for
  the LiveView socket or a `Plug.Conn` (API controllers building
  copy-paste/poll URLs). Falls back to a hardcoded production URL when
  the socket has no `host_uri` (e.g. tests that don't go through a
  real HTTP request).
  """
  def derive_base_url(%Plug.Conn{scheme: scheme, host: host, port: port}) do
    origin_url(to_string(scheme), host, port)
  end

  def derive_base_url(%{host_uri: %URI{scheme: scheme, host: host, port: port}})
      when is_binary(host) do
    origin_url(scheme || "http", host, port)
  end

  def derive_base_url(_), do: @fallback_url

  @doc """
  The copy-pasteable one-liner that installs (or upgrades) the MCP bridge
  from this deployment. The hosted portal keeps the minimal
  `curl | sudo bash` (the installer already defaults to it); any other
  base URL — dev, self-hosted — rides along as `EMISAR_URL` so the
  installer's LLM-client setup writes configs that point back at the
  portal that issued the command.
  """
  def mcp_install_command(base_url) do
    with {:ok, base, fetch} <- InstallCommand.fetch(base_url, :mcp) do
      shell_base = if String.contains?(base, "["), do: "'#{base}'", else: base

      command =
        if base == @fallback_url do
          "#{fetch} | sudo bash"
        else
          "#{fetch} | sudo EMISAR_URL=#{shell_base} bash"
        end

      {:ok, command}
    end
  end

  @doc "The copy-pasteable PowerShell command that installs the Windows MCP bridge."
  def mcp_windows_install_command(base_url) do
    with {:ok, base, _fetch} <- InstallCommand.fetch(base_url, :mcp) do
      script_url = "#{base}/install-mcp.ps1"

      command =
        if base == @fallback_url do
          "irm #{script_url} | iex"
        else
          "& ([scriptblock]::Create((irm '#{script_url}'))) -PortalOrigin '#{base}'"
        end

      {:ok, command}
    end
  end

  defp origin_url(scheme, host, port),
    do: URI.to_string(%URI{scheme: scheme, host: host, port: port})
end
