defmodule Emisar.Catalog do
  @moduledoc """
  Pack and action observation, plus per-pack trust pinning.

  Every time a runner advertises `runner_state` we upsert
  `pack_versions` (with TOFU/baseline pinning) and the runner's
  actions, and prune actions that disappeared.

  ## Trust model

  `pack_versions` is keyed `(account_id, pack_id, version)`. Each row
  holds the trusted hash plus optionally a pending hash. Dispatch
  is refused while a row is pending. Pinning:

    * **First sight of a `(pack_id, version)`** —
      * Hash matches `PackBaseline.lookup/2` → auto-pin trusted.
      * Hash differs from baseline → pin baseline as trusted,
        record advertised as pending (operator review required).
      * No baseline (third-party pack) → TOFU pin advertised.

    * **Subsequent sight** —
      * Same as trusted hash → no-op (touch last_seen).
      * Different → keep trusted, set pending_hash. Dispatch refuses.

    * **Rejected rows remember the refused bytes** — a rejected
      advertisement keeps its hash in `pending_hash` (and a revoked
      trust keeps `hash`), so re-advertising the same bytes stays
      quiet; only a genuinely new hash re-opens the `:pending` review.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Repo, Runners}
  alias Emisar.Auth.Subject
  alias Emisar.Catalog.{ActionSetDiff, Authorizer, PackBaseline}
  alias Emisar.Catalog.{PackVersion, RunnerAction, TrustedManifest}
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      job_module("PackVersionRetention")
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # The 1.0 catalog contains 80 packs and 1,270 actions. These limits leave
  # substantial growth headroom while bounding the per-advertisement DB work
  # an authenticated but hostile runner can trigger.
  @max_advertised_packs 128
  @max_advertised_actions 2_048

  @doc """
  Observe the full `runner_state` payload: upsert pack_versions and
  the runner's actions, prune actions that disappeared from the
  latest advertisement. Also applies hostname/labels/version to the
  runner row in the same transaction.

  Internal — called by the runner socket process which is itself
  authenticated by the runner token. Not exposed to LV/MCP.
  """
  def observe_state(%Runners.Runner{} = runner, %{} = payload) do
    observe_state(runner, payload, nil)
  end

  def observe_state(runner_id, payload) when is_binary(runner_id) do
    case Emisar.Runners.peek_runner_by_id(runner_id) do
      %Runners.Runner{} = runner -> observe_state(runner, payload)
      nil -> {:error, :unknown_runner}
    end
  end

  @doc """
  Ingests a runner-state envelope only while the socket still owns the supplied
  connection generation and lease. Each durable mutation rechecks ownership
  under the runner-row lock, so a successor claim fences an in-flight stale
  socket rather than relying on a separate preflight read.
  """
  def observe_state_from_connection(
        runner_id,
        %{} = payload,
        generation,
        lease_id
      )
      when is_binary(runner_id) and is_integer(generation) and is_binary(lease_id) do
    case Emisar.Runners.peek_runner_by_id(runner_id) do
      %Runners.Runner{} = runner ->
        observe_state(runner, payload, {generation, lease_id})

      nil ->
        {:error, :unknown_runner}
    end
  end

  defp observe_state(runner, payload, connection) do
    with {:ok, packs, actions} <- validate_catalog_payload(payload) do
      observe_validated_state(runner, payload, packs, actions, connection)
    end
  end

  defp observe_validated_state(runner, payload, packs, actions, connection) do
    case apply_runner_facts(runner, payload, connection) do
      {:error, :not_found} ->
        connection_error(connection)

      {:ok, updated_runner} ->
        case sync_catalog(updated_runner, packs, actions, connection) do
          {:ok, pending_changed?} ->
            # Light up the pack-trust badge only when the pending set actually
            # moved (drift / new custom pack), and only after the commit.
            if pending_changed?, do: broadcast_pack_trust(updated_runner.account_id)

            {:ok, updated_runner}

          {:error, :connection_superseded} ->
            {:error, :connection_superseded}

          {:error, reason} ->
            Logger.warning(
              "catalog sync for runner #{updated_runner.id} failed: #{inspect(reason)}"
            )

            {:ok, updated_runner}
        end
    end
  end

  defp connection_error(nil), do: {:error, :unknown_runner}
  defp connection_error({_generation, _lease_id}), do: {:error, :connection_superseded}

  # Commit the runner-row facts (version, group, hostname, labels) FIRST,
  # in their own transaction. They must land on every reconnect even when
  # the heavier pack/action catalog sync is slow, errors, or the socket
  # dies mid-sync — folding them into one transaction once pinned runners
  # to stale versions whenever a single bad action rolled the batch back.
  #
  # `apply_state` can return `{:error, changeset}` on a stale-struct race
  # or a bad/oversized field from untrusted runner JSON; keep the existing
  # struct on error (the next heartbeat re-syncs) rather than crashing the
  # socket.
  defp apply_runner_facts(%Runners.Runner{} = runner, payload, connection) do
    result =
      case connection do
        nil ->
          Emisar.Runners.apply_state(runner, payload)

        {generation, lease_id} ->
          Emisar.Runners.apply_state_from_connection(runner, payload, generation, lease_id)
      end

    case result do
      {:ok, updated} ->
        {:ok, updated}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("apply_state for runner #{runner.id} failed: #{inspect(reason)}")
        {:ok, runner}
    end
  end

  # One transaction for the catalog facts: pin/refresh every advertised
  # pack, upsert the advertised actions, prune the vanished ones.
  # Returns {:ok, pending_changed?} — whether this advertisement put a
  # new pack decision in front of the operator (drives the badge).
  #
  # Best-effort by design: the catalog re-syncs on the next runner_state,
  # so a raise must never crash the runner socket (the durable runner-row
  # facts are already saved by then).
  defp sync_catalog(%Runners.Runner{} = runner, packs, actions, connection) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case fetch_catalog_connection_owner(runner, connection) do
        {:ok, _active_runner} ->
          pending_changed? =
            packs
            |> Enum.map(&observe_pack(runner.account_id, &1, now))
            |> Enum.any?(&(&1 == :pending_changed))

          seen_ids =
            actions
            |> Enum.map(&observe_action(runner, &1, packs, now))
            |> Enum.reject(&is_nil/1)

          _ = prune_missing_actions(runner.id, actions, seen_ids)
          pending_changed?

        {:error, :not_found} ->
          Repo.rollback(connection_reason(connection))
      end
    end)
  rescue
    error -> {:error, error}
  end

  defp validate_catalog_payload(payload) do
    packs = payload["packs"]
    actions = payload["actions"]

    with :ok <- validate_advertised_packs(packs),
         :ok <- validate_advertised_actions(actions) do
      {:ok, packs, actions}
    end
  end

  defp validate_advertised_packs(packs) when is_map(packs) do
    count = map_size(packs)

    if count <= @max_advertised_packs do
      :ok
    else
      invalid_catalog("packs contains #{count} entries; maximum is #{@max_advertised_packs}")
    end
  end

  defp validate_advertised_packs(_packs) do
    invalid_catalog("packs must be an object with at most #{@max_advertised_packs} entries")
  end

  defp validate_advertised_actions(actions) when is_list(actions) do
    count = length(actions)

    if count <= @max_advertised_actions do
      :ok
    else
      invalid_catalog("actions contains #{count} entries; maximum is #{@max_advertised_actions}")
    end
  end

  defp validate_advertised_actions(_actions) do
    invalid_catalog("actions must be an array with at most #{@max_advertised_actions} entries")
  end

  defp invalid_catalog(message), do: {:error, {:invalid_catalog, message}}

  defp fetch_catalog_connection_owner(runner, nil) do
    Runners.fetch_and_lock_active_runner(runner.id, runner.account_id, repo: Repo)
  end

  defp fetch_catalog_connection_owner(runner, {generation, lease_id}) do
    Runners.fetch_and_lock_connection_owner(
      runner.account_id,
      runner.id,
      generation,
      lease_id,
      repo: Repo
    )
  end

  defp connection_reason(nil), do: :unknown_runner
  defp connection_reason({_generation, _lease_id}), do: :connection_superseded

  # -- Pack-version pinning --------------------------------------------

  # One sighting of (account, pack_id, version) = ONE upsert: first sight
  # inserts the pin computed from the baseline below; any later (or
  # concurrent) sight only refreshes last_seen_at, and RETURNING hands
  # back the canonical row for the drift judgment. The conflict update
  # deliberately never touches the trust fields — the existing row's
  # state machine must be JUDGED (judge_drift/3), not replaced; this is
  # the documented exception to the plain-upsert rule.
  #
  # Pin decision on first sight:
  #
  #   * Baseline + match → auto-pin trusted (bytes match the shipped
  #     pack library).
  #   * Baseline + mismatch → pin BASELINE as trusted, advertised as
  #     pending; operator must Trust to adopt or Reject to keep the
  #     library baseline. Dispatch refuses in the meantime.
  #   * No baseline (self-written / third-party pack) → pending with NO
  #     trusted hash; a human must Trust in /app/packs before any of
  #     its actions can run.
  #
  # Returns :pending_changed when this sighting put a new decision in
  # front of the operator (fresh pending pin, or drift on a known row).
  defp observe_pack(account_id, {pack_id, info}, now) when is_map(info) do
    version = info["version"] || "unknown"
    advertised = info["hash"]
    baseline = PackBaseline.lookup(pack_id, version)

    {trusted_hash, pending_hash, trust_state, trusted_manifest, audit_event} =
      cond do
        is_binary(baseline) and baseline == advertised ->
          {advertised, nil, :trusted, PackBaseline.manifest(pack_id, version, advertised),
           :pack_trust_baseline_match}

        is_binary(baseline) ->
          {baseline, advertised, :pending, PackBaseline.manifest(pack_id, version, baseline),
           :pack_trust_baseline_mismatch}

        true ->
          {nil, advertised, :pending, nil, :pack_trust_review_required}
      end

    changeset =
      PackVersion.Changeset.insert(%{
        account_id: account_id,
        pack_id: pack_id,
        version: version,
        hash: trusted_hash,
        pending_hash: pending_hash,
        trust_state: trust_state,
        trusted_manifest: trusted_manifest,
        first_seen_at: now,
        last_seen_at: now
      })

    case Repo.insert(changeset,
           on_conflict: [set: [last_seen_at: now]],
           conflict_target: [:account_id, :pack_id, :version],
           returning: true
         ) do
      {:ok, %PackVersion{} = pack_version} ->
        if DateTime.compare(pack_version.first_seen_at, now) == :eq do
          # Fresh pin — this sighting inserted it.
          Audit.record(Audit.Events.pack_pinned(pack_version, audit_event, advertised, baseline))
          if pack_version.trust_state == :pending, do: :pending_changed, else: :ok
        else
          judge_drift(pack_version, advertised, now)
        end

      {:error, _changeset} ->
        # Malformed advertisement (oversized/bad field) — skip this pack,
        # keep the rest of the batch.
        :ok
    end
  end

  # Skip a malformed (non-map) pack advertisement rather than letting
  # `info["version"]` raise and abort the whole sync (the valid packs +
  # actions in the same batch should still persist).
  defp observe_pack(_account_id, _entry, _now), do: :ok

  # Known row + new advertisement. The upsert already refreshed
  # last_seen_at; the only state change worth writing (and auditing) is
  # a hash we haven't seen — trusted→pending or pending-on-a-new-hash.
  # A previously recorded pending_hash is deliberately kept until an
  # operator decides via Trust/Reject, not by whichever runner
  # heartbeats next.
  defp judge_drift(%PackVersion{} = pack_version, advertised, now) do
    cond do
      pack_version.hash == advertised ->
        restore_baseline_manifest(pack_version)

      pack_version.pending_hash == advertised ->
        :ok

      true ->
        {:ok, _updated} =
          pack_version
          |> PackVersion.Changeset.mark_pending(advertised, now)
          |> Repo.update()

        Audit.record(Audit.Events.pack_trust_drift_detected(pack_version, advertised))
        :pending_changed
    end
  end

  # Rows trusted before complete manifests existed are upgraded only from the
  # release-frozen catalog and only when the exact trusted hash still matches.
  # Runner-advertised prose never becomes trusted through this repair path.
  defp restore_baseline_manifest(%PackVersion{} = pack_version) do
    case TrustedManifest.validate(pack_version.trusted_manifest) do
      {:ok, _manifest} -> :ok
      {:error, :incomplete_manifest} -> persist_baseline_manifest(pack_version)
    end
  end

  defp persist_baseline_manifest(%PackVersion{} = pack_version) do
    manifest =
      PackBaseline.manifest(pack_version.pack_id, pack_version.version, pack_version.hash)

    case manifest do
      nil ->
        :ok

      %{} ->
        changeset = PackVersion.Changeset.restore_baseline_manifest(pack_version, manifest)

        case Repo.update(changeset) do
          {:ok, _updated} -> :ok
          {:error, _changeset} -> :ok
        end
    end
  end

  # -- Trust / Reject mutators -----------------------------------------

  @doc """
  Adopt the pending hash as the new trusted hash. Snapshots the action set
  advertised for this `(pack_id, version)` into `trusted_manifest` in the
  SAME transaction as the flip, so a later re-advertised hash can be diffed
  against what was trusted. Also serves a `:rejected` row — adopt the refused
  bytes, or restore a revoked row's recorded hash (the fix-admin-mistake
  path). Records who clicked and audits the adoption. Returns
  `{:error, :not_pending}` when there's nothing to decide and
  `{:error, :nothing_to_trust}` for a rejected row with no recorded hash.
  """
  def trust_pack_version(pack_version_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ) do
      overridden_by_id = Subject.actor_id(subject)

      Multi.new()
      |> Multi.run(:before, fn repo, _changes ->
        lock_trustable_pack_version(repo, pack_version_id, subject)
      end)
      |> Multi.run(:manifest, fn repo, %{before: pack_version} ->
        trusted_manifest_source(repo, pack_version)
      end)
      # Trusting a RETIRED version IS the override — an explicit,
      # permission-gated action. Compute it inside the transaction (retirement
      # is release-controlled, so this can't race the lock) and thread it to
      # both the changeset and the audit payload from one source.
      |> Multi.run(:retired, fn _repo, %{before: pack_version} ->
        {:ok, PackBaseline.retired?(pack_version.pack_id, pack_version.version)}
      end)
      |> Multi.run(:pack_version, fn repo,
                                     %{before: pack_version, manifest: manifest, retired: retired} ->
        repo.update(trust_changeset(pack_version, manifest, retired, overridden_by_id))
      end)
      |> Multi.insert(:audit, fn %{before: pack_version, retired: retired} ->
        Audit.Events.pack_trust_adopted(subject, pack_version, retired)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{pack_version: updated} ->
          broadcast_pack_trust(updated.account_id)
          :ok
        end
      )
      |> case do
        {:ok, %{pack_version: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reject the pending hash.

  Two cases:

    * The row has a previously-trusted hash (baseline-mismatch or a
      drift event after an earlier Trust). Reject drops `pending_hash`
      and reverts `trust_state` to `"trusted"` — the previously
      trusted bytes remain authoritative; dispatch resumes.

    * The row has NO trusted hash yet (a custom / self-written pack
      that was just observed for the first time). Reject marks the row
      `:rejected` — it is NOT deleted, because `runner_actions` reference
      this `(pack_id, version)` by string with no FK, so a deleted row
      reads as "missing" which the dispatch gate USED to treat as trusted
      (fail-open). The persisted `:rejected` state fails dispatch CLOSED.
      The refused bytes stay in `pending_hash`, so a runner re-advertising
      them is parked quietly (`judge_drift`) instead of re-opening the
      review; only a genuinely NEW hash flips it back to `:pending`.
  """
  def reject_pack_version(pack_version_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ) do
      Multi.new()
      |> Multi.run(:before, fn repo, _changes ->
        lock_pending_pack_version(repo, pack_version_id, subject)
      end)
      |> Multi.run(:pack_version, fn repo, %{before: pending} ->
        repo.update(reject_changeset(pending))
      end)
      |> Multi.insert(:audit, fn %{before: pending} ->
        Audit.Events.pack_trust_rejected(subject, pending)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{pack_version: pack_version} ->
          broadcast_pack_trust(pack_version.account_id)
          :ok
        end
      )
      |> case do
        {:ok, %{pack_version: pack_version}} -> {:ok, pack_version}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Reject reverts to a previously-trusted hash when one exists, else marks
  # the never-trusted row `:rejected` (kept, not deleted — see the docstring).
  defp reject_changeset(%PackVersion{hash: nil} = pack_version),
    do: PackVersion.Changeset.reject_untrusted(pack_version)

  defp reject_changeset(%PackVersion{} = pack_version),
    do: PackVersion.Changeset.reject(pack_version)

  # Adopt the hash (pending or restored), and — when the version is retired —
  # stamp the override in the SAME changeset so trusting a retired version
  # re-enables dispatch atomically with the trust flip.
  defp trust_changeset(%PackVersion{} = pack_version, manifest, true, overridden_by_id) do
    pack_version
    |> adopt_trust_changeset(manifest)
    |> PackVersion.Changeset.override_retirement(overridden_by_id)
  end

  defp trust_changeset(%PackVersion{} = pack_version, manifest, false, _overridden_by_id),
    do: adopt_trust_changeset(pack_version, manifest)

  defp adopt_trust_changeset(%PackVersion{} = pack_version, :restore),
    do: PackVersion.Changeset.restore_trust(pack_version)

  defp adopt_trust_changeset(%PackVersion{} = pack_version, %{} = manifest),
    do: PackVersion.Changeset.trust(pack_version, manifest)

  # What the trust adopts: a row carrying a pending_hash snapshots the
  # complete advertised descriptor set for those exact bytes; a revoked row
  # with no pending hash restores its recorded hash + manifest instead.
  defp trusted_manifest_source(_repo, %PackVersion{pending_hash: nil}), do: {:ok, :restore}

  defp trusted_manifest_source(repo, %PackVersion{} = pack_version),
    do: snapshot_action_set(repo, pack_version)

  @doc """
  Explicitly re-trust an already-trusted pack version whose version the
  shipped catalog has RETIRED — the deliberate, audited admin override that
  lets it dispatch again. The `Trust` action covers a still-pending retired
  version; this covers a row that was trusted BEFORE its version was retired.
  Requires the same manage-catalog permission as Trust; returns
  `{:error, :not_trusted}` for a non-trusted row and `{:error, :not_found}`
  cross-account.
  """
  def override_pack_retirement(pack_version_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ) do
      overridden_by_id = Subject.actor_id(subject)

      if Repo.valid_uuid?(pack_version_id) do
        PackVersion.Query.all()
        |> PackVersion.Query.by_id(pack_version_id)
        |> Authorizer.for_subject(subject)
        |> Repo.fetch_and_update(PackVersion.Query,
          with: &override_retirement_changeset(&1, overridden_by_id),
          audit: &Audit.Events.pack_retirement_overridden(subject, &1),
          after_commit: fn updated ->
            broadcast_pack_trust(updated.account_id)
            :ok
          end
        )
      else
        {:error, :not_found}
      end
    end
  end

  # Only a TRUSTED row can be overridden (the override re-enables dispatch for
  # a version trusted before it was retired). Any other state aborts the
  # fetch_and_update as `{:error, :not_trusted}`.
  defp override_retirement_changeset(
         %PackVersion{trust_state: :trusted} = pack_version,
         overridden_by_id
       ),
       do: PackVersion.Changeset.override_retirement(pack_version, overridden_by_id)

  defp override_retirement_changeset(%PackVersion{}, _overridden_by_id), do: :not_trusted

  @doc """
  Revoke trust in a version — the inverse of Trust for an accidental adopt,
  and the quiet way to silence a retired version's warning without allowing
  it to dispatch. The row moves to `:rejected` (dispatch fails closed, no
  review alert), keeps its recorded hash + manifest so trust can be restored
  later, and clears any retirement override so a re-trust must re-decide it.
  Requires `manage_catalog`; returns `{:error, :not_trusted}` for a
  non-trusted row and `{:error, :not_found}` cross-account.
  """
  def revoke_pack_version_trust(pack_version_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ) do
      if Repo.valid_uuid?(pack_version_id) do
        PackVersion.Query.all()
        |> PackVersion.Query.by_id(pack_version_id)
        |> Authorizer.for_subject(subject)
        |> Repo.fetch_and_update(PackVersion.Query,
          with: &revoke_trust_changeset/1,
          audit: &Audit.Events.pack_trust_revoked(subject, &1),
          after_commit: fn updated ->
            broadcast_pack_trust(updated.account_id)
            :ok
          end
        )
      else
        {:error, :not_found}
      end
    end
  end

  # Only a TRUSTED row can be revoked; any other state aborts as :not_trusted.
  defp revoke_trust_changeset(%PackVersion{trust_state: :trusted} = pack_version),
    do: PackVersion.Changeset.revoke_trust(pack_version)

  defp revoke_trust_changeset(%PackVersion{}), do: :not_trusted

  # Locked, account-scoped re-read shared by the trust-state deciders
  # (`FOR NO KEY UPDATE`): two operators racing decisions on the same row
  # serialize, and the loser judges the winner's already-flipped state
  # instead of overwriting it.
  defp lock_pack_version(repo, pack_version_id, %Subject{} = subject) do
    if Repo.valid_uuid?(pack_version_id) do
      queryable =
        PackVersion.Query.all()
        |> PackVersion.Query.by_id(pack_version_id)
        |> PackVersion.Query.lock_for_update()
        |> Authorizer.for_subject(subject)

      repo.fetch(queryable, PackVersion.Query)
    else
      {:error, :not_found}
    end
  end

  # Reject decides a live pending review only.
  defp lock_pending_pack_version(repo, pack_version_id, %Subject{} = subject) do
    with {:ok, pack_version} <- lock_pack_version(repo, pack_version_id, subject) do
      judge_pending(pack_version)
    end
  end

  defp judge_pending(%PackVersion{trust_state: :pending, pending_hash: hash} = pack_version)
       when not is_nil(hash),
       do: {:ok, pack_version}

  defp judge_pending(%PackVersion{}), do: {:error, :not_pending}

  # Trust decides a live pending review OR a rejected row (adopt the refused
  # bytes / restore revoked trust). A rejected row with nothing recorded (a
  # pre-revoke-era reject that cleared both hashes) has nothing to adopt
  # until a runner advertises the pack again.
  defp lock_trustable_pack_version(repo, pack_version_id, %Subject{} = subject) do
    with {:ok, pack_version} <- lock_pack_version(repo, pack_version_id, subject) do
      judge_trustable(pack_version)
    end
  end

  defp judge_trustable(%PackVersion{trust_state: :pending, pending_hash: hash} = pack_version)
       when not is_nil(hash),
       do: {:ok, pack_version}

  defp judge_trustable(%PackVersion{trust_state: :rejected, pending_hash: nil, hash: nil}),
    do: {:error, :nothing_to_trust}

  defp judge_trustable(%PackVersion{trust_state: :rejected} = pack_version),
    do: {:ok, pack_version}

  defp judge_trustable(%PackVersion{}), do: {:error, :not_pending}

  # -- Deletion ----------------------------------------------------------

  @doc """
  Delete one observed pack version — the pin row AND the runner-action rows
  advertising that exact `(pack_id, version)`. The catalog is derived state:
  a runner still advertising this version re-inserts it as a fresh trust
  decision on its next advertisement (connect or reload), which the UI warns
  about. Audit history persists (events reference versions by snapshot).
  Requires `manage_catalog`; `{:error, :not_found}` cross-account.
  """
  def delete_pack_version(pack_version_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ) do
      Multi.new()
      |> Multi.run(:pack_version, fn repo, _changes ->
        lock_pack_version(repo, pack_version_id, subject)
      end)
      |> Multi.run(:actions, fn repo, %{pack_version: pack_version} ->
        queryable =
          RunnerAction.Query.all()
          |> RunnerAction.Query.by_account_id(pack_version.account_id)
          |> RunnerAction.Query.by_pack(pack_version.pack_id, pack_version.version)

        {count, _} = repo.delete_all(queryable)
        {:ok, count}
      end)
      |> Multi.delete(:deleted, fn %{pack_version: pack_version} -> pack_version end)
      |> Multi.insert(:audit, fn %{pack_version: pack_version, actions: action_count} ->
        Audit.Events.pack_version_deleted(subject, pack_version, action_count)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{pack_version: pack_version} ->
          broadcast_pack_trust(pack_version.account_id)
          :ok
        end
      )
      |> case do
        {:ok, %{pack_version: pack_version}} -> {:ok, pack_version}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Delete every observed version of a pack — all its pin rows AND all its
  runner-action rows in the subject's account. Same derived-state semantics
  as `delete_pack_version/2`: a runner still advertising the pack re-inserts
  it as a fresh trust decision. One `pack_deleted` audit event carries the
  removed versions. Requires `manage_catalog`; `{:error, :not_found}` when
  the account has no versions of `pack_id`.
  """
  def delete_pack(pack_id, %Subject{} = subject) when is_binary(pack_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ) do
      Multi.new()
      |> Multi.run(:versions, fn repo, _changes ->
        lock_pack_versions_by_pack_id(repo, pack_id, subject)
      end)
      |> Multi.run(:actions, fn repo, %{versions: [version | _]} ->
        queryable =
          RunnerAction.Query.all()
          |> RunnerAction.Query.by_account_id(version.account_id)
          |> RunnerAction.Query.by_pack_id(pack_id)

        {count, _} = repo.delete_all(queryable)
        {:ok, count}
      end)
      |> Multi.run(:deleted, fn repo, %{versions: versions} ->
        # Exactly the locked (and audited) set — a version observed after the
        # lock survives and simply reappears in the list, which is the
        # documented derived-state semantics.
        queryable =
          PackVersion.Query.all()
          |> PackVersion.Query.by_ids(Enum.map(versions, & &1.id))

        {count, _} = repo.delete_all(queryable)
        {:ok, count}
      end)
      |> Multi.insert(:audit, fn %{versions: versions, actions: action_count} ->
        Audit.Events.pack_deleted(subject, pack_id, versions, action_count)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{versions: [version | _]} ->
          broadcast_pack_trust(version.account_id)
          :ok
        end
      )
      |> case do
        {:ok, %{versions: versions}} -> {:ok, versions}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Locked, account-scoped read of every version row of a pack — the
  # whole-pack delete works from this exact set, so a version observed after
  # the lock re-inserts (documented semantics) instead of vanishing silently.
  defp lock_pack_versions_by_pack_id(repo, pack_id, %Subject{} = subject) do
    queryable =
      PackVersion.Query.all()
      |> PackVersion.Query.by_pack_id(pack_id)
      |> PackVersion.Query.lock_for_update()
      |> Authorizer.for_subject(subject)

    case repo.all(queryable) do
      [] -> {:error, :not_found}
      versions -> {:ok, versions}
    end
  end

  # -- Retention ---------------------------------------------------------

  @doc """
  Run the pack-retention sweep for the subject's account right now — the
  packs page "Clean up now" button. Uses the account's configured window
  (`settings.pack_unseen_retention_days`); `{:error, :retention_disabled}`
  when automatic cleanup is off. Requires `manage_catalog`. Returns
  `{:ok, deleted_count}`.
  """
  def sweep_unseen_pack_versions(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ),
         {:ok, days} <- fetch_retention_days(subject) do
      delete_unseen_pack_versions(subject.account.id, days, subject)
    end
  end

  # The subject's account struct is a socket snapshot — read the setting fresh.
  defp fetch_retention_days(%Subject{account: %{id: account_id}}) do
    case Accounts.fetch_account_settings(account_id) do
      {:ok, %{pack_unseen_retention_days: days}} when is_integer(days) and days > 0 ->
        {:ok, days}

      {:ok, _settings} ->
        {:error, :retention_disabled}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Internal — the pack-retention sweep for one account: the daily
  `Catalog.Jobs.PackVersionRetention` tick (no subject → system audit actor)
  and `sweep_unseen_pack_versions/1` (operator actor). Deletes every pack
  version no runner has advertised for `days` days — pin rows and their
  advertised action rows — and records ONE `pack_retention_swept` audit
  event only when something was removed. Returns `{:ok, deleted_count}`.
  """
  def delete_unseen_pack_versions(account_id, days, subject \\ nil)
      when is_binary(account_id) and is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Multi.new()
    |> Multi.run(:versions, fn repo, _changes ->
      queryable =
        PackVersion.Query.all()
        |> PackVersion.Query.by_account_id(account_id)
        |> PackVersion.Query.last_seen_before(cutoff)
        |> PackVersion.Query.lock_for_update()

      {:ok, repo.all(queryable)}
    end)
    |> Multi.run(:actions, fn repo, %{versions: versions} ->
      {:ok, delete_advertised_actions(repo, account_id, versions)}
    end)
    |> Multi.run(:deleted, fn repo, %{versions: versions} ->
      queryable =
        PackVersion.Query.all()
        |> PackVersion.Query.by_ids(Enum.map(versions, & &1.id))

      {count, _} = repo.delete_all(queryable)
      {:ok, count}
    end)
    |> Multi.run(:audit, fn repo, %{versions: versions} ->
      record_retention_sweep(repo, versions, days, subject)
    end)
    |> Repo.commit_multi(
      after_commit: fn %{deleted: deleted} ->
        if deleted > 0, do: broadcast_pack_trust(account_id)
        :ok
      end
    )
    |> case do
      {:ok, %{deleted: deleted}} -> {:ok, deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_advertised_actions(_repo, _account_id, []), do: 0

  defp delete_advertised_actions(repo, account_id, versions) do
    Enum.reduce(versions, 0, fn %PackVersion{} = version, total ->
      queryable =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_account_id(account_id)
        |> RunnerAction.Query.by_pack(version.pack_id, version.version)

      {count, _} = repo.delete_all(queryable)
      total + count
    end)
  end

  # No marker when nothing was removed — scheduled housekeeping must not
  # manufacture audit noise on inactive accounts.
  defp record_retention_sweep(_repo, [], _days, _subject), do: {:ok, :nothing_removed}

  defp record_retention_sweep(repo, versions, days, subject) do
    actor = subject || hd(versions).account_id
    repo.insert(Audit.Events.pack_retention_swept(actor, versions, days))
  end

  # The complete descriptors advertised for the exact pending hash — read
  # inside the trust transaction so adopting the hash and its reviewed model
  # contract is atomic. Rows for another runner's different hash are excluded.
  defp snapshot_action_set(repo, %PackVersion{} = pack_version) do
    actions =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_account_id(pack_version.account_id)
      |> RunnerAction.Query.by_pack(pack_version.pack_id, pack_version.version)
      |> RunnerAction.Query.by_pack_hash(pack_version.pending_hash)
      |> repo.all()

    case TrustedManifest.from_runner_actions(actions) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, :invalid_manifest} -> {:error, :invalid_manifest}
    end
  end

  # -- Dispatch gate ---------------------------------------------------

  @doc """
  Internal — `Runs.dispatch_run` calls this before queueing a run.
  Returns `:ok` if the action's `(pack_id, pack_version)` is trusted,
  `{:error, :pack_untrusted, info}` otherwise.

  The action carries `pack_version` populated by `observe_action`
  based on the runner's last-reported `runner_state.packs` payload.

  A pack-less action (no `pack_id`), or one whose `pack_version` the runner
  hasn't reported yet, has no version to pin and passes. For a fully versioned
  pack (both `pack_id` and `pack_version`), trust is fail-CLOSED: only an
  explicit `:trusted` pin allows dispatch. A MISSING pin row (the old design
  DELETED it on reject), `:pending`, or `:rejected` all refuse — `runner_actions`
  reference the version by string with no FK, so a missing row must never read
  as trusted.

  A trusted row whose version the shipped catalog has RETIRED
  (`PackBaseline.retired?/2`) refuses with a distinct `{:error,
  :pack_retired, pack_version}` unless an admin has overridden it — the
  operator action differs (update the pack vs. review a hash).
  """
  def check_pack_trusted(%RunnerAction{pack_id: nil}), do: {:ok, nil}
  def check_pack_trusted(%RunnerAction{pack_version: nil}), do: {:ok, nil}

  def check_pack_trusted(%RunnerAction{} = action) do
    case peek_pack_version_for_action(action) do
      %PackVersion{trust_state: :trusted} = pack_version ->
        retired? = PackBaseline.retired?(pack_version.pack_id, pack_version.version)
        trusted_row_dispatch_decision(pack_version, retired?)

      %PackVersion{} = pack_version ->
        {:error, :pack_untrusted, pack_version}

      nil ->
        # Fail closed: a versioned pack with no pin row is untrusted, not
        # trusted. `:no_pin` carries no PackVersion struct — the caller audits
        # off the action instead.
        {:error, :pack_untrusted, :no_pin}
    end
  end

  @doc """
  Internal — the dispatch decision for a TRUSTED pack-version row, given
  whether the shipped catalog retired its version. Pattern-matched clause
  heads carry the exhaustive branch coverage because the compiled
  `PackBaseline` can't be fixtured; `check_pack_trusted/1` composes this
  with the real `PackBaseline.retired?/2`.

  Not retired → hand back the trusted hash so the caller can SNAPSHOT it onto
  the run; never the pending one, so the runner verifies the bytes the
  operator actually said yes to. Retired with an explicit override → still
  trusted. Retired with no override → fail closed with `:pack_retired`.
  """
  @spec trusted_row_dispatch_decision(PackVersion.t(), boolean()) ::
          {:ok, String.t()} | {:error, :pack_retired, PackVersion.t()}
  def trusted_row_dispatch_decision(%PackVersion{hash: hash}, false), do: {:ok, hash}

  def trusted_row_dispatch_decision(
        %PackVersion{retirement_overridden_at: %DateTime{}, hash: hash},
        true
      ),
      do: {:ok, hash}

  def trusted_row_dispatch_decision(
        %PackVersion{retirement_overridden_at: nil} = pack_version,
        true
      ),
      do: {:error, :pack_retired, pack_version}

  @doc """
  Retirement state of a pack row against the shipped catalog, for the Packs
  page: `:active`, or `{:retired, current_version}` when the row's version is
  below its pack's retirement watermark — `current_version` is the fixed
  version to update to (`nil` if we no longer ship the pack). Pure over the
  release-frozen `PackBaseline`. An already-overridden row still reports
  `{:retired, _}`; the override is a row field (`retirement_overridden_at`) the
  caller reads alongside.
  """
  @spec pack_version_retirement(PackVersion.t()) :: :active | {:retired, String.t() | nil}
  def pack_version_retirement(%PackVersion{pack_id: pack_id, version: version}) do
    if PackBaseline.retired?(pack_id, version) do
      {:retired, PackBaseline.current_version(pack_id)}
    else
      :active
    end
  end

  @doc """
  Whether a trusted pack version has a newer shipped successor to update to —
  `{:outdated, successor}` for a NON-retired version below the current shipped
  version, else `:current`. A convenience signal, not a warning: a security fix
  RETIRES a version (packs retire only on security/critical fixes), so an
  outdated-but-not-retired version is safe by construction and still dispatches.
  Retirement takes precedence — a retired version reads `:current` here so the
  stronger rose retired block shows alone, never the gentle hint on top of it.
  Pure over the release-frozen `PackBaseline`; the packs LiveView reads it.
  """
  @spec pack_version_outdated(PackVersion.t()) :: {:outdated, String.t()} | :current
  def pack_version_outdated(%PackVersion{pack_id: pack_id, version: version}) do
    with false <- PackBaseline.retired?(pack_id, version),
         successor when is_binary(successor) <- PackBaseline.newer_version(pack_id, version) do
      {:outdated, successor}
    else
      _ -> :current
    end
  end

  @doc """
  The content hash the release ships for `(pack_id, version)`, or nil when we
  don't ship it — the `--hash` integrity pin for an `emisar pack install`
  command that updates a runner to a shipped version. Pure over the
  release-frozen `PackBaseline`.
  """
  @spec shipped_hash(String.t(), String.t() | nil) :: String.t() | nil
  def shipped_hash(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: PackBaseline.lookup(pack_id, version)

  def shipped_hash(_, _), do: nil

  @doc """
  A version awaiting an operator decision: a pending trust review, or a
  trusted version whose shipped-catalog retirement blocks dispatch until an
  admin overrides, updates, revokes, or deletes it. Rejected and overridden
  rows are decided. Pure over the release-frozen `PackBaseline`; drives the
  sidebar badge and the packs page attention notices.
  """
  def pack_version_needs_decision?(%PackVersion{trust_state: :pending}), do: true

  def pack_version_needs_decision?(%PackVersion{
        trust_state: :trusted,
        retirement_overridden_at: nil,
        pack_id: pack_id,
        version: version
      }),
      do: PackBaseline.retired?(pack_id, version)

  def pack_version_needs_decision?(%PackVersion{}), do: false

  # The pinned pack_version row for an action's (account, pack_id, version),
  # or nil — shared by the two dispatch-gate reads. `peek` (nil-or-struct)
  # per §1.1: a missing row is a meaningful "nothing pinned yet" state.
  defp peek_pack_version_for_action(%RunnerAction{} = action) do
    PackVersion.Query.all()
    |> PackVersion.Query.by_account_id(action.account_id)
    |> PackVersion.Query.by_pack_id_and_version(action.pack_id, action.pack_version)
    |> Repo.peek()
  end

  # -- Action upsert ---------------------------------------------------

  defp observe_action(%Runners.Runner{} = runner, descriptor, packs, now)
       when is_map(descriptor) do
    pack_id = descriptor["pack_id"]

    {primary_executable_available, missing_executable} =
      primary_executable_availability(descriptor)

    # `packs` is untrusted runner-advertised state: a descriptor can name a
    # pack_id that isn't in the packs map, or map to a non-map. Pull the
    # version defensively so one malformed descriptor doesn't abort the whole
    # batch's action upsert (vs. `packs[pack_id]["version"]` raising BadMapError).
    {pack_version, pack_hash} =
      case packs[pack_id] do
        %{"version" => version, "hash" => hash} -> {version, hash}
        %{"version" => version} -> {version, nil}
        _ -> {nil, nil}
      end

    attrs = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: descriptor["id"],
      pack_id: pack_id,
      pack_version: pack_version,
      pack_hash: pack_hash,
      title: descriptor["title"] || descriptor["id"],
      summary: descriptor["summary"],
      # `kind`/`risk` are RUNNER-ADVERTISED. The dispatch gate reads them
      # catalog-authoritative (runs.ex) so the MCP/operator CALLER can't spoof
      # "low", but the runner that ships the pack authors them: for a pack with a
      # compiled baseline the risk lives inside the trusted hash; for a TOFU pack
      # (no baseline) trusting the hash = trusting the declared risk — an accepted
      # limitation, like the runner-declared group. See docs/security-model.md.
      kind: descriptor["kind"] || "exec",
      risk: descriptor["risk"] || "low",
      description: descriptor["description"],
      side_effects: descriptor["side_effects"] || [],
      args_schema: %{"args" => descriptor["args"] || []},
      examples: descriptor["examples"] || [],
      search_terms: descriptor["search_terms"] || [],
      primary_executable_available: primary_executable_available,
      missing_executable: missing_executable,
      first_seen_at: now,
      last_seen_at: now
    }

    existing =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_account_runner_and_action(
        runner.account_id,
        runner.id,
        descriptor["id"]
      )
      |> Repo.peek()

    case existing do
      nil ->
        changeset = RunnerAction.Changeset.upsert(attrs)

        case Repo.insert(changeset) do
          {:ok, %RunnerAction{action_id: id}} -> id
          {:error, _} -> nil
        end

      %RunnerAction{} = row ->
        changeset = RunnerAction.Changeset.update(row, attrs)

        case Repo.update(changeset) do
          {:ok, %RunnerAction{action_id: id}} -> id
          {:error, _} -> nil
        end
    end
  end

  # A runner can advertise a malformed (non-map) action descriptor; skip it
  # (the caller rejects nils) rather than letting `descriptor["id"]` raise and
  # abort the whole batch's action upsert.
  defp observe_action(_runner, _descriptor, _packs, _now), do: nil

  # The field is additive: absence means an older runner and stays unknown.
  # Malformed present values fail closed. The executable is diagnostic only,
  # normalized before storage because the authenticated runner is hostile input.
  defp primary_executable_availability(descriptor) do
    case Map.fetch(descriptor, "primary_executable_available") do
      :error ->
        {nil, nil}

      {:ok, true} ->
        {true, nil}

      {:ok, false} ->
        {false, normalize_missing_executable(descriptor["missing_executable"])}

      {:ok, _malformed} ->
        {false, "unknown"}
    end
  end

  defp normalize_missing_executable(executable)
       when is_binary(executable) and executable != "" do
    executable
    |> String.replace(~r/[\p{Cc}\p{Cf}\p{Cs}]/u, "")
    |> String.slice(0, 255)
    |> case do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp normalize_missing_executable(_invalid), do: "unknown"

  defp prune_missing_actions(runner_id, [], _seen_action_ids) do
    RunnerAction.Query.all()
    |> RunnerAction.Query.by_runner_id(runner_id)
    |> Repo.delete_all()
  end

  defp prune_missing_actions(_runner_id, _advertised_actions, []), do: :ok

  defp prune_missing_actions(runner_id, _advertised_actions, seen_action_ids) do
    RunnerAction.Query.all()
    |> RunnerAction.Query.by_runner_id(runner_id)
    |> RunnerAction.Query.except_action_ids(seen_action_ids)
    |> Repo.delete_all()
  end

  # -- Reads -----------------------------------------------------------

  @doc """
  Actions advertised by a runner, scoped to the subject's account.
  Returns `{:ok, [runner_action], %Paginator.Metadata{}}`.
  """
  def list_actions_for_runner(runner_id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      # No pre-ordering: the query module's cursor drives the ORDER BY so it
      # matches the keyset WHERE.
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(RunnerAction.Query, opts)
    end
  end

  @doc """
  Distinct pack ids advertised by a runner, as `{pack_id, pack_id}` options for
  the runner-detail action catalog's Pack filter (the pack id IS the display
  name). Same `view_catalog` gate + account scoping as the other catalog reads;
  returns `{:ok, [{pack_id, label}]}` sorted for a stable dropdown.
  """
  def list_action_pack_options_for_runner(runner_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      pack_ids =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_runner_id(runner_id)
        |> RunnerAction.Query.distinct_pack_ids()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, pack_ids |> Enum.sort() |> Enum.map(&{&1, &1})}
    end
  end

  @doc """
  Every advertised catalog action for the subject's account — the
  COMPLETE set, deliberately un-paginated.

  This is the MCP path. `tools/list` and dispatch resolution must see
  the whole catalog, not a page: a single runner with a handful of
  packs advertises hundreds of actions. Same `view_catalog` gate +
  account scoping; returns `{:ok, actions}` — there is no cursor.
  """
  def list_all_actions_for_account(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      actions =
        RunnerAction.Query.all()
        |> RunnerAction.Query.ordered_by_action_seen()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, actions}
    end
  end

  @doc """
  `%{action_id => most-severe risk}` for a set of `action_id`s, in ONE
  account-scoped query — the runbook list resolves every listed runbook's
  steps' risks at once (no per-runbook DB call). Same `view_catalog` gate +
  account scoping as the other catalog reads; returns `{:ok, %{}}` for an
  empty id list without touching the DB.

  Only `action_id`s a connected runner advertises appear in the map — an
  unobserved step is simply absent, which `max_risk/1` treats conservatively
  (no false-low). Folds the rows through `most_severe_risk_by_action/1`, so an
  action advertised by several runners at mixed risk keeps the worst.
  """
  def risk_by_action_ids([], %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      {:ok, %{}}
    end
  end

  def risk_by_action_ids(action_ids, %Subject{} = subject) when is_list(action_ids) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      actions =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_action_ids(action_ids)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, most_severe_risk_by_action(actions)}
    end
  end

  # Severity rank for `RunnerAction.risk` (an Ecto.Enum) — lets us pick the
  # WORST risk when the same action is advertised by more than one runner.
  @risk_rank %{low: 0, medium: 1, high: 2, critical: 3}

  @doc """
  Builds `%{action_id => risk}` from already-fetched `%RunnerAction{}` rows
  (e.g. from `list_all_actions_for_account/1`), keeping the MOST-SEVERE risk
  per action_id. The same action_id can appear on several runners with
  different risk (mixed pack versions, a stale runner). A runbook UI that
  warns before a fleet-wide group dispatch must show the worst a targeted
  runner would apply, not whichever runner phoned home last — the latter
  would under-state risk in exactly that case.
  """
  def most_severe_risk_by_action(runner_actions) when is_list(runner_actions) do
    Enum.reduce(runner_actions, %{}, fn %RunnerAction{action_id: id, risk: risk}, acc ->
      Map.update(acc, id, risk, &most_severe(&1, risk))
    end)
  end

  defp most_severe_risk_by_action_rows(rows) when is_list(rows) do
    Enum.reduce(rows, %{}, fn {_runner_id, action_id, risk}, acc ->
      Map.update(acc, action_id, risk, &most_severe(&1, risk))
    end)
  end

  defp most_severe(current, candidate) do
    if Map.get(@risk_rank, candidate, 0) > Map.get(@risk_rank, current, 0),
      do: candidate,
      else: current
  end

  @doc """
  The single most-severe risk across a list of risks (atoms, or `nil` for an
  unresolved step), using the same `@risk_rank` as `most_severe_risk_by_action/1`.
  Returns that worst risk, or `nil` when the list is empty.

  Conservative on the unknown: an unresolvable risk in the list (a step whose
  action no connected runner advertises, so it's `nil`) sorts at the bottom of
  the rank and never *lowers* the result — but if EVERY risk is unknown the
  result is `nil`, so the caller shows no pill rather than a falsely-low one.
  This is a security product: a critical step must never be under-flagged, and
  a runbook of all-unknown steps must not read as "low".
  """
  def max_risk(risks) when is_list(risks) do
    case Enum.reject(risks, &is_nil/1) do
      [] -> nil
      [first | rest] -> Enum.reduce(rest, first, &most_severe(&2, &1))
    end
  end

  @doc """
  The account's advertised catalog as `%{action_id => risk}` — DISTINCT actions,
  most-severe risk winning when one action is advertised at mixed risk across
  runners. The policy page derives BOTH the risk breakdown (`risk_breakdown_of/1`)
  and the live policy outcome (`Policies.simulate_outcome/2`) from it. Inherits
  `list_all_actions_for_account/1`'s `view_catalog` gate + account scope;
  `{:ok, %{action_id => risk}}`.
  """
  def action_risks_for_account(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      rows =
        RunnerAction.Query.all()
        |> RunnerAction.Query.select_action_risk_rows()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, most_severe_risk_by_action_rows(rows)}
    end
  end

  @doc """
  Compact, account-scoped action risk index for policy previews.

  Returns the account-wide `%{action_id => worst_risk}` plus each runner's own
  `%{action_id => risk}` from one `view_catalog`-gated query that selects only
  `{runner_id, action_id, risk}`. Policy rails use this instead of loading full
  `runner_actions` structs or issuing one query per targeted ruleset.
  """
  def action_risk_index_for_account(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      rows =
        RunnerAction.Query.all()
        |> RunnerAction.Query.select_action_risk_rows()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, action_risk_index(rows)}
    end
  end

  @doc """
  Same as `action_risks_for_account/1` but scoped to a set of runners — the
  policy page uses it per targeted ruleset (a group resolves to its runners'
  ids at the call site) so the rail speaks for THAT runner or group.
  `view_catalog` gated + account-scoped (`for_subject`, so a foreign runner id
  contributes nothing); an empty id list is the empty map, still gated.
  `{:ok, %{action_id => risk}}`.
  """
  def action_risks_for_runner_ids([], %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      {:ok, %{}}
    end
  end

  def action_risks_for_runner_ids(runner_ids, %Subject{} = subject) when is_list(runner_ids) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      rows =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_runner_ids(runner_ids)
        |> RunnerAction.Query.select_action_risk_rows()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, most_severe_risk_by_action_rows(rows)}
    end
  end

  @doc """
  Derives `%{action_id => worst_risk}` for `runner_ids` from an
  `action_risk_index_for_account/1` result. Pure and intentionally tolerant:
  unknown runner ids contribute nothing, matching the account-scoped query path.
  """
  def action_risks_from_index(%{runners: actions_by_runner}, runner_ids)
      when is_list(runner_ids) do
    runner_ids
    |> Enum.flat_map(&Map.get(actions_by_runner, &1, %{}))
    |> Enum.reduce(%{}, fn {action_id, risk}, acc ->
      Map.update(acc, action_id, risk, &most_severe(&1, risk))
    end)
  end

  defp action_risk_index(rows) when is_list(rows) do
    Enum.reduce(rows, %{account: %{}, runners: %{}}, &add_action_risk_row/2)
  end

  defp add_action_risk_row({runner_id, action_id, risk}, index) do
    account = Map.update(index.account, action_id, risk, &most_severe(&1, risk))

    runners =
      Map.update(index.runners, runner_id, %{action_id => risk}, fn actions ->
        Map.update(actions, action_id, risk, &most_severe(&1, risk))
      end)

    %{index | account: account, runners: runners}
  end

  @doc """
  The per-tier action count of an `%{action_id => risk}` map (from
  `action_risks_for_*`) — `%{"low" => n, "medium" => n, "high" => n,
  "critical" => n}`. Pure — no gate; the caller already fetched the map. All four
  tiers are present (0 for a tier no action carries).
  """
  def risk_breakdown_of(action_risks) when is_map(action_risks) do
    counts = Enum.frequencies_by(action_risks, fn {_id, risk} -> risk end)

    Map.new([:low, :medium, :high, :critical], fn risk ->
      {Atom.to_string(risk), Map.get(counts, risk, 0)}
    end)
  end

  @doc """
  Lookup a single catalog action row by (runner, action_id) scoped to
  the subject's account.
  """
  def fetch_action_by_id(action_id, runner_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ),
         true <- Repo.valid_uuid?(runner_id) do
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> RunnerAction.Query.by_action_id(action_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(RunnerAction.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Internal: same lookup as `fetch_action_by_id/3` but scoped to an explicit
  account instead of a `%Subject{}`. For the system-side dispatch paths (the
  pack-hash stamp and the runbook continuation) that already authorized
  upstream and run where no user is in scope.
  """
  def fetch_action_for_account(action_id, runner_id, account_id) do
    RunnerAction.Query.all()
    |> RunnerAction.Query.by_runner_id(runner_id)
    |> RunnerAction.Query.by_action_id(action_id)
    |> RunnerAction.Query.by_account_id(account_id)
    |> Repo.fetch(RunnerAction.Query)
  end

  def list_pack_versions(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      PackVersion.Query.all()
      |> apply_pack_version_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(PackVersion.Query, opts)
    end
  end

  @doc "Returns every pack-version row in the subject's account after the view-catalog gate."
  @spec list_all_pack_versions_for_account(Subject.t()) ::
          {:ok, [PackVersion.t()]} | {:error, :unauthorized}
  def list_all_pack_versions_for_account(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      pack_versions =
        PackVersion.Query.all()
        |> PackVersion.Query.ordered_by_pack()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, pack_versions}
    end
  end

  # Rendering concern: the Packs page passes `preload:
  # [:retirement_overridden_by]` only where it renders the retirement-override
  # note; a counting caller omits it and pays for no join. Unknown atoms raise.
  defp apply_pack_version_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :retirement_overridden_by, queryable ->
        PackVersion.Query.with_preloaded_retirement_overridden_by(queryable)
    end)
  end

  @doc """
  Runner ids currently advertising `pack_id` at `pack_version` — the blast
  radius of trusting that version (which hosts will be allowed to run it).
  Account-scoped via the subject. Returns `{:ok, [runner_id]}`.
  """
  def runner_ids_advertising_pack(pack_id, pack_version, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      runner_ids =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_pack(pack_id, pack_version)
        |> RunnerAction.Query.distinct_runner_ids()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, runner_ids}
    end
  end

  @doc """
  The distinct actions a pack version advertises — the catalog rows deduped to
  one per `action_id`, sorted, so a trust decision shows WHAT the version can do
  (action + risk), not just its hash. Account-scoped via the subject. Returns
  `{:ok, [%RunnerAction{}]}`.
  """
  def list_pack_actions(pack_id, pack_version, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      actions =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_pack(pack_id, pack_version)
        |> RunnerAction.Query.ordered_by_action()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> most_severe_actions_by_id()

      {:ok, actions}
    end
  end

  @doc """
  Every pack version's advertised actions across the account in ONE read, keyed
  by `{pack_id, pack_version}` and deduped to one row per `action_id`. The Packs
  page uses it to filter packs by risk tier or action name without a per-version
  query. Account-scoped via the subject. Returns
  `{:ok, %{{pack_id, pack_version} => [%RunnerAction{}]}}`.
  """
  def pack_actions_index(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      index =
        RunnerAction.Query.all()
        |> RunnerAction.Query.ordered_by_action()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> Enum.group_by(&{&1.pack_id, &1.pack_version})
        |> Map.new(fn {key, actions} -> {key, most_severe_actions_by_id(actions)} end)

      {:ok, index}
    end
  end

  defp most_severe_actions_by_id(actions) do
    actions
    |> Enum.group_by(& &1.action_id)
    |> Enum.map(fn {_action_id, actions} ->
      Enum.max_by(actions, fn action -> {@risk_rank[action.risk] || 0, to_string(action.kind)} end)
    end)
    |> Enum.sort_by(& &1.action_id)
  end

  @doc """
  Diff a pending pack version's NEWLY-advertised action set against the
  `trusted_manifest` snapshotted when its hash was last trusted — so the
  re-trust UI shows what changed (added / removed / risk-or-kind-changed),
  not just a new hash.

  Pure over already-authorized data: pass the `%PackVersion{}` (loaded via a
  Subject-gated read) and its advertised `%RunnerAction{}` rows (from
  `list_pack_actions/3`). A nil manifest (trusted before this feature, or never
  trusted) yields an empty diff — the UI falls back to listing the actions.
  Returns `%{added: [...], removed: [...], changed: [...]}`.
  """
  def action_set_changes(%PackVersion{} = pack_version, advertised_actions)
      when is_list(advertised_actions) do
    pending_actions =
      Enum.filter(advertised_actions, &(&1.pack_hash == pack_version.pending_hash))

    ActionSetDiff.changes(pending_actions, pack_version.trusted_manifest)
  end

  @doc """
  Return a complete trusted action manifest for static/MCP reads.

  This is deliberately stricter than the execution trust gate: historical
  trusted rows with null or sparse manifests keep their dispatch semantics, but
  cannot supply model-facing prose or schemas until an operator reviews a new
  hash. The caller must already hold an account-scoped row.
  """
  @spec trusted_manifest_for_static_reads(PackVersion.t()) ::
          {:ok, map()} | {:error, :pack_untrusted | :incomplete_manifest}
  def trusted_manifest_for_static_reads(%PackVersion{trust_state: :trusted} = pack_version),
    do: TrustedManifest.validate(pack_version.trusted_manifest)

  def trusted_manifest_for_static_reads(%PackVersion{}), do: {:error, :pack_untrusted}

  @doc """
  Cheap count of pack versions awaiting an operator decision — pending trust
  reviews PLUS retired-blocked trusted versions (see
  `pack_version_needs_decision?/1`) — drives the sidebar + dashboard badge.
  Same Subject gate + account scoping as `list_pack_versions/2`; returns `0`
  when the caller lacks permission so the badge silently disappears instead
  of erroring.
  """
  def count_pack_versions_needing_decision(%Subject{} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      :ok ->
        pending =
          PackVersion.Query.pending()
          |> Authorizer.for_subject(subject)
          |> Repo.aggregate(:count)

        pending + count_retired_blocked(subject)

      _ ->
        0
    end
  end

  # Retirement is compile-time data (`PackBaseline`), so the version
  # comparison happens in Elixir over a narrow read: trusted, unoverridden
  # rows of the packs that carry a watermark at all.
  defp count_retired_blocked(%Subject{} = subject) do
    watermarked_pack_ids = Map.keys(PackBaseline.retired_below())

    queryable =
      PackVersion.Query.trusted_unoverridden()
      |> PackVersion.Query.by_pack_ids(watermarked_pack_ids)
      |> Authorizer.for_subject(subject)

    queryable
    |> Repo.all()
    |> Enum.count(&pack_version_needs_decision?/1)
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's pack-trust badge signal (`{:pack_trust_changed, account_id}`)."
  def subscribe_account_packs(account_id),
    do: Emisar.PubSub.subscribe(account_packs_topic(account_id))

  defp account_packs_topic(account_id), do: "account:#{account_id}:packs"

  # Pack-trust badge signal: a pack version just became pending (drift or
  # a new custom pack) or was resolved (Trust/Reject). Subscribers
  # recompute the "needs review" count. Fired only after the mutation
  # commits, so a rolled-back observe can't light up the badge.
  defp broadcast_pack_trust(account_id) when is_binary(account_id) do
    Emisar.PubSub.broadcast(account_packs_topic(account_id), {:pack_trust_changed, account_id})
  end

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may view the pack catalog (the console nav + section gate)."
  def subject_can_view_packs?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_catalog_permission())

  @doc "Whether `subject` may manage packs (admin+)."
  def subject_can_manage_packs?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_catalog_permission())
end
