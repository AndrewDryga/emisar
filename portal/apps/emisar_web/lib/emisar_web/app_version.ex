defmodule EmisarWeb.AppVersion do
  @moduledoc """
  The running release's product version and source revision.

  Product surfaces share the version from `portal/VERSION`. Deployment probes
  also report the Git revision embedded in the image so two builds of the
  same product version remain operationally distinguishable.
  """

  @revision_path "/app/REVISION"

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

  @doc "The Git revision embedded in the running release image."
  def revision do
    case File.read(@revision_path) do
      {:ok, revision} -> String.trim(revision)
      {:error, _reason} -> "dev"
    end
  end
end
