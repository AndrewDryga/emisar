defmodule EmisarWeb.InstallMcpController do
  @moduledoc """
  Serves the canonical `install-mcp.sh` from the repo root.

  Mirrors `EmisarWeb.InstallController`: embedded at compile time via
  `@external_resource`, recompiles whenever `install-mcp.sh` changes,
  so the served script is always in sync with the source.
  """
  use EmisarWeb, :controller

  @install_mcp_sh Path.expand("../../../../../../install-mcp.sh", __DIR__)
  @external_resource @install_mcp_sh
  @body File.read!(@install_mcp_sh)

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, @body)
  end
end
