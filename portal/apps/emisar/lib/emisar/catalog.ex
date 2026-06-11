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
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.Runner
  alias Emisar.Catalog.{Authorizer, PackBaseline, PackVersion, RunnerAction}
  require Logger

  @doc """
  Observe the full `runner_state` payload: upsert pack_versions and
  the runner's actions, prune actions that disappeared from the
  latest advertisement. Also applies hostname/labels/version to the
  runner row in the same transaction.

  Internal — called by the runner socket process which is itself
  authenticated by the runner token. Not exposed to LV/MCP.
  """
  def observe_state(%Runner{} = runner, %{} = payload) do
    # Commit the runner-row facts (version, group, hostname, labels, packs)
    # FIRST, in their own transaction. They must land on every reconnect
    # even when the heavier pack/action catalog sync below is slow, errors,
    # or the socket dies mid-sync. Folding the row update into the same
    # transaction as a few-hundred-action upsert meant one bad action — or a
    # disconnect mid-sync — rolled the whole thing back, pinning the runner
    # to a stale version/group while the catalog churned.
    #
    # `apply_state` ends in `Repo.update` and can return `{:error, changeset}`
    # on a stale-struct race or a bad/oversized field from untrusted runner
    # JSON. A hard match would raise a MatchError above the try/rescue and drop
    # the socket → reconnect loop → same crash. Keep the existing struct on
    # error (the next heartbeat re-syncs) and continue with the catalog sync.
    runner =
      case Emisar.Runners.apply_state(runner, payload) do
        {:ok, updated} ->
          updated

        {:error, reason} ->
          Logger.warning("apply_state for runner #{runner.id} failed: #{inspect(reason)}")

          runner
      end

    now = DateTime.utc_now()
    packs = payload["packs"] || %{}
    actions = payload["actions"] || []

    catalog =
      try do
        Repo.transaction(fn ->
          pending_before = pending_pack_count(runner.account_id)
          Enum.each(packs, &observe_pack(runner.account_id, &1, now))
          pending_after = pending_pack_count(runner.account_id)

          seen_ids =
            actions
            |> Enum.map(&observe_action(runner, &1, packs, now))
            |> Enum.reject(&is_nil/1)

          prune_missing_actions(runner.id, seen_ids)
          pending_before != pending_after
        end)
      rescue
        # The catalog is best-effort and re-syncs on the next runner_state;
        # never let it crash the runner socket (which would drop + revert
        # the connection) now that the durable row facts are already saved.
        error -> {:error, error}
      end

    case catalog do
      {:ok, pending_changed?} ->
        # Light up the pack-trust badge only when the pending set actually
        # moved (drift / new custom pack), and only after the commit.
        if pending_changed?, do: broadcast_pack_trust(runner.account_id)

      {:error, reason} ->
        Logger.warning("catalog sync for runner #{runner.id} failed: #{inspect(reason)}")
    end

    {:ok, runner}
  end

  def observe_state(runner_id, payload) when is_binary(runner_id) do
    case Emisar.Runners.peek_runner_by_id(runner_id) do
      %Runner{} = runner -> observe_state(runner, payload)
      nil -> {:error, :unknown_runner}
    end
  end

  # COUNT of pending pack versions for an account — internal liveness
  # signal for the badge broadcast, no Subject (runs inside the already
  # authenticated runner-socket observe path).
  defp pending_pack_count(account_id) do
    PackVersion.Query.all()
    |> PackVersion.Query.by_account_id(account_id)
    |> PackVersion.Query.pending()
    |> Repo.aggregate(:count)
  end

  # -- Pack-version pinning --------------------------------------------

  defp observe_pack(account_id, {pack_id, info}, now) when is_map(info) do
    version = info["version"] || "unknown"
    advertised = info["hash"]

    existing =
      PackVersion.Query.all()
      |> PackVersion.Query.by_account_id(account_id)
      |> PackVersion.Query.by_pack_id_and_version(pack_id, version)
      |> Repo.peek()

    case existing do
      nil -> insert_pinned(account_id, pack_id, version, advertised, now)
      %PackVersion{} = pack_version -> maybe_mark_pending(pack_version, advertised, now)
    end
  end

  # Skip a malformed (non-map) pack advertisement rather than letting
  # `info["version"]` raise and abort the whole sync (the valid packs +
  # actions in the same batch should still persist).
  defp observe_pack(_account_id, _entry, _now), do: :ok

  # First sight of (account, pack_id, version). Behavior depends on
  # whether we ship a baseline hash for this (pack_id, version):
  #
  #   * Baseline + match → auto-pin trusted. The bytes match what we
  #     vouched for in the shipped pack library; no review needed.
  #   * Baseline + mismatch → pin BASELINE as trusted, advertised as
  #     pending. The pack is one of ours but the bytes were modified
  #     locally; operator must Trust to adopt or Reject to keep the
  #     library baseline. Dispatch refuses in the meantime.
  #   * No baseline (self-written / third-party / custom pack) → pin
  #     as pending with NO trusted hash. Operator must approve in
  #     /app/packs before any of its actions can run. Trust adopts
  #     the advertised hash as the trusted hash.
  #
  # Concurrency: multiple runners can advertise the same pack at the
  # same time, so two `observe_state` calls can peek nil for the same
  # `(account, pack_id, version)` and then both try to insert. We use
  # `on_conflict: :nothing` against the unique index so the loser of
  # the race quietly drops through to the "row exists" path and
  # follows `maybe_mark_pending`, instead of crashing the runner
  # socket with a unique-violation Changeset error.
  defp insert_pinned(account_id, pack_id, version, advertised, now) do
    baseline = PackBaseline.lookup(pack_id, version)

    {trusted_hash, pending_hash, trust_state, audit_event} =
      cond do
        is_binary(baseline) and baseline == advertised ->
          {advertised, nil, :trusted, :pack_trust_baseline_match}

        is_binary(baseline) ->
          {baseline, advertised, :pending, :pack_trust_baseline_mismatch}

        true ->
          # Self-written / custom pack — never auto-trust. Dispatch
          # refuses until a human clicks Trust in /app/packs.
          {nil, advertised, :pending, :pack_trust_review_required}
      end

    changeset =
      PackVersion.Changeset.insert(%{
        account_id: account_id,
        pack_id: pack_id,
        version: version,
        hash: trusted_hash,
        pending_hash: pending_hash,
        trust_state: trust_state,
        pinned_at: now,
        first_seen_at: now,
        last_seen_at: now
      })

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:account_id, :pack_id, :version]
         ) do
      {:ok, %PackVersion{id: id} = pack_version} when not is_nil(id) ->
        # We won the race and inserted. id is the Postgres-returned UUID.
        Audit.record(Audit.Events.pack_pinned(pack_version, audit_event, advertised, baseline))
        pack_version

      _ ->
        # Lost the race (or RETURNING gave us no id because of conflict).
        # Treat the row that's now there as the canonical one and feed
        # the advertised hash through the drift detector — no audit log
        # for the missed pin; the winning insert already logged it.
        existing =
          PackVersion.Query.all()
          |> PackVersion.Query.by_account_id(account_id)
          |> PackVersion.Query.by_pack_id_and_version(pack_id, version)
          |> Repo.peek()

        case existing do
          %PackVersion{} = pack_version -> maybe_mark_pending(pack_version, advertised, now)
          # Truly nothing there (would mean a non-conflict failure we don't
          # know how to recover from) — let the caller see the empty result.
          nil -> nil
        end
    end
  end

  # Existing row + new advertisement. Only state changes worth
  # audit-logging are trusted→pending and pending→pending-with-new-hash.
  defp maybe_mark_pending(%PackVersion{} = pack_version, advertised, now) do
    cond do
      pack_version.hash == advertised ->
        # Runner is still reporting the trusted bytes — keep state,
        # but if a pending_hash had been recorded earlier, leave it
        # in place. Operators decide via Trust/Reject, not by
        # whichever runner heartbeats next.
        pack_version
        |> PackVersion.Changeset.touch(now)
        |> Repo.update!()

      pack_version.pending_hash == advertised ->
        # Already pending against this exact hash — just touch.
        pack_version
        |> PackVersion.Changeset.touch(now)
        |> Repo.update!()

      true ->
        {:ok, updated} =
          pack_version
          |> PackVersion.Changeset.mark_pending(advertised, now)
          |> Repo.update()

        Audit.record(Audit.Events.pack_trust_drift_detected(pack_version, advertised))
        updated
    end
  end

  # -- Trust / Reject mutators -----------------------------------------

  @doc """
  Adopt the pending hash as the new trusted hash. Records who clicked,
  audits the adoption in the same transaction as the flip. Returns
  `{:error, :not_pending}` when there's nothing pending to adopt.
  """
  def trust_pack_version(pack_version_id, %Subject{} = subject) do
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
        repo.update(PackVersion.Changeset.trust(pending, subject))
      end)
      |> Multi.insert(:audit, fn %{before: pending} ->
        Audit.Events.pack_trust_adopted(subject, pending)
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
      that was just observed for the first time). Reject deletes the
      row entirely. There's nothing to fall back to and we don't
      want a stale `trusted-but-null-hash` row to leak through. If
      the runner keeps advertising the pack on later heartbeats it
      will come back as pending — that gives the operator another
      chance to approve, OR a signal to remove the pack at the
      runner end.
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
        if is_nil(pending.hash) do
          # Never trusted. Drop the row — Trust is a no-op when nothing
          # exists, and a future advertisement will recreate it as
          # pending.
          repo.delete(pending)
        else
          repo.update(PackVersion.Changeset.reject(pending, subject))
        end
      end)
      |> Multi.insert(:audit, fn %{before: pending} ->
        Audit.Events.pack_trust_rejected(subject, pending, row_deleted: is_nil(pending.hash))
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

  # Locked re-read for the Trust/Reject decision: the row is fetched
  # FOR NO KEY UPDATE inside the transaction (account-scoped via
  # for_subject) and must still be pending — so two operators racing
  # Trust vs. Reject serialize, and the loser gets `:not_pending`
  # instead of flipping or deleting a row the winner already resolved.
  defp lock_pending_pack_version(repo, pack_version_id, %Subject{} = subject) do
    if Repo.valid_uuid?(pack_version_id) do
      pack_version =
        PackVersion.Query.all()
        |> PackVersion.Query.by_id(pack_version_id)
        |> PackVersion.Query.lock_for_update()
        |> Authorizer.for_subject(subject)
        |> repo.one()

      case pack_version do
        nil ->
          {:error, :not_found}

        %PackVersion{trust_state: :pending, pending_hash: hash} = pack_version
        when not is_nil(hash) ->
          {:ok, pack_version}

        %PackVersion{} ->
          {:error, :not_pending}
      end
    else
      {:error, :not_found}
    end
  end

  def fetch_pack_version_by_id(id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      PackVersion.Query.all()
      |> PackVersion.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(PackVersion.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # -- Dispatch gate ---------------------------------------------------

  @doc """
  Internal — `Runs.dispatch_run` calls this before queueing a run.
  Returns `:ok` if the action's `(pack_id, pack_version)` is trusted,
  `{:error, :pack_untrusted, info}` otherwise.

  The action carries `pack_version` populated by `observe_action`
  based on the runner's last-reported `runner_state.packs` payload.
  Actions advertised before this migration ran (pack_version is nil)
  pass through — they'll get a version on the next runner heartbeat.
  """
  def check_pack_trusted(%RunnerAction{} = action) do
    if is_nil(action.pack_id) or is_nil(action.pack_version) do
      :ok
    else
      case peek_pack_version_for_action(action) do
        nil ->
          :ok

        %PackVersion{trust_state: :trusted} ->
          :ok

        %PackVersion{trust_state: :pending} = pack_version ->
          {:error, :pack_untrusted, pack_version}
      end
    end
  end

  # The pinned pack_version row for an action's (account, pack_id, version),
  # or nil — shared by the two dispatch-gate reads. `peek` (nil-or-struct)
  # per §1.1: a missing row is a meaningful "nothing pinned yet" state.
  defp peek_pack_version_for_action(%RunnerAction{} = action) do
    PackVersion.Query.all()
    |> PackVersion.Query.by_account_id(action.account_id)
    |> PackVersion.Query.by_pack_id_and_version(action.pack_id, action.pack_version)
    |> Repo.peek()
  end

  @doc """
  Internal — returns the **trusted** hash the cloud has on file for the
  action's `(pack_id, pack_version)`, or `nil` if we don't have one yet
  (e.g. action observed before pack_version was populated, or no pack
  row exists). `Runs.dispatch_to_runner` stamps this into the wire
  envelope as `expected_pack_hash`; the runner re-hashes its on-disk
  pack on receive and refuses the dispatch on mismatch.

  This is the *trusted* hash, never the pending one — that's what makes
  the runner-side check meaningful. If the operator hasn't approved
  drift yet, dispatch already refuses upstream in `check_pack_trusted`;
  if they have approved drift, the new hash *is* the trusted hash by
  then. Either way, the field we ship matches the bytes the operator
  said yes to.
  """
  def trusted_hash_for_action(%RunnerAction{} = action) do
    if is_nil(action.pack_id) or is_nil(action.pack_version) do
      nil
    else
      case peek_pack_version_for_action(action) do
        %PackVersion{trust_state: :trusted, hash: hash} -> hash
        _ -> nil
      end
    end
  end

  # -- Action upsert ---------------------------------------------------

  defp observe_action(%Runner{} = runner, descriptor, packs, now) when is_map(descriptor) do
    pack_id = descriptor["pack_id"]

    # `packs` is untrusted runner-advertised state: a descriptor can name a
    # pack_id that isn't in the packs map, or map to a non-map. Pull the
    # version defensively so one malformed descriptor doesn't abort the whole
    # batch's action upsert (vs. `packs[pack_id]["version"]` raising BadMapError).
    pack_version =
      case packs[pack_id] do
        %{"version" => v} -> v
        _ -> nil
      end

    attrs = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: descriptor["id"],
      pack_id: pack_id,
      pack_version: pack_version,
      title: descriptor["title"] || descriptor["id"],
      kind: descriptor["kind"] || "exec",
      risk: descriptor["risk"] || "low",
      description: descriptor["description"],
      side_effects: descriptor["side_effects"] || [],
      args_schema: %{"args" => descriptor["args"] || []},
      limits: descriptor["limits"] || %{},
      output: descriptor["output"] || %{},
      examples: descriptor["examples"] || [],
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
        case RunnerAction.Changeset.upsert(attrs) |> Repo.insert() do
          {:ok, %RunnerAction{action_id: id}} -> id
          {:error, _} -> nil
        end

      %RunnerAction{} = row ->
        case RunnerAction.Changeset.update(row, attrs) |> Repo.update() do
          {:ok, %RunnerAction{action_id: id}} -> id
          {:error, _} -> nil
        end
    end
  end

  # A runner can advertise a malformed (non-map) action descriptor; skip it
  # (the caller rejects nils) rather than letting `descriptor["id"]` raise and
  # abort the whole batch's action upsert.
  defp observe_action(_runner, _descriptor, _packs, _now), do: nil

  defp prune_missing_actions(_runner_id, []), do: :ok

  defp prune_missing_actions(runner_id, seen_action_ids) do
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
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> RunnerAction.Query.ordered_by_action()
      |> Authorizer.for_subject(subject)
      |> Repo.list(RunnerAction.Query, opts)
    end
  end

  def list_actions_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      {risk, opts} = Keyword.pop(opts, :risk)

      RunnerAction.Query.all()
      |> RunnerAction.Query.ordered_by_action_seen()
      |> apply_risk_filter(risk)
      |> Authorizer.for_subject(subject)
      |> Repo.list(RunnerAction.Query, opts)
    end
  end

  defp apply_risk_filter(query, nil), do: query
  defp apply_risk_filter(query, risk), do: RunnerAction.Query.by_risk(query, risk)

  @doc """
  Every advertised catalog action for the subject's account — the
  COMPLETE set, deliberately un-paginated.

  This is the MCP path. `tools/list` and dispatch resolution must see
  the whole catalog, not a page: a single runner with a handful of
  packs advertises hundreds of actions, so the paginated
  `list_actions_for_account/2` (what the UI uses) would silently hide
  everything past the first page. Same `view_catalog` gate + account
  scoping; returns `{:ok, actions}` — there is no cursor.
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
      PackVersion.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(PackVersion.Query, opts)
    end
  end

  @doc """
  Cheap COUNT(*) of pack versions pending trust review — drives the
  sidebar + dashboard "needs review" badge. Same Subject gate + account
  scoping as `list_pack_versions/2`; returns `0` when the caller lacks
  permission so the badge silently disappears instead of erroring.
  """
  def count_pending_pack_versions(%Subject{} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_catalog_permission()) do
      :ok ->
        PackVersion.Query.pending()
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      _ ->
        0
    end
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

  @doc "Whether `subject` may manage packs (admin+)."
  def subject_can_manage_packs?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_catalog_permission())
end
