defmodule EmisarWeb.PackRegistryController do
  @moduledoc """
  Machine-facing pack registry endpoints consumed by the runner's
  `emisar pack install`:

    * `GET /packs.json`            — index of every pack (id, version,
                                     content hash, requirements, tarball URL)
    * `GET /packs/:id/pack.tar.gz` — a single pack as a gzip tarball

  The human-facing `/packs` + `/packs/:id` HTML pages live in
  `MarketingController`. Both read from the same compile-time
  `EmisarWeb.PacksRegistry`.
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
          tarball: url(~p"/packs/#{p.id}/pack.tar.gz")
        }
      end)

    json(conn, %{packs: packs})
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

  @doc "Single pack as a gzip tarball, or a 404 for an unknown id."
  def tarball(conn, %{"id" => id}) do
    case PacksRegistry.tarball(id) do
      {:ok, bin} ->
        conn
        |> put_resp_content_type("application/gzip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{id}.tar.gz"))
        # Packs change only on a deploy; let CDNs/clients cache briefly.
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, bin)

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "unknown pack #{id}", browse: url(~p"/packs")})
    end
  end
end
