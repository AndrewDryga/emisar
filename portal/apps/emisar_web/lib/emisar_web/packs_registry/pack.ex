defmodule EmisarWeb.PacksRegistry.Pack do
  @moduledoc """
  One pack's catalog metadata, decoded from a published `catalog.json`
  entry (`EmisarWeb.PacksRegistry.Catalog`). Lives in its own file so a
  reader can see the shape the registry cache hands to every pack page,
  the install snippet, and the command preview.
  """

  @enforce_keys [
    :id,
    :name,
    :version,
    :description,
    :vendor,
    :source_url,
    :content_hash,
    :tarball_url,
    :actions
  ]
  defstruct [
    :id,
    :name,
    :version,
    :description,
    :vendor,
    :homepage,
    # source_url links back to the pack's directory in the public source
    # repo (rendered as the per-pack "Source" link). Comes straight from
    # the catalog so the portal doesn't hardcode the repo layout.
    :source_url,
    :requires_os,
    :requires_binaries,
    # content_hash is the runner's content-addressable pack hash
    # ("sha256:..."), computed by `emisar pack catalog build` over the
    # same byte set and algorithm the Go runner uses. Drives the `--hash`
    # pin shown in the install snippet so an operator's `emisar pack
    # install` rejects a tampered or drifted copy.
    :content_hash,
    # tarball_url is the immutable, content-addressed GCS URL the pack
    # bytes live at (v1/packs/<id>/<version>/<sha256>/pack.tar.gz). The
    # portal's `/packs/:id/pack.tar.gz` endpoint 302-redirects here; the
    # bytes are no longer carried in the release.
    :tarball_url,
    # previous_versions carries the last few prior releases of this pack
    # (newest first, excluding the current version), each with its own
    # immutable content_hash + tarball_url. Empty on a pack with no shipped
    # history. The versioned tarball route resolves an install against these
    # too, and the portal trust window (PackBaseline) auto-trusts them.
    # retired_below, when set, is the watermark below which every version is
    # retired — enforced at dispatch (PackBaseline), not here.
    previous_versions: [],
    retired_below: nil,
    # detect is the service-presence signal for `emisar pack suggest`:
    # the binaries/processes/ports that mean "this service runs here".
    # Computed at compile time = the pack's declared `detect` block, else
    # requires_binaries minus ubiquitous helpers (curl, nc, …). A pack with
    # an all-empty detect (e.g. a remote-API pack) is never auto-suggested.
    detect: %{binaries: [], processes: [], ports: []},
    actions: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          vendor: String.t(),
          homepage: String.t() | nil,
          source_url: String.t(),
          requires_os: [String.t()],
          requires_binaries: [String.t()],
          content_hash: String.t(),
          tarball_url: String.t(),
          previous_versions: [
            %{version: String.t(), content_hash: String.t(), tarball_url: String.t()}
          ],
          retired_below: String.t() | nil,
          detect: %{
            binaries: [String.t()],
            processes: [String.t()],
            ports: [integer()]
          },
          actions: [EmisarWeb.PacksRegistry.Action.t()]
        }

  @doc """
  The immutable tarball URL for this pack at `version` — its current version
  or one of its remembered prior versions — or `:error` when `version` is
  neither. Pure resolution over the pack's own catalog entry; the cache read
  by pack id happens in `EmisarWeb.PacksRegistry`.
  """
  @spec tarball_url(t(), String.t()) :: {:ok, String.t()} | :error
  def tarball_url(%__MODULE__{version: version, tarball_url: url}, version), do: {:ok, url}

  def tarball_url(%__MODULE__{previous_versions: previous}, version) do
    case Enum.find(previous, &(&1.version == version)) do
      %{tarball_url: url} -> {:ok, url}
      nil -> :error
    end
  end
end
