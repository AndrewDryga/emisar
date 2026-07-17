defmodule EmisarWeb.AppVersion do
  @moduledoc """
  The running release's product version — ONE read path for every surface
  that reports it (marketing footer, MCP `serverInfo`, `/healthz`). The MCP
  registry reconciler compares `/healthz`'s copy against the latest release
  tag to publish the listing only once a deploy actually serves it.
  """

  @doc """
  The `:vsn` of the running `emisar_web` application (`portal/VERSION` via
  mix.exs), read at call time so the value always reflects the running
  release; `"dev"` when no release metadata is loaded.
  """
  def version do
    case Application.spec(:emisar_web, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
