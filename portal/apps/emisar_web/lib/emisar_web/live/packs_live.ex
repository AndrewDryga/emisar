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
    # "View contents" disclosure (see `inspect_pack`), keyed by version id —
    # trusted versions can be many, so we never eagerly look them all up.
    socket = assign(socket, :inspected_actions, %{})

    # Which "View contents" disclosures are open, keyed by version id. The rows
    # are a stream, so opening one re-inserts its group; without tracking the open
    # state server-side that re-render would strip the browser's native `<details
    # open>` and snap the disclosure shut on the first click.
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
        # current filter — only the rendered groups narrow.
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
        # Keep the sidebar badge in step after Trust/Reject on this page.
        |> assign(:pending_packs_count, pending)
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
          |> assign(:pending_packs_count, pending)
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

  defp pack_action_list(assigns) do
    ~H"""
    <ul class="mt-1 space-y-1">
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
  attr :pack_id, :string, required: true
  attr :inspected, :any, required: true, doc: "nil (unloaded), [] (none), or the action list"
  attr :matched, :any, default: nil, doc: "MapSet of matched action_ids, or nil when unfiltered"
  attr :open, :boolean, required: true

  # A trusted version's auditable contents. Unfiltered it's the full set behind a
  # "View contents" disclosure (one lazy query on first open — see `inspect_pack`).
  # While a filter is active it auto-opens and shows ONLY the actions that matched
  # (the pack's other actions are noise then), labelled with the count.
  defp trusted_disclosure(assigns) do
    assigns = assign(assigns, :shown, filtered_contents(assigns.inspected, assigns.matched))

    ~H"""
    <details open={@open} class="group">
      <summary
        phx-click="inspect_pack"
        phx-value-id={@version.id}
        phx-value-pack-id={@pack_id}
        phx-value-version={@version.version}
        class="flex cursor-pointer list-none items-center gap-1.5 text-[11px] text-zinc-500 hover:text-zinc-300"
      >
        <.icon name="hero-chevron-right" class="h-3 w-3 transition-transform group-open:rotate-90" />
        <span :if={@matched} class="text-brand-300">{match_count_label(@shown)}</span>
        <span :if={!@matched} class="group-open:hidden">View contents</span>
        <span :if={!@matched} class="hidden group-open:inline">Trusted contents</span>
      </summary>
      <div class="mt-2 pl-4">
        <p :if={is_nil(@inspected)} class="text-[11px] text-zinc-500">Loading…</p>
        <p :if={@inspected == []} class="text-[11px] text-zinc-500">
          No actions advertised for this version right now.
        </p>
        <.pack_action_list :if={@shown not in [nil, []]} actions={@shown} />
      </div>
    </details>
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
  # retirement here. An already-overridden row shows a muted, dated note instead
  # of the block + CTA — the override is deliberate and audited, so it doesn't
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
    <div
      :if={@retired? and not @overridden?}
      class="mt-2 rounded border border-rose-800/60 bg-rose-950/30 p-3"
    >
      <div class="flex items-center gap-1.5 text-[11px] font-semibold text-rose-100">
        <.icon name="hero-shield-exclamation" class="h-3.5 w-3.5" /> Retired by a newer release
      </div>
      <p class="mt-1 text-xs text-rose-100/90">
        A critical fix superseded this version. Dispatch is blocked for <code>{@pack_id}</code>
        v{@version.version} until you update the pack on the runner.
      </p>
      <p class="mt-1 font-mono text-[11px] text-rose-100/80">
        <span :if={@current_version} class="not-italic">→ v{@current_version}: </span>emisar pack install {@pack_id}
      </p>
      <%!-- Overriding a critical-fix retirement is a deliberate bypass — rose
           confirm, admin-only. It re-enables dispatch for this exact retired
           version; the audited context fn stays the server gate (IL-15).
           Bordered rose is the house destructive face — a FILLED rose pair
           deliberately doesn't exist in `button_face/2`. The version is
           already trusted, so the CTA names what it actually does — override
           the retirement — never "Trust". The quiet alternative (Revoke
           trust, in the row's meta column) silences this warning by refusing
           the version instead. --%>
      <.confirm_button
        :if={@can_manage}
        id={"override-#{@version.id}"}
        variant={:secondary}
        tone={:rose}
        size={:sm}
        class="mt-3"
        title={"Override the retirement of #{@pack_id} v#{@version.version}?"}
        confirm_label="Override retirement"
        on_confirm={JS.push("override_retirement", value: %{id: @version.id})}
      >
        <:body>
          This version was retired by a newer release. Overriding lets its actions run again
          despite the fix — do this only if you can't yet update the pack on the runner. The
          override is audited. To silence this warning without allowing dispatch, revoke the
          version's trust instead.
        </:body>
        Override retirement
      </.confirm_button>
    </div>
    <p
      :if={@retired? and @overridden?}
      class="mt-2 flex flex-wrap items-center gap-1.5 text-[11px] text-zinc-500"
    >
      <.icon name="hero-shield-check" class="h-3.5 w-3.5 text-zinc-600" />
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
        Each pack version is pinned to a trusted hash — a runner advertising different
        contents flips it to pending, and dispatch refuses it until you review.
        <.doc_link href="/docs/action-packs">Action pack docs</.doc_link>
      </.page_intro>

      <.callout
        :if={@pending_count > 0}
        tone={:amber}
        icon="hero-shield-exclamation"
        title={pending_review_title(@pending_count)}
        class="mt-4"
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
          @pack_count == 0 and (@name_filter != "" or @risk_filter != "") and not @load_error? and
            not @loading?
        }
        class="mt-6 text-sm text-zinc-500"
      >
        {no_match_copy(@name_filter, @risk_filter)}
      </p>

      <ul id="packs" phx-update="stream" class="mt-4">
        <%!-- CONTENT ON CANVAS (the runners-group grammar): each pack is a
             naked group — mono pack id + version count on a hairline — with
             its version rows below. The stream <li> wraps label + rows. --%>
        <li :for={{dom_id, pack} <- @streams.packs} id={dom_id} class="pt-5 first:pt-0">
          <header class="flex items-baseline gap-2 border-b border-zinc-800/70 pb-2">
            <h2 class="font-mono text-sm text-zinc-100">{pack.id}</h2>
            <span class="text-[11px] text-zinc-500">{version_count_label(pack.versions)}</span>
            <.status_badge
              :if={any_pending?(pack.versions)}
              status="pending"
              class="ml-2 text-[11px]"
            />
            <%!-- Whole-pack removal — every version at once. Derived state:
                 runners still advertising it re-insert it, which the modal
                 says plainly. --%>
            <.confirm_button
              :if={Catalog.subject_can_manage_packs?(@current_subject)}
              id={"delete-pack-#{pack.id}"}
              variant={:ghost}
              tone={:rose}
              size={:sm}
              class="ml-auto"
              title={"Delete #{pack.id}?"}
              confirm_label="Delete pack"
              on_confirm={JS.push("delete_pack", value: %{pack_id: pack.id})}
            >
              <:body>
                Removes every recorded version of <code>{pack.id}</code> — trust decisions
                and advertised actions — from the catalog. Runners still advertising it
                will re-insert it as a fresh trust decision. Audit history is kept.
              </:body>
              Delete pack
            </.confirm_button>
          </header>

          <ul class="divide-y divide-zinc-800/70">
            <li :for={v <- pack.versions} class="flex flex-col gap-3 py-2.5">
              <%!-- items-start: the one-line version/hash/registry sits at the TOP,
                   in register with the meta column's trust badge, instead of
                   floating in the vertical middle of its three lines (which read
                   as a too-tall row). --%>
              <div class="flex flex-wrap items-start gap-x-4 gap-y-1">
                <div class="flex min-w-0 flex-col gap-2">
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <span class="font-mono text-sm text-zinc-200">v{v.version}</span>
                    <%!-- A rejected never-trusted row has no trusted hash — show the
                         refused bytes it remembers instead of a bare dash. --%>
                    <span
                      class="truncate font-mono text-[11px] text-zinc-500"
                      title={v.hash || v.pending_hash}
                    >
                      sha256:{short_hash(v.hash || v.pending_hash)}
                    </span>
                    <%!-- If this exact trusted hash is a published pack version,
                         link out to its public registry page (opens in a new tab). --%>
                    <.registry_link version={v} />
                    <%!-- A trusted version a newer release RETIRED — a scannable
                         rose flag in the list; the full warning + admin override
                         renders below via `retired_notice`. --%>
                    <.chip :if={pack_version_retired?(v)} upcase tone={:rose}>Retired</.chip>
                  </div>
                  <%!-- "View contents" sits directly under the version line (in
                       the left column), NOT below the taller trust/timestamps
                       column — otherwise it floated at the row bottom, detached
                       from the version it belongs to. A trusted version's
                       contents stay auditable via this collapsed disclosure (one
                       lazy query on first open — see `inspect_pack`). --%>
                  <.trusted_disclosure
                    :if={v.trust_state == :trusted}
                    version={v}
                    pack_id={pack.id}
                    inspected={@inspected_actions[v.id]}
                    matched={@matched_actions[v.id]}
                    open={MapSet.member?(@open_versions, v.id)}
                  />
                  <.retired_notice
                    :if={v.trust_state == :trusted}
                    version={v}
                    pack_id={pack.id}
                    can_manage={Catalog.subject_can_manage_packs?(@current_subject)}
                  />
                  <%!-- A rejected version stays listed quietly — no alert, no
                       pending count — with Trust as the fix-admin-mistake path
                       (adopt the refused bytes, or restore revoked trust). --%>
                  <div
                    :if={v.trust_state == :rejected}
                    class="flex flex-wrap items-center gap-3"
                  >
                    <p class="text-xs text-zinc-500">
                      Rejected — dispatch refuses this version until you trust it.
                    </p>
                    <.confirm_button
                      :if={
                        Catalog.subject_can_manage_packs?(@current_subject) and
                          (v.pending_hash || v.hash) != nil
                      }
                      id={"trust-#{v.id}"}
                      variant={:secondary}
                      tone={:amber}
                      size={:sm}
                      title={"Trust #{pack.id} v#{v.version}?"}
                      confirm_label="Trust pack"
                      on_confirm={JS.push("trust", value: %{id: v.id})}
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
                      Trust
                    </.confirm_button>
                  </div>
                </div>
                <%!-- The meta column caps with the trust state (dot + word, not a
                     filled pill — the run/runner status grammar), then the
                     first→last chronology beneath it. Relative like every peer
                     list ("1d ago"); absolute rides the local_time hover. --%>
                <div class="ml-auto shrink-0 text-right text-xs text-zinc-500">
                  <div class="mb-1 flex justify-end">
                    <.status_badge status={to_string(v.trust_state)} />
                  </div>
                  <div :if={v.first_seen_at && v.first_seen_at != v.last_seen_at}>
                    first seen
                    <.local_time
                      id={"pack-version-first-#{v.id}"}
                      value={v.first_seen_at}
                      mode={:relative}
                      class="inline"
                    />
                  </div>
                  <div>
                    last seen
                    <.local_time
                      id={"pack-version-last-#{v.id}"}
                      value={v.last_seen_at}
                      mode={:relative}
                      class="text-zinc-300"
                    />
                  </div>
                  <%!-- Quiet per-version admin controls, kept next to the badge
                       they act on. Revoke trust is the undo for an accidental
                       Trust (BLOCKS dispatch — the safe direction — and is
                       reversible from the rejected row); Delete removes the
                       observation entirely (derived state: a runner still
                       advertising it re-inserts it). --%>
                  <div
                    :if={Catalog.subject_can_manage_packs?(@current_subject)}
                    class="mt-1.5 flex justify-end gap-1"
                  >
                    <.confirm_button
                      :if={v.trust_state == :trusted}
                      id={"revoke-#{v.id}"}
                      variant={:ghost}
                      tone={:neutral}
                      size={:sm}
                      title={"Revoke trust in #{pack.id} v#{v.version}?"}
                      confirm_label="Revoke trust"
                      on_confirm={JS.push("revoke_trust", value: %{id: v.id})}
                    >
                      <:body>
                        Dispatch refuses this version until it's trusted again. It stays
                        listed as rejected, so you can restore trust later.
                      </:body>
                      Revoke trust
                    </.confirm_button>
                    <.confirm_button
                      id={"delete-version-#{v.id}"}
                      variant={:ghost}
                      tone={:rose}
                      size={:sm}
                      title={"Delete #{pack.id} v#{v.version}?"}
                      confirm_label="Delete version"
                      on_confirm={JS.push("delete_version", value: %{id: v.id})}
                    >
                      <:body>
                        Removes this version and its advertised actions from the catalog.
                        If a runner still advertises it, it will reappear as a fresh trust
                        decision on its next connection or reload. Audit history is kept.
                      </:body>
                      Delete
                    </.confirm_button>
                  </div>
                </div>
              </div>

              <div
                :if={v.trust_state == :pending}
                class="rounded border border-amber-800/60 bg-amber-950/30 p-3"
              >
                <p :if={is_nil(v.hash)} class="text-xs text-amber-100/90">
                  A runner advertised <code>{pack.id}</code> v{v.version} — a
                  pack we don't ship a baseline for. Dispatch is blocked
                  until you trust its contents.
                </p>
                <p :if={not is_nil(v.hash)} class="text-xs text-amber-100/90">
                  A runner is advertising a different hash. Dispatch is blocked
                  for <code>{pack.id}</code> v{v.version} until you decide.
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
                  class="mt-2 text-[11px] leading-relaxed text-amber-100/80"
                >
                  <span class="font-semibold">{length(@advertising[v.id])}</span>
                  runner(s) advertise this — trusting unblocks dispatch on:
                  <.chip :for={r <- @advertising[v.id]} tone={:amber} mono class="ml-1">
                    {r.name}<span class="text-amber-400/70"> · {r.group}</span>
                  </.chip>
                </div>
                <%!-- What CHANGED since this hash was last trusted — diffed
                     against the action set snapshotted at that Trust
                     (`trusted_manifest`). Only shown when a manifest exists
                     (a re-advertised hash, not a first-time pending). An added
                     critical action or a low→critical escalation is the
                     headline danger an operator must see before re-trusting. --%>
                <div
                  :if={diff_has_changes?(@pack_diffs[v.id])}
                  class="mt-3 rounded border border-rose-800/60 bg-rose-950/30 p-3"
                >
                  <div class="flex items-center gap-1.5 text-[11px] font-semibold text-rose-100">
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
                      <span
                        :if={c.old_kind != c.new_kind}
                        class="flex-none text-zinc-500"
                      >
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
                  <div class="text-[11px] font-semibold text-amber-100/80">
                    Trusting authorizes {length(@pack_actions[v.id])} action(s):
                  </div>
                  <.pack_action_list actions={@pack_actions[v.id]} matched={@matched_actions[v.id]} />
                </div>
                <%!-- Trust/Reject mutate authorization state — owner/admin
                     only. The context gate (manage_catalog) is defense in
                     depth; hide the buttons for viewers/operators too so
                     they aren't offered an action that always denies. The
                     pending banner above stays visible to everyone — it
                     explains WHY dispatch is blocked. --%>
                <div
                  :if={Catalog.subject_can_manage_packs?(@current_subject)}
                  class="mt-3 flex flex-wrap gap-2"
                >
                  <%!-- Trust adopts code fleet-wide — a caution-approve (amber),
                       not a destruction, so the modal is amber, not rose. --%>
                  <.confirm_button
                    id={"trust-#{v.id}"}
                    variant={:primary}
                    tone={:amber}
                    size={:sm}
                    title={
                      if is_nil(v.hash),
                        do: "Trust #{pack.id} v#{v.version}?",
                        else: "Adopt the new hash for #{pack.id} v#{v.version}?"
                    }
                    confirm_label={if is_nil(v.hash), do: "Trust pack", else: "Trust new contents"}
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
                    {if is_nil(v.hash), do: "Trust pack", else: "Trust new contents"}
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
              </div>
            </li>
          </ul>
        </li>
      </ul>

      <%!-- Family-standard count footer (runners/runs/approvals/audit all
           carry one). --%>
      <p :if={@pack_count > 0} class="mt-4 text-xs text-zinc-600">
        {count_footer(@pack_count, @version_count)}
      </p>

      <%!-- Housekeeping: the catalog is derived state, so versions nothing
           advertises anymore only pile up. Same grammar as the approvals
           grant cap — the current setting rides in the header, the control
           expands below; Clean up now runs the sweep immediately. --%>
      <.collapsible_section id="packs-cleanup" title="Automatic cleanup" class="mt-8">
        <:summary>
          <span
            :if={is_nil(@current_account.settings.pack_unseen_retention_days)}
            class="flex items-center gap-1.5 text-xs"
          >
            <.status_dot tone={:neutral} size={:sm} />
            <span class="text-zinc-400">off</span>
            <span class="hidden text-zinc-500 sm:inline">
              — unseen pack versions are kept forever
            </span>
          </span>
          <span
            :if={@current_account.settings.pack_unseen_retention_days}
            class="text-xs text-zinc-400"
          >
            {retention_days_label(@current_account.settings.pack_unseen_retention_days)}
          </span>
        </:summary>

        <p class="mb-4 max-w-prose text-xs leading-relaxed text-zinc-400">
          Remove pack versions no runner has advertised for the selected period. A daily
          sweep deletes them — trust decisions included — and a runner advertising one
          again re-inserts it as a fresh trust decision.
        </p>

        <%= cond do %>
          <% not Accounts.subject_can_manage_account?(@current_subject) -> %>
            <p class="text-[11px] text-zinc-600">
              Owner/admin only — the current setting is shown above.
            </p>
          <% true -> %>
            <div class="flex flex-wrap items-center gap-3">
              <form phx-change="set_pack_retention" class="w-full max-w-xs">
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
                size={:sm}
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
            </div>
        <% end %>
      </.collapsible_section>

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
  defp short_hash(nil), do: "—"

  defp short_hash(hash) when is_binary(hash) do
    hash |> String.replace_prefix("sha256:", "") |> String.slice(0, 12)
  end

  attr :version, :map, required: true

  # A link out to the public pack-registry page — but ONLY when this trusted
  # version's hash is the currently-published one, so the link always lands on
  # exactly the version the operator trusted (a `computePackHash` match, the same
  # algorithm both sides). Renders nothing for a custom pack, or a version that
  # isn't what the registry currently ships.
  defp registry_link(assigns) do
    assigns = assign(assigns, :url, registry_pack_url(assigns.version))

    ~H"""
    <.link
      :if={@url}
      href={@url}
      target="_blank"
      rel="noopener"
      class="inline-flex shrink-0 items-center gap-0.5 text-[11px] font-medium text-brand-400 hover:text-brand-300"
      title="This exact version is published in emisar's public pack registry — opens in a new tab"
    >
      Registry <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
    </.link>
    """
  end

  defp registry_pack_url(%{trust_state: :trusted, pack_id: pack_id, hash: hash})
       when is_binary(pack_id) and is_binary(hash) do
    case EmisarWeb.PacksRegistry.get(pack_id) do
      %{content_hash: ^hash} -> ~p"/packs/#{pack_id}"
      _ -> nil
    end
  end

  defp registry_pack_url(_), do: nil

  # The diff block renders only when there's something to show — a re-advertised
  # hash whose action set moved vs the stored `trusted_manifest`. nil (dead
  # render, or a version with no manifest) and an all-empty diff render nothing.
  defp diff_has_changes?(%{added: [], removed: [], changed: []}), do: false
  defp diff_has_changes?(%{added: _, removed: _, changed: _}), do: true
  defp diff_has_changes?(nil), do: false
end
