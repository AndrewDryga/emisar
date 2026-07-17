defmodule EmisarWeb.PacksLive do
  @moduledoc """
  Pack inventory + trust state across the account's runners.

  Each `(pack_id, version)` is one row holding the trusted hash + an
  optional pending hash. The page surfaces:

    * Which packs / versions are deployed.
    * **Pending trust** — a runner advertised a hash that doesn't
      match the trusted one. Dispatch refuses to authorize against
      pending versions until an admin clicks Trust or Reject.

  Pinning rules (see `Emisar.Catalog`):

    * First sight, hash matches our shipped baseline → trusted.
    * First sight, hash diverges from baseline → pending; baseline
      is the trusted hash, advertised is the pending.
    * First sight, no baseline (self-written / custom pack) →
      pending with NO trusted hash. Operator must Trust before any
      of its actions can run.
    * Hash later changes → pending.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Catalog, Runners}
  alias EmisarWeb.ConfirmDialog

  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, "Packs")

    # Trusted versions' actions are loaded lazily, one query per opened
    # contents expansion (see `inspect_pack`), keyed by version id — trusted
    # versions can be many, so we never eagerly look them all up.
    socket = assign(socket, :inspected_actions, %{})

    # Which contents expansions are open, keyed by version id. The rows are a
    # stream (static once pushed), so the open state must live server-side for
    # the chevron + expansion to survive each group re-insert.
    socket = assign(socket, :open_versions, MapSet.new())

    # Reject is IRREVERSIBLE-feeling (the trusted/pending decision flips
    # dispatch authorization), so it routes through a typed-confirm modal. The
    # pack rows live in a `phx-update="stream"` (static once pushed), so the
    # dialog can't live per-row — instead one page-level dialog reads the pack
    # being rejected from `@reject_target`, set by the `open_reject` event.
    socket = socket |> ConfirmDialog.init() |> assign(:reject_target, nil)

    # Two filters narrow the list. `name_filter` searches pack id AND action id
    # (so "postgres.activity" surfaces the postgres pack); `risk_filter` keeps
    # only packs advertising an action at that tier. Both filter on the account's
    # action index, loaded (once) only while a filter is active — see `load_packs`.
    socket = assign(socket, :name_filter, "")
    socket = assign(socket, :risk_filter, "")
    socket = assign(socket, :pack_action_index, %{})
    socket = assign(socket, :matched_actions, %{})

    if connected?(socket) do
      {:ok, socket |> load_packs() |> assign(:loading?, false)}
    else
      # `mount` runs twice (dead render + connected mount) — the pack list
      # is up to 500 rows, so defer the read to the connected pass (IL-18)
      # and render an empty stream + loading shimmer on the dead one.
      {:ok,
       socket
       |> assign(:loading?, true)
       |> assign(:load_error?, false)
       |> assign(:pack_count, 0)
       |> assign(:version_count, 0)
       |> assign(:pending_count, 0)
       |> assign(:advertising, %{})
       |> assign(:pack_actions, %{})
       |> assign(:pack_diffs, %{})
       |> stream(:packs, [])}
    end
  end

  # Each stream entry is one pack group: `%{id: pack_id, versions: [...]}`.
  # The list is held by the stream (bounded socket memory), not a plain
  # assign. `reset: true` replaces the whole set on the connected mount and
  # after a mutation reload; targeted Trust/Reject updates a single group
  # via `stream_insert`/`stream_delete` (see `restream_pack/2`).
  defp load_packs(socket) do
    case fetch_rows(socket) do
      {:ok, rows} ->
        # Pending counts + the sidebar badge reflect the ACCOUNT, not the
        # current filter — only the rendered groups narrow. The badge counts
        # every decision (pending reviews + retired-blocked); the page's
        # amber callout stays trust-review-only — retired versions carry
        # their own rose notice per row.
        pending = Enum.count(rows, &(&1.trust_state == :pending))
        index = load_action_index(socket)
        socket = assign(socket, :pack_action_index, index)
        {visible_rows, matched} = filter_view(rows, socket)
        groups = group_by_pack(visible_rows)

        socket
        |> assign(:load_error?, false)
        |> assign(:pack_count, count_packs(visible_rows))
        |> assign(:version_count, length(visible_rows))
        |> assign(:pending_count, pending)
        # Keep the sidebar badge in step after a decision on this page.
        |> assign(:pending_packs_count, Enum.count(rows, &Catalog.pack_version_needs_decision?/1))
        |> assign(:advertising, advertising_runners(rows, socket.assigns.current_subject))
        |> assign_pending_pack_actions(rows)
        |> assign(:matched_actions, matched)
        # A filter drives what's expanded: auto-open every version it matched
        # (via risk/action) and pre-load those action lists so they render at
        # once. A manual open (`inspect_pack`) then adds to this set until the
        # next filter change re-seeds it.
        |> assign(:open_versions, MapSet.new(Map.keys(matched)))
        |> update(:inspected_actions, &seed_action_lists(&1, visible_rows, index, matched))
        |> stream(:packs, groups, reset: true)

      # A failed read must read as an error, not an empty inventory — "No packs
      # reported yet" would wrongly imply the fleet advertises nothing.
      :error ->
        socket
        |> assign(:load_error?, true)
        |> assign(:pack_count, 0)
        |> assign(:version_count, 0)
        |> assign(:pending_count, 0)
        |> assign(:advertising, %{})
        |> assign(:pack_actions, %{})
        |> assign(:pack_diffs, %{})
        |> assign(:pack_action_index, %{})
        |> assign(:matched_actions, %{})
        |> stream(:packs, [], reset: true)
    end
  end

  @risk_tiers ~w(low medium high critical)
  defp normalize_risk(risk) when risk in @risk_tiers, do: risk
  defp normalize_risk(_), do: ""

  defp filter_active?(socket),
    do: socket.assigns.name_filter != "" or socket.assigns.risk_filter != ""

  # The account's whole pack→action index — one read, only while a filter is
  # live (an unfiltered page keeps the lazy per-disclosure loading it always had).
  defp load_action_index(socket) do
    if filter_active?(socket) do
      case Catalog.pack_actions_index(socket.assigns.current_subject) do
        {:ok, index} -> index
        _ -> %{}
      end
    else
      %{}
    end
  end

  # Apply the active filters to freshly-read rows using the cached index:
  # `{visible_rows, matched}` where `matched` is `%{version_id => MapSet of the
  # action_ids that matched}` (the reason a version is shown, for auto-open +
  # highlight). With no filter active every row survives and nothing is matched.
  defp filter_view(rows, socket) do
    apply_filters(
      rows,
      socket.assigns.name_filter,
      socket.assigns.risk_filter,
      socket.assigns.pack_action_index
    )
  end

  defp apply_filters(rows, "", "", _index), do: {rows, %{}}

  defp apply_filters(rows, name, risk, index) do
    needle = String.downcase(name)
    name? = name != ""
    risk? = risk != ""

    {kept, matched} =
      Enum.reduce(rows, {[], %{}}, fn v, {kept, matched} ->
        actions = Map.get(index, {v.pack_id, v.version}, [])
        pack_hit? = name? and String.contains?(String.downcase(v.pack_id), needle)
        action_hit? = &String.contains?(String.downcase(&1.action_id), needle)

        name_ok = not name? or pack_hit? or Enum.any?(actions, action_hit?)
        risk_ok = not risk? or Enum.any?(actions, &(to_string(&1.risk) == risk))

        if name_ok and risk_ok do
          # An action is a "match" — it drives auto-open + the matched-only
          # contents view — when it satisfies every ACTIVE axis at the ACTION
          # level: its risk is the filtered tier, and its id carries the needle.
          # A pack matched only by its id (no action carries the needle) has no
          # matched action, so it stays collapsed — nothing specific to surface.
          matched_ids =
            for a <- actions,
                not risk? or to_string(a.risk) == risk,
                not name? or action_hit?.(a),
                into: MapSet.new(),
                do: a.action_id

          matched =
            if Enum.empty?(matched_ids), do: matched, else: Map.put(matched, v.id, matched_ids)

          {[v | kept], matched}
        else
          {kept, matched}
        end
      end)

    {Enum.reverse(kept), matched}
  end

  defp count_packs(rows), do: rows |> Enum.map(& &1.pack_id) |> Enum.uniq() |> length()

  # Pre-load the action list for each matched version so its auto-opened
  # disclosure renders immediately (the index already holds them) — merged over
  # whatever `inspect_pack` lazily cached.
  defp seed_action_lists(inspected, visible_rows, index, matched) do
    visible_rows
    |> Enum.filter(&Map.has_key?(matched, &1.id))
    |> Enum.reduce(inspected, fn v, acc ->
      Map.put(acc, v.id, Map.get(index, {v.pack_id, v.version}, []))
    end)
  end

  # What trusting each pending version authorizes, keyed by pack_version id
  # (only pending versions are looked up). Two assigns built from one read of
  # the advertised actions:
  #
  #   * `pack_actions` — the full advertised action set + risk, so "Trust new
  #     contents" shows the capability, not just a hash.
  #   * `pack_diffs` — when this version was trusted before (has a stored
  #     manifest), what CHANGED vs then: added / removed / risk-or-kind
  #     changed. An added critical action is exactly what an operator must see
  #     before re-trusting a re-advertised hash.
  defp assign_pending_pack_actions(socket, rows) do
    subject = socket.assigns.current_subject

    details =
      rows
      |> Enum.filter(&(&1.trust_state == :pending))
      |> Map.new(fn version ->
        actions =
          case Catalog.list_pack_actions(version.pack_id, version.version, subject) do
            {:ok, actions} -> actions
            _ -> []
          end

        {version.id, {actions, Catalog.action_set_changes(version, actions)}}
      end)

    socket
    |> assign(:pack_actions, Map.new(details, fn {id, {actions, _diff}} -> {id, actions} end))
    |> assign(:pack_diffs, Map.new(details, fn {id, {_actions, diff}} -> {id, diff} end))
  end

  # Blast radius of a trust decision: which runners advertise each version
  # awaiting one (so the operator sees one canary box vs the whole fleet).
  # Keyed by pack_version id; pending reviews and rejected rows (whose Trust
  # modal quotes the same count) are looked up.
  defp advertising_runners(rows, subject) do
    runners_by_id =
      case Runners.list_runners_for_account(subject) do
        {:ok, runners, _meta} -> Map.new(runners, &{&1.id, &1})
        _ -> %{}
      end

    rows
    |> Enum.filter(&(&1.trust_state in [:pending, :rejected]))
    |> Map.new(fn version ->
      ids =
        case Catalog.runner_ids_advertising_pack(version.pack_id, version.version, subject) do
          {:ok, ids} -> ids
          _ -> []
        end

      {version.id, ids |> Enum.map(&Map.get(runners_by_id, &1)) |> Enum.reject(&is_nil/1)}
    end)
  end

  defp fetch_rows(socket) do
    case Catalog.list_pack_versions(socket.assigns.current_subject,
           order_by: [{:packs, :asc, :pack_id}, {:packs, :asc, :version}],
           # The retirement-override note names who re-trusted a retired version.
           preload: [:retirement_overridden_by],
           page: [limit: 500]
         ) do
      # Rejected rows stay listed (quietly — no review alert) so an admin
      # mistake is visible and reversible: the row offers Trust to adopt the
      # refused bytes or restore revoked trust. Dispatch fails closed on them
      # either way.
      {:ok, rows, _meta} -> {:ok, rows}
      {:error, _} -> :error
    end
  end

  defp pending_review_title(1), do: "1 pack version needs trust review."
  defp pending_review_title(count), do: "#{count} pack versions need trust review."

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:name_filter, String.trim(params["name"] || ""))
     |> assign(:risk_filter, normalize_risk(params["risk"]))
     |> load_packs()}
  end

  def handle_event("trust", %{"id" => id}, socket) do
    case Catalog.trust_pack_version(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Trusted #{pack_version.pack_id} v#{pack_version.version}.")
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Nothing pending on that pack.")}

      {:error, :nothing_to_trust} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Nothing recorded to trust — wait for a runner to advertise this pack again."
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to trust packs.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not trust pack — try again.")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case Catalog.reject_pack_version(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(:info, reject_flash(pack_version))
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Nothing pending on that pack.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to reject packs.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reject pack — try again.")}
    end
  end

  def handle_event("revoke_trust", %{"id" => id}, socket) do
    case Catalog.revoke_pack_version_trust(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Revoked trust in #{pack_version.pack_id} v#{pack_version.version}. Dispatch refuses it until you trust it again."
         )
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_trusted} ->
        {:noreply, put_flash(socket, :error, "Only a trusted version can be revoked.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to revoke pack trust.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That pack version no longer exists.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not revoke trust — try again.")}
    end
  end

  def handle_event("delete_version", %{"id" => id}, socket) do
    case Catalog.delete_pack_version(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Deleted #{pack_version.pack_id} v#{pack_version.version}. A runner still advertising it will re-insert it as a fresh trust decision."
         )
         |> restream_pack(pack_version.pack_id)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to delete packs.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That pack version no longer exists.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete the version — try again.")}
    end
  end

  def handle_event("delete_pack", %{"pack_id" => pack_id}, socket) do
    case Catalog.delete_pack(pack_id, socket.assigns.current_subject) do
      {:ok, versions} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Deleted #{pack_id} (#{version_count_label(versions)}). A runner still advertising it will re-insert it as a fresh trust decision."
         )
         |> restream_pack(pack_id)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to delete packs.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That pack no longer exists.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete the pack — try again.")}
    end
  end

  def handle_event("set_pack_retention", %{"days" => raw}, socket) do
    apply_pack_retention(socket, parse_retention_days(raw))
  end

  def handle_event("cleanup_now", _params, socket) do
    case Catalog.sweep_unseen_pack_versions(socket.assigns.current_subject) do
      {:ok, 0} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Nothing to remove — every pack version was seen within the window."
         )}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, cleanup_flash(count))
         |> load_packs()}

      {:error, :retention_disabled} ->
        {:noreply, put_flash(socket, :error, "Turn on automatic cleanup first.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to clean up the catalog.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not clean up — try again.")}
    end
  end

  # Override the retirement of a trusted version — the deliberate, audited
  # admin decision that unblocks dispatch again. `override_pack_retirement/2`
  # re-checks manage_catalog (IL-15), so a crafted event from a viewer denies.
  def handle_event("override_retirement", %{"id" => id}, socket) do
    case Catalog.override_pack_retirement(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Overrode the retirement of #{pack_version.pack_id} v#{pack_version.version}. Dispatch is unblocked for this version — update the pack on your runners when you can."
         )
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_trusted} ->
        {:noreply,
         put_flash(socket, :error, "Only a trusted version's retirement can be overridden.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to override pack retirement.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That pack version no longer exists.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not override retirement — try again.")}
    end
  end

  # Stash which pack version the reject dialog targets (the rows are a stream,
  # so the dialog is page-level and reads this assign). Typed-confirm is UX
  # friction only — `reject` above stays the server gate.
  def handle_event(
        "open_reject",
        %{"id" => id, "pack_id" => pack_id, "version" => version},
        socket
      ) do
    target = %{id: id, token: "#{pack_id} v#{version}"}
    {:noreply, socket |> assign(:reject_target, target) |> ConfirmDialog.reset()}
  end

  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  # The "View contents" disclosure toggled. Track the open state server-side so
  # the pack group's re-insert (a stream child is static once pushed) renders
  # `<details open>` — otherwise the first open snaps shut when the re-render
  # strips the browser's native `open`. We mirror the native toggle (which fired
  # on the same click): open when it wasn't, close when it was, so the two stay in
  # sync. The action set is loaded once, on first open, and cached in
  # `inspected_actions` keyed by version id (trusted versions can be many, so we
  # never eagerly look them all up). The Catalog read re-checks `view_catalog`
  # itself (IL-15) — `pack_id`/`version` come from the rendered row, so a crafted
  # event can't reach another account's actions.
  def handle_event(
        "inspect_pack",
        %{"id" => id, "pack-id" => pack_id, "version" => version},
        socket
      ) do
    socket =
      if MapSet.member?(socket.assigns.open_versions, id) do
        update(socket, :open_versions, &MapSet.delete(&1, id))
      else
        socket
        |> maybe_load_actions(id, pack_id, version)
        |> update(:open_versions, &MapSet.put(&1, id))
      end

    {:noreply, reinsert_pack_group(socket, pack_id)}
  end

  defp maybe_load_actions(socket, id, pack_id, version) do
    if Map.has_key?(socket.assigns.inspected_actions, id) do
      socket
    else
      actions =
        case Catalog.list_pack_actions(pack_id, version, socket.assigns.current_subject) do
          {:ok, actions} -> actions
          _ -> []
        end

      update(socket, :inspected_actions, &Map.put(&1, id, actions))
    end
  end

  # A drift-reject reverts to the trusted bytes and the on-host mismatch stays
  # live, so it re-surfaces on the next advertisement; a never-trusted reject
  # sticks (the refused hash is remembered) until different bytes show up.
  defp reject_flash(%Catalog.PackVersion{trust_state: :trusted} = pack_version) do
    "Rejected drift on #{pack_version.pack_id} v#{pack_version.version}. The runner advertising the new hash will re-broadcast — if it's still set, this will re-surface."
  end

  defp reject_flash(%Catalog.PackVersion{} = pack_version) do
    "Rejected #{pack_version.pack_id} v#{pack_version.version}. It stays listed as rejected — a runner advertising different contents will re-open the review."
  end

  defp apply_pack_retention(socket, :error),
    do: {:noreply, put_flash(socket, :error, "Pick a valid cleanup period.")}

  defp apply_pack_retention(socket, {:ok, days_or_nil}) do
    case Accounts.update_account(
           socket.assigns.current_account,
           %{settings: %{pack_unseen_retention_days: days_or_nil}},
           socket.assigns.current_subject
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:current_account, account)
         |> put_flash(:info, retention_set_flash(days_or_nil))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update automatic cleanup.")}
    end
  end

  defp parse_retention_days(""), do: {:ok, nil}

  defp parse_retention_days(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {days, ""} when days > 0 -> {:ok, days}
      _ -> :error
    end
  end

  defp retention_set_flash(nil), do: "Automatic cleanup turned off — pack versions are kept."

  defp retention_set_flash(days),
    do: "Automatic cleanup on — pack versions unseen for #{days} days are removed daily."

  defp cleanup_flash(1), do: "Removed 1 pack version no runner has advertised recently."

  defp cleanup_flash(count),
    do: "Removed #{count} pack versions no runner has advertised recently."

  defp retention_days_label(days), do: "after #{days} days unseen"

  defp pack_retention_options(current) do
    [
      %{
        value: "",
        label: "Off — keep unseen versions",
        selected: is_nil(current),
        disabled: false
      },
      %{value: "7", label: "After 7 days unseen", selected: current == 7, disabled: false},
      %{value: "14", label: "After 14 days unseen", selected: current == 14, disabled: false},
      %{value: "30", label: "After 30 days unseen", selected: current == 30, disabled: false},
      %{value: "60", label: "After 60 days unseen", selected: current == 60, disabled: false},
      %{value: "90", label: "After 90 days unseen", selected: current == 90, disabled: false}
    ]
  end

  # Re-render one pack group's stream item against the current assigns (a
  # stream child is static once pushed, so the just-loaded `inspected_actions`
  # only appears after a re-insert). One query for the group's versions; unlike
  # `restream_pack` this doesn't recompute the pending panels — inspecting a
  # trusted version changes nothing about what's pending.
  defp reinsert_pack_group(socket, pack_id) do
    case fetch_rows(socket) do
      {:ok, rows} ->
        {visible_rows, _matched} = filter_view(rows, socket)
        versions = visible_rows |> Enum.filter(&(&1.pack_id == pack_id)) |> sort_versions()

        if versions == [] do
          socket
        else
          stream_insert(socket, :packs, %{id: pack_id, versions: versions})
        end

      :error ->
        socket
    end
  end

  # After a trust decision, recompute just the affected pack group and update
  # the stream in place: `stream_delete` if no displayable version of the pack
  # remains (the name/risk filter can drop the group), otherwise
  # `stream_insert` the regrouped versions. The `pending_count` (and sidebar
  # badge) are recomputed from the full set.
  defp restream_pack(socket, pack_id) do
    case fetch_rows(socket) do
      {:ok, rows} ->
        pending = Enum.count(rows, &(&1.trust_state == :pending))
        {visible_rows, matched} = filter_view(rows, socket)
        versions = visible_rows |> Enum.filter(&(&1.pack_id == pack_id)) |> sort_versions()

        socket =
          socket
          |> assign(:pack_count, count_packs(visible_rows))
          |> assign(:version_count, length(visible_rows))
          |> assign(:pending_count, pending)
          |> assign(
            :pending_packs_count,
            Enum.count(rows, &Catalog.pack_version_needs_decision?/1)
          )
          |> assign(:advertising, advertising_runners(rows, socket.assigns.current_subject))
          |> assign_pending_pack_actions(rows)
          |> assign(:matched_actions, matched)
          |> update(
            :inspected_actions,
            &seed_action_lists(&1, visible_rows, socket.assigns.pack_action_index, matched)
          )

        if versions == [] do
          stream_delete(socket, :packs, %{id: pack_id})
        else
          stream_insert(socket, :packs, %{id: pack_id, versions: versions})
        end

      # The mutation committed but the re-read failed — surface the error rather
      # than leaving a stale count; the existing stream rows stay until reload.
      :error ->
        assign(socket, :load_error?, true)
    end
  end

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The action + risk rows a pack version contains — shared by the pending
  # "Trust new contents" panel and the trusted "View contents" disclosure so
  # both render the identical list. `action_id`/`title` are runner-advertised
  # (attacker-influenced); they render through escaped HEEx, never `raw/1`.
  attr :actions, :list, required: true
  attr :matched, :any, default: nil, doc: "MapSet of action_ids the active filter matched"
  attr :class, :string, default: nil

  defp pack_action_list(assigns) do
    ~H"""
    <ul class={["space-y-1", @class]}>
      <li
        :for={action <- @actions}
        class={[
          "flex items-center gap-2 border-l-2 pl-2 text-[11px]",
          (matched?(@matched, action.action_id) && "border-brand-500") || "border-transparent"
        ]}
      >
        <.risk_pill risk={action.risk} class="flex-none" />
        <span class={[
          "font-mono",
          (matched?(@matched, action.action_id) && "text-brand-200") || "text-zinc-300"
        ]}>
          {action.action_id}
        </span>
        <span :if={action.title} class="truncate text-zinc-500">{action.title}</span>
      </li>
    </ul>
    """
  end

  defp matched?(nil, _action_id), do: false
  defp matched?(matched, action_id), do: MapSet.member?(matched, action_id)

  attr :version, :map, required: true
  attr :inspected, :any, required: true, doc: "nil (unloaded), [] (none), or the action list"
  attr :matched, :any, default: nil, doc: "MapSet of matched action_ids, or nil when unfiltered"

  # A trusted version's auditable contents, expanded by the row's leading
  # chevron (one lazy query on first open — see `inspect_pack`). Carries the
  # forensic detail the one-line row deliberately drops: first seen + the full
  # hash. While a filter is active the row auto-opens and shows ONLY the
  # actions that matched, labelled with the count.
  defp version_contents(assigns) do
    assigns = assign(assigns, :shown, filtered_contents(assigns.inspected, assigns.matched))

    ~H"""
    <div class="mt-2 pl-8">
      <p class="text-[11px] text-zinc-500">
        <span :if={@matched} class="font-medium text-brand-300">
          {match_count_label(@shown)} ·
        </span>
        first seen
        <.local_time
          id={"pack-version-first-#{@version.id}"}
          value={@version.first_seen_at}
          mode={:relative}
          class="inline text-zinc-400"
        />
        <span class="text-zinc-700">·</span>
        <span class="break-all font-mono">{@version.hash || @version.pending_hash}</span>
      </p>
      <p :if={is_nil(@inspected)} class="mt-2 text-[11px] text-zinc-500">Loading…</p>
      <p :if={@inspected == []} class="mt-2 text-[11px] text-zinc-500">
        No actions advertised for this version right now.
      </p>
      <.pack_action_list :if={@shown not in [nil, []]} actions={@shown} class="mt-2" />
    </div>
    """
  end

  # The contents a disclosure renders: everything when unfiltered, only the
  # matched actions when a filter is active (nil stays nil — still loading).
  defp filtered_contents(nil, _matched), do: nil
  defp filtered_contents(actions, nil), do: actions

  defp filtered_contents(actions, matched),
    do: Enum.filter(actions, &matched?(matched, &1.action_id))

  defp match_count_label(shown) do
    n = length(shown || [])
    "#{n} matching #{if n == 1, do: "action", else: "actions"}"
  end

  attr :version, :map, required: true
  attr :pack_id, :string, required: true
  attr :can_manage, :boolean, required: true

  # A trusted version the shipped catalog RETIRED — a newer release marked every
  # version below a watermark unsafe (a critical fix). Dispatch fails closed
  # against it until the pack is updated on the runner OR an admin overrides the
  # retirement here. Rendered as the shared icon-capped spine — the ONE house
  # face for an operational alert; a hand-tinted box matches nothing else in
  # the console. An already-overridden row shows a muted, dated note instead of
  # the block + CTA — the override is deliberate and audited, so it doesn't
  # nag. Renders nothing for a version that isn't retired.
  defp retired_notice(assigns) do
    {retired?, current} =
      case Catalog.pack_version_retirement(assigns.version) do
        {:retired, current} -> {true, current}
        :active -> {false, nil}
      end

    assigns =
      assigns
      |> assign(:retired?, retired?)
      |> assign(:current_version, current)
      |> assign(:overridden?, not is_nil(assigns.version.retirement_overridden_at))

    ~H"""
    <.event_block
      :if={@retired? and not @overridden?}
      icon="hero-shield-exclamation"
      tone={:rose}
      title="Retired by a newer release"
      class="mt-3 pl-8"
    >
      <:body>
        A critical fix superseded this version. Dispatch is blocked for <code>{@pack_id}</code>
        v{@version.version} until you update the pack on the runner.
      </:body>
      <p class="mt-2 font-mono text-[11px] text-zinc-400">
        <span :if={@current_version}>→ v{@current_version}: </span>emisar pack install {@pack_id}
      </p>
      <%!-- Overriding a critical-fix retirement is a deliberate bypass — rose
           confirm, admin-only. It re-enables dispatch for this exact retired
           version; the audited context fn stays the server gate (IL-15). The
           version is already trusted, so the CTA names what it actually does —
           override the retirement — never "Trust". The quiet alternative
           (Revoke trust, in the row menu) silences this by refusing the
           version instead. --%>
      <div :if={@can_manage} class="mt-3 flex flex-wrap gap-2">
        <.confirm_button
          id={"override-#{@version.id}"}
          variant={:secondary}
          tone={:rose}
          size={:sm}
          title={"Override the retirement of #{@pack_id} v#{@version.version}?"}
          confirm_label="Override retirement"
          on_confirm={JS.push("override_retirement", value: %{id: @version.id})}
        >
          <:body>
            This version was retired by a newer release. Overriding lets its actions run again
            despite the fix — do this only if you can't yet update the pack on the runner. The
            override is audited. To silence this warning without allowing dispatch, remove the
            version instead.
          </:body>
          Override retirement
        </.confirm_button>
        <%!-- The other resolution: clear the alert WITHOUT allowing dispatch —
             remove the version (opens the row menu's delete dialog; a runner
             still advertising it re-inserts it). --%>
        <.button
          variant={:secondary}
          size={:sm}
          type="button"
          phx-click={open_confirm("delete-version-#{@version.id}")}
        >
          Remove version
        </.button>
      </div>
    </.event_block>
    <p
      :if={@retired? and @overridden?}
      class="mt-2 flex flex-wrap items-center gap-1.5 pl-8 text-[11px] text-zinc-500"
    >
      <.icon name="hero-shield-check" class="h-3.5 w-3.5 text-zinc-500" />
      Retired by a newer release — overridden by {overrider_name(@version)}
      <.local_time
        id={"pack-version-override-#{@version.id}"}
        value={@version.retirement_overridden_at}
        mode={:relative}
        class="inline"
      />
    </p>
    """
  end

  # Retirement is an overlay on a trusted row (release-frozen `PackBaseline`),
  # not a trust_state — so it's a pure per-row check, not a row field.
  defp pack_version_retired?(version),
    do: match?({:retired, _}, Catalog.pack_version_retirement(version))

  # A version the shipped catalog RETIRED and no admin has overridden — the one
  # row state the "retired" badge marks (replacing the trust badge, which would
  # contradict it). Covers a trusted row a watermark bump retired AND a
  # first-seen retired version a lagging runner still advertises (pending, never
  # trusted — a KNOWN pack whose bytes a security fix superseded, not an unknown
  # one to trust). A rejected row stays quiet.
  defp retired_blocked?(version) do
    version.trust_state != :rejected and is_nil(version.retirement_overridden_at) and
      pack_version_retired?(version)
  end

  # The version that superseded a retired one (nil if not retired) — the upgrade
  # target named in the "emisar pack install" guidance.
  defp retirement_successor(version) do
    case Catalog.pack_version_retirement(version) do
      {:retired, current} -> current
      :active -> nil
    end
  end

  # The admin who overrode a retirement, human-first (name, then email). The
  # user is preloaded; a soft-deleted overrider reads as "an admin".
  defp overrider_name(%{retirement_overridden_by: %{full_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp overrider_name(%{retirement_overridden_by: %{email: email}}) when is_binary(email),
    do: email

  defp overrider_name(_), do: "an admin"

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:packs}
      width={:table}
    >
      <:title>Packs</:title>

      <.page_intro>
        A pack is a versioned bundle of <span class="text-zinc-200">vetted actions</span>
        a runner may execute — the runner advertises what it has installed, and this
        page is your account's trust ledger over it.
        <.doc_link href="/docs/action-packs">Action pack docs</.doc_link>
      </.page_intro>

      <div class="mt-2 grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
        <div class="min-w-0">
          <.callout
            :if={@pending_count > 0}
            tone={:amber}
            icon="hero-shield-exclamation"
            title={pending_review_title(@pending_count)}
            class="mt-2"
          >
            Dispatch against these versions is blocked until an admin reviews the new hash.
          </.callout>

          <.loading_state :if={@loading?} />

          <.empty_state
            :if={@load_error? and not @loading?}
            tone={:danger}
            icon="hero-exclamation-triangle"
            title="Couldn't load packs"
            class="mt-8"
          >
            This is a load error, not an empty inventory — your runners may well be advertising
            packs. Refresh the page; if it persists, your access to this account may have changed.
          </.empty_state>

          <.empty_state
            :if={
              @pack_count == 0 and @name_filter == "" and @risk_filter == "" and not @load_error? and
                not @loading?
            }
            icon="hero-cube"
            title="No packs reported yet."
            class="mt-8"
          >
            A pack is the bundle of actions a runner can run.
            <.link
              navigate={~p"/app/#{@current_account}/runners"}
              class="text-brand-400 hover:text-brand-300"
            >
              Connect a runner
            </.link>
            and the packs it loads appear here to trust or reject.
          </.empty_state>

          <%!-- Inline filter row (shared LiveTable field grammar: label + brand
               active-state, sm:w-48). Search spans pack AND action ids; Risk keeps
               packs advertising an action at that tier. --%>
          <form
            :if={
              not @loading? and not @load_error? and
                (@pack_count > 0 or @name_filter != "" or @risk_filter != "")
            }
            phx-change="filter"
            class="mt-6 flex flex-wrap items-end gap-3"
          >
            <label class={[
              "flex w-full flex-col text-xs font-medium sm:w-56",
              (@name_filter != "" && "text-brand-300") || "text-zinc-400"
            ]}>
              <span class="mb-1">Pack or action</span>
              <input
                type="text"
                name="name"
                value={@name_filter}
                phx-debounce="300"
                placeholder="e.g. postgres.activity"
                class={[
                  "w-full rounded-lg border bg-zinc-950 px-2 py-1.5 text-xs text-zinc-200 placeholder:text-zinc-600",
                  (@name_filter != "" && "border-brand-500/60 ring-1 ring-brand-500/25") ||
                    "border-zinc-700"
                ]}
              />
            </label>
            <label class={[
              "flex w-full flex-col text-xs font-medium sm:w-40",
              (@risk_filter != "" && "text-brand-300") || "text-zinc-400"
            ]}>
              <span class="mb-1">Risk</span>
              <select
                name="risk"
                class={[
                  "w-full rounded-lg border bg-zinc-950 px-2 py-1.5 text-xs text-zinc-200",
                  (@risk_filter != "" && "border-brand-500/60 ring-1 ring-brand-500/25") ||
                    "border-zinc-700"
                ]}
              >
                <option value="" selected={@risk_filter == ""}>All risk</option>
                <option
                  :for={tier <- ~w(low medium high critical)}
                  value={tier}
                  selected={@risk_filter == tier}
                >
                  {String.capitalize(tier)}
                </option>
              </select>
            </label>
          </form>

          <%!-- Filter-empty ≠ account-empty: a quiet line, the filter stays live. --%>
          <p
            :if={
              @pack_count == 0 and (@name_filter != "" or @risk_filter != "") and
                not @load_error? and not @loading?
            }
            class="mt-6 text-sm text-zinc-500"
          >
            {no_match_copy(@name_filter, @risk_filter)}
          </p>

          <ul id="packs" phx-update="stream" class="mt-10 space-y-10">
            <%!-- CONTENT ON CANVAS (the runners-group grammar): each pack is a
                 naked group — mono pack id + version count on a hairline — with
                 its version rows below. The stream <li> wraps label + rows. The
                 1-2 rare admin verbs per row are small bordered buttons (the
                 LLM-agents grammar — a menu earns its click only at 3+ verbs);
                 their confirm dialogs render per row. --%>
            <li :for={{dom_id, pack} <- @streams.packs} id={dom_id}>
              <header class="flex flex-wrap items-baseline gap-x-2.5 gap-y-1 border-b border-zinc-800/70 pb-2.5">
                <h2 class="font-mono text-base font-semibold text-zinc-100">{pack.id}</h2>
                <span class="text-[11px] text-zinc-500">{version_count_label(pack.versions)}</span>
                <.registry_link pack_id={pack.id} />
                <.status_badge
                  :if={any_pending?(pack.versions)}
                  status="pending"
                  class="ml-1 text-[11px]"
                />
                <.button
                  :if={Catalog.subject_can_manage_packs?(@current_subject)}
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  type="button"
                  class="ml-auto self-center"
                  phx-click={open_confirm("delete-pack-#{pack.id}")}
                >
                  Delete pack
                </.button>
              </header>

              <.confirm_dialog
                :if={Catalog.subject_can_manage_packs?(@current_subject)}
                id={"delete-pack-#{pack.id}"}
                title={"Delete #{pack.id}?"}
                confirm_label="Delete pack"
                on_confirm={
                  JS.push("delete_pack", value: %{pack_id: pack.id})
                  |> close_confirm("delete-pack-#{pack.id}")
                }
              >
                <:body>
                  Removes every recorded version of <code>{pack.id}</code> — trust decisions
                  and advertised actions — from the catalog. Runners still advertising it
                  will re-insert it as a fresh trust decision. Audit history is kept.
                </:body>
              </.confirm_dialog>

              <ul class="divide-y divide-zinc-800/70">
                <li :for={v <- pack.versions} class="py-2.5">
                  <%!-- ONE line per version: chevron (contents) · identity ·
                       state — bound left, so the eye never crosses a gulf to
                       pair them — then last-seen + the row menu at the end. --%>
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <button
                      :if={v.trust_state == :trusted}
                      type="button"
                      phx-click="inspect_pack"
                      phx-value-id={v.id}
                      phx-value-pack-id={pack.id}
                      phx-value-version={v.version}
                      aria-expanded={to_string(MapSet.member?(@open_versions, v.id))}
                      aria-label={"Contents of #{pack.id} v#{v.version}"}
                      class="flex h-5 w-5 shrink-0 items-center justify-center rounded text-zinc-500 hover:text-zinc-200"
                    >
                      <.icon
                        name="hero-chevron-right"
                        class={"h-3.5 w-3.5 transition-transform #{if MapSet.member?(@open_versions, v.id), do: "rotate-90"}"}
                      />
                    </button>
                    <span
                      :if={v.trust_state != :trusted}
                      class="w-5 shrink-0"
                      aria-hidden="true"
                    >
                    </span>
                    <span class="font-mono text-sm text-zinc-200">v{v.version}</span>
                    <%!-- ONE row-state marker in ONE grammar (dot + word), BESIDE
                         the identity it qualifies — the page's primary fact, so
                         nothing wedges between them and the status column stays
                         steady to scan. A blocked row reads "retired" INSTEAD of
                         "trusted" (side by side they contradicted); an overridden
                         row is trusted again (the note below says why). --%>
                    <.status_badge
                      status={(retired_blocked?(v) && "retired") || to_string(v.trust_state)}
                      class="text-xs"
                    />
                    <%!-- The hash said nothing at browse altitude — the full hash
                         lives in the contents expansion; last-seen trails like
                         timestamps everywhere else in the console. --%>
                    <span class="text-[11px] text-zinc-500">
                      last seen
                      <.local_time
                        id={"pack-version-last-#{v.id}"}
                        value={v.last_seen_at}
                        mode={:relative}
                        class="text-zinc-400"
                      />
                    </span>
                    <div
                      :if={Catalog.subject_can_manage_packs?(@current_subject)}
                      class="ml-auto flex shrink-0 items-center gap-2"
                    >
                      <.button
                        :if={v.trust_state == :rejected and (v.pending_hash || v.hash) != nil}
                        variant={:secondary}
                        tone={:amber}
                        size={:sm}
                        type="button"
                        phx-click={open_confirm("trust-#{v.id}")}
                      >
                        Trust
                      </.button>
                      <.button
                        :if={v.trust_state == :trusted}
                        variant={:secondary}
                        size={:sm}
                        type="button"
                        phx-click={open_confirm("revoke-#{v.id}")}
                      >
                        Revoke trust
                      </.button>
                      <.button
                        variant={:secondary}
                        tone={:rose}
                        size={:sm}
                        type="button"
                        phx-click={open_confirm("delete-version-#{v.id}")}
                      >
                        Delete
                      </.button>
                    </div>
                  </div>

                  <%!-- The row buttons' confirm dialogs — per row, plain
                       (client-side) modals; the pushed events stay
                       server-authz-gated (IL-15). --%>
                  <%= if Catalog.subject_can_manage_packs?(@current_subject) do %>
                    <.confirm_dialog
                      :if={v.trust_state == :rejected and (v.pending_hash || v.hash) != nil}
                      id={"trust-#{v.id}"}
                      tone={:amber}
                      title={"Trust #{pack.id} v#{v.version}?"}
                      confirm_label="Trust pack"
                      on_confirm={
                        JS.push("trust", value: %{id: v.id}) |> close_confirm("trust-#{v.id}")
                      }
                    >
                      <:body>
                        <span :if={not is_nil(v.pending_hash)}>
                          Adopts the refused contents — its actions may run on {length(
                            @advertising[v.id] || []
                          )} advertising runner(s).
                        </span>
                        <span :if={is_nil(v.pending_hash)}>
                          Restores trust in the previously recorded contents — its actions may
                          dispatch again.
                        </span>
                        <span :if={pack_version_retired?(v)} class="text-rose-300">
                          This version was retired by a newer release — trusting it also
                          overrides that retirement, so its actions run despite the fix.
                        </span>
                      </:body>
                    </.confirm_dialog>
                    <.confirm_dialog
                      :if={v.trust_state == :trusted}
                      id={"revoke-#{v.id}"}
                      title={"Revoke trust in #{pack.id} v#{v.version}?"}
                      confirm_label="Revoke trust"
                      on_confirm={
                        JS.push("revoke_trust", value: %{id: v.id})
                        |> close_confirm("revoke-#{v.id}")
                      }
                    >
                      <:body>
                        Dispatch refuses this version until it's trusted again. It stays
                        listed as rejected, so you can restore trust later.
                      </:body>
                    </.confirm_dialog>
                    <.confirm_dialog
                      id={"delete-version-#{v.id}"}
                      title={"Delete #{pack.id} v#{v.version}?"}
                      confirm_label="Delete version"
                      on_confirm={
                        JS.push("delete_version", value: %{id: v.id})
                        |> close_confirm("delete-version-#{v.id}")
                      }
                    >
                      <:body>
                        Removes this version and its advertised actions from the catalog.
                        If a runner still advertises it, it will reappear as a fresh trust
                        decision on its next connection or reload. Audit history is kept.
                      </:body>
                    </.confirm_dialog>
                  <% end %>

                  <.version_contents
                    :if={v.trust_state == :trusted and MapSet.member?(@open_versions, v.id)}
                    version={v}
                    inspected={@inspected_actions[v.id]}
                    matched={@matched_actions[v.id]}
                  />

                  <.retired_notice
                    :if={v.trust_state == :trusted}
                    version={v}
                    pack_id={pack.id}
                    can_manage={Catalog.subject_can_manage_packs?(@current_subject)}
                  />

                  <%!-- A rejected version stays listed quietly — no alert, no
                       pending count; the row menu carries Trust, the
                       fix-admin-mistake path. --%>
                  <p :if={v.trust_state == :rejected} class="mt-1.5 pl-8 text-xs text-zinc-500">
                    Rejected — dispatch refuses this version until you trust it again.
                  </p>

                  <%!-- The one state that earns real weight: a live trust
                       decision, on the shared spine like every operational
                       alert — what changed, who it unblocks, and the decision
                       buttons inside one contained unit. A pending version that
                       sits below a shipped pack's retirement watermark is a KNOWN
                       pack whose bytes a security fix superseded, NOT an unknown
                       one to trust — it wears the rose retired face and leads
                       with the upgrade, keeping trust a labelled escape hatch. --%>
                  <.event_block
                    :if={v.trust_state == :pending}
                    icon="hero-shield-exclamation"
                    tone={(retired_blocked?(v) && :rose) || :amber}
                    title={
                      (retired_blocked?(v) && "Retired by a newer release") || "Pending trust review"
                    }
                    class="mt-3 pl-8"
                  >
                    <:body>
                      <span :if={retired_blocked?(v)}>
                        <code>{pack.id}</code> v{v.version} was retired by a newer release — a
                        security fix superseded it. The runners below are still on the old
                        version; update the pack to clear this.
                      </span>
                      <span :if={not retired_blocked?(v) and is_nil(v.hash)}>
                        A runner advertised <code>{pack.id}</code> v{v.version} —
                        a pack we don't ship a baseline for. Dispatch is blocked until
                        you trust its contents.
                      </span>
                      <span :if={not retired_blocked?(v) and not is_nil(v.hash)}>
                        A runner is advertising a different hash. Dispatch is blocked for
                        <code>{pack.id}</code>
                        v{v.version} until you decide.
                      </span>
                    </:body>
                    <p
                      :if={retired_blocked?(v)}
                      class="mt-2 font-mono text-[11px] text-zinc-400"
                    >
                      <span :if={retirement_successor(v)}>→ v{retirement_successor(v)}: </span>emisar pack install {pack.id}
                    </p>
                    <dl class="mt-2 grid grid-cols-[max-content,1fr] gap-x-3 gap-y-0.5 text-[11px]">
                      <.kv layout={:grid} label="trusted:">{v.hash || "— (none yet)"}</.kv>
                      <%!-- Amber flags the hash that CHANGED — the reason dispatch is blocked. --%>
                      <.kv layout={:grid} label="advertising:">
                        <span class="text-amber-300">{v.pending_hash || "—"}</span>
                      </.kv>
                    </dl>
                    <%!-- Blast radius — which hosts this trust click unblocks.
                         One canary box vs the whole fleet is the difference
                         between a safe and a scary Trust. --%>
                    <div
                      :if={@advertising[v.id] not in [nil, []]}
                      class="mt-2 text-[11px] leading-relaxed text-zinc-400"
                    >
                      <p>
                        <span class="font-semibold text-zinc-300">
                          {length(@advertising[v.id])}
                        </span>
                        <span :if={retired_blocked?(v)}>
                          runner(s) still on this retired version — update the pack on:
                        </span>
                        <span :if={not retired_blocked?(v)}>
                          runner(s) advertise this — trusting unblocks dispatch on:
                        </span>
                      </p>
                      <%!-- The chips wrap: a fleet can advertise dozens of runners, and a
                           comprehension renders them with no whitespace between, so an inline
                           run would be one unbreakable line that overflows the page. --%>
                      <div class="mt-1.5 flex flex-wrap gap-1">
                        <.chip :for={r <- @advertising[v.id]} tone={:amber} mono>
                          {r.name}<span class="text-amber-400/70"> · {r.group}</span>
                        </.chip>
                      </div>
                    </div>
                    <%!-- What CHANGED since this hash was last trusted — diffed
                         against the action set snapshotted at that Trust
                         (`trusted_manifest`). Only shown when a manifest exists
                         (a re-advertised hash, not a first-time pending). An added
                         critical action or a low→critical escalation is the
                         headline danger an operator must see before re-trusting. --%>
                    <div :if={diff_has_changes?(@pack_diffs[v.id])} class="mt-3">
                      <div class="flex items-center gap-1.5 text-[11px] font-semibold text-rose-300">
                        <.icon name="hero-arrows-right-left" class="h-3.5 w-3.5" />
                        Changes since you last trusted this pack:
                      </div>
                      <ul class="mt-2 space-y-1">
                        <li
                          :for={a <- @pack_diffs[v.id].added}
                          class="flex items-center gap-2 text-[11px]"
                        >
                          <span class="w-12 flex-none font-semibold uppercase tracking-wide text-rose-300">
                            + added
                          </span>
                          <.risk_pill risk={a.risk} class="flex-none" />
                          <span class="truncate font-mono text-zinc-200">{a.action_id}</span>
                        </li>
                        <li
                          :for={c <- @pack_diffs[v.id].changed}
                          class="flex items-center gap-2 text-[11px]"
                        >
                          <span class={[
                            "w-12 flex-none font-semibold uppercase tracking-wide",
                            if(c.risk_escalated?, do: "text-rose-300", else: "text-amber-300")
                          ]}>
                            ~ changed
                          </span>
                          <span class="flex items-center gap-1">
                            <.risk_pill risk={c.old_risk} class="flex-none opacity-60" />
                            <.icon name="hero-arrow-right" class="h-3 w-3 text-zinc-500" />
                            <.risk_pill risk={c.new_risk} class="flex-none" />
                          </span>
                          <span class="truncate font-mono text-zinc-200">{c.action_id}</span>
                          <span :if={c.old_kind != c.new_kind} class="flex-none text-zinc-500">
                            {c.old_kind} → {c.new_kind}
                          </span>
                        </li>
                        <li
                          :for={r <- @pack_diffs[v.id].removed}
                          class="flex items-center gap-2 text-[11px] text-zinc-500"
                        >
                          <span class="w-12 flex-none font-semibold uppercase tracking-wide">
                            − removed
                          </span>
                          <.risk_pill risk={r.risk} class="flex-none opacity-50" />
                          <span class="truncate font-mono line-through">{r.action_id}</span>
                        </li>
                      </ul>
                    </div>
                    <%!-- What trusting this authorizes — the FULL advertised action
                         set + risk (the diff above shows only what moved), so
                         "Trust new contents" isn't a blind click. --%>
                    <div :if={@pack_actions[v.id] not in [nil, []]} class="mt-3">
                      <div class="text-[11px] font-semibold text-zinc-300">
                        Trusting authorizes {length(@pack_actions[v.id])} action(s):
                      </div>
                      <.pack_action_list
                        actions={@pack_actions[v.id]}
                        matched={@matched_actions[v.id]}
                        class="mt-1"
                      />
                    </div>
                    <%!-- Trust/Reject mutate authorization state — owner/admin
                         only. The context gate (manage_catalog) is defense in
                         depth; hide the buttons for viewers/operators too so
                         they aren't offered an action that always denies. The
                         pending spine above stays visible to everyone — it
                         explains WHY dispatch is blocked. --%>
                    <div
                      :if={Catalog.subject_can_manage_packs?(@current_subject)}
                      class="mt-3 flex flex-wrap gap-2"
                    >
                      <%!-- Trust adopts code fleet-wide — a caution-approve (amber),
                           not a destruction, so the modal is amber. On a RETIRED
                           version trust is the wrong default (upgrade the runner
                           instead), so it recedes to a rose "Trust anyway" escape
                           hatch — the confirm body spells out the override. --%>
                      <.confirm_button
                        id={"trust-#{v.id}"}
                        variant={(retired_blocked?(v) && :secondary) || :primary}
                        tone={(retired_blocked?(v) && :rose) || :amber}
                        size={:sm}
                        title={
                          cond do
                            retired_blocked?(v) ->
                              "Trust the retired #{pack.id} v#{v.version} anyway?"

                            is_nil(v.hash) ->
                              "Trust #{pack.id} v#{v.version}?"

                            true ->
                              "Adopt the new hash for #{pack.id} v#{v.version}?"
                          end
                        }
                        confirm_label={
                          cond do
                            retired_blocked?(v) -> "Trust anyway"
                            is_nil(v.hash) -> "Trust pack"
                            true -> "Trust new contents"
                          end
                        }
                        on_confirm={JS.push("trust", value: %{id: v.id})}
                      >
                        <:body>
                          Cloud will allow its actions to run on {length(@advertising[v.id] || [])} advertising
                          runner(s). Trusting adopts this exact code fleet-wide.
                          <span :if={pack_version_retired?(v)} class="text-rose-300">
                            This version was retired by a newer release — trusting it also overrides
                            that retirement, so its actions run despite the fix.
                          </span>
                        </:body>
                        {cond do
                          retired_blocked?(v) -> "Trust anyway"
                          is_nil(v.hash) -> "Trust pack"
                          true -> "Trust new contents"
                        end}
                      </.confirm_button>
                      <%!-- IRREVERSIBLE-feeling — typed-confirm modal instead of
                           data-confirm. The button only OPENS the page-level dialog
                           (stashing this version as the target); `reject` still fires
                           from Confirm and stays server-authz-gated (manage_catalog). --%>
                      <.button
                        variant={:secondary}
                        size={:sm}
                        type="button"
                        phx-click={
                          JS.push("open_reject",
                            value: %{id: v.id, pack_id: pack.id, version: v.version}
                          )
                          |> show_confirm_dialog("reject-pack")
                        }
                      >
                        Reject
                      </.button>
                    </div>
                  </.event_block>
                </li>
              </ul>
            </li>
          </ul>

          <%!-- Family-standard count footer (runners/runs/approvals/audit all
               carry one). --%>
          <p :if={@pack_count > 0} class="mt-4 text-xs text-zinc-400">
            {count_footer(@pack_count, @version_count)}
          </p>
        </div>

        <aside class="space-y-6">
          <.docs_rail
            title="How pack trust works"
            doc_href="/docs/action-packs"
            doc_label="Action pack docs"
          >
            <p>
              Packs published by emisar are <span class="text-zinc-200">trusted automatically</span>
              — every version is
              pinned to the exact content hash of the signed registry build. When a
              security fix supersedes a version, the older release is
              <span class="text-zinc-200">retired</span>
              and dispatch to it is blocked until you update the runner or decide
              otherwise.
            </p>
            <p>
              Everything else — your own packs, third-party builds, or contents that
              changed on a host — waits as <span class="text-zinc-200">pending</span>
              until an admin reviews and trusts it.
            </p>
          </.docs_rail>

          <div>
            <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
              Housekeeping
            </h3>
            <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — self-contained control card, the team-security rail grammar --%>
            <div id="packs-cleanup" class="mt-3 rounded-xl border border-zinc-800/80 p-4">
              <h4 class="text-sm font-medium text-zinc-100">Automatic cleanup</h4>
              <p class="mt-1 text-xs leading-relaxed text-zinc-400">
                Remove pack versions no runner has advertised for the selected period. A daily
                sweep deletes them — trust decisions included — and a runner advertising one
                again re-inserts it as a fresh trust decision.
              </p>
              <%= if Accounts.subject_can_manage_account?(@current_subject) do %>
                <form phx-change="set_pack_retention" class="mt-3">
                  <.select
                    name="days"
                    aria-label="Remove pack versions not seen for"
                    options={
                      pack_retention_options(@current_account.settings.pack_unseen_retention_days)
                    }
                  />
                </form>
                <.confirm_button
                  :if={@current_account.settings.pack_unseen_retention_days}
                  id="packs-cleanup-now"
                  variant={:secondary}
                  tone={:neutral}
                  size={:lg}
                  class="mt-3 w-full"
                  title="Clean up unseen pack versions?"
                  confirm_label="Clean up now"
                  on_confirm={JS.push("cleanup_now")}
                >
                  <:body>
                    Deletes every pack version no runner has advertised in the last {@current_account.settings.pack_unseen_retention_days} days
                    — trust decisions included. Runners still advertising one will
                    re-insert it as a fresh trust decision.
                  </:body>
                  Clean up now
                </.confirm_button>
              <% else %>
                <p class="mt-2 text-[11px] text-zinc-400">
                  Owner/admin only — currently {(@current_account.settings.pack_unseen_retention_days &&
                                                   retention_days_label(
                                                     @current_account.settings.pack_unseen_retention_days
                                                   )) || "off"}.
                </p>
              <% end %>
            </div>
          </div>
        </aside>
      </div>

      <%!-- One page-level reject dialog (the rows are a stream, so it can't be
           per-row). It's always in the DOM so the trigger's `show` finds it;
           `open_reject` then fills @reject_target with the version's token +
           id. With no target the token is blank, so Confirm stays disabled.
           Confirm fires `reject` (still server-authz-gated) then closes. --%>
      <.confirm_dialog
        id="reject-pack"
        title="Reject this pack version"
        confirm_label="Reject pack"
        confirm_token={(@reject_target && @reject_target.token) || ""}
        typed={@typed}
        on_confirm={
          JS.push("reject", value: %{id: @reject_target && @reject_target.id})
          |> hide_confirm_dialog("reject-pack")
        }
      >
        <:body>
          Rejects <span class="font-mono font-medium text-zinc-200">
            {(@reject_target && @reject_target.token) || "this pack version"}
          </span>: its actions stay blocked and dispatch keeps refusing it. If a runner keeps
          advertising the hash, it reappears here pending another decision.
        </:body>
      </.confirm_dialog>
    </.dashboard_shell>
    """
  end

  defp group_by_pack(rows) do
    rows
    |> Enum.group_by(& &1.pack_id)
    |> Enum.map(fn {pack_id, vs} -> %{id: pack_id, versions: sort_versions(vs)} end)
    |> Enum.sort_by(& &1.id)
  end

  defp sort_versions(versions),
    do: Enum.sort_by(versions, & &1.last_seen_at, {:desc, DateTime})

  defp any_pending?(versions), do: Enum.any?(versions, &(&1.trust_state == :pending))

  defp version_count_label(versions) do
    n = length(versions)
    "#{n} #{if n == 1, do: "version", else: "versions"}"
  end

  defp count_footer(pack_count, version_count) do
    packs = if pack_count == 1, do: "pack", else: "packs"
    versions = if version_count == 1, do: "version", else: "versions"
    "#{pack_count} #{packs} · #{version_count} #{versions}"
  end

  # The filtered-empty line names whichever axes are active, so a no-match reads
  # as "nothing matched THESE filters", not an empty inventory.
  defp no_match_copy(name, risk) do
    cond do
      name != "" and risk != "" -> ~s(No #{risk}-risk packs match "#{name}".)
      name != "" -> ~s(No packs or actions match "#{name}".)
      true -> "No packs advertise a #{risk}-risk action."
    end
  end

  # The stored hash already carries the "sha256:" prefix the template
  # labels — strip it before slicing, or the row reads "sha256:sha256:…"
  # and shows five useful hex chars of the value operators verify.
  attr :pack_id, :string, required: true

  # A link out to the public pack-registry page. The registry page is
  # pack-scoped (one page per pack id), so the link lives on the pack header
  # — riding a version row implied it was version-specific and confused the
  # placement. Renders nothing for a custom pack the registry doesn't ship.
  defp registry_link(assigns) do
    assigns = assign(assigns, :url, registry_pack_url(assigns.pack_id))

    ~H"""
    <%!-- Muted on purpose: a rarely-used reference link must not outshine
         the pack identity it sits beside. --%>
    <.link
      :if={@url}
      href={@url}
      target="_blank"
      rel="noopener"
      class="inline-flex shrink-0 items-center gap-0.5 text-[11px] text-zinc-500 transition-colors hover:text-zinc-300"
      title="Published in emisar's public pack registry — opens in a new tab"
    >
      Registry <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
    </.link>
    """
  end

  defp registry_pack_url(pack_id) when is_binary(pack_id) do
    if EmisarWeb.PacksRegistry.get(pack_id), do: ~p"/packs/#{pack_id}", else: nil
  end

  # The diff block renders only when there's something to show — a re-advertised
  # hash whose action set moved vs the stored `trusted_manifest`. nil (dead
  # render, or a version with no manifest) and an all-empty diff render nothing.
  defp diff_has_changes?(%{added: [], removed: [], changed: []}), do: false
  defp diff_has_changes?(%{added: _, removed: _, changed: _}), do: true
  defp diff_has_changes?(nil), do: false
end
