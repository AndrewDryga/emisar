defmodule EmisarWeb.PacksRegistry.Cache do
  @moduledoc """
  Holds the current pack catalog and keeps it fresh.

  Boot is **independent of live GCS**: `init/1` loads the bundled
  `priv/packs/catalog.json` (shipped in the release, regenerated from the
  packs tree by `emisar pack catalog build`) so the registry is always
  populated before the Endpoint accepts a request. When a published
  catalog URL is configured, the cache then refreshes from it on a timer
  and keeps the **last good** catalog on any fetch or validation failure —
  a registry outage or a malformed publish never blanks the pack pages.

  The catalog lives in `:persistent_term` (read-mostly, refreshed rarely),
  so every `EmisarWeb.PacksRegistry` read is a lock-free term lookup rather
  than a `GenServer.call` through this process.
  """
  use GenServer
  alias EmisarWeb.PacksRegistry.{Catalog, CatalogClient, Pack}
  require Logger

  @term_key {__MODULE__, :catalog}
  @refresh_interval :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The current catalog packs (alphabetical by id). Always populated after boot."
  @spec current() :: [Pack.t()]
  def current, do: :persistent_term.get(@term_key, [])

  @doc "Operational snapshot — which source is live and when it last loaded."
  @spec status() :: %{
          source: :bundled | :remote,
          loaded_at: DateTime.t(),
          count: non_neg_integer()
        }
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    packs = load_bundled!()
    :persistent_term.put(@term_key, packs)
    state = %{source: :bundled, loaded_at: DateTime.utc_now(), url: catalog_url()}

    if state.url do
      send(self(), :refresh)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{source: state.source, loaded_at: state.loaded_at, count: length(current())}, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state =
      case evaluate(CatalogClient.fetch(state.url), state.url) do
        {:ok, packs} ->
          :persistent_term.put(@term_key, packs)
          %{state | source: :remote, loaded_at: DateTime.utc_now()}

        {:keep, message} ->
          Logger.warning("PacksRegistry.Cache: #{message}; serving last-good catalog")
          state
      end

    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  @doc """
  Decide what a fetch result means for the cached catalog. `{:ok, packs}`
  to replace the last-good catalog with the freshly-validated one, or
  `{:keep, message}` to hold the last-good catalog (fetch failed, the
  published document didn't validate, or a tarball_url pointed off the
  registry base derived from `catalog_url`). Pure, so the last-good
  contract is directly testable.
  """
  @spec evaluate({:ok, binary()} | {:error, term()}, String.t()) ::
          {:ok, [Pack.t()]} | {:keep, String.t()}
  def evaluate({:ok, body}, catalog_url) do
    case Catalog.parse(body) do
      # A valid-but-EMPTY published catalog would blank /packs and every
      # resolve_command lookup — never a real publish. Treat it as a bad
      # document and hold the last-good catalog rather than serving nothing.
      {:ok, []} -> {:keep, "rejected published catalog: no packs"}
      {:ok, packs} -> pin_tarballs(packs, tarball_base(catalog_url))
      {:error, reason} -> {:keep, "rejected published catalog: #{reason}"}
    end
  end

  def evaluate({:error, reason}, _catalog_url),
    do: {:keep, "catalog fetch failed: #{inspect(reason)}"}

  # Pin every tarball_url (current + carried-forward history) to the
  # registry base derived from the configured catalog_url: the portal
  # 302s installers to these URLs, so a poisoned REMOTE catalog naming an
  # off-base tarball could redirect an install to another host or bucket
  # (supply chain). The bundled boot parse deliberately skips this — it
  # ships the canonical GCS URLs while a self-hoster overrides catalog_url,
  # so the pin is the remote path's alone.
  defp pin_tarballs(packs, base) do
    case find_off_base_tarball(packs, base) do
      nil ->
        {:ok, packs}

      {pack_id, url} ->
        {:keep,
         "rejected published catalog: pack #{inspect(pack_id)} tarball_url #{inspect(url)} " <>
           "is not under the registry base #{inspect(base)}"}
    end
  end

  defp find_off_base_tarball(packs, base) do
    Enum.find_value(packs, fn pack ->
      urls = [pack.tarball_url | Enum.map(pack.previous_versions, & &1.tarball_url)]

      case Enum.find(urls, &(not String.starts_with?(&1, base))) do
        nil -> nil
        url -> {pack.id, url}
      end
    end)
  end

  # The registry base is the directory the configured catalog.json lives
  # in (…/v1/catalog.json → …/v1/); every published tarball must sit under it.
  defp tarball_base(catalog_url) do
    uri = URI.parse(catalog_url)
    dir = Path.dirname(uri.path || "/")
    base_path = if String.ends_with?(dir, "/"), do: dir, else: dir <> "/"
    URI.to_string(%{uri | path: base_path, query: nil, fragment: nil})
  end

  # The bundled catalog is a committed, test-verified artifact — a parse
  # failure here is a build defect, so fail loud rather than boot empty.
  # sobelow_skip ["Traversal.FileModule"] — the path is a compile-known
  # app_dir constant, no request input reaches it; Sobelow's low-confidence
  # traversal heuristic can't see that.
  defp load_bundled! do
    path = Application.app_dir(:emisar, "priv/packs/catalog.json")

    case Catalog.parse(File.read!(path)) do
      {:ok, packs} ->
        packs

      {:error, reason} ->
        raise "PacksRegistry.Cache: bundled catalog at #{path} is invalid: #{reason}"
    end
  end

  defp catalog_url do
    :emisar_web
    |> Application.get_env(EmisarWeb.PacksRegistry, [])
    |> Keyword.get(:catalog_url)
  end
end
