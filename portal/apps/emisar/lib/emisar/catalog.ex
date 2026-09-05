defmodule Emisar.Catalog do
  @moduledoc """
  Pack and action observation, plus per-pack trust pinning.

  Every time a runner advertises `runner_state` we upsert
  `pack_versions` (with baseline pinning and pending review) and the runner's
  actions, and prune actions that disappeared.

  ## Trust model

  `pack_versions` is keyed `(account_id, pack_id, version)`. Each row
  holds the trusted hash plus optionally a pending hash. Dispatch
  is refused while a row is pending. Pinning:

    * **First sight of a `(pack_id, version)`** —
      * Hash matches `PackBaseline.lookup/2` → auto-pin trusted.
      * Hash differs from baseline → pin baseline as trusted,
        record advertised as pending (operator review required).
      * No baseline (third-party pack) → record advertised as pending
        with no trusted hash (operator review required).

    * **Subsequent sight** —
      * Same as trusted hash → no-op (touch last_seen).
      * Different → keep trusted, set pending_hash. Dispatch refuses.
      * Same as a never-trusted pending hash the baseline now carries →
        auto-pin trusted on the published manifest. A later publish of
        those exact bytes IS the answer to the review.

    * **Rejected rows remember the refused bytes** — a rejected
      advertisement keeps its hash in `pending_hash` (and a revoked
      trust keeps `hash`), so re-advertising the same bytes stays
      quiet; only a genuinely new hash re-opens the `:pending` review.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, ActionContract, Audit, Auth, Repo, Runners, SafeText, Telemetry}
  alias Emisar.Auth.Subject
  alias Emisar.Catalog.{Authorizer, ConsoleProjection, EditorProjection}
  alias Emisar.Catalog.{MCPProjection, PackBaseline, PackRetentionInput}
  alias Emisar.Catalog.{PackVersion, PublishedRegistry}
  alias Emisar.Catalog.{RunnerAction, TrustedManifest}
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      # The published catalog the pack pages, the registry endpoints, and the
      # command preview read. Loads the bundled artifact synchronously, so it
      # is populated before the Endpoint accepts a request.
      PublishedRegistry.Cache,
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

  # Every column a re-advertisement may refresh — that is, all of them but the
  # identity, `first_seen_at`, and `inserted_at`. Also the ON CONFLICT replace
  # list, so an existing action's row is brought fully up to date.
  @upsert_replace_fields ~w[
    action_id pack_id pack_version pack_hash title summary kind risk description
    side_effects args_schema output_schema examples search_terms descriptor_digest
    primary_executable_available missing_executable last_seen_at updated_at
  ]a

  # Postgres caps a statement at 65,535 bindings and a row here spends about
  # twenty, so a full 2,048-action advertisement stays a few statements while
  # each one keeps well clear of the limit.
  @upsert_chunk_size 500

  # The console Packs page renders its whole inventory at once, so the read is
  # bounded rather than paged — well above the 80 packs the 1.0 catalog ships.
  @console_pack_version_limit 500

  # How many runners the page reads to answer "who is on this version". Above
  # this the answer is explicitly partial, so the console never turns a short
  # list into "no runner is on it".
  @console_advertising_runner_limit 100

  # One runbook's execution items are capped at this same number, so a single
  # compile always fits; a caller resolving several runbooks at once splits its
  # requests into reads of this size.
  @max_candidate_requests 256

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
            # Refresh pack-trust surfaces only when the pending set changes
            # (opened by a new/drifted pack or resolved by the baseline), and
            # only after the commit.
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

  # The catalog facts in TWO transactions: pin/refresh every advertised pack,
  # then upsert this runner's advertised actions and prune the vanished ones.
  # Returns {:ok, pending_changed?} — whether this advertisement opened or
  # resolved a pending pack decision (drives the badge and open Packs pages).
  #
  # Best-effort by design: the catalog re-syncs on the next runner_state,
  # so a raise must never crash the runner socket (the durable runner-row
  # facts are already saved by then).
  defp sync_catalog(%Runners.Runner{} = runner, packs, actions, connection) do
    now = DateTime.utc_now()

    with {:ok, pending_changed?} <- pin_advertised_packs(runner, packs, connection, now),
         {:ok, _seen_ids} <- sync_advertised_actions(runner, actions, packs, connection, now) do
      {:ok, pending_changed?}
    end

    # Narrow: a transient DB/connection blip re-syncs on the next runner_state and
    # must not crash the socket, but a bare rescue also swallowed a real bug in
    # the observe path — which the caller then logs and reports as success — so
    # let a programmer error surface instead.
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  # Pack pins are the SHARED rows: every runner advertising the same
  # pack@version upserts the same `pack_versions` row, and that row stays
  # locked until its transaction commits. Holding it through the advertising
  # runner's whole action upsert + prune made a fleet-wide reconnect serialize
  # — each host waiting out the previous host's entire sync. Committing the
  # pins on their own keeps that contention proportional to the pins.
  defp pin_advertised_packs(%Runners.Runner{} = runner, packs, connection, now) do
    Multi.new()
    |> Multi.run(:owner, fn _repo, _changes ->
      case fetch_catalog_connection_owner(runner, connection) do
        {:ok, active_runner} -> {:ok, active_runner}
        {:error, :not_found} -> {:error, connection_reason(connection)}
      end
    end)
    |> Multi.run(:pins, fn _repo, _changes ->
      observe_packs(runner.account_id, packs, now)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{pins: pending_changed?}} -> {:ok, pending_changed?}
      {:error, reason} -> {:error, reason}
    end
  end

  # This runner's OWN rows (`catalog_runner_actions` is keyed by runner_id), so
  # nothing here contends with a peer. The connection owner is re-checked
  # because a socket superseded between the two commits must not write, and
  # the runner-row lock it takes is per-runner.
  #
  # A pin committed without its actions is the same fail-closed state the
  # runner-facts commit already produces ahead of this sync: the advertised
  # deployment has no matching descriptors, so it compares as a mismatch and
  # is not executable. It never reads as trusted-and-runnable.
  defp sync_advertised_actions(%Runners.Runner{} = runner, actions, packs, connection, now) do
    Multi.new()
    |> Multi.run(:owner, fn _repo, _changes ->
      case fetch_catalog_connection_owner(runner, connection) do
        {:ok, active_runner} -> {:ok, active_runner}
        {:error, :not_found} -> {:error, connection_reason(connection)}
      end
    end)
    |> Multi.run(:actions, fn _repo, _changes ->
      seen_ids = observe_actions(runner, actions, packs, now)
      {:ok, prune_missing_actions(runner.id, actions, seen_ids)}
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{actions: pruned}} -> {:ok, pruned}
      {:error, reason} -> {:error, reason}
    end
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

  # One runner_state = ONE sorted upsert for every valid advertised pin. A
  # reconnect therefore holds the shared pack rows for one statement instead
  # of issuing (and serializing) up to 128 statements. RETURNING hands back the
  # canonical row for each drift judgment. The conflict update deliberately
  # never touches trust fields — the existing row's state machine must be
  # JUDGED (judge_drift/4), not replaced.
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
  # Candidate ids distinguish the transaction that actually inserted a row
  # from concurrent conflicts, so first-sight audit is emitted exactly once.
  # Results are all materialized before reducing the pending flag: reducing
  # with Enum.any?/2 over the work itself would stop after the first change and
  # silently skip later packs.
  defp observe_packs(account_id, packs, now) do
    observations =
      packs
      |> Enum.map(&pack_observation(account_id, &1, now))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1.pack_id, &1.version})

    returned_by_ref =
      observations
      |> upsert_pack_observations(now)
      |> Map.new(&{{&1.pack_id, &1.version}, &1})

    results =
      Enum.map(observations, fn observation ->
        pack_version = Map.fetch!(returned_by_ref, {observation.pack_id, observation.version})
        judge_pack_observation(pack_version, observation, now)
      end)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.any?(results, &(&1 == :pending_changed))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pack_observation(account_id, {pack_id, %{"hash" => advertised} = info}, now)
       when is_binary(advertised) and advertised != "" do
    version = info["version"] || "unknown"
    verdict = baseline_verdict(pack_id, version, advertised)
    candidate_id = Repo.generate_id()

    changeset =
      PackVersion.Changeset.insert(%{
        account_id: account_id,
        pack_id: pack_id,
        version: version,
        hash: verdict.trusted_hash,
        pending_hash: verdict.pending_hash,
        trust_state: verdict.trust_state,
        trusted_manifest: verdict.trusted_manifest,
        first_seen_at: now,
        last_seen_at: now
      })

    if changeset.valid? do
      entry =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.take([
          :account_id,
          :pack_id,
          :version,
          :hash,
          :pending_hash,
          :trust_state,
          :trusted_manifest,
          :first_seen_at,
          :last_seen_at
        ])
        |> Map.merge(%{
          id: candidate_id,
          inserted_at: now,
          updated_at: now
        })

      %{
        advertised: advertised,
        candidate_id: candidate_id,
        entry: entry,
        pack_id: pack_id,
        verdict: verdict,
        version: version
      }
    else
      # Malformed advertisement (oversized/bad field) — skip this pack,
      # keep the rest of the batch.
      nil
    end
  end

  # Skip a malformed (non-map) or hash-less pack advertisement rather than
  # letting `info["version"]` raise and abort the whole sync (the valid packs +
  # actions in the same batch should still persist). A hash the peer omitted is
  # nothing to review: it would erase the bytes an operator was asked about and
  # leave a pending row Trust and Reject both refuse forever, with dispatch
  # closed account-wide until someone deletes it.
  defp pack_observation(_account_id, _entry, _now), do: nil

  defp upsert_pack_observations([], _now), do: []

  defp upsert_pack_observations(observations, now) do
    entries = Enum.map(observations, & &1.entry)

    {_count, returned} =
      Repo.insert_all(PackVersion, entries,
        on_conflict: [set: [last_seen_at: now]],
        conflict_target: [:account_id, :pack_id, :version],
        returning: true
      )

    returned
  end

  defp judge_pack_observation(
         %PackVersion{id: candidate_id} = pack_version,
         %{candidate_id: candidate_id} = observation,
         _now
       ) do
    audit =
      Audit.Events.pack_pinned(
        pack_version,
        observation.verdict.audit_event,
        observation.advertised,
        observation.verdict.baseline
      )

    case Audit.record(audit) do
      {:ok, _event} ->
        if pack_version.trust_state == :pending, do: :pending_changed, else: :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp judge_pack_observation(%PackVersion{} = pack_version, observation, now) do
    judge_drift(pack_version, observation.advertised, observation.verdict, now)
  end

  # The pin these advertised bytes earn, judged purely against the published
  # baseline. ONE trust snapshot answers both halves of the verdict — the
  # canonical hash and the manifest for that exact hash — so a refresh landing
  # mid-judgement can never pin one catalog's hash against another's
  # descriptors. The conflict path recomputes the SAME verdict, so a row pinned
  # before we published the pack is judged by today's catalog instead of
  # waiting forever on a decision the registry has since made.
  defp baseline_verdict(pack_id, version, advertised) do
    trust = PublishedRegistry.Cache.trust_snapshot()
    baseline = Map.get(trust.baseline, {pack_id, version})

    cond do
      is_binary(baseline) and baseline == advertised ->
        %{
          baseline: baseline,
          trusted_hash: advertised,
          pending_hash: nil,
          trust_state: :trusted,
          trusted_manifest: Map.get(trust.manifests, {pack_id, version, advertised}),
          audit_event: :pack_trust_baseline_match
        }

      is_binary(baseline) ->
        %{
          baseline: baseline,
          trusted_hash: baseline,
          pending_hash: advertised,
          trust_state: :pending,
          trusted_manifest: Map.get(trust.manifests, {pack_id, version, baseline}),
          audit_event: :pack_trust_baseline_mismatch
        }

      true ->
        %{
          baseline: nil,
          trusted_hash: nil,
          pending_hash: advertised,
          trust_state: :pending,
          trusted_manifest: nil,
          audit_event: :pack_trust_review_required
        }
    end
  end

  # Known row + new advertisement. The upsert already refreshed
  # last_seen_at; the only state change worth writing (and auditing) is
  # a hash we haven't seen — trusted→pending or pending-on-a-new-hash.
  # A previously recorded pending_hash is deliberately kept until an
  # operator decides via Trust/Reject, not by whichever runner
  # heartbeats next — the one exception being bytes the release has since
  # published itself (reconcile_baseline_pending/3).
  defp judge_drift(%PackVersion{} = pack_version, advertised, verdict, now) do
    cond do
      pack_version.hash == advertised ->
        restore_baseline_manifest(pack_version)

      pack_version.pending_hash == advertised ->
        reconcile_baseline_pending(pack_version, advertised, verdict)

      true ->
        result =
          pack_version
          |> PackVersion.Changeset.mark_pending(advertised, now)
          |> Repo.update()

        case result do
          {:ok, _updated} ->
            case Audit.record(Audit.Events.pack_trust_drift_detected(pack_version, advertised)) do
              {:ok, _event} -> :pending_changed
              {:error, changeset} -> {:error, changeset}
            end

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  # A never-trusted row whose parked bytes this release now publishes: the
  # decision the operator was asked for has since been made by the release
  # itself, so adopt it on the published manifest instead of leaving a
  # question nobody can answer differently. Anything else keeps its state — a
  # rejected row stays refused, a row with a trusted hash keeps it (adopting
  # drift is an operator's call), and bytes the baseline doesn't carry stay
  # pending — as does a historical artifact the catalog retains no manifest
  # for, because trust snapshots that manifest.
  defp reconcile_baseline_pending(
         %PackVersion{trust_state: :pending, hash: nil} = pack_version,
         advertised,
         %{trust_state: :trusted, trusted_manifest: %{} = manifest} = verdict
       ) do
    changeset = PackVersion.Changeset.trust(pack_version, manifest)

    case Repo.update(changeset) do
      {:ok, %PackVersion{} = updated} ->
        audit =
          Audit.Events.pack_pinned(
            updated,
            :pack_trust_baseline_reconciled,
            advertised,
            verdict.baseline
          )

        case Audit.record(audit) do
          {:ok, _event} -> :pending_changed
          {:error, changeset} -> {:error, changeset}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp reconcile_baseline_pending(%PackVersion{}, _advertised, _verdict), do: :ok

  # Rows trusted before complete manifests existed are upgraded only from the
  # published catalog and only when the exact trusted hash still matches.
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
          {:error, changeset} -> {:error, changeset}
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
  `{:error, :not_pending}` when there's nothing to decide,
  `{:error, :nothing_to_trust}` for a rejected row with no recorded hash, and
  `{:error, {:descriptor_mismatch, action_id, runner_names}}` when the fleet's
  advertisements for the pending hash disagree about an action — trust stays
  blocked (fail-closed) and the UI names the disagreeing runners.
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
        trusted_manifest_source(repo, pack_version, subject)
      end)
      # Trusting a RETIRED version IS the override — an explicit,
      # permission-gated action. Compute it inside the transaction (retirement
      # is a lock-free read of the published snapshot, so this can't race the
      # lock) and thread it to both the changeset and the audit payload from
      # one source.
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
  defp trusted_manifest_source(_repo, %PackVersion{pending_hash: nil}, %Subject{}),
    do: {:ok, :restore}

  defp trusted_manifest_source(repo, %PackVersion{} = pack_version, %Subject{} = subject),
    do: snapshot_action_set(repo, pack_version, subject)

  @doc """
  Explicitly re-trust an already-trusted pack version whose version the
  published catalog has RETIRED — the deliberate, audited admin override that
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
        |> scope_pack_versions_to_subject(subject)
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
        |> scope_pack_versions_to_subject(subject)
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
  # instead of overwriting it. Pack access is judged on the LOCKED row rather
  # than on the id the caller sent, so the pack whose trust is being decided is
  # the pack that was checked.
  defp lock_pack_version(repo, pack_version_id, %Subject{} = subject) do
    if Repo.valid_uuid?(pack_version_id) do
      queryable =
        PackVersion.Query.all()
        |> PackVersion.Query.by_id(pack_version_id)
        |> scope_pack_versions_to_subject(subject)
        |> PackVersion.Query.lock_for_update()
        |> Authorizer.for_subject(subject)

      repo.fetch(queryable, PackVersion.Query)
    else
      {:error, :not_found}
    end
  end

  # Both dimensions `list_console_packs/2` narrows by — pack access AND the
  # runners the member can reach — so a version the console never showed cannot
  # be decided from an id lifted out of the audit trail. Composed into the
  # statement that locks the row, an out-of-scope version answers `:not_found`,
  # the same answer a cross-account id gets and before any state guard could
  # report whether it is trusted. Access is re-read here rather than taken from
  # the session, so a scope narrowed mid-session takes the decision away from an
  # already-open page immediately.
  defp scope_pack_versions_to_subject(queryable, %Subject{} = subject) do
    access = Accounts.runner_access_for_subject(subject)

    queryable
    |> scope_pack_versions_to_packs(access)
    |> scope_pack_versions_to_visible_runners(visible_deployments(subject, access))
  end

  # Reach a pack and you may decide its versions; cannot reach it and the pack
  # does not exist for you.
  defp pack_in_scope?(%PackVersion{} = pack_version, %Subject{} = subject) do
    access = Accounts.runner_access_for_subject(subject)
    Accounts.RunnerAccess.pack_in_scope?(pack_version.pack_id, access)
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
  # Pack access is judged on a locked row, not on the `pack_id` argument.
  defp lock_pack_versions_by_pack_id(repo, pack_id, %Subject{} = subject) do
    queryable =
      PackVersion.Query.all()
      |> PackVersion.Query.by_pack_id(pack_id)
      |> PackVersion.Query.lock_for_update()
      |> Authorizer.for_subject(subject)

    case repo.all(queryable) do
      [] -> {:error, :not_found}
      [version | _] = versions -> judge_pack_reach(versions, version, subject)
    end
  end

  # Deliberately the pack dimension only, NOT the runner dimension the
  # per-version deciders (`lock_pack_version/3`, override, revoke) use. Deleting
  # a whole pack removes the CATALOG entry — a pack-access operation, not a
  # decision about the versions a particular host happens to run — so a member
  # who may manage that pack may delete it whole, even if some versions are
  # deployed only on runners outside their reach. (Founder decision, 2026-08-28,
  # answering the D-5 sibling question: pack-level delete stays pack-scoped.)
  defp judge_pack_reach(versions, %PackVersion{} = version, %Subject{} = subject) do
    if pack_in_scope?(version, subject), do: {:ok, versions}, else: {:error, :not_found}
  end

  # -- Retention ---------------------------------------------------------

  @doc """
  Changeset for the account's pack-cleanup settings — the raw `days` period,
  where a blank value means automatic cleanup is off. Accepts the rail form's
  string keys or an atom-keyed map / keyword list; a malformed or non-positive
  period is a field error. Pure.
  """
  def change_pack_retention_settings(attrs \\ %{}), do: PackRetentionInput.changeset(attrs)

  @doc """
  Set how long a pack version may go unadvertised before the daily sweep
  removes it. Requires `manage_catalog` and unrestricted pack access — the
  schedule is account-wide, so a pack-restricted admin must not arm a sweep
  that reaches past their own scope — and `account` must be the subject's own.
  `attrs` is validated through `change_pack_retention_settings/1` before
  anything is written, so an invalid period never reaches the stored setting;
  a blank period turns automatic cleanup off. Returns
  `{:ok, %Accounts.Account{}}` or
  `{:error, %Ecto.Changeset{} | :unauthorized | :not_found}`.
  """
  def update_pack_retention_settings(%Accounts.Account{} = account, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_catalog_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id),
         :ok <- ensure_full_pack_access(subject),
         {:ok, %PackRetentionInput{days: days}} <- pack_retention_input(attrs) do
      Accounts.put_account_pack_retention_days(account.id, days, subject)
    end
  end

  defp ensure_full_pack_access(%Subject{} = subject) do
    if full_pack_access?(subject), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  What the account's stored cleanup setting means right now — `{:ok, days}`
  while automatic cleanup is on, `{:error, :retention_disabled}` when it is
  off or the stored period is not a usable positive number. Takes the account
  (the job sweep's row) or its settings (the operator sweep's fresh read).
  Both sweeps read the setting through here, so one contract decides when a
  destructive sweep may run.
  """
  def pack_retention_days(%Accounts.Account{settings: settings}),
    do: pack_retention_days(settings)

  def pack_retention_days(%Accounts.Account.Settings{} = settings) do
    case pack_retention_input(%{days: settings.pack_unseen_retention_days}) do
      {:ok, %PackRetentionInput{days: days}} when is_integer(days) -> {:ok, days}
      {:ok, %PackRetentionInput{}} -> {:error, :retention_disabled}
      {:error, %Ecto.Changeset{}} -> {:error, :retention_disabled}
    end
  end

  defp pack_retention_input(attrs) do
    attrs
    |> change_pack_retention_settings()
    |> Ecto.Changeset.apply_action(:insert)
  end

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

  # The manual "Clean up now" sweep is narrowed to the operator's own scope,
  # exactly as the trust decisions are — deleting a pin REMOVES a trust
  # decision, and the console never showed this member those versions. The daily
  # job passes no subject and stays account-wide, which is the same split
  # `Runners.scope_sweep_to_subject/2` makes for the fleet.
  defp scope_sweep_to_pack_access(queryable, %Subject{} = subject),
    do: scope_pack_versions_to_subject(queryable, subject)

  defp scope_sweep_to_pack_access(queryable, nil), do: queryable

  # The subject's account struct is a socket snapshot — read the setting fresh.
  defp fetch_retention_days(%Subject{account: %{id: account_id}}) do
    with {:ok, settings} <- Accounts.fetch_account_settings(account_id) do
      pack_retention_days(settings)
    end
  end

  @doc """
  Internal — the pack-retention sweep for one account: the daily
  `Catalog.Jobs.PackVersionRetention` tick (no subject → system audit actor)
  and `sweep_unseen_pack_versions/1` (operator actor). Deletes every pack
  version no runner has advertised for `days` days — pin rows and their
  advertised action rows — except versions a connected runner still
  advertises: runner_state is only re-sent on change, so a stable host's
  `last_seen_at` goes stale while its packs are live. Records ONE
  `pack_retention_swept` audit event only when something was removed.
  Returns `{:ok, deleted_count}`.
  """
  def delete_unseen_pack_versions(account_id, days, subject \\ nil)
      when is_binary(account_id) and is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    delete_pack_version_set(
      account_id,
      fn repo ->
        live_versions = live_advertised_versions(repo, account_id)

        PackVersion.Query.all()
        |> PackVersion.Query.by_account_id(account_id)
        |> PackVersion.Query.last_seen_before(cutoff)
        |> scope_sweep_to_pack_access(subject)
        |> PackVersion.Query.lock_for_update()
        |> repo.all()
        |> Enum.reject(&MapSet.member?(live_versions, {&1.pack_id, &1.version}))
      end,
      &Audit.Events.pack_retention_swept(subject || account_id, &1, days)
    )
  end

  @doc """
  Internal — the daily bookkeeping for retired versions, run for every
  account whatever its cleanup window: deletes each pack version the
  published catalog retired (`PackBaseline.retired?/2`) that no runner in the
  account advertises anymore — pin rows and their advertised action rows. Such
  a version is dead weight the fix already routed around: dispatch refuses
  it, nothing runs it, and the console's only remedy was removing it by hand.
  Advertisement is judged on every non-deleted runner's durable `packs` map,
  offline hosts included, so a version a host still lists is kept exactly as
  the console counts it. Records ONE `pack_retirement_swept` audit event
  (system actor) only when something was removed. Returns
  `{:ok, deleted_count}`.
  """
  def delete_unadvertised_retired_pack_versions(account_id) when is_binary(account_id) do
    delete_pack_version_set(
      account_id,
      fn repo ->
        advertised =
          account_id
          |> Runners.list_pack_advertisement_facts_for_account(repo: repo)
          |> advertised_pack_refs()

        PackVersion.Query.all()
        |> PackVersion.Query.by_account_id(account_id)
        |> PackVersion.Query.by_pack_ids(Map.keys(PackBaseline.retired_below()))
        |> PackVersion.Query.lock_for_update()
        |> repo.all()
        |> Enum.filter(&PackBaseline.retired?(&1.pack_id, &1.version))
        |> Enum.reject(&MapSet.member?(advertised, {&1.pack_id, &1.version}))
      end,
      &Audit.Events.pack_retirement_swept(account_id, &1)
    )
  end

  # The one transactional shape both bookkeeping sweeps share: lock the
  # candidate rows (`select_versions` picks them inside the transaction), drop
  # their advertised action rows, delete the pins, and insert the marker
  # `record` builds — only when something was removed, since scheduled
  # housekeeping must not manufacture audit noise on inactive accounts.
  defp delete_pack_version_set(account_id, select_versions, record) do
    Multi.new()
    |> Multi.run(:versions, fn repo, _changes -> {:ok, select_versions.(repo)} end)
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
    |> Multi.run(:audit, fn
      _repo, %{versions: []} -> {:ok, :nothing_removed}
      repo, %{versions: versions} -> repo.insert(record.(versions))
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

  # A version a connected runner still advertises is not "unseen": runners
  # re-send runner_state on reconnect, SIGHUP, and pack changes — not on a
  # timer — so a stable host's advertisement keeps `last_seen_at` frozen while
  # the pack stays live. Liveness comes from the durable connection-record
  # columns; an ungracefully dropped socket reads connected until its next
  # reconnect, which errs toward keeping rows — the safe direction for a
  # destructive sweep.
  defp live_advertised_versions(repo, account_id) do
    account_id
    |> Runners.list_pack_referencing_runners_for_account(repo: repo)
    |> advertised_pack_refs()
  end

  # The `{pack_id, version}` pairs a set of runners durably advertises — their
  # `packs` maps. Mirrors observe_pack/3's "unknown" version default so
  # protection matches pin creation.
  defp advertised_pack_refs(runners) do
    for runner <- runners,
        {pack_id, info} <- runner.packs,
        is_map(info),
        into: MapSet.new() do
      {pack_id, info["version"] || "unknown"}
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

  # The complete descriptors advertised for the exact pending hash — read
  # inside the trust transaction so adopting the hash and its reviewed model
  # contract is atomic. Rows for another runner's different hash are excluded.
  defp snapshot_action_set(repo, %PackVersion{} = pack_version, %Subject{} = subject) do
    actions =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_account_id(pack_version.account_id)
      |> RunnerAction.Query.by_pack(pack_version.pack_id, pack_version.version)
      |> RunnerAction.Query.by_pack_hash(pack_version.pending_hash)
      |> repo.all()

    case TrustedManifest.from_runner_actions(actions) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, {:descriptor_mismatch, action_id}} ->
        {:error,
         {:descriptor_mismatch, action_id,
          disagreeing_runner_names(pack_version.account_id, actions, action_id, subject)}}

      {:error, :invalid_manifest} ->
        {:error, :invalid_manifest}
    end
  end

  # Which runners to name when the fleet disagrees about `action_id` at the
  # pending hash: every runner advertising it THAT THIS MEMBER ALREADY REACHES.
  # With no trusted baseline there is no way to tell the honest advertisement
  # from the hostile one, so the error names them all — but a trust decision is
  # not a way to enumerate the fleet, so a runner-restricted member learns no
  # name the runners list would withhold. The list can narrow to empty, and the
  # console then states the block without naming anyone.
  defp disagreeing_runner_names(account_id, actions, action_id, %Subject{} = subject) do
    runner_ids =
      actions
      |> Enum.filter(&(&1.action_id == action_id))
      |> Enum.map(& &1.runner_id)
      |> Enum.uniq()
      |> narrow_to_runner_reach(account_id, subject)

    labels = Runners.runner_labels_for_ids(account_id, runner_ids)

    runner_ids
    |> Enum.map(&Map.get(labels, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  # `Runners.reachable_scope_values/2` is the one definition of which runners a
  # member may name, shared with the audit and policy reads. An unrestricted
  # member reaches the whole fleet, so skip the read entirely rather than
  # selecting every runner id to filter against.
  defp narrow_to_runner_reach(runner_ids, account_id, %Subject{} = subject) do
    case Accounts.runner_access_for_subject(subject) do
      %Accounts.RunnerAccess{mode: :all} ->
        runner_ids

      %Accounts.RunnerAccess{} = access ->
        {reachable_ids, _groups} = Runners.reachable_scope_values(account_id, access)
        reachable = MapSet.new(reachable_ids)
        Enum.filter(runner_ids, &MapSet.member?(reachable, &1))
    end
  end

  # -- Dispatch gate ---------------------------------------------------

  @doc """
  Internal inspection surface with no production caller — kept by decision
  (`@intended_api_surface` in `test/emisar/context_coverage_test.exs`) because
  its trust-matrix tests are the coverage of this classification. The live
  dispatch gate is `fetch_dispatch_contract/5`. Returns `{:ok, hash}` — the
  trusted hash a run snapshots — when the action's `(pack_id, pack_version)` is
  trusted, `{:error, :pack_untrusted, info}` or
  `{:error, :pack_retired, pack_version}` otherwise.

  The action carries `pack_version` populated by `observe_action`
  based on the runner's last-reported `runner_state.packs` payload.

  `pack_id` is required at ingestion, so a pack-less action no longer reaches
  here. An action that NAMES a pack but carries no resolved `pack_version`
  refuses (`:unresolved_pack_version`): ingestion no longer persists that shape,
  so a surviving row is stale hostile input, not a not-yet-reported version. For
  a fully versioned pack (both `pack_id` and `pack_version`), trust is
  fail-CLOSED: only an explicit `:trusted` pin allows dispatch. A MISSING pin row
  (the old design DELETED it on reject), `:pending`, or `:rejected` all refuse —
  `runner_actions` reference the version by string with no FK, so a missing row
  must never read as trusted.

  A trusted row whose version the published catalog has RETIRED
  (`PackBaseline.retired?/2`) refuses with a distinct `{:error,
  :pack_retired, pack_version}` unless an admin has overridden it — the
  operator action differs (update the pack vs. review a hash).
  """
  def check_pack_trusted(%RunnerAction{pack_version: nil}),
    do: {:error, :pack_untrusted, :unresolved_pack_version}

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
  Internal — `Runs` composes this into the dispatch transaction. Locks the
  pack version and the runner-action row, then authorizes dispatch from the
  TRUSTED manifest descriptor rather than the mutable runner advertisement:
  policy inputs (risk, kind, args schema, output schema) come from what the
  operator reviewed, and a drifted advertisement fails closed as
  `:action_contract_changed`.

  Every action names a pack, so an action carrying no resolved
  `(pack_id, pack_version, pack_hash)` fails closed as `:pack_ref_mismatch`
  rather than dispatching from the runner's own advertisement.
  """
  def fetch_dispatch_contract(repo, account_id, runner_id, action_id, pack_ref) do
    case fetch_action_for_account(action_id, runner_id, account_id) do
      {:ok, observed} -> fetch_dispatch_contract_for_action(repo, observed, pack_ref)
      {:error, :not_found} -> {:error, :action_not_found}
    end
  end

  defp fetch_dispatch_contract_for_action(repo, %RunnerAction{} = observed, pack_ref) do
    with {:ok, {pack_id, version, hash}} <- dispatch_pack_identity(observed, pack_ref),
         {:ok, pack_version} <-
           lock_dispatch_pack_version(repo, observed.account_id, pack_id, version),
         {:ok, trusted_hash} <- trusted_pack_version_hash(pack_version),
         :ok <- ensure_requested_hash_trusted(trusted_hash, hash, pack_version),
         {:ok, trusted_actions} <- TrustedManifest.actions(pack_version.trusted_manifest),
         %{} = descriptor <- Map.get(trusted_actions, observed.action_id),
         {:ok, action} <- lock_runner_action(repo, observed),
         true <- action.pack_id == pack_id,
         true <- action.pack_version == version,
         true <- action.pack_hash == hash,
         {:ok, current_descriptor} <- runner_action_descriptor(action),
         true <- current_descriptor == descriptor do
      {:ok, %{action: action, descriptor: descriptor, pack_hash: trusted_hash}}
    else
      {:error, :not_found} -> {:error, :action_not_found}
      {:error, :pack_retired, _pack_version} = error -> error
      {:error, :pack_untrusted, _pack_version} = error -> error
      _other -> {:error, :action_contract_changed}
    end
  end

  # One action rendered through the same builder as a trusted manifest, so the
  # drift comparison covers every model-facing field, including the optional
  # output contract — compared structurally, because the stored digest's
  # canonical form flattens objects into sorted pairs and so cannot tell an
  # object from the array of pairs it becomes.
  defp runner_action_descriptor(%RunnerAction{} = action) do
    with {:ok, manifest} <- TrustedManifest.from_runner_actions([action]),
         {:ok, actions} <- TrustedManifest.actions(manifest),
         %{} = descriptor <- Map.get(actions, action.action_id) do
      {:ok, descriptor}
    else
      _other -> {:error, :invalid_manifest}
    end
  end

  # Trust moved to a different hash since the caller's snapshot — that is a
  # trust decision (`:pack_untrusted`, with its own audit event), not mere
  # descriptor drift.
  defp ensure_requested_hash_trusted(trusted_hash, trusted_hash, _pack_version), do: :ok

  defp ensure_requested_hash_trusted(_trusted_hash, _hash, pack_version),
    do: {:error, :pack_untrusted, pack_version}

  defp dispatch_pack_identity(observed, nil) do
    if is_binary(observed.pack_id) and is_binary(observed.pack_version) and
         is_binary(observed.pack_hash) do
      {:ok, {observed.pack_id, observed.pack_version, observed.pack_hash}}
    else
      {:error, :pack_ref_mismatch}
    end
  end

  defp dispatch_pack_identity(_observed, pack_ref), do: MCPProjection.parse_pack_ref(pack_ref)

  defp lock_dispatch_pack_version(repo, account_id, pack_id, version) do
    queryable =
      PackVersion.Query.all()
      |> PackVersion.Query.by_account_id(account_id)
      |> PackVersion.Query.by_pack_id_and_version(pack_id, version)
      |> PackVersion.Query.lock_for_update()

    case repo.fetch(queryable, PackVersion.Query) do
      {:ok, %PackVersion{} = pack_version} -> {:ok, pack_version}
      {:error, :not_found} -> {:error, :pack_untrusted, :no_pin}
    end
  end

  defp trusted_pack_version_hash(%PackVersion{trust_state: :trusted} = pack_version) do
    retired? = PackBaseline.retired?(pack_version.pack_id, pack_version.version)
    trusted_row_dispatch_decision(pack_version, retired?)
  end

  defp trusted_pack_version_hash(%PackVersion{} = pack_version),
    do: {:error, :pack_untrusted, pack_version}

  defp lock_runner_action(repo, %RunnerAction{} = observed) do
    queryable =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_account_runner_and_action(
        observed.account_id,
        observed.runner_id,
        observed.action_id
      )
      |> RunnerAction.Query.lock_for_update()

    repo.fetch(queryable, RunnerAction.Query)
  end

  @doc """
  Internal — the dispatch decision for a TRUSTED pack-version row, given
  whether the published catalog retired its version. Pattern-matched clause
  heads carry the exhaustive branch coverage over that boolean;
  `check_pack_trusted/1` composes this with `PackBaseline.retired?/2`.

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

  # One advertisement used to cost two sequential queries per action — a peek
  # then an insert or update — so a legal 605-action fleet ran ~1,300 round
  # trips inside one default-timeout transaction and died at production
  # latency, invisibly, inside the best-effort rescue. Validate every
  # descriptor first, then write the survivors in chunked bulk upserts: the
  # same fleet is a handful of statements.
  #
  # Returns the action ids that actually landed, which is what prune reads.
  defp observe_actions(%Runners.Runner{} = runner, actions, packs, now) do
    actions
    |> Enum.map(&observe_action(runner, &1, packs, now))
    |> report_rejected_descriptors(runner)
    |> Enum.filter(&match?(%Ecto.Changeset{valid?: true}, &1))
    |> Enum.map(&upsert_entry(&1, now))
    |> dedupe_by_action_id()
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.flat_map(&upsert_action_chunk/1)
  end

  # A descriptor the catalog cannot accept is DROPPED — `kind` and `risk` are
  # closed Ecto.Enums, so a value outside the set invalidates the changeset and
  # the action never appears. That is the right outcome (we will not persist a
  # descriptor we cannot interpret) but it used to be silent: no log, no metric,
  # no audit row, and the wire has a channel for "a pack failed to LOAD"
  # (degraded_packs) and none for "I advertised a descriptor you could not
  # parse". To an operator, an action missing from the catalog and one the
  # runner never offered look identical — a bad pair to confuse on a security
  # product, since the visible effect is a capability quietly disappearing.
  #
  # So say so. Fleet-wide counter for alerting, and a log line naming the action
  # and the fields that failed, because "which one and why" is the question that
  # follows.
  defp report_rejected_descriptors(entries, %Runners.Runner{} = runner) do
    rejected = Enum.reject(entries, &match?(%Ecto.Changeset{valid?: true}, &1))

    if rejected != [] do
      Telemetry.catalog_descriptors_rejected(length(rejected))

      Logger.warning(
        "Catalog: runner #{runner.id} advertised #{length(rejected)} descriptor(s) the " <>
          "catalog cannot accept, so they are absent from its action list: " <>
          Enum.map_join(rejected, "; ", &describe_rejected_descriptor/1)
      )
    end

    entries
  end

  defp describe_rejected_descriptor(%Ecto.Changeset{} = changeset) do
    action_id = Ecto.Changeset.get_field(changeset, :action_id) || "<no action_id>"
    fields = changeset.errors |> Keyword.keys() |> Enum.uniq() |> Enum.join(", ")
    "#{action_id} (#{fields})"
  end

  # A descriptor rejected before a changeset existed — an unresolvable pack_id,
  # or not a map at all.
  defp describe_rejected_descriptor(_other), do: "<unparseable descriptor>"

  # A runner may advertise the same action id twice. Postgres refuses to let one
  # ON CONFLICT statement touch a row twice, so collapse duplicates here, last
  # occurrence winning — which is what the per-row loop did by overwriting.
  defp dedupe_by_action_id(entries) do
    entries
    |> Enum.reduce(%{}, &Map.put(&2, &1.action_id, &1))
    |> Map.values()
  end

  defp upsert_action_chunk(entries) do
    {_count, returned} =
      Repo.insert_all(RunnerAction, entries,
        on_conflict: {:replace, @upsert_replace_fields},
        conflict_target: [:runner_id, :action_id],
        returning: [:action_id]
      )

    Enum.map(returned, & &1.action_id)
  end

  defp upsert_entry(%Ecto.Changeset{} = changeset, now) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take([:account_id, :runner_id | @upsert_replace_fields])
    |> Map.merge(%{id: Repo.generate_id(), first_seen_at: now, inserted_at: now, updated_at: now})
  end

  defp observe_action(%Runners.Runner{} = runner, descriptor, packs, now)
       when is_map(descriptor) do
    pack_id = descriptor["pack_id"]

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

    # A descriptor naming a pack_id its own packs map doesn't resolve never
    # comes from a healthy runner (loading stamps every action's pack id and
    # version from one registry) — it is hostile or corrupt input. Persisting
    # it with pack_version nil used to hand it the unversioned
    # row-authoritative dispatch path at the trusted-manifest boundary, so it
    # is rejected here instead; the batch prune then retires any stale row a
    # previous advertisement left behind.
    if is_binary(pack_id) and is_nil(pack_version) do
      nil
    else
      observe_action_attrs(runner, descriptor, pack_id, pack_version, pack_hash, now)
    end
  end

  # A runner can advertise a malformed (non-map) action descriptor; skip it
  # (the caller rejects nils) rather than letting `descriptor["id"]` raise and
  # abort the whole batch's action upsert.
  defp observe_action(_runner, _descriptor, _packs, _now), do: nil

  defp observe_action_attrs(runner, descriptor, pack_id, pack_version, pack_hash, now) do
    {primary_executable_available, missing_executable} =
      primary_executable_availability(descriptor)

    attrs = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: descriptor["id"],
      pack_id: pack_id,
      pack_version: pack_version,
      pack_hash: pack_hash,
      title: descriptor["title"],
      summary: descriptor["summary"],
      # These runner-advertised fields are required by the existing changeset.
      # Dispatch later treats the persisted descriptor as authoritative, so an
      # incomplete advertisement must be rejected instead of receiving defaults.
      kind: descriptor["kind"],
      risk: descriptor["risk"],
      description: descriptor["description"],
      side_effects: descriptor["side_effects"] || [],
      args_schema: %{"args" => descriptor["args"] || []},
      output_schema: descriptor["output_schema"],
      examples: descriptor["examples"] || [],
      search_terms: descriptor["search_terms"] || [],
      primary_executable_available: primary_executable_available,
      missing_executable: missing_executable,
      first_seen_at: now,
      last_seen_at: now
    }

    RunnerAction.Changeset.upsert(attrs)
  end

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
    |> SafeText.strip()
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

  @doc "The runner-actions table's `%Repo.Filter{}` list."
  def runner_action_filters, do: RunnerAction.Query.filters()

  @doc """
  Actions advertised by a runner, scoped to the subject's account.
  Returns `{:ok, [runner_action], %Paginator.Metadata{}}`.
  """
  def list_actions_for_runner(runner_id, %Subject{} = subject, opts \\ []) do
    # No pre-ordering: the query module's cursor drives the ORDER BY so it
    # matches the keyset WHERE.
    queryable =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> scope_actions_to_subject_membership(subject)
      |> Authorizer.for_subject(subject)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ),
         {:ok, actions, metadata} <-
           Repo.list(queryable, RunnerAction.Query, opts) do
      {:ok, annotate_dispatch_blocks(actions, subject), metadata}
    end
  end

  defp annotate_dispatch_blocks([], %Subject{}), do: []

  defp annotate_dispatch_blocks(actions, %Subject{} = subject) do
    versioned_actions =
      Enum.filter(actions, &(is_binary(&1.pack_id) and is_binary(&1.pack_version)))

    pack_versions =
      if versioned_actions == [] do
        []
      else
        pack_ids = Enum.map(versioned_actions, & &1.pack_id) |> Enum.uniq()
        versions = Enum.map(versioned_actions, & &1.pack_version) |> Enum.uniq()

        PackVersion.Query.all()
        |> PackVersion.Query.by_pack_ids(pack_ids)
        |> PackVersion.Query.by_versions(versions)
        |> Authorizer.for_subject(subject)
        |> Repo.all()
      end

    versions_by_ref = Map.new(pack_versions, &{{&1.pack_id, &1.version}, &1})

    Enum.map(actions, fn action ->
      %{action | dispatch_block_reason: dispatch_block_reason(action, versions_by_ref)}
    end)
  end

  defp dispatch_block_reason(%RunnerAction{pack_version: nil}, _versions_by_ref), do: nil

  defp dispatch_block_reason(%RunnerAction{} = action, versions_by_ref) do
    case Map.get(versions_by_ref, {action.pack_id, action.pack_version}) do
      %PackVersion{trust_state: :trusted} = pack_version ->
        retired? = PackBaseline.retired?(pack_version.pack_id, pack_version.version)

        case trusted_row_dispatch_decision(pack_version, retired?) do
          {:ok, hash} when is_binary(action.pack_hash) and action.pack_hash == hash -> nil
          {:error, :pack_retired, _pack_version} -> :pack_retired
          _untrusted_or_mismatched -> :pack_untrusted
        end

      _missing_or_untrusted ->
        :pack_untrusted
    end
  end

  @doc """
  Every pack id the account knows, sorted — the choices a member's or directory
  grant's pack scope may name. Requires `view_catalog`; scoped by
  `Authorizer.for_subject/2`. Returns `{:ok, [pack_id]}`.
  """
  def list_account_pack_ids(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      access = Accounts.runner_access_for_subject(subject)
      visible_deployments = visible_deployments(subject, access)

      pack_ids =
        PackVersion.Query.all()
        |> scope_pack_versions_to_packs(access)
        |> scope_pack_versions_to_visible_runners(visible_deployments)
        |> PackVersion.Query.distinct_pack_ids()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, Enum.sort(pack_ids)}
    end
  end

  @doc """
  Which runners advertise which pack, as `%{pack_id => [runner_id]}` — what a
  grant editor needs to offer only the packs the chosen runners actually carry,
  and to say how many of them each one is on. Requires `view_catalog`; scoped by
  `Authorizer.for_subject/2`. Returns `{:ok, map}`.
  """
  def list_pack_advertisements(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      pairs =
        RunnerAction.Query.all()
        |> scope_actions_to_subject_membership(subject)
        |> RunnerAction.Query.distinct_pack_runner_pairs()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      advertisements =
        pairs
        |> Enum.reject(fn {pack_id, _runner_id} -> pack_id in [nil, ""] end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      {:ok, advertisements}
    end
  end

  @doc """
  Internal - every pack id in one already-authorized account, for the directory
  sync's pack-scope allowlist.
  """
  def list_pack_ids_for_account(account_id) when is_binary(account_id) do
    PackVersion.Query.all()
    |> PackVersion.Query.by_account_id(account_id)
    |> PackVersion.Query.distinct_pack_ids()
    |> Repo.all()
    |> Enum.sort()
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
        |> scope_actions_to_subject_membership(subject)
        |> RunnerAction.Query.distinct_pack_ids()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, pack_ids |> Enum.sort() |> Enum.map(&{&1, &1})}
    end
  end

  @doc """
  The model-facing catalog snapshot for the subject's account: every exact
  trusted pack ref projected onto the fleet the subject may reach, as
  `%{packs: [...], runners: [...]}`.

  This is the single model-visible projection. Untrusted, rejected, revoked,
  hash-mismatched, incomplete, retired, and out-of-scope refs are absent;
  offline or drifted trusted deployments remain visible only as unavailable
  diagnostics, never compatible targets. Requires `view_catalog` (plus the
  runner-scope gate the fleet read applies); returns `{:ok, snapshot}` or
  `{:error, :unauthorized}`.
  """
  @spec model_catalog(Subject.t()) :: {:ok, map()} | {:error, :unauthorized}
  def model_catalog(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      model_snapshot(subject)
    end
  end

  @doc """
  Resolve one exact `action_id` inside one exact trusted `pack_ref`, plus the
  projected runners that can execute it, for the subject's account.

  `runner_refs` is the caller's explicit fan-out: `[]` means every compatible
  runner (ordered by ref), while a non-empty list must resolve EXACTLY — every
  ref present in the subject's own snapshot AND compatible — and comes back in
  the requested order. Anything else fails the whole call closed. Requires
  `view_catalog`; returns `{:ok, %{action: action, pack: pack, runners: runners}}`
  or `{:error, :not_found | :unauthorized}`.
  """
  @spec resolve_model_action(String.t(), String.t(), [String.t()], Subject.t()) ::
          {:ok, %{action: map(), pack: map(), runners: [map()]}}
          | {:error, :not_found | :unauthorized}
  def resolve_model_action(action_id, pack_ref, runner_refs, %Subject{} = subject)
      when is_list(runner_refs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()),
         {:ok, deployment} <- MCPProjection.parse_pack_ref(pack_ref),
         {:ok, snapshot} <- model_snapshot(subject, deployment),
         %{} = pack <- Enum.find(snapshot.packs, &(&1.pack_ref == pack_ref)),
         %{} = action <- Enum.find(pack.actions, &(&1["action_id"] == action_id)),
         {:ok, runners} <- compatible_model_runners(snapshot.runners, action, runner_refs) do
      {:ok, %{action: action, pack: pack, runners: runners}}
    else
      {:error, reason} -> {:error, reason}
      _unresolvable -> {:error, :not_found}
    end
  end

  # The fleet read carries live membership + API-key runner scope, so it — not
  # the account — decides which advertisements may reach a model at all.
  #
  # `deployment` narrows both reads to one exact {pack_id, version, hash} when
  # the caller is resolving ONE action; a listing still spans the account. Either
  # way the actions come back as manifest-match columns only — the descriptors a
  # model sees are the trusted manifest's, and the row's own copy is now compared
  # through its stored digest.
  defp model_snapshot(%Subject{} = subject, deployment \\ nil) do
    with {:ok, runners} <-
           Runners.list_all_runners_for_account(subject, preload: [:online?]) do
      access = Accounts.runner_access_for_subject(subject)
      runners = Enum.map(runners, &scope_runner_pack_facts(&1, access))
      runner_ids = Enum.map(runners, & &1.id)

      actions =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_runner_ids(runner_ids)
        |> scope_actions_to_deployment(deployment)
        |> RunnerAction.Query.ordered_by_action_seen()
        |> RunnerAction.Query.select_manifest_match_columns()
        |> scope_actions_to_packs(access)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      pack_versions =
        PackVersion.Query.all()
        |> scope_pack_versions_to_deployment(deployment)
        |> PackVersion.Query.ordered_by_pack()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok,
       MCPProjection.build(pack_versions, actions, runners, only_pack_ref: pack_ref(deployment))}
    end
  end

  defp scope_runner_pack_facts(runner, %Accounts.RunnerAccess{} = access) do
    packs =
      (runner.packs || %{})
      |> Enum.filter(fn {pack_id, _deployment} ->
        Accounts.RunnerAccess.pack_in_scope?(pack_id, access)
      end)
      |> Map.new()

    degraded_packs =
      (runner.degraded_packs || [])
      |> Enum.filter(fn
        %{"pack" => pack_id} -> Accounts.RunnerAccess.pack_in_scope?(pack_id, access)
        _malformed -> false
      end)

    %{runner | packs: packs, degraded_packs: degraded_packs}
  end

  defp scope_actions_to_deployment(queryable, nil), do: queryable

  defp scope_actions_to_deployment(queryable, {pack_id, version, hash}) do
    queryable
    |> RunnerAction.Query.by_pack_id(pack_id)
    |> RunnerAction.Query.by_pack_version(version)
    |> RunnerAction.Query.by_pack_hash(hash)
  end

  defp scope_pack_versions_to_deployment(queryable, nil), do: queryable

  defp scope_pack_versions_to_deployment(queryable, {pack_id, version, _hash}),
    do: PackVersion.Query.by_pack_id_and_version(queryable, pack_id, version)

  defp pack_ref(nil), do: nil

  defp pack_ref({pack_id, version, hash}) do
    case MCPProjection.pack_ref(pack_id, version, hash) do
      {:ok, pack_ref} -> pack_ref
      {:error, :invalid_pack_ref} -> nil
    end
  end

  defp compatible_model_runners(runners, action, []) do
    compatible_ids = MapSet.new(action.compatible_runner_ids)

    compatible =
      runners
      |> Enum.filter(&MapSet.member?(compatible_ids, &1.id))
      |> Enum.sort_by(& &1.runner_ref)

    {:ok, compatible}
  end

  defp compatible_model_runners(runners, action, runner_refs) do
    runners_by_ref = Map.new(runners, &{&1.runner_ref, &1})
    compatible_ids = MapSet.new(action.compatible_runner_ids)

    requested =
      Enum.map(runner_refs, fn runner_ref ->
        runner = Map.get(runners_by_ref, runner_ref)
        if runner && MapSet.member?(compatible_ids, runner.id), do: runner
      end)

    if Enum.all?(requested), do: {:ok, requested}, else: {:error, :not_found}
  end

  @doc """
  The most requests one candidate resolution answers. A caller resolving for
  SEVERAL runbooks at once batches within this bound rather than re-deriving it.
  """
  @spec max_candidate_requests() :: pos_integer()
  def max_candidate_requests, do: @max_candidate_requests

  @doc """
  Returns bounded trusted exact pack/action candidates for already scoped
  runbook runners. The caller owns requirement matching; this context owns the
  trusted-manifest projection and hides untrusted, retired, drifted, offline,
  or incomplete deployments.
  """
  def resolve_runbook_candidates(requests, runners, %Subject{} = subject)
      when is_list(requests) and is_list(runners) do
    with true <- length(requests) <= @max_candidate_requests,
         :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ),
         deployments = requested_deployments(requests, runners),
         {:ok, actions} <- deployment_actions(deployments, subject),
         {:ok, pack_versions} <- deployment_pack_versions(deployments, subject) do
      requested_runner_ids = MapSet.new(requests, & &1.runner_id)
      requested_runners = Enum.filter(runners, &MapSet.member?(requested_runner_ids, &1.id))
      snapshot = MCPProjection.build(pack_versions, actions, requested_runners)

      candidates =
        Map.new(requests, fn request ->
          key = {request.runner_id, request.pack_id, request.action_id}
          {key, runbook_candidates(snapshot, request)}
        end)

      {:ok, candidates}
    else
      false -> {:error, :fan_out_too_large}
      other -> other
    end
  end

  defp requested_deployments(requests, runners) do
    runners_by_id = Map.new(runners, &{&1.id, &1})

    requests
    |> Enum.flat_map(fn request ->
      with %Runners.Runner{} = runner <- Map.get(runners_by_id, request.runner_id),
           %{"version" => version, "hash" => hash} <- get_in(runner.packs, [request.pack_id]) do
        [{runner.id, request.pack_id, version, hash}]
      else
        _missing_deployment -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Builds the runbook editor's trusted candidate projection for an already
  scoped, eligible runner list.

  The caller owns runner eligibility; this context rechecks current runner
  scope and owns trust. Every candidate comes from the same trusted-manifest
  projection dispatch resolves against, so untrusted, retired, drifted,
  disconnected, and incomplete deployments are absent. Requires `view_catalog`
  and fails closed when a supplied runner is outside the subject's account or
  current runner scope. Returns `{:ok, %EditorProjection{}}` or
  `{:error, :unauthorized | :not_found | :candidate_catalog_too_large}`.
  """
  @spec build_editor_projection([Runners.Runner.t()], Subject.t()) ::
          {:ok, EditorProjection.t()}
          | {:error, :unauthorized | :not_found | :candidate_catalog_too_large}
  def build_editor_projection(runners, %Subject{} = subject) when is_list(runners) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ),
         :ok <- ensure_runners_in_account(runners, subject),
         {:ok, scoped_runners} <- Runners.list_all_runners_for_account(subject),
         :ok <- ensure_runners_in_scope(runners, scoped_runners),
         [_deployment | _rest] = deployments <- runner_deployments(runners),
         {:ok, actions} <- deployment_actions(deployments, subject),
         {:ok, pack_versions} <- deployment_pack_versions(deployments, subject) do
      snapshot = MCPProjection.build(pack_versions, actions, runners)
      {:ok, EditorProjection.build(snapshot)}
    else
      [] -> {:ok, %EditorProjection{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Actions the runners in `runner_ids` can execute from an editor projection
  under one complete common action contract.

  Selection is the compiler's: one exact trusted candidate per runner, then
  identical normalized `ActionContract` snapshots across them. Every selected
  runner must advertise the action's pack; a runner whose advertised deployment
  currently holds no trusted candidate (retired, pending, rejected, or drifted)
  narrows the executable set instead of hiding the action, and at least one
  trusted candidate must remain. An action whose capable runners disagree on
  risk, arguments, or output shape is absent rather than reconciled. Returns
  the ordered `[%{pack_id, action_id, title, risk, args}]`.
  """
  @spec common_actions(EditorProjection.t(), [String.t()]) :: [map()]
  def common_actions(%EditorProjection{}, []), do: []

  def common_actions(%EditorProjection{} = projection, runner_ids) when is_list(runner_ids) do
    projection.candidates
    |> Enum.flat_map(fn {{pack_id, action_id}, by_runner} ->
      runner_candidates =
        Enum.map(runner_ids, &{&1, editor_runner_candidates(projection, by_runner, &1, pack_id)})

      case select_common_action(runner_candidates) do
        {:ok, selected} -> [common_action(pack_id, action_id, selected)]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&{&1.action_id, &1.pack_id})
  end

  defp editor_runner_candidates(projection, by_runner, runner_id, pack_id) do
    case Map.fetch(by_runner, runner_id) do
      {:ok, candidates} ->
        candidates

      :error ->
        advertised = Map.get(projection.advertised_packs, runner_id, MapSet.new())
        if MapSet.member?(advertised, pack_id), do: [], else: :not_advertised
    end
  end

  @doc """
  Selects one exact trusted candidate per already-scoped runner and requires one
  complete common action contract across the runners that can supply one.

  `runner_candidates` is an ordered `[{runner, candidates | :not_advertised}]`
  list; each selected candidate carries its `runner`. A runner that advertises
  the pack but currently holds no trusted candidate (retired, pending,
  rejected, or drifted deployment) narrows the selection instead of failing it:
  trust is judged per runner, so a trust gap on one runner never blocks the
  runners that hold a trusted deployment. A runner tagged `:not_advertised`
  fails the selection — declared structural coverage never silently shrinks.

  Returns `{:ok, %{candidates: [candidate], contract: contract}}`,
  `{:error, [{runner, :ambiguous_pack_version | :pack_unavailable}]}` when a
  runner advertises conflicting hashes, lacks the pack entirely, or no runner
  holds a trusted candidate, or `{:error, :incompatible_action_contracts}` when
  the selected candidates' normalized contracts differ.
  """
  @spec select_common_action([{term(), [map()] | :not_advertised}]) ::
          {:ok, %{candidates: [map()], contract: map()}}
          | {:error, [{term(), atom()}] | :incompatible_action_contracts}
  def select_common_action(runner_candidates) when is_list(runner_candidates) do
    {selected, narrowed, failures} =
      Enum.reduce(runner_candidates, {[], [], []}, fn
        {runner, :not_advertised}, {selected, narrowed, failures} ->
          {selected, narrowed, [{runner, :pack_unavailable} | failures]}

        {runner, []}, {selected, narrowed, failures} ->
          {selected, [runner | narrowed], failures}

        {runner, candidates}, {selected, narrowed, failures} ->
          case select_exact_candidate(candidates) do
            {:ok, candidate} ->
              {[Map.put(candidate, :runner, runner) | selected], narrowed, failures}

            {:error, reason} ->
              {selected, narrowed, [{runner, reason} | failures]}
          end
      end)

    selected = Enum.reverse(selected)
    contracts = selected |> Enum.map(&ActionContract.snapshot(&1.descriptor)) |> Enum.uniq()

    cond do
      failures != [] ->
        {:error, Enum.reverse(failures)}

      selected == [] ->
        {:error, narrowed |> Enum.reverse() |> Enum.map(&{&1, :pack_unavailable})}

      length(contracts) == 1 ->
        {:ok, %{candidates: selected, contract: hd(contracts)}}

      true ->
        {:error, :incompatible_action_contracts}
    end
  end

  defp common_action(pack_id, action_id, %{candidates: [candidate | _rest], contract: contract}) do
    %{
      pack_id: pack_id,
      action_id: action_id,
      title: candidate.descriptor["title"],
      risk: contract["risk"],
      args: get_in(contract, ["args_schema", "args"]) || []
    }
  end

  defp select_exact_candidate(candidates) do
    ambiguous? =
      candidates
      |> Enum.group_by(& &1.version, & &1.hash)
      |> Enum.any?(fn {_version, hashes} -> length(Enum.uniq(hashes)) > 1 end)

    if ambiguous?,
      do: {:error, :ambiguous_pack_version},
      else: {:ok, Enum.reduce(candidates, &newer_candidate/2)}
  end

  defp newer_candidate(candidate, selected) do
    if compare_versions(candidate.version, selected.version) == :gt,
      do: candidate,
      else: selected
  end

  defp compare_versions(left, right) do
    case {Version.parse(left), Version.parse(right)} do
      {{:ok, left_version}, {:ok, right_version}} ->
        compare_semantic_versions(left_version, right_version, left, right)

      {{:ok, _left_version}, :error} ->
        :gt

      {:error, {:ok, _right_version}} ->
        :lt

      {:error, :error} ->
        compare_version_text(left, right)
    end
  end

  defp compare_semantic_versions(left_version, right_version, left, right) do
    case Version.compare(left_version, right_version) do
      :eq -> compare_version_text(left, right)
      ordering -> ordering
    end
  end

  defp compare_version_text(left, right) when left > right, do: :gt
  defp compare_version_text(left, right) when left < right, do: :lt
  defp compare_version_text(_left, _right), do: :eq

  defp ensure_runners_in_account(runners, %Subject{} = subject) do
    if Enum.all?(runners, &Subject.in_account?(subject, &1.account_id)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp ensure_runners_in_scope(runners, scoped_runners) do
    scoped_ids = MapSet.new(scoped_runners, & &1.id)

    if Enum.all?(runners, &MapSet.member?(scoped_ids, &1.id)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp runner_deployments(runners) do
    runners
    |> Enum.flat_map(fn runner ->
      Enum.flat_map(runner.packs || %{}, fn
        {pack_id, %{"version" => version, "hash" => hash}} ->
          [{runner.id, pack_id, version, hash}]

        _invalid ->
          []
      end)
    end)
    |> Enum.uniq()
  end

  defp deployment_actions(deployments, subject) do
    max_actions = length(deployments) * TrustedManifest.max_actions()

    actions =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_deployments(deployments)
      |> RunnerAction.Query.select_manifest_match_columns()
      |> scope_actions_to_pack_access(subject)
      |> RunnerAction.Query.limit_to(max_actions + 1)
      |> Authorizer.for_subject(subject)
      |> Repo.all()

    oversized_deployment? =
      actions
      |> Enum.group_by(&{&1.runner_id, &1.pack_id, &1.pack_version, &1.pack_hash})
      |> Enum.any?(fn {_deployment, rows} ->
        length(rows) > TrustedManifest.max_actions()
      end)

    if length(actions) <= max_actions and not oversized_deployment?,
      do: {:ok, actions},
      else: {:error, :candidate_catalog_too_large}
  end

  defp deployment_pack_versions(deployments, subject) do
    pack_refs =
      deployments
      |> Enum.map(fn {_runner_id, pack_id, version, _hash} -> {pack_id, version} end)
      |> Enum.uniq()

    pack_versions =
      PackVersion.Query.all()
      |> PackVersion.Query.by_pack_refs(pack_refs)
      |> Authorizer.for_subject(subject)
      |> Repo.all()

    {:ok, pack_versions}
  end

  defp runbook_candidates(snapshot, request) do
    snapshot.packs
    |> Enum.filter(&(&1.pack_id == request.pack_id))
    |> Enum.flat_map(fn pack ->
      case Enum.find(pack.actions, &(&1["action_id"] == request.action_id)) do
        %{compatible_runner_ids: runner_ids} = descriptor ->
          if request.runner_id in runner_ids do
            [
              %{
                runner_id: request.runner_id,
                runner_ref: request.runner_ref,
                pack_id: pack.pack_id,
                version: pack.version,
                hash: pack.hash,
                pack_ref: pack.pack_ref,
                descriptor: Map.drop(descriptor, [:compatible_runner_ids])
              }
            ]
          else
            []
          end

        _unavailable ->
          []
      end
    end)
    |> Enum.sort(&(compare_versions(&1.version, &2.version) != :lt))
  end

  @doc """
  `%{action_id => most-severe risk}` for a set of `action_id`s, in ONE
  account-scoped query — the runbook list resolves every listed runbook's
  steps' risks at once (no per-runbook DB call). Same `view_catalog` gate +
  account scoping as the other catalog reads; returns `{:ok, %{}}` for an
  empty id list without touching the DB.

  Only `action_id`s a runner the caller may reach advertises appear in the map —
  an unobserved or out-of-scope step is simply absent, which `max_risk/1` treats
  conservatively (no false-low). Folds the rows through
  `most_severe_risk_by_action/1`, so an action advertised by several runners at
  mixed risk keeps the worst.
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
        |> scope_actions_to_subject_membership(subject)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, most_severe_risk_by_action(actions)}
    end
  end

  @doc """
  `%{{runner_id, action_id} => risk}` for exact runner/action pairs, in ONE
  query — the approvals queue resolves every
  pending request's own frozen action without a read per card. Requires
  `view_catalog`; rows are scoped to the caller's CURRENT membership runner
  access and their account.

  A pair whose runner or action is unknown, malformed, out of the caller's
  runner scope, or in another account is simply absent, so a caller shows no
  risk rather than a wrong one. An empty list still runs the permission gate.
  Returns `{:ok, %{{runner_id, action_id} => risk}}` or `{:error, :unauthorized}`.
  """
  def risk_by_runner_action_pairs(pairs, %Subject{} = subject) when is_list(pairs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      {:ok, pairs |> Enum.filter(&resolvable_pair?/1) |> risk_by_pair(subject)}
    end
  end

  defp resolvable_pair?({runner_id, action_id}),
    do: Repo.valid_uuid?(runner_id) and is_binary(action_id)

  defp resolvable_pair?(_pair), do: false

  defp risk_by_pair([], _subject), do: %{}

  defp risk_by_pair(pairs, %Subject{} = subject) do
    rows =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_action_pairs(pairs)
      |> scope_actions_to_subject_membership(subject)
      |> RunnerAction.Query.select_action_risk_rows()
      |> Authorizer.for_subject(subject)
      |> Repo.all()

    Map.new(rows, fn {runner_id, action_id, risk} -> {{runner_id, action_id}, risk} end)
  end

  # Membership runner access is current authorization data, not session state:
  # resolve it on every risk read so a narrowed scope takes effect immediately
  # on open sessions and old API keys.
  defp scope_actions_to_subject_membership(queryable, %Subject{} = subject) do
    access = Accounts.runner_access_for_subject(subject)

    queryable
    |> scope_actions_to_runners(access)
    |> scope_actions_to_packs(access)
  end

  defp scope_actions_to_runners(queryable, %Accounts.RunnerAccess{mode: :none}),
    do: RunnerAction.Query.none(queryable)

  defp scope_actions_to_runners(queryable, %Accounts.RunnerAccess{mode: :all}), do: queryable

  defp scope_actions_to_runners(queryable, %Accounts.RunnerAccess{mode: :restricted} = access),
    do: RunnerAction.Query.by_runner_scope_values(queryable, access.runner_ids, access.groups)

  # The pack dimension of the same grant. Reads that scope their runners through
  # a fleet read compose THIS on top, so a member restricted to some packs never
  # sees — or selects — an action outside them.
  defp scope_actions_to_pack_access(queryable, %Subject{} = subject),
    do: scope_actions_to_packs(queryable, Accounts.runner_access_for_subject(subject))

  defp scope_actions_to_packs(queryable, %Accounts.RunnerAccess{mode: :none}),
    do: RunnerAction.Query.none(queryable)

  defp scope_actions_to_packs(queryable, %Accounts.RunnerAccess{pack_mode: :all}), do: queryable

  defp scope_actions_to_packs(queryable, %Accounts.RunnerAccess{pack_mode: :restricted} = access),
    do: RunnerAction.Query.by_pack_ids(queryable, access.pack_ids)

  defp scope_pack_versions_to_packs(queryable, %Accounts.RunnerAccess{mode: :none}),
    do: PackVersion.Query.none(queryable)

  defp scope_pack_versions_to_packs(queryable, %Accounts.RunnerAccess{pack_mode: :all}),
    do: queryable

  defp scope_pack_versions_to_packs(
         queryable,
         %Accounts.RunnerAccess{pack_mode: :restricted} = access
       ),
       do: PackVersion.Query.by_pack_ids(queryable, access.pack_ids)

  defp visible_deployments(_subject, %Accounts.RunnerAccess{mode: :all}), do: :all
  defp visible_deployments(_subject, %Accounts.RunnerAccess{mode: :none}), do: []

  defp visible_deployments(%Subject{} = subject, %Accounts.RunnerAccess{mode: :restricted}) do
    case Runners.list_all_runners_for_account(subject) do
      {:ok, runners} ->
        runners
        |> Enum.flat_map(fn runner ->
          for {pack_id, %{"version" => version, "hash" => hash}} <- runner.packs || %{},
              is_binary(pack_id) and is_binary(version) and is_binary(hash),
              do: {pack_id, version, hash}
        end)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  defp scope_pack_versions_to_visible_runners(queryable, :all), do: queryable

  defp scope_pack_versions_to_visible_runners(queryable, deployments),
    do: PackVersion.Query.by_deployments(queryable, deployments)

  # Severity rank for `RunnerAction.risk` (an Ecto.Enum) — lets us pick the
  # WORST risk when the same action is advertised by more than one runner.

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
    if Map.get(ConsoleProjection.risk_rank(), candidate, 0) >
         Map.get(ConsoleProjection.risk_rank(), current, 0),
       do: candidate,
       else: current
  end

  # The tiers `max_risk/1` accepts, keyed by both the `RunnerAction.risk`
  # Ecto.Enum atom and the string form a frozen runbook plan stores. Anything
  # else is unresolved — never coerced into a tier.
  @risk_tiers %{
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "critical" => :critical,
    low: :low,
    medium: :medium,
    high: :high,
    critical: :critical
  }

  @doc """
  The single most-severe risk across a COMPLETE list of tiers — atoms or their
  string forms — using the same severity order as `most_severe_risk_by_action/1`.

  Returns `nil` when the list is empty OR any member is unresolved (`nil`, or a
  value that is not one of the four tiers), and otherwise the worst tier as an
  atom. This is a security product, so an incomplete answer is reported as no
  answer: a runbook or frozen plan whose steps we cannot fully resolve must
  read as "unknown" (no pill) rather than as the worst of the part we happened
  to resolve, which would understate the whole.
  """
  def max_risk([]), do: nil

  def max_risk(risks) when is_list(risks) do
    Enum.reduce_while(risks, :low, fn risk, worst ->
      case Map.get(@risk_tiers, risk) do
        nil -> {:halt, nil}
        tier -> {:cont, most_severe(worst, tier)}
      end
    end)
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
        |> scope_actions_to_subject_membership(subject)
        |> RunnerAction.Query.select_action_risk_rows()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, action_risk_index(rows)}
    end
  end

  @doc """
  Same as `action_risk_index_for_account/1` but scoped to a set of runners — the
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
        |> scope_actions_to_subject_membership(subject)
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
      # Narrow by the member's runner scope, like risk_by_action_ids/2 above.
      # Without it, an operator scoped to one host could open
      # /runs/new/<other-runner>/<action> and read the action's id, title, risk
      # and full args schema — dispatch was refused, but the existence and shape
      # of an out-of-scope host's action leaked, against the existence-hiding
      # promise on /docs/teams-and-access.
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> RunnerAction.Query.by_action_id(action_id)
      |> scope_actions_to_subject_membership(subject)
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
      access = Accounts.runner_access_for_subject(subject)
      visible_deployments = visible_deployments(subject, access)

      PackVersion.Query.all()
      |> scope_pack_versions_to_packs(access)
      |> scope_pack_versions_to_visible_runners(visible_deployments)
      |> apply_pack_version_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(PackVersion.Query, opts)
    end
  end

  @doc """
  The console Packs page's whole projection in one bounded read.

  Requires `view_catalog`. `filters` narrows only what the page RENDERS —
  `:name` is a case-insensitive substring over the pack id OR an advertised
  action id, `:risk` keeps versions advertising an action at that tier, and an
  empty (or missing) value turns the axis off. A version survives when every
  active axis matches, even when two different actions satisfy them;
  `matched_action_ids` is stricter — an action id appears only when that single
  action satisfies every active action-level axis, so a version matched by its
  pack id alone contributes none and the page leaves it collapsed.

  Advertised actions are read only when a filter is active or a pending version
  needs its contents, so an unfiltered, nothing-pending page pays for no action
  read and keeps its per-disclosure lazy loading (`list_pack_actions/3`). The
  fleet's advertisement facts are read once, and only when some row's lifecycle
  actually depends on who is running it.

  Returns `{:ok, projection}` — `pack_versions` (every row in the member's
  current pack access, bounded, ordered by pack id then version; browse rows
  omit `trusted_manifest`, and only rows carrying a decision — pending trust,
  or an overridden retirement — come back whole with the overrider preloaded),
  `groups` (`%{id: pack_id,
  versions: [...], update: nil | %{version, hash}}` over the visible rows,
  packs ascending and versions newest-seen first), `actions_by_pack_ref`,
  `matched_action_ids`,
  `out_of_scope_pack_ids` (the account's other pack ids — identity only, for
  discovery; empty under a `:risk` filter, which cannot be judged without
  reading actions the member may not see), and
  `version_facts` (see `list_console_packs/2`'s fact map) keyed by pack-version
  id, and the visible `pack_count`/`version_count`, `pending_count`, and
  `decision_count` — or `{:error, :unauthorized}`.

  `version_facts` carries every lifecycle and trust judgment the console
  renders, so no caller re-derives one from raw row fields: `trust_state` and
  the `display_state` a retirement block replaces it with, `trust_review?` /
  `needs_decision?`, the pending decision's `actions` + `action_changes`
  (selected on the row's exact `pending_hash`), `advertising`
  (`%{coverage: :not_needed | :complete | :partial, runners: [...]}`),
  `current_version`, `retired?` / `retirement_blocked?` /
  `retirement_successor` (+ `_hash`) / `retirement_remedy`, `update_successor`
  (+ `_hash`), and the `override` attribution.
  """
  def list_console_packs(filters, %Subject{} = subject) when is_map(filters) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      name = filters |> Map.get(:name, "") |> String.downcase()
      risk = Map.get(filters, :risk, "")
      access = Accounts.runner_access_for_subject(subject)
      visible_deployments = visible_deployments(subject, access)

      pack_versions =
        PackVersion.Query.all()
        |> scope_pack_versions_to_packs(access)
        |> scope_pack_versions_to_visible_runners(visible_deployments)
        |> PackVersion.Query.ordered_by_pack()
        |> PackVersion.Query.select_without_manifest()
        |> PackVersion.Query.limit_to(@console_pack_version_limit)
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> hydrate_decision_rows(subject)

      action_rows = console_action_rows(pack_versions, name, risk, access, subject)

      actions_by_pack_ref =
        Map.new(action_rows, fn {pack_ref, actions} ->
          {pack_ref, ConsoleProjection.most_severe_actions_by_id(actions)}
        end)

      with {:ok, advertising} <- console_advertising(pack_versions, subject) do
        version_facts =
          ConsoleProjection.console_version_facts(pack_versions, action_rows, advertising)

        {visible, matched_ids} =
          ConsoleProjection.console_filter(pack_versions, name, risk, actions_by_pack_ref)

        groups = ConsoleProjection.console_groups(visible, pack_versions)

        {:ok,
         %{
           pack_versions: pack_versions,
           groups: groups,
           actions_by_pack_ref: actions_by_pack_ref,
           matched_action_ids: matched_ids,
           out_of_scope_pack_ids: out_of_scope_pack_ids(pack_versions, name, risk, subject),
           version_facts: version_facts,
           pack_count: length(groups),
           version_count: length(visible),
           pending_count: Enum.count(pack_versions, &(&1.trust_state == :pending)),
           decision_count:
             Enum.count(pack_versions, &ConsoleProjection.pack_version_needs_decision?/1)
         }}
      end
    end
  end

  # The browse read drops `trusted_manifest` (the table's heaviest column) and
  # the override join; only the rows whose rendering turns on them are re-read
  # whole: a pending review diffs against its manifest, and an overridden
  # retirement names its overrider. A row that vanishes between the two reads
  # keeps its slim struct — a nil manifest already means "nothing to diff", and
  # the override note words an absent overrider.
  defp hydrate_decision_rows(pack_versions, %Subject{} = subject) do
    decision_ids =
      for %PackVersion{} = version <- pack_versions,
          version.trust_state == :pending or not is_nil(version.retirement_overridden_at),
          do: version.id

    if decision_ids == [] do
      pack_versions
    else
      whole_by_id =
        PackVersion.Query.all()
        |> PackVersion.Query.by_ids(decision_ids)
        |> PackVersion.Query.with_preloaded_retirement_overridden_by()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})

      Enum.map(pack_versions, &Map.get(whole_by_id, &1.id, &1))
    end
  end

  # Action rows grouped by `{pack_id, version}`, read only when the page needs
  # them and only as wide as each need: a live filter matches over the whole
  # account's rows in summary columns, while a pending version's trust card
  # reads its own pairs WHOLE — the manifest diff compares every descriptor
  # field, so summary rows would silently blind it. Kept as RAW rows either way
  # (no dedupe here) so a pending review can select its exact hash BEFORE the
  # most-severe dedupe collapses two hashes' rows for the same action id.
  defp console_action_rows(
         pack_versions,
         name,
         risk,
         %Accounts.RunnerAccess{} = access,
         %Subject{} = subject
       ) do
    pending_pairs =
      for %PackVersion{trust_state: :pending} = version <- pack_versions,
          do: {version.pack_id, version.version}

    Map.merge(
      filter_match_action_rows(name, risk, access, subject),
      pending_decision_action_rows(pending_pairs, access, subject)
    )
  end

  defp filter_match_action_rows("", "", %Accounts.RunnerAccess{}, %Subject{}), do: %{}

  defp filter_match_action_rows(
         _name,
         _risk,
         %Accounts.RunnerAccess{} = access,
         %Subject{} = subject
       ) do
    RunnerAction.Query.all()
    |> scope_actions_to_runners(access)
    |> scope_actions_to_packs(access)
    |> RunnerAction.Query.ordered_by_action()
    |> RunnerAction.Query.select_console_columns()
    |> Authorizer.for_subject(subject)
    |> Repo.all()
    |> Enum.group_by(&{&1.pack_id, &1.pack_version})
  end

  defp pending_decision_action_rows([], %Accounts.RunnerAccess{}, %Subject{}), do: %{}

  defp pending_decision_action_rows(
         pending_pairs,
         %Accounts.RunnerAccess{} = access,
         %Subject{} = subject
       ) do
    RunnerAction.Query.all()
    |> RunnerAction.Query.by_pack_refs(pending_pairs)
    |> scope_actions_to_runners(access)
    |> scope_actions_to_packs(access)
    |> RunnerAction.Query.ordered_by_action()
    |> Authorizer.for_subject(subject)
    |> Repo.all()
    |> Enum.group_by(&{&1.pack_id, &1.pack_version})
  end

  # Which runners advertise each `(pack_id, version)`, from ONE bounded fleet
  # read — and only when some row's lifecycle actually turns on it (a trust
  # decision's blast radius, or a retired row whose remedy depends on whether
  # any host is still running it). A plain trusted row pays for nothing.
  defp console_advertising(pack_versions, %Subject{} = subject) do
    if Enum.any?(pack_versions, &ConsoleProjection.advertiser_facts_needed?/1) do
      # The fleet read carries its own permission gate, so a role that may read
      # the catalog but not the fleet refuses here rather than raising a
      # MatchError on the page.
      with {:ok, facts, %{coverage: coverage}} <-
             Runners.list_pack_advertisement_facts(@console_advertising_runner_limit, subject) do
        {index, malformed?} = ConsoleProjection.advertising_index(facts)
        # A fact we couldn't read is a runner we can't rule out, so it degrades
        # coverage rather than vanishing from the answer.
        {:ok, {index, (malformed? && :partial) || coverage}}
      end
    else
      {:ok, :not_needed}
    end
  end

  # Discovery: the pack ids in this account that the member's own pack or runner
  # access does not reach, so the console can say a pack EXISTS without handing
  # over anything about it. Identity only, and structurally so — the read
  # selects `pack_id` and nothing else (`distinct_pack_ids/1`), so no trust
  # state, action, advertiser, version or decision fact about an out-of-scope
  # pack is produced for a caller to render by accident. The name filter still
  # applies because the id is all we matched on anyway; a RISK filter returns
  # none, since judging an out-of-scope pack's risk would mean reading its
  # actions — exactly what the member may not see.
  defp out_of_scope_pack_ids(pack_versions, name, "", %Subject{} = subject) do
    in_scope = MapSet.new(pack_versions, & &1.pack_id)

    PackVersion.Query.all()
    |> PackVersion.Query.distinct_pack_ids()
    |> Authorizer.for_subject(subject)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(in_scope, &1))
    |> Enum.filter(fn pack_id ->
      pack_id |> String.downcase() |> String.contains?(name)
    end)
    |> Enum.sort()
  end

  defp out_of_scope_pack_ids(_pack_versions, _name, _risk, _subject), do: []

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
  The distinct actions a pack version advertises — the catalog rows deduped to
  one per `action_id`, sorted, so a trust decision shows WHAT the version can do
  (action + risk), not just its hash. Account-scoped via the subject. Returns
  `{:ok, [%RunnerAction{}]}`.
  """
  def list_pack_actions(pack_id, pack_version, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      access = Accounts.runner_access_for_subject(subject)

      actions =
        RunnerAction.Query.all()
        |> RunnerAction.Query.by_pack(pack_id, pack_version)
        |> scope_actions_to_runners(access)
        |> scope_actions_to_packs(access)
        |> RunnerAction.Query.ordered_by_action()
        |> RunnerAction.Query.select_console_columns()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> ConsoleProjection.most_severe_actions_by_id()

      {:ok, actions}
    end
  end

  @doc """
  Cheap count of pack versions in the member's current pack access awaiting an
  operator decision — pending trust reviews PLUS retired-blocked trusted versions (see
  `pack_version_needs_decision?/1`) — drives the sidebar + dashboard badge.
  Same Subject gate + account scoping as `list_pack_versions/2`; returns `0`
  when the caller lacks permission so the badge silently disappears instead
  of erroring.
  """
  def count_pack_versions_needing_decision(%Subject{} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      :ok ->
        access = Accounts.runner_access_for_subject(subject)
        visible_deployments = visible_deployments(subject, access)

        pending =
          PackVersion.Query.pending()
          |> scope_pack_versions_to_packs(access)
          |> scope_pack_versions_to_visible_runners(visible_deployments)
          |> Authorizer.for_subject(subject)
          |> Repo.aggregate(:count)

        pending + count_retired_blocked(access, visible_deployments, subject)

      _ ->
        0
    end
  end

  # Retirement lives in the published catalog snapshot (`PackBaseline`), not in
  # a column, so the version comparison happens in Elixir over a narrow read:
  # trusted, unoverridden rows of the packs that carry a watermark at all.
  defp count_retired_blocked(
         %Accounts.RunnerAccess{} = access,
         visible_deployments,
         %Subject{} = subject
       ) do
    watermarked_pack_ids = Map.keys(PackBaseline.retired_below())

    queryable =
      PackVersion.Query.trusted_unoverridden()
      |> PackVersion.Query.by_pack_ids(watermarked_pack_ids)
      |> scope_pack_versions_to_packs(access)
      |> scope_pack_versions_to_visible_runners(visible_deployments)
      |> PackVersion.Query.select_decision_fields()
      |> Authorizer.for_subject(subject)

    queryable
    |> Repo.all()
    |> Enum.count(&ConsoleProjection.pack_version_needs_decision?/1)
  end

  # -- Published catalog ------------------------------------------------
  #
  # The published pack library is one public document, identical for every
  # tenant, so these reads take no `%Auth.Subject{}`. They are the context's
  # window onto `PublishedRegistry` for the marketing pages, the machine
  # registry endpoints, and the sitemap.

  @doc "Every published pack, ordered alphabetically by id."
  @spec list_published_packs() :: [PublishedRegistry.Pack.t()]
  def list_published_packs, do: PublishedRegistry.list()

  @doc "How many packs the published catalog carries."
  @spec published_pack_count() :: non_neg_integer()
  def published_pack_count, do: PublishedRegistry.pack_count()

  @doc "How many actions the published catalog declares across every pack."
  @spec published_action_count() :: non_neg_integer()
  def published_action_count, do: PublishedRegistry.action_count()

  @doc "The lean host-matching index `emisar pack suggest` reads."
  @spec published_pack_suggestion_index() :: [map()]
  def published_pack_suggestion_index, do: PublishedRegistry.suggest_index()

  @doc """
  The immutable, content-addressed tarball URL for a published pack's current
  version. Returns `{:ok, url} | :error`.
  """
  @spec published_pack_tarball_url(String.t()) :: {:ok, String.t()} | :error
  def published_pack_tarball_url(id), do: PublishedRegistry.tarball_url(id)

  @doc """
  The immutable tarball URL for one published pack VERSION — its current one or
  a remembered prior one. Returns `{:ok, url} | :error`.
  """
  @spec published_pack_tarball_url(String.t(), String.t()) :: {:ok, String.t()} | :error
  def published_pack_tarball_url(id, version), do: PublishedRegistry.tarball_url(id, version)

  @doc "One published pack by id, or nil when the catalog doesn't carry it."
  @spec get_published_pack(String.t()) :: PublishedRegistry.Pack.t() | nil
  def get_published_pack(id), do: PublishedRegistry.get(id)

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

  @doc "Whether `subject` may change the account-wide pack-retention schedule."
  def subject_can_manage_pack_retention?(%Subject{} = subject),
    do: subject_can_manage_packs?(subject) and full_pack_access?(subject)

  # Current access, re-read on every call: a narrowed pack scope takes the
  # account-wide schedule away from an open session immediately.
  defp full_pack_access?(%Subject{} = subject) do
    case Accounts.runner_access_for_subject(subject) do
      %Accounts.RunnerAccess{pack_mode: :all} -> true
      %Accounts.RunnerAccess{} -> false
    end
  end
end
