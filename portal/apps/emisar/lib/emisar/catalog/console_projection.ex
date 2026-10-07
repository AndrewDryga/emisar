defmodule Emisar.Catalog.ConsoleProjection do
  @moduledoc """
  Turns already-fetched catalog rows into what the Packs page renders.

  Everything here is pure — no Repo, no query execution, no `%Subject{}` — and that
  was measured before it moved: the transitive closure of these functions never
  reaches the database. That is the whole reason it is its own module. Inside
  `Emisar.Catalog` they were private and only reachable through a Subject-gated
  read, so the rules they encode could not be exercised without first building
  an account, a runner, a pack version and a trust decision.

  `Emisar.Catalog` keeps the six of these the web already calls and delegates to
  them, so the dependency runs one way.
  """

  alias Emisar.Catalog.{ActionSetDiff, PackBaseline, PackVersion, RunnerAction, TrustedManifest}

  # Severity order. Catalog's own risk folding reads it back through
  # risk_rank/0 rather than keeping a second copy, so one table ranks risk for
  # the whole context.
  @risk_rank %{low: 0, medium: 1, high: 2, critical: 3}

  @doc "The severity order used when picking the worst of several risks."
  def risk_rank, do: @risk_rank

  @doc """
  Retirement state of a pack row against the published catalog, for the Packs
  page: `:active`, or `{:retired, current_version}` when the row's version is
  below its pack's retirement watermark — `current_version` is the fixed
  version to update to (`nil` if we no longer publish the pack). Pure over the
  published `PackBaseline` snapshot. An already-overridden row still reports
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
  Whether a trusted pack version has a newer published successor to update to —
  `{:outdated, successor}` for a NON-retired version below the current
  published version, else `:current`. A convenience signal, not a warning: a security fix
  RETIRES a version (packs retire only on security/critical fixes), so an
  outdated-but-not-retired version is safe by construction and still dispatches.
  Retirement takes precedence — a retired version reads `:current` here so the
  stronger rose retired block shows alone, never the gentle hint on top of it.
  Pure over the published `PackBaseline` snapshot; the packs LiveView reads it.
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
  The content hash we publish for `(pack_id, version)`, or nil when we don't
  publish it — the `--hash` integrity pin for an `emisar pack install`
  command that updates a runner to a published version. Pure over the
  published `PackBaseline` snapshot.
  """
  @spec shipped_hash(String.t(), String.t() | nil) :: String.t() | nil
  def shipped_hash(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: PackBaseline.lookup(pack_id, version)

  def shipped_hash(_, _), do: nil

  @doc """
  A version awaiting an operator decision: a pending trust review, or a
  trusted version whose published-catalog retirement blocks dispatch until an
  admin overrides, updates, revokes, or deletes it. Rejected and overridden
  rows are decided. Pure over the published `PackBaseline` snapshot; drives the
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

  # Rows whose rendering needs to know WHO is on the version: a pending or
  # rejected review (the trust decision's blast radius) and a trusted row the
  # published catalog retired (its remedy differs when hosts are still on it).
  def advertiser_facts_needed?(%PackVersion{trust_state: state})
      when state in [:pending, :rejected],
      do: true

  def advertiser_facts_needed?(%PackVersion{} = pack_version), do: retired?(pack_version)

  def advertising_index(facts) do
    Enum.reduce(facts, {%{}, false}, fn runner, {index, malformed?} ->
      identity = Map.take(runner, [:id, :name, :group])

      case runner.packs do
        packs when is_map(packs) ->
          Enum.reduce(packs, {index, malformed?}, fn entry, {index, malformed?} ->
            case advertised_pack_ref(entry) do
              {:ok, pack_ref} ->
                {Map.update(index, pack_ref, [identity], &[identity | &1]), malformed?}

              :error ->
                {index, true}
            end
          end)

        _malformed ->
          {index, true}
      end
    end)
  end

  # Mirrors `observe_packs/3`'s `info["version"] || "unknown"` so an
  # advertisement resolves to the very row that pin created; anything else is
  # reported as malformed, never silently dropped.
  def advertised_pack_ref({pack_id, info}) when is_binary(pack_id) and is_map(info) do
    case Map.get(info, "version") do
      version when is_binary(version) -> {:ok, {pack_id, version}}
      nil -> {:ok, {pack_id, "unknown"}}
      _malformed -> :error
    end
  end

  def advertised_pack_ref(_entry), do: :error

  def console_version_facts(pack_versions, action_rows, advertising) do
    Map.new(pack_versions, fn pack_version ->
      {pack_version.id, console_version_fact(pack_version, action_rows, advertising)}
    end)
  end

  def console_version_fact(%PackVersion{} = pack_version, action_rows, advertising) do
    {retired?, successor} =
      case pack_version_retirement(pack_version) do
        {:retired, successor} -> {true, successor}
        :active -> {false, nil}
      end

    # A rejected row is already dispatch-blocked and an overridden one was
    # decided, so neither wears the retirement face.
    blocked? =
      retired? and pack_version.trust_state != :rejected and
        is_nil(pack_version.retirement_overridden_at)

    actions = pending_decision_actions(pack_version, action_rows)
    advertising_fact = advertising_fact(pack_version, advertising)
    update_successor = update_successor(pack_version)

    %{
      trust_state: pack_version.trust_state,
      display_state: (blocked? && "retired") || to_string(pack_version.trust_state),
      trust_review?: pack_version.trust_state == :pending,
      needs_decision?: pack_version_needs_decision?(pack_version),
      actions:
        Enum.map(
          action_summaries(actions),
          &%{
            &1
            | availability: %{
                status: :unavailable,
                reason: availability_reason(:untrusted),
                coverage: :not_needed,
                runners: []
              }
          }
        ),
      action_changes: action_set_changes(pack_version, actions),
      advertising: advertising_fact,
      reporting: reporting_fact(pack_version, advertising),
      current_version: PackBaseline.current_version(pack_version.pack_id),
      retired?: retired?,
      retirement_blocked?: blocked?,
      retirement_successor: successor,
      retirement_successor_hash: shipped_hash(pack_version.pack_id, successor),
      retirement_remedy: retirement_remedy(pack_version, blocked?, advertising_fact),
      update_successor: update_successor,
      update_successor_hash: shipped_hash(pack_version.pack_id, update_successor),
      override: override_attribution(pack_version)
    }
  end

  # Keep full descriptors through the exact-hash trust diff, then retain only
  # the fields rendered in the action list, matching its lazy query projection.
  def action_summaries(actions) do
    fields = RunnerAction.Query.console_columns()
    Enum.map(actions, &struct(RunnerAction, Map.take(&1, fields)))
  end

  # What trusting THIS decision would authorize: the rows carrying the exact
  # hash awaiting review, selected before the most-severe dedupe so a row
  # bearing the already-trusted hash can never stand in for the pending one and
  # skew the manifest diff.
  def pending_decision_actions(%PackVersion{trust_state: :pending} = pack_version, action_rows) do
    action_rows
    |> Map.get({pack_version.pack_id, pack_version.version}, [])
    |> Enum.filter(&(&1.pack_hash == pack_version.pending_hash))
    |> most_severe_actions_by_id()
  end

  def pending_decision_actions(%PackVersion{}, _action_rows), do: []

  def advertising_fact(%PackVersion{} = pack_version, {index, coverage}) do
    if advertiser_facts_needed?(pack_version) do
      pack_ref = {pack_version.pack_id, pack_version.version}
      %{coverage: coverage, runners: index |> Map.get(pack_ref, []) |> Enum.reverse()}
    else
      %{coverage: :not_needed, runners: []}
    end
  end

  def advertising_fact(version, %{lifecycle: advertising}),
    do: advertising_fact(version, advertising)

  def advertising_fact(%PackVersion{}, :not_needed),
    do: %{coverage: :not_needed, runners: []}

  @doc "Exact-hash reporter index, separate from whole-version lifecycle blast radius."
  def reporting_index(facts) do
    Enum.reduce(facts, {%{}, false}, fn runner, {index, malformed?} ->
      packs = if is_map(runner.packs), do: runner.packs, else: %{}
      malformed? = malformed? or not is_map(runner.packs)

      Enum.reduce(packs, {index, malformed?}, fn entry, {index, malformed?} ->
        with {:ok, {pack_id, version}} <- advertised_pack_ref(entry),
             {_id, %{"hash" => hash}} when is_binary(hash) <- entry do
          identity = Map.take(runner, [:id, :name, :group])
          {Map.update(index, {pack_id, version, hash}, [identity], &[identity | &1]), malformed?}
        else
          _ -> {index, true}
        end
      end)
    end)
  end

  def reporting_fact(version, %{reporting: {index, coverage}}) do
    hash =
      if version.trust_state == :pending,
        do: version.pending_hash,
        else: version.hash || version.pending_hash

    runners =
      index |> Map.get({version.pack_id, version.version, hash}, []) |> ordered_reporters()

    others =
      index
      |> Enum.flat_map(fn
        {{pack_id, pack_version, other_hash}, reporters}
        when pack_id == version.pack_id and pack_version == version.version and other_hash != hash ->
          reporters

        _ ->
          []
      end)
      |> ordered_reporters()

    %{coverage: coverage, runners: runners, other_hash_runners: others}
  end

  def reporting_fact(_version, _advertising),
    do: %{coverage: :unavailable, runners: [], other_hash_runners: []}

  defp ordered_reporters(reporters),
    do: reporters |> Enum.uniq_by(& &1.id) |> Enum.sort_by(&{&1.group || "", &1.name, &1.id})

  @doc "Compact immutable manifest contents, independent of current advertisements."
  def trusted_action_summaries(%PackVersion{} = version) do
    case TrustedManifest.actions(version.trusted_manifest) do
      {:ok, actions} ->
        actions
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, descriptor} ->
          %RunnerAction{
            action_id: id,
            pack_id: version.pack_id,
            pack_version: version.version,
            pack_hash: version.hash,
            title: descriptor["title"],
            kind: enum_value(descriptor["kind"], [:exec, :script]),
            risk: enum_value(descriptor["risk"], [:low, :medium, :high, :critical])
          }
        end)

      {:error, :incomplete_manifest} ->
        []
    end
  end

  defp enum_value(value, values), do: Enum.find(values, &(to_string(&1) == value))

  def console_contents(%PackVersion{trust_state: :trusted} = version, _observed) do
    case TrustedManifest.actions(version.trusted_manifest) do
      {:ok, _} -> trusted_action_summaries(version)
      {:error, :incomplete_manifest} -> :incomplete_manifest
    end
  end

  def console_contents(version, observed) do
    observed
    |> Map.get({version.pack_id, version.version}, [])
    |> most_severe_actions_by_id()
    |> action_summaries()
  end

  @doc "Browse facts over the existing scoped MCP compatibility verdict, not a second dispatch gate."
  def action_availability(version, actions, snapshot, runners, rows, coverage, execution_allowed?) do
    pack =
      Enum.find(
        snapshot.packs,
        &(&1.pack_id == version.pack_id and &1.version == version.version and
            &1.hash == version.hash)
      )

    projected_runners = Map.new(snapshot.runners, &{&1.id, &1})
    evidence = Map.new(rows, &{{&1.runner_id, &1.action_id}, &1})
    block = lifecycle_block(version)

    reporters =
      Enum.filter(runners, &reports_version?(&1, version))
      |> Enum.sort_by(&{&1.group || "", &1.name, &1.id})

    Enum.map(actions, fn action ->
      projected_action = pack && Enum.find(pack.actions, &(&1["action_id"] == action.action_id))
      eligible = (projected_action && projected_action.compatible_runner_ids) || []

      details =
        Enum.map(reporters, fn runner ->
          deployment = pack && pack.compatibility[runner.id]
          row = evidence[{runner.id, action.action_id}]

          status =
            block ||
              reporter_action_status(deployment, projected_runners[runner.id], action.action_id)

          Map.merge(Map.take(runner, [:id, :name, :group]), %{
            status: status,
            reason: availability_reason(status),
            admission_reported?: not is_nil(row) and not is_nil(row.admission_allowed),
            prerequisite_reported?:
              not is_nil(row) and not is_nil(row.primary_executable_available)
          })
        end)

      {status, reason} =
        availability_verdict(block, pack, eligible, details, coverage, execution_allowed?)

      %{
        action
        | availability: %{status: status, reason: reason, coverage: coverage, runners: details}
      }
    end)
  end

  defp reports_version?(runner, version) do
    match?(
      %{"version" => v} when v == version.version,
      Map.get(runner.packs || %{}, version.pack_id)
    )
  end

  defp reporter_action_status(_deployment, %{status: status}, _action_id)
       when status != "connected",
       do: if(status == "disabled", do: :disabled, else: :disconnected)

  defp reporter_action_status(nil, _runner, _action_id), do: :integrity_mismatch

  defp reporter_action_status(%{descriptor_match?: false}, _runner, _action_id),
    do: :integrity_mismatch

  defp reporter_action_status(deployment, _runner, action_id) do
    cond do
      action_id in deployment.admission_denied_action_ids -> :admission_denied
      action_id in deployment.unavailable_action_ids -> :executable_missing
      action_id in deployment.compatible_action_ids -> :available
      true -> :outside_scope
    end
  end

  defp lifecycle_block(%{trust_state: state}) when state != :trusted, do: :untrusted

  defp lifecycle_block(version) do
    cond do
      retired?(version) and is_nil(version.retirement_overridden_at) ->
        :retired

      TrustedManifest.actions(version.trusted_manifest) == {:error, :incomplete_manifest} ->
        :manifest_incomplete

      true ->
        nil
    end
  end

  defp availability_verdict(block, pack, eligible, details, coverage, execution_allowed?) do
    cond do
      block ->
        {:unavailable, availability_reason(block)}

      not execution_allowed? ->
        {:unavailable, availability_reason(:outside_scope)}

      eligible != [] ->
        ready = Enum.filter(details, &(&1.status == :available))
        qualifiers = if coverage == :partial, do: ["Partial fleet preview"], else: []

        qualifiers =
          if Enum.any?(ready, &(not &1.admission_reported?)),
            do: ["Admission not reported" | qualifiers],
            else: qualifiers

        qualifiers =
          if Enum.any?(ready, &(not &1.prerequisite_reported?)),
            do: ["Executable availability not reported" | qualifiers],
            else: qualifiers

        {:available, Enum.join(Enum.reverse(qualifiers), "; ")}

      coverage == :unavailable ->
        {:unknown, "Runner details require fleet access."}

      coverage == :partial ->
        {:unknown, "No eligible runner in this partial fleet preview."}

      details == [] ->
        {:unavailable, "No runner reports this exact pack version."}

      is_nil(pack) ->
        {:unavailable, "Runner reports a different hash or an unverifiable pack reference."}

      true ->
        connected = Enum.reject(details, &(&1.status in [:disconnected, :disabled]))
        relevant = if connected == [], do: details, else: connected
        reasons = relevant |> Enum.map(&availability_reason(&1.status)) |> Enum.uniq()
        {:unavailable, Enum.join(reasons, " ")}
    end
  end

  def availability_reason(:available),
    do: "Available; policy and approval are checked when starting a run."

  def availability_reason(:admission_denied), do: "Local admission denies this action."
  def availability_reason(:executable_missing), do: "Primary executable is missing."
  def availability_reason(:disabled), do: "Runner is disabled."
  def availability_reason(:disconnected), do: "Runner is not connected."

  def availability_reason(:integrity_mismatch),
    do: "Advertisement does not match the complete trusted manifest."

  def availability_reason(:outside_scope),
    do: "Your current execution access excludes this target."

  def availability_reason(:untrusted), do: "Pack contents are not trusted."
  def availability_reason(:retired), do: "This pack version is retired."
  def availability_reason(:manifest_incomplete), do: "The trusted manifest is incomplete."

  # The ONE fix a retired version's notice offers. Hosts we know are still on it
  # → update them (override only if you genuinely can't yet). None, from a
  # COMPLETE fleet read → the version is dead weight and removal is clean. None,
  # from a PARTIAL read → we cannot claim nobody is on it, so neither removing
  # nor overriding is honest; the operator resolves who is advertising it first.
  def retirement_remedy(%PackVersion{trust_state: :trusted}, true, %{runners: [_ | _]}),
    do: :update_or_override

  def retirement_remedy(%PackVersion{trust_state: :trusted}, true, %{coverage: :complete}),
    do: :remove

  def retirement_remedy(%PackVersion{trust_state: :trusted}, true, %{coverage: :partial}),
    do: :resolve_advertisers

  def retirement_remedy(%PackVersion{trust_state: :trusted}, true, %{coverage: :unavailable}),
    do: :resolve_advertisers

  def retirement_remedy(%PackVersion{}, _blocked?, _advertising), do: :none

  def update_successor(%PackVersion{trust_state: :trusted} = pack_version) do
    case pack_version_outdated(pack_version) do
      {:outdated, successor} -> successor
      :current -> nil
    end
  end

  def update_successor(%PackVersion{}), do: nil

  def override_attribution(%PackVersion{retirement_overridden_at: nil}), do: nil

  def override_attribution(%PackVersion{} = pack_version) do
    %{
      at: pack_version.retirement_overridden_at,
      actor_id: pack_version.retirement_overridden_by_membership_id,
      actor_label: pack_version.retirement_override_label
    }
  end

  def retired?(%PackVersion{} = pack_version),
    do: match?({:retired, _}, pack_version_retirement(pack_version))

  def console_filter(pack_versions, "", "", _actions_by_pack_ref), do: {pack_versions, %{}}

  def console_filter(pack_versions, name, risk, actions_by_pack_ref) do
    name? = name != ""
    risk? = risk != ""
    name_hit? = &String.contains?(String.downcase(&1.action_id), name)
    risk_hit? = &(to_string(&1.risk) == risk)

    {visible, matched} =
      Enum.reduce(pack_versions, {[], %{}}, fn version, {visible, matched} ->
        actions = Map.get(actions_by_pack_ref, {version.pack_id, version.version}, [])

        name_ok? =
          not name? or String.contains?(String.downcase(version.pack_id), name) or
            Enum.any?(actions, name_hit?)

        risk_ok? = not risk? or Enum.any?(actions, risk_hit?)

        if name_ok? and risk_ok? do
          matched_ids =
            for action <- actions,
                not risk? or risk_hit?.(action),
                not name? or name_hit?.(action),
                into: MapSet.new(),
                do: action.action_id

          {[version | visible], track_matched(matched, version.id, matched_ids)}
        else
          {visible, matched}
        end
      end)

    {Enum.reverse(visible), matched}
  end

  # A version whose only hit was its pack id has nothing specific to surface, so
  # it stays out of the map entirely rather than carrying an empty set.
  def track_matched(matched, version_id, matched_ids) do
    if Enum.empty?(matched_ids), do: matched, else: Map.put(matched, version_id, matched_ids)
  end

  def console_groups(visible, pack_versions) do
    account_versions = Enum.group_by(pack_versions, & &1.pack_id)

    visible
    |> Enum.group_by(& &1.pack_id)
    |> Enum.map(fn {pack_id, versions} ->
      %{
        id: pack_id,
        versions: Enum.sort_by(versions, & &1.last_seen_at, {:desc, DateTime}),
        update: pack_update(pack_id, Map.fetch!(account_versions, pack_id))
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  # The pack-level "a newer version shipped" nudge, said once per pack: a
  # trusted, non-retired version below the current shipped one, and nothing
  # trusted already AT (or ahead of) it. Judged over the account's WHOLE set for
  # the pack rather than the filtered rows — a filter that hides the current
  # version must not invent a nudge to update to a version you already run.
  def pack_update(pack_id, versions) do
    states =
      for %PackVersion{trust_state: :trusted} = version <- versions,
          do: {version, pack_version_outdated(version)}

    successor = Enum.find_value(states, fn {_version, state} -> outdated_successor(state) end)

    already_current? =
      Enum.any?(states, fn {version, state} -> state == :current and not retired?(version) end)

    if successor && not already_current? do
      %{version: successor, hash: shipped_hash(pack_id, successor)}
    end
  end

  def outdated_successor({:outdated, successor}), do: successor

  def outdated_successor(:current), do: nil

  def most_severe_actions_by_id(actions) do
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
  Subject-gated read) and its advertised `%RunnerAction{}` rows loaded WHOLE —
  the diff compares every descriptor field, so summary-column rows (from
  `list_pack_actions/3` or `select_console_columns/1`) would silently report no
  changes. A nil manifest (trusted before this feature, or never trusted)
  yields an empty diff — the UI falls back to listing the actions.
  Returns `%{added: [...], removed: [...], changed: [...]}`.
  """
  def action_set_changes(%PackVersion{} = pack_version, advertised_actions)
      when is_list(advertised_actions) do
    pending_actions =
      Enum.filter(advertised_actions, &(&1.pack_hash == pack_version.pending_hash))

    ActionSetDiff.changes(pending_actions, pack_version.trusted_manifest)
  end
end
