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
      case evaluate(CatalogClient.fetch(state.url)) do
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
  `{:keep, message}` to hold the last-good catalog (fetch failed, or the
  published document didn't validate). Pure, so the last-good contract is
  directly testable.
  """
  @spec evaluate({:ok, binary()} | {:error, term()}) :: {:ok, [Pack.t()]} | {:keep, String.t()}
  def evaluate({:ok, body}) do
    case Catalog.parse(body) do
      # A valid-but-EMPTY published catalog would blank /packs and every
      # resolve_command lookup — never a real publish. Treat it as a bad
      # document and hold the last-good catalog rather than serving nothing.
      {:ok, []} -> {:keep, "rejected published catalog: no packs"}
      {:ok, packs} -> {:ok, packs}
      {:error, reason} -> {:keep, "rejected published catalog: #{reason}"}
    end
  end

  def evaluate({:error, reason}), do: {:keep, "catalog fetch failed: #{inspect(reason)}"}

  # The bundled catalog is a committed, test-verified artifact — a parse
  # failure here is a build defect, so fail loud rather than boot empty.
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
