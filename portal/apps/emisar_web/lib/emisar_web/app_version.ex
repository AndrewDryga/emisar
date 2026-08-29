defmodule EmisarWeb.AppVersion do
  @moduledoc """
  The running release's product version.

  Product surfaces share the version from `portal/VERSION`. The immutable source
  revision baked into the image (`/app/REVISION`) is deliberately not exposed
  over HTTP — the repository is public, so the exact deployed Git SHA is verified
  from the image itself in CI and from a deploy's reviewed digest, never handed to
  an anonymous caller.
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
