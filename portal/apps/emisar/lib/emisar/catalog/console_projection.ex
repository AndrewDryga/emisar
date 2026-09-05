defmodule Emisar.Catalog.ConsoleProjection do
  @moduledoc """
  Turns already-fetched catalog rows into what the Packs page renders.

  Everything here is pure — no Repo, no Query module, no `%Subject{}` — and that
  was measured before it moved: the transitive closure of these functions never
  reaches the database. That is the whole reason it is its own module. Inside
  `Emisar.Catalog` they were private and only reachable through a Subject-gated
  read, so the rules they encode could not be exercised without first building
  an account, a runner, a pack version and a trust decision.

  `Emisar.Catalog` keeps the six of these the web already calls and delegates to
  them, so the dependency runs one way.
  """

  alias Emisar.Catalog.{ActionSetDiff, PackBaseline, PackVersion}
  alias Emisar.Users

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

  # Mirrors `observe_pack/3`'s `info["version"] || "unknown"` so an
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
      actions: actions,
      action_changes: action_set_changes(pack_version, actions),
      advertising: advertising_fact,
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

  def advertising_fact(%PackVersion{}, :not_needed),
    do: %{coverage: :not_needed, runners: []}

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
      actor_id: pack_version.retirement_overridden_by_id,
      actor_label: override_actor_label(pack_version.retirement_overridden_by)
    }
  end

  # Human-first: the name, then the email. A soft-deleted (or unloaded)
  # overrider has no label at all — the web words that absence.
  def override_actor_label(%Users.User{full_name: full_name})
      when is_binary(full_name) and full_name != "",
      do: full_name

  def override_actor_label(%Users.User{email: email}) when is_binary(email), do: email

  def override_actor_label(_absent), do: nil

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
