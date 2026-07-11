defmodule EmisarWeb.PackRegistryController do
  @moduledoc """
  Machine-facing pack registry endpoints consumed by the runner's
  `emisar pack install`:

    * `GET /packs.json`            — index of every pack (id, version,
                                     content hash, requirements, tarball URL,
                                     version window + retirement watermark)
    * `GET /packs/:id/pack.tar.gz` — 302-redirect to the pack's immutable,
                                     content-addressed tarball
    * `GET /packs/:id/versions/:version/pack.tar.gz` — 302-redirect to a
                                     SPECIFIC version's tarball (current or a
                                     remembered prior one)

  The human-facing `/packs` + `/packs/:id` HTML pages live in
  `MarketingController`. Both read from the same `EmisarWeb.PacksRegistry`
  catalog cache.
  """
  use EmisarWeb, :controller
  alias EmisarWeb.PacksRegistry

  @doc "JSON index of the full catalog — drives discovery + OS matching."
  def index(conn, _params) do
    packs =
      Enum.map(PacksRegistry.list(), fn p ->
        %{
          id: p.id,
          name: p.name,
          version: p.version,
          hash: p.content_hash,
          description: p.description,
          requires_os: p.requires_os,
          requires_binaries: p.requires_binaries,
          tarball: url(~p"/packs/#{p.id}/pack.tar.gz"),
          previous_versions: Enum.map(p.previous_versions, &previous_version_entry(p, &1)),
          retired_below: p.retired_below
        }
      end)

    json(conn, %{packs: packs})
  end

  # A prior version's tarball points at the versioned portal route (which
  # 302s to the immutable bytes), mirroring the current entry's `tarball`.
  defp previous_version_entry(pack, %{version: version, content_hash: hash}) do
    %{
      version: version,
      hash: hash,
      tarball: url(~p"/packs/#{pack.id}/versions/#{version}/pack.tar.gz")
    }
  end

  @doc """
  Lean suggest index consumed by `emisar pack suggest` — only the per-pack
  detect signal (binaries/processes/ports, generic helpers stripped) plus
  id/name/os, and only for packs that are host-detectable. Smaller than the
  full index, and the curl/nc filtering lives server-side so the list can
  evolve without a runner release.
  """
  def suggest(conn, _params) do
    json(conn, %{packs: PacksRegistry.suggest_index()})
  end

  @doc """
  Redirect to a pack's immutable, content-addressed tarball, or a 404 for
  an unknown id. The bytes live in the pack registry bucket; the `--hash`
  pin in the install snippet makes the redirect target tamper-evident, so
  `emisar pack install` still rejects a poisoned mirror.
  """
  def tarball(conn, %{"id" => id}) do
    redirect_to_tarball(conn, PacksRegistry.tarball_url(id), "unknown pack #{id}")
  end

  @doc """
  Redirect to a SPECIFIC pack version's immutable tarball — the pack's
  current version or a remembered prior one — or a 404 when the id or version
  is unknown. Lets an operator pin an exact release with `emisar pack install
  <id>=<version>`; a retired version is still installable here (the trust gate
  is what blocks dispatching it), so history stays a break-glass path.
  """
  def tarball_version(conn, %{"id" => id, "version" => version}) do
    redirect_to_tarball(
      conn,
      PacksRegistry.tarball_url(id, version),
      "unknown pack #{id} version #{version}"
    )
  end

  defp redirect_to_tarball(conn, {:ok, tarball_url}, _not_found) do
    conn
    # A pack version's bytes are immutable (content-addressed), so the
    # redirect itself is cacheable; clients follow it to the real bytes.
    |> put_resp_header("cache-control", "public, max-age=300")
    |> redirect(external: tarball_url)
  end

  defp redirect_to_tarball(conn, :error, not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: not_found, browse: url(~p"/packs")})
  end
end
