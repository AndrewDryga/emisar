defmodule EmisarWeb.InstallController do
  @moduledoc """
  Serves the canonical `install.sh` from the repo root.

  Embedded at compile time via `@external_resource`, so the release
  binary contains a frozen copy. Mix recompiles this module whenever
  `install.sh` changes, so the served script is always in sync with the
  source — no separate copy/sync step needed.
  """
  use EmisarWeb, :controller

  # Path relative to this file: portal/apps/emisar_web/lib/emisar_web/controllers/
  # → six "..":
  #   1: lib/emisar_web/
  #   2: lib/
  #   3: emisar_web/
  #   4: apps/
  #   5: portal/
  #   6: <repo root>
  @install_sh Path.expand("../../../../../../install.sh", __DIR__)
  @external_resource @install_sh
  @body File.read!(@install_sh)

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, @body)
  end
end
