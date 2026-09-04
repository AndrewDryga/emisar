defmodule Emisar.Catalog.PublishedRegistry.Cache do
  @moduledoc """
  Holds the current pack catalog — packs plus the trust snapshot — and keeps
  it fresh.

  Boot is **independent of live GCS**: `init/1` loads the bundled
  `priv/packs/catalog.json` (shipped in the release, regenerated from the
  packs tree by `packctl catalog build`) so the registry is always
  populated before the Endpoint accepts a request. When a published
  catalog URL is configured, the cache then refreshes from it on a timer
  and keeps the **last good** catalog on any fetch or validation failure —
  a registry outage or a malformed publish never blanks the pack pages and
  never blanks the trust baseline.

  Boot installs the bundled catalog only when the term is genuinely absent.
  A crash-and-restart of THIS process finds a snapshot already installed and
  leaves it alone: rolling a supervisor back to the release's bundled bytes
  would silently drop a retirement watermark we have since published, which
  is the one thing that must never regress on its own.

  Packs and trust live under ONE `:persistent_term` key so a reader can
  never observe new packs against stale trust maps mid-refresh, and every
  `Emisar.Catalog.PublishedRegistry` / `Emisar.Catalog.PackBaseline` read is
  a lock-free term lookup rather than a `GenServer.call` through this
  process.

  ## Why swaps are rare

  `:persistent_term.put/2` replacing a live term schedules a literal-area
  GC across every process that may reference it, and this term is hot-path
  data — read per pack per runner advertisement and on every dispatch gate.
  So a refresh guards in two stages: a body byte-identical to the last one
  we acted on skips decode, validation and the swap entirely (the common
  case), and a body that decodes to the snapshot we already serve skips the
  swap too. The digest lives in this process's state, never in the term —
  otherwise we would be putting in order to decide whether to put.

  That makes `checked_at` (we validated a body from the registry) and
  `loaded_at` (the served catalog changed) different facts. Only the first
  going stale is a problem; an unchanged catalog is not a stale one. At boot
  `checked_at` is nil — nothing remote has been validated yet — and a fetch
  error or a rejected document leaves it exactly where it was.
  """
  use GenServer
  alias Emisar.Catalog.PublishedRegistry.{Catalog, CatalogClient, Pack}
  alias Emisar.Crypto
  require Logger

  @term_key {__MODULE__, :catalog}
  @refresh_interval :timer.minutes(10)
  @type snapshot :: %{
          packs: [Pack.t()],
          trust: Catalog.trust()
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The current catalog packs (alphabetical by id). Always populated after boot."
  @spec current() :: [Pack.t()]
  def current, do: snapshot().packs

  @doc """
  What the current catalog publishes, for `Emisar.Catalog.PackBaseline`:
  baseline hashes, exact-hash manifests, retirement watermarks, and current
  versions. Moves atomically with the packs it was parsed from.
  """
  @spec trust_snapshot() :: Catalog.trust()
  def trust_snapshot, do: snapshot().trust

  @doc """
  Internal — the installed snapshot, read as one atomic term. Raises before
  the supervised cache has booted: an empty fallback would read as "we
  publish nothing", quietly un-trusting every pack and blanking every
  retirement watermark instead of failing where the mistake is.
  """
  @spec snapshot() :: snapshot()
  def snapshot, do: :persistent_term.get(@term_key)

  @doc "Internal — swap the installed snapshot. The boot and refresh paths' only writer."
  @spec install_snapshot(snapshot()) :: :ok
  def install_snapshot(snapshot), do: :persistent_term.put(@term_key, snapshot)

  @doc """
  Operational snapshot — which source is live, when we last accepted a body
  from the registry (`checked_at`, whether or not it had moved; nil until a
  fetch validates) and when the served catalog last changed (`loaded_at`).
  """
  @spec status() :: %{
          source: :bundled | :remote,
          checked_at: DateTime.t() | nil,
          loaded_at: DateTime.t(),
          count: non_neg_integer()
        }
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    state = boot_state(opts)

    if state.url do
      send(self(), :refresh)
    end

    {:ok, state}
  end

  @doc """
  Internal — the boot state. The bundled catalog is parsed either way (a
  broken artifact must fail the boot, not the first refresh), but it is
  installed only when no snapshot exists yet; a restart onto an existing one
  keeps what is already being served. `:put` overrides the installer so a
  test can count real swaps.
  """
  @spec boot_state(keyword()) :: map()
  def boot_state(opts \\ []) do
    put = Keyword.get(opts, :put, &install_snapshot/1)
    {body, bundled} = load_bundled!()
    {source, digest} = install_boot_snapshot(put, bundled, Crypto.hash(body))

    %{
      source: source,
      checked_at: nil,
      loaded_at: DateTime.utc_now(),
      url: catalog_url(),
      digest: digest,
      put: put
    }
  end

  # The change guard is seeded from the bundled bytes only when those bytes are
  # what we serve, so a first remote fetch of exactly what we shipped correctly
  # does nothing. A PRESERVED snapshot came from a body this process never saw,
  # so it starts with no digest: the next fetch must parse and compare
  # semantically rather than take a byte fast-path against the wrong document.
  defp install_boot_snapshot(put, bundled, bundled_digest) do
    case :persistent_term.get(@term_key, :absent) do
      :absent ->
        put.(bundled)
        {:bundled, bundled_digest}

      ^bundled ->
        {:bundled, bundled_digest}

      _preserved ->
        {:remote, nil}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      source: state.source,
      checked_at: state.checked_at,
      loaded_at: state.loaded_at,
      count: length(current())
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = refresh(state, CatalogClient.fetch(state.url))
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  @doc """
  Internal — apply one completed fetch to the cache state.

  Stage 1 of the change guard: a body byte-identical to the last one we acted
  on records only that we reached the registry — no decode, no validation, no
  swap. Anything else goes through `evaluate/2`, which decides whether the
  document is servable at all, and only a snapshot that differs from the one
  installed is swapped in.
  """
  @spec refresh(map(), {:ok, binary()} | {:error, term()}) :: map()
  def refresh(state, {:ok, body}) do
    digest = Crypto.hash(body)

    if digest == state.digest do
      %{state | source: :remote, checked_at: DateTime.utc_now()}
    else
      apply_evaluation(state, evaluate({:ok, body}, state.url), digest)
    end
  end

  def refresh(state, {:error, _reason} = failed),
    do: apply_evaluation(state, evaluate(failed, state.url), state.digest)

  @doc """
  Decide what a fetch result means for the cached catalog. `{:ok, snapshot}` —
  packs plus the trust maps — to replace the last-good one with the freshly
  validated document, or `{:keep, message}` to hold the last-good one (fetch
  failed, the published document didn't validate, or a tarball_url pointed off
  the registry base derived from `catalog_url`). Pure, so the last-good
  contract is directly testable.
  """
  @spec evaluate({:ok, binary()} | {:error, term()}, String.t()) ::
          {:ok, snapshot()} | {:keep, String.t()}
  def evaluate({:ok, body}, catalog_url) do
    case Catalog.parse(body) do
      # A valid-but-EMPTY published catalog would blank /packs, every
      # resolve_action lookup, and the whole auto-trust baseline — never a real
      # publish. Treat it as a bad document and hold the last-good catalog
      # rather than serving nothing.
      {:ok, %{packs: []}} -> {:keep, "rejected published catalog: no packs"}
      {:ok, snapshot} -> bind_remote_source(snapshot, catalog_url)
      {:error, reason} -> {:keep, "rejected published catalog: #{reason}"}
    end
  end

  def evaluate({:error, reason}, _catalog_url),
    do: {:keep, "catalog fetch failed: #{inspect(reason)}"}

  defp apply_evaluation(state, {:ok, snapshot}, digest), do: install(state, snapshot, digest)

  defp apply_evaluation(state, {:keep, message}, _digest) do
    Logger.warning("PublishedRegistry.Cache: #{message}; serving last-good catalog")
    state
  end

  defp install(state, incoming, digest) do
    if incoming == snapshot() do
      %{state | source: :remote, checked_at: DateTime.utc_now(), digest: digest}
    else
      state.put.(incoming)
      now = DateTime.utc_now()
      %{state | source: :remote, checked_at: now, loaded_at: now, digest: digest}
    end
  end

  # Pin every tarball_url (current + carried-forward history) to the
  # registry base derived from the configured catalog_url: the portal
  # 302s installers to these URLs, so a poisoned REMOTE catalog naming an
  # off-base tarball could redirect an install to another host or bucket
  # (supply chain). The bundled boot parse deliberately skips this — it
  # ships our canonical serving-domain URLs while a self-hoster overrides
  # catalog_url, so the pin is the remote path's alone.
  defp pin_tarballs(%{packs: packs} = snapshot, base) do
    case find_off_base_tarball(packs, base) do
      nil ->
        {:ok, snapshot}

      {pack_id, url} ->
        {:keep,
         "rejected published catalog: pack #{inspect(pack_id)} tarball_url #{inspect(url)} " <>
           "is not under the registry base #{inspect(base)}"}
    end
  end

  defp bind_remote_source(snapshot, catalog_url) do
    pin_tarballs(snapshot, tarball_base(catalog_url))
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
    body = File.read!(path)

    case Catalog.parse(body) do
      {:ok, snapshot} ->
        {body, snapshot}

      {:error, reason} ->
        raise "PublishedRegistry.Cache: bundled catalog at #{path} is invalid: #{reason}"
    end
  end

  defp catalog_url do
    :emisar
    |> Application.get_env(Emisar.Catalog.PublishedRegistry, [])
    |> Keyword.get(:catalog_url)
  end
end
