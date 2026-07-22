defmodule EmisarWeb.AppVersion do
  @moduledoc """
  The running release's product version and source revision.

  Product surfaces share the version from `portal/VERSION`. Deployment probes
  also report the Git revision compiled into the image so two builds of the
  same product version remain operationally distinguishable.
  """

  @revision System.get_env("EMISAR_SOURCE_REVISION", "dev")

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

  @doc "The Git revision compiled into the running release image."
  def revision, do: @revision
end
