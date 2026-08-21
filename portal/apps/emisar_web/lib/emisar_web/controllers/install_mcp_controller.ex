defmodule EmisarWeb.InstallMCPController do
  @moduledoc """
  Serves the canonical Unix and Windows MCP installers from the repo root.

  Mirrors `EmisarWeb.InstallController`: embedded at compile time via
  `@external_resource`, recompiles whenever either source changes, so the
  served scripts stay in sync with the repository.
  """
  use EmisarWeb, :controller

  @install_mcp_sh Path.expand("../../../../../../install-mcp.sh", __DIR__)
  @external_resource @install_mcp_sh
  @body File.read!(@install_mcp_sh)

  @install_mcp_ps1 Path.expand("../../../../../../install-mcp.ps1", __DIR__)
  @external_resource @install_mcp_ps1
  @powershell_body File.read!(@install_mcp_ps1)

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, @body)
  end

  def show_powershell(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, @powershell_body)
  end
end
