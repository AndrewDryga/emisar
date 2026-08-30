defmodule Emisar.Fixtures.Catalog do
  @moduledoc """
  Catalog action test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Catalog.create_action/1`.
  """

  alias Emisar.{Catalog, Crypto, Repo}

  @pack_hash_format ~r/\Asha256:[0-9a-f]{64}\z/

  @default_pack_id "fixture-pack"
  @default_pack_version "1.0"

  @doc "Returns a deterministic canonical SHA-256 pack hash for a test label."
  def pack_hash(value) when is_binary(value) do
    if Regex.match?(@pack_hash_format, value),
      do: value,
      else: "sha256:" <> Crypto.hash_hex(value)
  end

  @doc """
  The pack hash + ref of the default (auto-trusted) fixture action. A test that
  parks a gated run directly via `Runs.create_run` snapshots these so approve's
  trust recheck sees the same hash dispatch would have written.
  """
  def default_pack_hash, do: pack_hash("#{@default_pack_id}@#{@default_pack_version}")
  def default_pack_ref, do: "#{@default_pack_id}@#{@default_pack_version}/" <> default_pack_hash()

  @doc """
  Inserts a catalog action row for a runner. Mirrors what
  `Catalog.observe_state` would do when a runner advertises this action —
  including its upsert, so a fixture that re-advertises the same action on a
  reused runner refreshes the row instead of hitting the unique index.
  Defaults to `action_id: "linux.uptime"`, `risk: "low"`, `kind: "exec"`.
  """
  def create_action(attrs \\ %{}) do
    attrs = Map.new(attrs)
    runner = attrs[:runner] || raise ":runner is required"
    {pack_id, pack_version, pack_hash} = action_pack_ref(attrs)

    params = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: attrs[:action_id] || "linux.uptime",
      pack_id: pack_id,
      pack_version: pack_version,
      pack_hash: pack_hash,
      title: attrs[:title] || "Uptime",
      kind: attrs[:kind] || "exec",
      risk: attrs[:risk] || "low",
      description: attrs[:description] || "Reports uptime + load.",
      side_effects: attrs[:side_effects] || ["reads /proc"],
      args_schema: attrs[:args_schema] || %{"args" => []},
      output_schema: Map.get(attrs, :output_schema),
      examples: attrs[:examples] || [],
      primary_executable_available: Map.get(attrs, :primary_executable_available),
      missing_executable: attrs[:missing_executable],
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }

    {:ok, action} =
      Catalog.RunnerAction.Changeset.upsert(params)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :first_seen_at, :inserted_at]},
        conflict_target: [:runner_id, :action_id],
        returning: true
      )

    # The default (no pack_id) models a dispatchable action, so trust its pack.
    unless Map.has_key?(attrs, :pack_id), do: trust_default_pack(action)

    action
  end

  # Every advertised action names a pack now: ingestion requires a pack_id and
  # dispatch requires a trusted pin. With no pack_id given, the fixture models
  # the dispatchable default — a shared "fixture-pack@1.0", trusted below.
  # Passing pack_id (with optional version/hash) opts out of the auto-trust, so
  # untrusted / unresolvable / drifted cases arrange their own pin.
  defp action_pack_ref(%{pack_id: pack_id} = attrs) when is_binary(pack_id),
    do: {pack_id, attrs[:pack_version], if(attrs[:pack_hash], do: pack_hash(attrs[:pack_hash]))}

  defp action_pack_ref(_attrs),
    do: {@default_pack_id, @default_pack_version, default_pack_hash()}

  # Trust the shared default pack with a manifest rebuilt from every action it
  # now carries: dispatch compares the trusted descriptor against the row, so
  # the manifest must hold each advertised action. Idempotent + race-free (one
  # sandboxed process per test); the upsert refreshes the accumulated manifest
  # on every added action.
  defp trust_default_pack(%Catalog.RunnerAction{} = action) do
    actions =
      Catalog.RunnerAction.Query.all()
      |> Catalog.RunnerAction.Query.by_account_id(action.account_id)
      |> Catalog.RunnerAction.Query.by_pack(action.pack_id, action.pack_version)
      |> Repo.all()
      |> Enum.uniq_by(& &1.action_id)

    {:ok, manifest} = Catalog.TrustedManifest.from_runner_actions(actions)
    now = DateTime.utc_now()

    {:ok, _pack_version} =
      Catalog.PackVersion.Changeset.insert(%{
        account_id: action.account_id,
        pack_id: action.pack_id,
        version: action.pack_version,
        hash: action.pack_hash,
        trust_state: :trusted,
        trusted_manifest: manifest,
        first_seen_at: now,
        last_seen_at: now
      })
      |> Repo.insert(
        on_conflict: {:replace, [:trusted_manifest, :hash, :trust_state, :last_seen_at]},
        conflict_target: [:account_id, :pack_id, :version]
      )

    :ok
  end

  @doc """
  Test helper: drop every action a runner advertises — the catalog state a run
  parked behind an approval meets once its runner stops advertising it.
  """
  def delete_actions_for_runner(runner_id) when is_binary(runner_id) do
    queryable =
      Catalog.RunnerAction.Query.all()
      |> Catalog.RunnerAction.Query.by_runner_id(runner_id)

    {_count, nil} = Repo.delete_all(queryable)
    :ok
  end

  @doc """
  Inserts a TRUSTED pack version row directly — the shape a version trusted
  under an older release has after a newer release raises the pack's
  retirement watermark: trusted, retired, and NO override stamp.
  `Catalog.trust_pack_version/2` cannot build this state (trusting an
  already-retired version stamps the override), so retirement UI paths
  arrange it here. Defaults to `pack_id: "acme-tools"`, `version: "9.9"`.
  """
  def create_trusted_pack_version(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || raise ":account_id is required"
    now = DateTime.utc_now()

    params = %{
      account_id: account_id,
      pack_id: attrs[:pack_id] || "acme-tools",
      version: attrs[:version] || "9.9",
      hash: pack_hash(attrs[:hash] || "trusted-fixture"),
      trust_state: :trusted,
      trusted_manifest: attrs[:trusted_manifest],
      first_seen_at: now,
      last_seen_at: now
    }

    {:ok, pack_version} =
      Catalog.PackVersion.Changeset.insert(params)
      |> Repo.insert()

    pack_version
  end

  @doc """
  Inserts a pack version row in an exact historical trust state — `trust_state`,
  `hash`, and `pending_hash` are written verbatim. Every trust mutator judges the
  current row before writing, so the states an earlier release left behind can
  only be arranged here: a never-trusted `:pending` row whose bytes the compiled
  baseline now carries, a `:rejected` row that still remembers the refused bytes,
  or a trusted row with drift parked on it. Defaults to a never-trusted
  `:pending` `acme-tools@9.9`.
  """
  def create_observed_pack_version(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || raise ":account_id is required"
    now = DateTime.utc_now()

    params = %{
      account_id: account_id,
      pack_id: attrs[:pack_id] || "acme-tools",
      version: attrs[:version] || "9.9",
      hash: if(attrs[:hash], do: pack_hash(attrs[:hash])),
      pending_hash: pack_hash(attrs[:pending_hash] || "observed-fixture"),
      trust_state: attrs[:trust_state] || :pending,
      first_seen_at: now,
      last_seen_at: now
    }

    {:ok, pack_version} =
      Catalog.PackVersion.Changeset.insert(params)
      |> Repo.insert()

    pack_version
  end

  @doc "Test helper: backdate a pack version's `last_seen_at` (retention sweeps)."
  def backdate_pack_version_last_seen(
        %Catalog.PackVersion{} = pack_version,
        %DateTime{} = seen_at
      ) do
    pack_version
    |> Ecto.Changeset.change(last_seen_at: seen_at)
    |> Repo.update!()
  end

  @doc "Test inspector: every pack-version row for one account, in catalog order."
  def list_pack_versions(account_id) do
    Catalog.PackVersion.Query.all()
    |> Catalog.PackVersion.Query.by_account_id(account_id)
    |> Catalog.PackVersion.Query.ordered_by_pack()
    |> Repo.all()
  end

  @doc """
  Inserts a REJECTED pack version row with NOTHING recorded — the legacy
  shape a pre-revoke-era reject left behind (it cleared both hashes).
  `Catalog.reject_pack_version/2` can no longer build it (rejects now keep
  the refused hash), so the nothing-to-trust paths arrange it here.
  """
  def create_empty_rejected_pack_version(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || raise ":account_id is required"
    now = DateTime.utc_now()

    params = %{
      account_id: account_id,
      pack_id: attrs[:pack_id] || "acme-tools",
      version: attrs[:version] || "9.9",
      trust_state: :rejected,
      first_seen_at: now,
      last_seen_at: now
    }

    {:ok, pack_version} =
      Catalog.PackVersion.Changeset.insert(params)
      |> Repo.insert()

    pack_version
  end
end
