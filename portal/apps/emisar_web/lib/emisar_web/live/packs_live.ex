defmodule EmisarWeb.PacksLive do
  @moduledoc """
  Pack inventory + trust state within the member's current pack access.

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
  alias Emisar.Catalog
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
    socket =
      socket
      |> ConfirmDialog.init()
      |> assign(:reject_target, nil)
      |> assign(:pending_pack_action, nil)

    # Two filters narrow the list. `name_filter` searches pack id AND action id
    # (so "postgres.activity" surfaces the postgres pack); `risk_filter` keeps
    # only packs advertising an action at that tier. Both are just form state
    # here — `Catalog.list_console_packs/2` owns the matching, the grouping, and
    # which actions each version matched.
    socket = assign(socket, :name_filter, "")
    socket = assign(socket, :risk_filter, "")
    socket = assign(socket, :matched_actions, %{})
    socket = assign(socket, :refresh_queued?, false)

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
       |> assign(:out_of_scope_pack_ids, [])
       |> assign(:version_facts, %{})
       |> assign(:group_cache, %{})
       |> assign(:can_manage_pack_retention?, false)
       |> stream(:packs, [])}
    end
  end

  # `subject_can_manage_pack_retention?/1` composes the permission with the
  # member's CURRENT pack access, so it costs a membership + access read. Resolve
  # it here rather than in the template, which re-runs on every render — and this
  # page re-renders on every search keystroke, every contents toggle, every trust
  # decision and every debounced catalog broadcast. Every load and every restream
  # lands here, so a scope narrowed mid-session still takes the control away.
  defp assign_pack_retention_access(socket) do
    assign(
      socket,
      :can_manage_pack_retention?,
      Catalog.subject_can_manage_pack_retention?(socket.assigns.current_subject)
    )
  end

  # Each stream entry is one pack group: `%{id: pack_id, versions: [...]}`.
  # The list is held by the stream (bounded socket memory), not a plain
  # assign. `reset: true` replaces the whole set on the connected mount and
  # after a mutation reload; targeted Trust/Reject updates a single group
  # via `stream_insert`/`stream_delete` (see `restream_pack/2`).
  defp load_packs(socket) do
    socket = assign_pack_retention_access(socket)

    case console_projection(socket) do
      {:ok, projection} ->
        # What the PREVIOUS filter opened on its own — read before the new match
        # set replaces it, since those auto-opens end with the filter that made
        # them while a hand-opened row outlives it.
        auto_opened = MapSet.new(Map.keys(socket.assigns.matched_actions))

        socket
        |> assign(:load_error?, false)
        |> assign(:pack_count, projection.pack_count)
        |> assign(:version_count, projection.version_count)
        # Pending counts + the sidebar badge reflect the member's current pack
        # access, not the current search filter — only the rendered groups
        # narrow. The badge counts every accessible decision (pending reviews
        # + retired-blocked); the page's
        # amber callout stays trust-review-only — retired versions carry
        # their own rose notice per row.
        |> assign(:pending_count, projection.pending_count)
        # Discovery only — the Catalog hands this list pack IDS and nothing
        # else, so the section below has no fact to render and no row to act on.
        |> assign(:out_of_scope_pack_ids, projection.out_of_scope_pack_ids)
        # Every lifecycle/trust judgment a row renders — trust + retirement
        # state, the pending decision's contents and diff, who advertises it,
        # and the remedy each state offers — comes from the Catalog, keyed by
        # pack-version id. The page words them; it never re-derives one.
        |> assign(:version_facts, projection.version_facts)
        |> assign(:matched_actions, projection.matched_action_ids)
        # A filter drives what's expanded: auto-open every version it matched
        # (via risk/action) and pre-load those action lists so they render at
        # once. A manual open (`inspect_pack`) survives a reload as long as its
        # version still renders — a live catalog change or a cleanup must not
        # collapse the contents an admin opened to review.
        |> update(:open_versions, &still_open_versions(&1, auto_opened, projection))
        |> update(:inspected_actions, &seed_action_lists(&1, projection))
        |> assign(:group_cache, group_cache(projection.groups))
        |> stream(:packs, projection.groups, reset: true)

      # A failed read must read as an error, not an empty inventory — "No packs
      # reported yet" would wrongly imply the fleet advertises nothing.
      :error ->
        socket
        |> assign(:load_error?, true)
        |> assign(:pack_count, 0)
        |> assign(:version_count, 0)
        |> assign(:pending_count, 0)
        |> assign(:out_of_scope_pack_ids, [])
        |> assign(:version_facts, %{})
        |> assign(:matched_actions, %{})
        |> assign(:group_cache, %{})
        |> stream(:packs, [], reset: true)
    end
  end

  # The last load's streamed groups, keyed by pack id — what a disclosure
  # toggle re-inserts (a stream child is static once pushed, so it must be
  # re-pushed to render newly-opened contents), WITHOUT re-reading the whole
  # projection: a toggle changes which assigns render, never the durable data,
  # and the re-read was a visible per-click delay on a real fleet. Decision
  # rows carry their trusted_manifest only for the load-time fact build; the
  # cache drops it so an open trust review doesn't pin megabytes to the
  # socket (IL-18).
  defp group_cache(groups) do
    Map.new(groups, fn group ->
      versions = Enum.map(group.versions, &%{&1 | trusted_manifest: nil})
      {group.id, %{group | versions: versions}}
    end)
  end

  @risk_tiers ~w(low medium high critical)
  defp normalize_risk(risk) when risk in @risk_tiers, do: risk
  defp normalize_risk(_), do: ""

  # A crafted `name[]=` posts a list, and `String.trim/1` crashes the socket on a
  # non-binary; total like normalize_risk/1 above.
  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(_), do: ""

  # Everything the page renders, from one Catalog read: the rows in current
  # pack access, the filtered groups, the actions each version advertises, and
  # the counts.
  # Rejected rows stay listed (quietly — no review alert) so an admin mistake is
  # visible and reversible: the row offers Trust to adopt the refused bytes or
  # restore revoked trust. Dispatch fails closed on them either way.
  defp console_projection(socket) do
    filters = %{name: socket.assigns.name_filter, risk: socket.assigns.risk_filter}

    case Catalog.list_console_packs(filters, socket.assigns.current_subject) do
      {:ok, projection} -> {:ok, projection}
      {:error, _} -> :error
    end
  end

  defp find_group(projection, pack_id), do: Enum.find(projection.groups, &(&1.id == pack_id))

  # Pre-load the action list for each matched version so its auto-opened
  # disclosure renders immediately (the projection already holds them) — merged
  # over whatever `inspect_pack` lazily cached.
  defp seed_action_lists(inspected, projection) do
    projection.groups
    |> Enum.flat_map(& &1.versions)
    |> Enum.filter(&Map.has_key?(projection.matched_action_ids, &1.id))
    |> Enum.reduce(inspected, fn version, acc ->
      Map.put(acc, version.id, version_actions(projection, version))
    end)
  end

  defp version_actions(projection, version),
    do: Map.get(projection.actions_by_pack_ref, {version.pack_id, version.version}, [])

  # The versions this load matches, plus the ones a person opened that it still
  # renders. A version the filter dropped or the catalog no longer holds has no
  # row left to expand, and the previous filter's own auto-opens go with it.
  defp still_open_versions(open_versions, auto_opened, projection) do
    rendered = projection.groups |> Enum.flat_map(& &1.versions) |> MapSet.new(& &1.id)

    open_versions
    |> MapSet.difference(auto_opened)
    |> MapSet.intersection(rendered)
    |> MapSet.union(MapSet.new(Map.keys(projection.matched_action_ids)))
  end

  defp pending_review_title(1), do: "1 pack version needs trust review."
  defp pending_review_title(count), do: "#{count} pack versions need trust review."

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:name_filter, normalize_name(params["name"]))
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

      {:error, {:descriptor_mismatch, action_id, runner_names}} ->
        {:noreply, put_flash(socket, :error, descriptor_mismatch_flash(action_id, runner_names))}

      {:error, :invalid_manifest} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Pack contents are invalid — fix the pack and have the runner advertise it again."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not trust pack — try again.")}
    end
  end

  # A crafted event that drops a required key would otherwise match no clause
  # and crash the socket, taking the page's unsaved state with it. Every
  # mutating handler on this page ends in this no-op.
  def handle_event("trust", _params, socket), do: {:noreply, socket}

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

  def handle_event("reject", _params, socket), do: {:noreply, socket}

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

  def handle_event("revoke_trust", _params, socket), do: {:noreply, socket}

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

  def handle_event("delete_version", _params, socket), do: {:noreply, socket}

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

  def handle_event("delete_pack", _params, socket), do: {:noreply, socket}

  # Catalog owns the cleanup contract — it re-checks manage_catalog plus current
  # unrestricted pack access (IL-15) and validates the raw period, so a crafted
  # event cannot arm the account-wide schedule past the caller's reach.
  def handle_event("set_pack_retention", %{"days" => _raw} = attrs, socket) do
    case Catalog.update_pack_retention_settings(
           socket.assigns.current_account,
           attrs,
           socket.assigns.current_subject
         ) do
      {:ok, account} ->
        days = account.settings.pack_unseen_retention_days

        {:noreply,
         socket
         |> assign(:current_account, account)
         |> put_flash(:info, retention_set_flash(days))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Pick a valid cleanup period.")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only owners and admins with full pack access can change this setting."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update automatic cleanup.")}
    end
  end

  def handle_event("set_pack_retention", _params, socket), do: {:noreply, socket}

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

  def handle_event("override_retirement", _params, socket), do: {:noreply, socket}

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

  def handle_event("open_reject", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("open_pack_action", %{"action" => action} = params, socket) do
    if Catalog.subject_can_manage_packs?(socket.assigns.current_subject) do
      case pending_pack_action(socket, action, params) do
        {:ok, pending} -> {:noreply, assign(socket, :pending_pack_action, pending)}
        :error -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_pack_action", _params, socket), do: {:noreply, socket}

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

  def handle_event("inspect_pack", _params, socket), do: {:noreply, socket}

  defp maybe_load_actions(socket, id, pack_id, version) do
    if Map.has_key?(socket.assigns.inspected_actions, id) do
      socket
    else
      # Three distinct values, because this list is what an admin reads before
      # trusting bytes: nil (not read yet), :error (the read failed), or the
      # actions. Collapsing the failure to [] said "advertises nothing" about a
      # version whose contents we never saw.
      actions =
        case Catalog.list_pack_actions(pack_id, version, socket.assigns.current_subject) do
          {:ok, actions} -> actions
          _ -> :error
        end

      update(socket, :inspected_actions, &Map.put(&1, id, actions))
    end
  end

  defp pending_pack_action(socket, "delete_pack", %{"pack-id" => pack_id}) do
    case Map.fetch(socket.assigns.group_cache, pack_id) do
      {:ok, _group} ->
        {:ok,
         %{
           action: "delete_pack",
           pack_id: pack_id,
           nonce: System.unique_integer([:positive])
         }}

      :error ->
        :error
    end
  end

  defp pending_pack_action(socket, action, %{"id" => id})
       when action in ["trust", "revoke_trust", "delete_version"] do
    with {pack_id, version} <- cached_version(socket.assigns.group_cache, id),
         fact when is_map(fact) <- socket.assigns.version_facts[id],
         true <- pack_action_available?(action, version, fact) do
      {:ok,
       %{
         action: action,
         pack_id: pack_id,
         version: version,
         fact: fact,
         nonce: System.unique_integer([:positive])
       }}
    else
      _other -> :error
    end
  end

  defp pending_pack_action(_socket, _action, _params), do: :error

  defp cached_version(group_cache, id) do
    Enum.find_value(group_cache, fn {pack_id, group} ->
      case Enum.find(group.versions, &(&1.id == id)) do
        nil -> nil
        version -> {pack_id, version}
      end
    end)
  end

  defp pack_action_available?("trust", version, fact),
    do: fact.trust_state == :rejected and (version.pending_hash || version.hash) != nil

  defp pack_action_available?("revoke_trust", _version, fact),
    do: fact.trust_state == :trusted

  defp pack_action_available?("delete_version", _version, _fact), do: true

  # A drift-reject reverts to the trusted bytes and the on-host mismatch stays
  # live, so it re-surfaces on the next advertisement; a never-trusted reject
  # sticks (the refused hash is remembered) until different bytes show up.
  defp reject_flash(%Catalog.PackVersion{trust_state: :trusted} = pack_version) do
    "Rejected drift on #{pack_version.pack_id} v#{pack_version.version}. The runner advertising the new hash will re-broadcast — if it's still set, this will re-surface."
  end

  defp reject_flash(%Catalog.PackVersion{} = pack_version) do
    "Rejected #{pack_version.pack_id} v#{pack_version.version}. It stays listed as rejected — a runner advertising different contents will re-open the review."
  end

  # The fleet disagrees about what the pending bytes contain — name the
  # runners so the operator can find the stale or hostile one. Trust stays
  # blocked (fail-closed) rather than letting one runner pick the manifest.
  defp descriptor_mismatch_flash(action_id, runner_names) do
    "#{disagreeing_runners(runner_names)} about what this version contains (action #{action_id}). Trust stays blocked until they advertise identical contents."
  end

  # The domain narrows the names to the runners this member reaches, so a
  # runner-restricted operator can be told the block and its cause without
  # being handed the name of a runner outside their fleet scope.
  defp disagreeing_runners([]), do: "Runners disagree"
  defp disagreeing_runners([first, second]), do: "Runners #{first} and #{second} disagree"
  defp disagreeing_runners(names), do: "Runners #{Enum.join(names, ", ")} disagree"

  defp retention_set_flash(nil), do: "Automatic cleanup turned off — pack versions are kept."

  defp retention_set_flash(days),
    do: "Automatic cleanup on — pack versions unseen for #{days_phrase(days)} are removed daily."

  defp cleanup_flash(1), do: "Removed 1 pack version no runner has advertised recently."

  defp cleanup_flash(count),
    do: "Removed #{count} pack versions no runner has advertised recently."

  # What a member who can't change the schedule reads in its place. Worded like
  # the select's own options, so both audiences read the setting the same way.
  defp pack_retention_value_label(nil), do: "Off"
  defp pack_retention_value_label(days), do: "After #{days_phrase(days)} unseen"

  defp days_phrase(1), do: "1 day"
  defp days_phrase(days), do: "#{days} days"

  defp pack_retention_options(current) do
    [
      %{
        value: "",
        label: "Off — keep unseen versions",
        selected: is_nil(current),
        disabled: false
      },
      %{value: "1", label: "After 1 day unseen", selected: current == 1, disabled: false},
      %{value: "7", label: "After 7 days unseen", selected: current == 7, disabled: false},
      %{value: "14", label: "After 14 days unseen", selected: current == 14, disabled: false},
      %{value: "30", label: "After 30 days unseen", selected: current == 30, disabled: false},
      %{value: "60", label: "After 60 days unseen", selected: current == 60, disabled: false},
      %{value: "90", label: "After 90 days unseen", selected: current == 90, disabled: false}
    ]
  end

  # Re-render one pack group's stream item against the current assigns (a
  # stream child is static once pushed, so the just-loaded `inspected_actions`
  # only appears after a re-insert). The group comes from the last load's
  # cache: a toggle changes nothing durable, so the group and the
  # `version_facts` already in assigns are one consistent snapshot — no read.
  defp reinsert_pack_group(socket, pack_id) do
    case Map.fetch(socket.assigns.group_cache, pack_id) do
      {:ok, group} -> stream_insert(socket, :packs, group)
      :error -> socket
    end
  end

  # After a trust decision, recompute just the affected pack group and update
  # the stream in place: `stream_delete` if no displayable version of the pack
  # remains (the name/risk filter can drop the group), otherwise
  # `stream_insert` the regrouped versions. The `pending_count` (and sidebar
  # badge) are recomputed from the full set.
  defp restream_pack(socket, pack_id) do
    socket = assign_pack_retention_access(socket)

    case console_projection(socket) do
      {:ok, projection} ->
        socket =
          socket
          |> assign(:pack_count, projection.pack_count)
          |> assign(:version_count, projection.version_count)
          |> assign(:pending_count, projection.pending_count)
          |> assign(:version_facts, projection.version_facts)
          |> assign(:matched_actions, projection.matched_action_ids)
          |> assign(:group_cache, group_cache(projection.groups))
          |> update(:inspected_actions, &seed_action_lists(&1, projection))

        case find_group(projection, pack_id) do
          nil -> stream_delete(socket, :packs, %{id: pack_id})
          group -> stream_insert(socket, :packs, group)
        end

      # The mutation committed but the re-read failed — surface the error rather
      # than leaving a stale count; the existing stream rows stay until reload.
      :error ->
        assign(socket, :load_error?, true)
    end
  end

  # The durable catalog changed under us — a runner advertised something new, a
  # peer trusted/rejected/deleted a version, or the retention sweep ran. The
  # pack-trust broadcast is the source of truth; connection Presence does not
  # change which durable runner advertisements the page renders.
  def handle_info({:pack_trust_changed, _account_id}, socket),
    do: {:noreply, queue_refresh(socket)}

  def handle_info(:refresh_packs, socket),
    do: {:noreply, socket |> assign(:refresh_queued?, false) |> load_packs()}

  # No-op for the remaining broadcasts the on_mount hooks forward (approvals
  # cues stay with the nav).
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp queue_refresh(%{assigns: %{refresh_queued?: true}} = socket), do: socket

  defp queue_refresh(socket) do
    Process.send_after(self(), :refresh_packs, 200)
    assign(socket, :refresh_queued?, true)
  end

  # The action + risk rows a pack version contains — shared by the pending
  # "Trust new contents" panel and the trusted "View contents" disclosure so
  # both render the identical list. `action_id`/`title` are runner-advertised
  # (attacker-influenced); they render through escaped HEEx, never `raw/1`.
  attr :actions, :list, required: true
  attr :id, :string, required: true, doc: "version-scoped prefix for the per-row risk tooltip ids"
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
        <%!-- One pill per row, all in the leading column — a fixed track keeps
             the action ids beside them on one left edge. --%>
        <.risk_pill id={"#{@id}-#{action.action_id}-risk"} risk={action.risk} variant={:track} />
        <span class={[
          "font-mono",
          (matched?(@matched, action.action_id) && "text-brand-200") || "text-zinc-300"
        ]}>
          {action.action_id}
        </span>
        <span :if={action.title} class="truncate text-zinc-400">{action.title}</span>
      </li>
    </ul>
    """
  end

  defp matched?(nil, _action_id), do: false
  defp matched?(matched, action_id), do: MapSet.member?(matched, action_id)

  attr :version, :map, required: true

  attr :inspected, :any,
    required: true,
    doc: "nil (unloaded), :error (read failed), [] (none), or the action list"

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
      <p data-role="pack-version-facts" class="text-[11px] text-zinc-400">
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
      <p :if={is_nil(@inspected)} class="mt-2 text-[11px] text-zinc-400">Loading…</p>
      <p :if={@inspected == :error} class="mt-2 text-[11px] text-rose-300">
        Couldn't load this version's actions — a read error, not an empty pack. Refresh before
        deciding on its trust.
      </p>
      <p :if={@inspected == []} class="mt-2 text-[11px] text-zinc-400">
        No actions advertised for this version right now.
      </p>
      <p
        :if={not is_nil(@matched) and @shown not in [nil, :error, []]}
        data-role="pack-action-match-summary"
        class="mt-2 text-[11px] font-medium text-brand-300"
      >
        {match_count_label(@shown)}
      </p>
      <.pack_action_list
        :if={@shown not in [nil, :error, []]}
        id={"pack-version-#{@version.id}-contents"}
        actions={@shown}
        class={if @matched, do: "mt-1.5", else: "mt-2"}
      />
    </div>
    """
  end

  # The contents a disclosure renders: everything when unfiltered, only the
  # matched actions when a filter is active. nil (still loading) and :error (the
  # read failed) pass through — neither is a list to filter.
  defp filtered_contents(nil, _matched), do: nil
  defp filtered_contents(:error, _matched), do: :error
  defp filtered_contents(actions, nil), do: actions

  defp filtered_contents(actions, matched),
    do: Enum.filter(actions, &matched?(matched, &1.action_id))

  defp match_count_label(shown) do
    n = length(shown || [])
    "#{n} matching #{if n == 1, do: "action", else: "actions"}"
  end

  attr :version, :map, required: true
  attr :pack_id, :string, required: true
  attr :fact, :map, required: true
  attr :can_manage, :boolean, required: true

  # A trusted version the shipped catalog RETIRED — a newer release marked every
  # version below a watermark unsafe (a critical fix). The Catalog picks the ONE
  # remedy that fits (`retirement_remedy`); this only words it. Runners still on
  # it → update them (or, only if you truly can't yet, override the retirement).
  # None, from a complete fleet read → it's dead weight the fix already routed
  # around, so just remove it. None, from a PARTIAL read → we can't claim nobody
  # is on it, so neither removal nor override is offered. Rendered as the shared
  # icon-capped rose spine — the ONE house face for an operational alert. An
  # already-overridden row shows a muted, dated note instead. Renders nothing for
  # a version that isn't retired.
  defp retired_notice(assigns) do
    ~H"""
    <.event_block
      :if={@fact.retirement_blocked?}
      icon="trust.untrusted"
      tone={:rose}
      title="Retired by a newer release"
      class="mt-3 pl-8"
    >
      <:body>
        <span :if={@fact.retirement_remedy == :update_or_override}>
          A critical fix superseded this version. Dispatch is blocked for <code>{@pack_id}</code>
          v{@version.version} until you update the runners still on it.
        </span>
        <span :if={@fact.retirement_remedy == :remove}>
          A critical fix superseded this version, and no runner is on it anymore. Remove it to
          clear it from the catalog — there's nothing to update.
        </span>
        <span :if={@fact.retirement_remedy == :resolve_advertisers}>
          A critical fix superseded this version. This account has more runners than this page
          reads, so we can't tell whether any is still on it — update your runners to clear it.
        </span>
      </:body>
      <%!-- Updating is the fix in every state that still shows this block: with
           hosts on it, and with a fleet we couldn't read to the end. --%>
      <.install_command
        :if={@fact.retirement_remedy != :remove}
        id={"retired-cmd-#{@version.id}"}
        pack_id={@pack_id}
        successor={@fact.retirement_successor}
        hash={@fact.retirement_successor_hash}
      />
      <%!-- Name which hosts, so the operator knows where to go. A partial fleet
           read can only name a floor, so it says so rather than implying the
           list is the whole of it. --%>
      <div
        :if={@fact.advertising.runners != []}
        class="mt-3 text-[11px] leading-relaxed text-zinc-400"
      >
        <p>
          <span class="font-semibold text-zinc-300">{advertiser_count(@fact.advertising)}</span>
          {advertiser_noun(@fact.advertising)} still on this version:
        </p>
        <div class="mt-2 flex flex-wrap gap-1.5">
          <.identity_tag
            :for={runner <- @fact.advertising.runners}
            category={runner.group}
            value={runner.name}
          />
        </div>
        <p :if={@fact.advertising.coverage == :partial} class="mt-2">
          More runners than this page reads — others may be on it too.
        </p>
      </div>
      <div :if={@can_manage} class="mt-3 flex flex-wrap gap-2">
        <%!-- Runners on it, and you genuinely can't update yet: override to let its
             actions run despite the fix. Deliberate bypass — rose confirm, admin-
             only, audited (the context fn stays the server gate, IL-15). Gone once
             no runner is on it: nothing to keep running, and re-enabling a retired
             version for a future runner is the opposite of the goal. --%>
        <.confirm_button
          :if={@fact.retirement_remedy == :update_or_override}
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
            override is audited. To silence this without allowing dispatch, remove the version.
          </:body>
          Override retirement
        </.confirm_button>
        <%!-- No runner on it → removal is the clean, durable resolution (nothing
             re-advertises it), so it's the recommended action here — the house
             destructive face (bordered rose, never a filled "go" green). With
             runners it's futile (a runner re-inserts it), so it's dropped for
             update/override; with a partial fleet read we can't promise it's
             unused, so it's dropped there too. --%>
        <.button
          :if={@fact.retirement_remedy == :remove}
          variant={:secondary}
          tone={:rose}
          size={:sm}
          type="button"
          phx-click={open_confirm("delete-version-#{@version.id}")}
        >
          Remove version
        </.button>
      </div>
    </.event_block>
    <p
      :if={@fact.retired? and @fact.override}
      class="mt-2 flex flex-wrap items-center gap-1.5 pl-8 text-[11px] text-zinc-400"
    >
      <.icon name="trust.declared" class="h-3.5 w-3.5 text-zinc-500" />
      Retired by a newer release — overridden by {@fact.override.actor_label || "an admin"}
      <.local_time
        id={"pack-version-override-#{@version.id}"}
        value={@fact.override.at}
        mode={:relative}
        class="inline"
      />
    </p>
    """
  end

  # How many runners advertise a version, in the operator's words. A COMPLETE
  # fleet read states the exact count; a PARTIAL one can only state a floor —
  # and with nothing found it cannot claim the version is unused at all.
  defp advertiser_count(%{coverage: :partial, runners: []}), do: "An unknown number of"

  defp advertiser_count(%{coverage: :partial, runners: runners}),
    do: "At least #{length(runners)}"

  defp advertiser_count(%{runners: runners}), do: length(runners)

  # The noun agrees with the count beside it, floor included ("At least 1
  # runner"), so no reader has to parse a "(s)".
  defp advertiser_noun(%{runners: [_]}), do: "runner"
  defp advertiser_noun(_advertising), do: "runners"

  # The remedy a retired version awaiting review actually has, which depends on
  # who is still on it — the same three states the trusted row's
  # `retirement_remedy` distinguishes, worded for a row whose buttons are Trust
  # anyway / Reject. Hosts we can see → update the pack there (they are named
  # below). A complete fleet read with none → nothing to update, and Reject is
  # what clears the row. A partial read → we cannot claim nobody is on it, so
  # the sentence stays conditional rather than asserting either way.
  defp pending_retired_remedy(%{runners: [_ | _]}),
    do: "Update the pack on the runners still on it to clear this."

  defp pending_retired_remedy(%{coverage: :complete}),
    do: "No runner advertises it now, so there is nothing to update — reject it to clear this."

  defp pending_retired_remedy(_advertising),
    do: "Update the pack on any runner still on it to clear this."

  # Nobody is on it and we read the whole fleet, so an install command would
  # offer a fix for a problem that no longer exists; Reject is the action.
  defp pending_retired_update?(%{runners: [], coverage: :complete}), do: false
  defp pending_retired_update?(_advertising), do: true

  attr :version, :map, required: true
  attr :pack_id, :string, required: true
  attr :fact, :map, required: true
  attr :matched, :any, default: nil, doc: "MapSet of matched action_ids, or nil when unfiltered"
  attr :can_manage, :boolean, required: true

  # The one state that earns real weight: a live trust decision, on the shared
  # spine like every operational alert — what changed, who it unblocks, and the
  # decision buttons inside one contained unit. A pending version that sits below
  # a shipped pack's retirement watermark is a KNOWN pack whose bytes a security
  # fix superseded, NOT an unknown one to trust — it wears the rose retired face
  # and leads with the upgrade, keeping trust a labelled escape hatch.
  defp pending_notice(assigns) do
    ~H"""
    <.event_block
      icon="trust.untrusted"
      tone={(@fact.retirement_blocked? && :rose) || :amber}
      title={(@fact.retirement_blocked? && "Retired by a newer release") || "Pending trust review"}
      class="mt-3 pl-8"
    >
      <:body>
        <span :if={@fact.retirement_blocked?}>
          <code>{@pack_id}</code> v{@version.version} was retired by a newer release — a
          security fix superseded it. {pending_retired_remedy(@fact.advertising)}
        </span>
        <span :if={not @fact.retirement_blocked? and is_nil(@version.hash)}>
          A runner advertised <code>{@pack_id}</code> v{@version.version} —
          a pack we don't ship a baseline for. Dispatch is blocked until
          you trust its contents.
        </span>
        <span :if={not @fact.retirement_blocked? and not is_nil(@version.hash)}>
          A runner is advertising a different hash. Dispatch is blocked for <code>{@pack_id}</code>
          v{@version.version} until you decide.
        </span>
      </:body>
      <.install_command
        :if={@fact.retirement_blocked? and pending_retired_update?(@fact.advertising)}
        id={"upgrade-cmd-#{@version.id}"}
        pack_id={@pack_id}
        successor={@fact.retirement_successor}
        hash={@fact.retirement_successor_hash}
      />
      <%!-- The two-hash comparison earns its rows only on a real drift —
           a trusted hash to diff the advertised one against. A first-seen
           retired version was never trusted, so drop the empty
           "trusted: (none yet)" and show just the bytes on the runner. A
           hash is a plain identifier, so it reads neutral. --%>
      <dl
        :if={not is_nil(@version.hash)}
        class="mt-3 grid grid-cols-[max-content,1fr] gap-x-3 gap-y-1 text-[11px]"
      >
        <.kv layout={:grid} label="trusted:">{@version.hash}</.kv>
        <.kv layout={:grid} label="advertising:">
          <span class="text-zinc-300">{@version.pending_hash || "—"}</span>
        </.kv>
      </dl>
      <%!-- Only a trust decision needs the bytes shown: an unknown pack you're
           about to trust. A retired version's fix-it command already pins the
           target hash (--hash), so its old bytes are noise — omit them. --%>
      <p
        :if={is_nil(@version.hash) and not @fact.retirement_blocked?}
        class="mt-3 flex flex-wrap items-baseline gap-x-2 text-[11px] text-zinc-400"
      >
        on the runner:
        <span class="break-all font-mono text-zinc-300">{@version.pending_hash || "—"}</span>
      </p>
      <%!-- Blast radius — which hosts this trust click unblocks. One canary box
           vs the whole fleet is the difference between a safe and a scary Trust.
           A fleet we couldn't read to the end says so: a short list is a floor,
           and an empty one is not proof that nobody is on it. --%>
      <div
        :if={@fact.advertising.runners != []}
        class="mt-3 text-[11px] leading-relaxed text-zinc-400"
      >
        <p>
          <span class="font-semibold text-zinc-300">
            {advertiser_count(@fact.advertising)}
          </span>
          <span :if={@fact.retirement_blocked?}>
            {advertiser_noun(@fact.advertising)} still on this retired version — update the pack on:
          </span>
          <span :if={not @fact.retirement_blocked?}>
            {advertiser_noun(@fact.advertising)} still advertising this — trusting unblocks dispatch on:
          </span>
        </p>
        <%!-- A neutral two-tone tag per runner — the group (muted, left)
             then the runner name (brighter, right), split by a divider.
             WHICH hosts is informative, not a warning: the retired/pending
             context above carries the concern, so the tag stays zinc, never
             amber. The tags wrap in a flex container (a fleet can advertise
             dozens, and a comprehension renders them with no whitespace
             between — an inline run would overflow the page). --%>
        <div class="mt-2 flex flex-wrap gap-1.5">
          <.identity_tag
            :for={runner <- @fact.advertising.runners}
            category={runner.group}
            value={runner.name}
          />
        </div>
        <p :if={@fact.advertising.coverage == :partial} class="mt-2">
          More runners than this page reads — others may advertise it too.
        </p>
      </div>
      <p
        :if={@fact.advertising.coverage == :partial and @fact.advertising.runners == []}
        class="mt-3 text-[11px] leading-relaxed text-zinc-400"
      >
        This account has more runners than this page reads, so we can't say how many advertise
        this version.
      </p>
      <%!-- What CHANGED since this hash was last trusted — diffed
           against the action set snapshotted at that Trust
           (`trusted_manifest`). Only shown when a manifest exists
           (a re-advertised hash, not a first-time pending). An added
           critical action or a low→critical escalation is the
           headline danger an operator must see before re-trusting. --%>
      <div :if={diff_has_changes?(@fact.action_changes)} class="mt-3">
        <div class="flex items-center gap-1.5 text-[11px] font-semibold text-rose-300">
          <.icon name="action.sync" class="h-3.5 w-3.5" /> Changes since you last trusted this pack:
        </div>
        <ul class="mt-2 space-y-1">
          <li :for={a <- @fact.action_changes.added} class="flex items-center gap-2 text-[11px]">
            <span class="w-12 flex-none font-semibold uppercase tracking-wide text-rose-300">
              + added
            </span>
            <%!-- Added / changed / removed rows put their verdicts in one
                 column after the w-12 marker, so every pill takes the track. --%>
            <.risk_pill
              id={"pack-version-#{@version.id}-added-#{a.action_id}-risk"}
              risk={a.risk}
              variant={:track}
            />
            <span class="truncate font-mono text-zinc-200">{a.action_id}</span>
          </li>
          <li :for={c <- @fact.action_changes.changed} class="flex items-center gap-2 text-[11px]">
            <span class={[
              "w-12 flex-none font-semibold uppercase tracking-wide",
              if(c.risk_escalated?, do: "text-rose-300", else: "text-amber-300")
            ]}>
              ~ changed
            </span>
            <span class="flex items-center gap-1">
              <.risk_pill
                id={"pack-version-#{@version.id}-changed-#{c.action_id}-old-risk"}
                risk={c.old_risk}
                variant={:track}
                class="opacity-60"
              />
              <.icon name="diagram.flow_right" class="h-3 w-3 text-zinc-500" />
              <.risk_pill
                id={"pack-version-#{@version.id}-changed-#{c.action_id}-new-risk"}
                risk={c.new_risk}
                variant={:track}
              />
            </span>
            <span class="truncate font-mono text-zinc-200">{c.action_id}</span>
            <span :if={c.old_kind != c.new_kind} class="flex-none text-zinc-500">
              {c.old_kind} → {c.new_kind}
            </span>
            <span :if={other_changed_fields(c) != []} class="flex-none text-zinc-500">
              {Enum.join(other_changed_fields(c), ", ")}
            </span>
          </li>
          <li
            :for={r <- @fact.action_changes.removed}
            class="flex items-center gap-2 text-[11px] text-zinc-400"
          >
            <span class="w-12 flex-none font-semibold uppercase tracking-wide">
              − removed
            </span>
            <.risk_pill
              id={"pack-version-#{@version.id}-removed-#{r.action_id}-risk"}
              risk={r.risk}
              variant={:track}
              class="opacity-50"
            />
            <span class="truncate font-mono line-through">{r.action_id}</span>
          </li>
        </ul>
      </div>
      <%!-- What trusting this authorizes — the FULL action set advertised under
           the exact hash awaiting review (the diff above shows only what moved),
           so "Trust new contents" isn't a blind click. --%>
      <div :if={@fact.actions != []} class="mt-3">
        <div class="text-[11px] font-semibold text-zinc-300">
          Trusting authorizes {length(@fact.actions)} action(s):
        </div>
        <.pack_action_list
          id={"pack-version-#{@version.id}-pending"}
          actions={@fact.actions}
          matched={@matched}
          class="mt-1"
        />
      </div>
      <%!-- Trust/Reject mutate authorization state — owner/admin
           only. The context gate (manage_catalog) is defense in
           depth; hide the buttons for viewers/operators too so
           they aren't offered an action that always denies. The
           pending spine above stays visible to everyone — it
           explains WHY dispatch is blocked. --%>
      <div :if={@can_manage} class="mt-3 flex flex-wrap gap-2">
        <%!-- Trust adopts code fleet-wide — a caution-approve (amber),
             not a destruction, so the modal is amber. On a RETIRED
             version trust is the wrong default (upgrade the runner
             instead), so it recedes to a rose "Trust anyway" escape
             hatch — the confirm body spells out the override. --%>
        <.confirm_button
          id={"trust-#{@version.id}"}
          variant={(@fact.retirement_blocked? && :secondary) || :primary}
          tone={(@fact.retirement_blocked? && :rose) || :amber}
          size={:sm}
          title={trust_confirm_title(@fact, @pack_id, @version)}
          confirm_label={trust_confirm_label(@fact, @version)}
          on_confirm={JS.push("trust", value: %{id: @version.id})}
        >
          <:body>
            Cloud will allow its actions to run on {advertiser_count(@fact.advertising)} advertising {advertiser_noun(
              @fact.advertising
            )}. Trusting adopts this exact code fleet-wide.
            <span :if={@fact.retired?} class="text-rose-300">
              This version was retired by a newer release — trusting it also overrides
              that retirement, so its actions run despite the fix.
            </span>
          </:body>
          {trust_confirm_label(@fact, @version)}
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
              value: %{id: @version.id, pack_id: @pack_id, version: @version.version}
            )
            |> show_confirm_dialog("reject-pack")
          }
        >
          Reject
        </.button>
      </div>
    </.event_block>
    """
  end

  # Trusting a retired version is an override, not an adoption — say so; a
  # never-trusted pack is a plain trust; anything else adopts a new hash.
  defp trust_confirm_title(%{retirement_blocked?: true}, pack_id, version),
    do: "Trust the retired #{pack_id} v#{version.version} anyway?"

  defp trust_confirm_title(_fact, pack_id, %{hash: nil} = version),
    do: "Trust #{pack_id} v#{version.version}?"

  defp trust_confirm_title(_fact, pack_id, version),
    do: "Adopt the new hash for #{pack_id} v#{version.version}?"

  defp trust_confirm_label(%{retirement_blocked?: true}, _version), do: "Trust anyway"
  defp trust_confirm_label(_fact, %{hash: nil}), do: "Trust pack"
  defp trust_confirm_label(_fact, _version), do: "Trust new contents"

  attr :pack_id, :string, required: true
  attr :update, :map, default: nil, doc: "the Catalog's pack-level %{version, hash}, or nil"

  # ONE pack-level "update available" nudge, said once per pack — the Catalog
  # decides whether the pack has one (a trusted, non-retired version below the
  # shipped current, with that current version not already installed beside it),
  # so it is never repeated on each stale version. A convenience, never a
  # warning: a security fix RETIRES a version (packs retire only on
  # security/critical fixes), so an outdated-but-not-retired version is safe by
  # construction and still dispatches — the weakest, quietest tier, a neutral
  # spine below the version rows.
  defp update_available_note(assigns) do
    ~H"""
    <%!-- The same icon-capped spine as a row's retired block, but NEUTRAL and
         pack-level: a newer version shipped, yet what's installed still runs and
         dispatches — a heads-up, not a warning, so it never wears rose. The glyph
         is the DOWNLOAD metaphor the runner surfaces use for the same act
         (§7.49); an up-arrow pointed the way the operator does not go. --%>
    <.event_block
      :if={@update}
      icon="state.update_available"
      tone={:neutral}
      title="Update available"
      class="mt-4"
    >
      <:body>
        v{@update.version} has shipped. Your installed versions still run and dispatch fine — update your runners when you can.
      </:body>
      <.install_command
        id={"update-cmd-#{@pack_id}"}
        pack_id={@pack_id}
        successor={@update.version}
        hash={@update.hash}
      />
    </.event_block>
    """
  end

  # The "fix it" command as a compact, copyable row — never a code panel (the
  # one-line-copy-value rule): the label names the target version, the row clips
  # the command mono at text-xs (a step below the block title, not above it), and
  # Copy lifts the complete value.
  attr :id, :string, required: true
  attr :pack_id, :string, required: true
  attr :successor, :string, default: nil
  attr :hash, :string, default: nil

  defp install_command(assigns) do
    ~H"""
    <div class="mt-3">
      <p class="text-xs text-zinc-400">
        <span :if={@successor}>
          Update the pack to <span class="font-medium text-zinc-200">v{@successor}</span>
        </span>
        <span :if={is_nil(@successor)}>Install on the runner</span>
      </p>
      <.code_line id={@id} value={install_command_string(@pack_id, @hash)} prompt class="mt-1.5" />
    </div>
    """
  end

  # The `--hash` pin (the shipped bytes) makes the install integrity-checked and
  # is the only place the hash needs to appear — no separate hash readout below.
  defp install_command_string(pack_id, nil), do: "emisar pack install #{pack_id}"

  defp install_command_string(pack_id, hash),
    do: "emisar pack install #{pack_id} --hash #{hash}"

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:packs}
      width={:table}
    >
      <:title>Packs</:title>

      <.page_intro>
        A pack is a versioned bundle of <span class="text-zinc-200">vetted actions</span>
        a runner may execute — the runner advertises what it has installed, and this
        page shows the trust ledger for packs in your access.
        <.doc_link href={~p"/docs/action-packs"}>Action pack docs</.doc_link>
      </.page_intro>

      <div class="mt-2 grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
        <div class="min-w-0">
          <.callout
            :if={@pending_count > 0}
            tone={:amber}
            icon="trust.untrusted"
            title={pending_review_title(@pending_count)}
            class="mt-2"
          >
            Dispatch against these versions is blocked until an admin reviews the new hash.
          </.callout>

          <.loading_state :if={@loading?} />

          <.empty_state
            :if={@load_error? and not @loading?}
            tone={:danger}
            icon="state.warning"
            title="Couldn't load packs"
            class="mt-8"
          >
            This is a load error, not an empty inventory — your runners may well be advertising
            packs. Refresh the page; if it persists, your access to this account may have changed.
          </.empty_state>

          <%!-- "Nothing here yet" is only true when the WORKSPACE has no packs.
               A member whose pack access reaches none of them is told that by
               the discovery section below, which names the ones that exist —
               this copy would send them to connect a runner that is already
               connected. --%>
          <.empty_state
            :if={
              @pack_count == 0 and @out_of_scope_pack_ids == [] and @name_filter == "" and
                @risk_filter == "" and not @load_error? and not @loading?
            }
            icon="product.pack"
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
            id="pack-filter-form"
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
              <.select
                name="risk"
                size={:filter}
                active?={@risk_filter != ""}
                prompt="All risk"
                prompt_selected={@risk_filter == ""}
                options={
                  Enum.map(~w(low medium high critical), fn tier ->
                    %{
                      value: tier,
                      label: String.capitalize(tier),
                      disabled: false,
                      selected: @risk_filter == tier
                    }
                  end)
                }
              />
            </label>
          </form>

          <%!-- Filter-empty ≠ account-empty: a quiet line, the filter stays live. --%>
          <p
            :if={
              @pack_count == 0 and (@name_filter != "" or @risk_filter != "") and
                not @load_error? and not @loading?
            }
            class="mt-6 text-sm text-zinc-400"
          >
            {no_match_copy(@name_filter, @risk_filter)}
          </p>

          <ul
            id="packs"
            phx-update="stream"
            class={["space-y-10", @pack_count > 0 && "mt-10"]}
          >
            <%!-- CONTENT ON CANVAS (the runners-group grammar): each pack is a
                 naked group — mono pack id + version count on a hairline — with
                 its version rows below. The stream <li> wraps label + rows. The
                 1-2 rare admin verbs per row are small bordered buttons (the
                 LLM-agents grammar — a menu earns its click only at 3+ verbs).
                 One selected-row dialog is rendered lazily below. --%>
            <li :for={{dom_id, pack} <- @streams.packs} id={dom_id}>
              <header class="flex flex-wrap items-baseline gap-x-2.5 gap-y-1 border-b border-zinc-800/70 pb-2.5">
                <h2 class="font-mono text-base font-semibold text-zinc-100">{pack.id}</h2>
                <span class="text-[11px] text-zinc-400">{version_count_label(pack.versions)}</span>
                <.registry_link pack_id={pack.id} />
                <%!-- No pack-level status here: each version row carries its own
                     trust state, so a rolled-up "pending" on the header just
                     double-labels the same fact and reads as a second, conflicting
                     status. --%>
                <.button
                  :if={Catalog.subject_can_manage_packs?(@current_subject)}
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  type="button"
                  class="ml-auto self-center"
                  phx-click="open_pack_action"
                  phx-value-action="delete_pack"
                  phx-value-pack-id={pack.id}
                >
                  Delete pack
                </.button>
              </header>

              <ul class="divide-y divide-zinc-800/70">
                <li :for={v <- pack.versions} class="py-2.5">
                  <%!-- ONE line per version: chevron (contents) · identity ·
                       state — bound left, so the eye never crosses a gulf to
                       pair them — then last-seen + the row menu at the end. --%>
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <button
                      :if={@version_facts[v.id].trust_state == :trusted}
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
                        name="action.disclose"
                        class={"h-3.5 w-3.5 transition-transform #{if MapSet.member?(@open_versions, v.id), do: "rotate-0", else: "-rotate-90"}"}
                      />
                    </button>
                    <span
                      :if={@version_facts[v.id].trust_state != :trusted}
                      class="w-5 shrink-0"
                      aria-hidden="true"
                    ></span>
                    <span class="font-mono text-sm text-zinc-200">v{v.version}</span>
                    <%!-- ONE row-state marker in ONE grammar (dot + word), BESIDE
                         the identity it qualifies — the page's primary fact, so
                         nothing wedges between them and the status column stays
                         steady to scan. A blocked row reads "retired" INSTEAD of
                         "trusted" (side by side they contradicted); an overridden
                         row is trusted again (the note below says why). --%>
                    <.status_badge status={@version_facts[v.id].display_state} class="text-xs" />
                    <%!-- The hash said nothing at browse altitude — the full hash
                         lives in the contents expansion; last-seen trails like
                         timestamps everywhere else in the console. --%>
                    <span class="text-[11px] text-zinc-400">
                      last seen
                      <.local_time
                        id={"pack-version-last-#{v.id}"}
                        value={v.last_seen_at}
                        mode={:relative}
                        class="text-zinc-400"
                      />
                    </span>
                    <%!-- A manager's row carries three verbs (read + one trust verb +
                         Delete) — the labeled-menu threshold (§7.47), same grammar as
                         the LLM-agents rows. Everyone else has only the read path, and
                         a one-item dropdown is ceremony, so it stays the house brand
                         link: navigation is never button chrome (§2). --%>
                    <div class="ml-auto flex shrink-0 items-center gap-2">
                      <%= if Catalog.subject_can_manage_packs?(@current_subject) do %>
                        <.dropdown
                          class="inline-block shrink-0 text-left"
                          summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                          panel_class="z-10 mt-2 w-48 p-1 text-xs shadow-xl"
                        >
                          <:trigger>
                            Actions
                            <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
                          </:trigger>
                          <.menu_item
                            navigate={
                              ~p"/app/#{@current_account}/audit?#{[target_kind: "pack_version", target_id: v.id]}"
                            }
                            icon="product.audit"
                          >
                            View activity
                          </.menu_item>
                          <.menu_item
                            :if={
                              @version_facts[v.id].trust_state == :rejected and
                                (v.pending_hash || v.hash) != nil
                            }
                            tone={:amber}
                            phx-click="open_pack_action"
                            phx-value-action="trust"
                            phx-value-id={v.id}
                          >
                            Trust
                          </.menu_item>
                          <.menu_item
                            :if={@version_facts[v.id].trust_state == :trusted}
                            phx-click="open_pack_action"
                            phx-value-action="revoke_trust"
                            phx-value-id={v.id}
                          >
                            Revoke trust
                          </.menu_item>
                          <div class="my-1 border-t border-zinc-800/70"></div>
                          <.menu_item
                            tone={:rose}
                            phx-click="open_pack_action"
                            phx-value-action="delete_version"
                            phx-value-id={v.id}
                          >
                            Delete
                          </.menu_item>
                        </.dropdown>
                      <% else %>
                        <.link
                          navigate={
                            ~p"/app/#{@current_account}/audit?#{[target_kind: "pack_version", target_id: v.id]}"
                          }
                          class="group inline-flex shrink-0 items-center gap-1 text-xs font-medium text-brand-400 hover:text-brand-300"
                        >
                          View activity <.cta_arrow />
                        </.link>
                      <% end %>
                    </div>
                  </div>

                  <.version_contents
                    :if={
                      @version_facts[v.id].trust_state == :trusted and
                        MapSet.member?(@open_versions, v.id)
                    }
                    version={v}
                    inspected={@inspected_actions[v.id]}
                    matched={@matched_actions[v.id]}
                  />

                  <.retired_notice
                    :if={@version_facts[v.id].trust_state == :trusted}
                    version={v}
                    pack_id={pack.id}
                    fact={@version_facts[v.id]}
                    can_manage={Catalog.subject_can_manage_packs?(@current_subject)}
                  />

                  <%!-- A rejected version stays listed quietly — no alert, no
                       pending count; the row menu carries Trust, the
                       fix-admin-mistake path. --%>
                  <p
                    :if={@version_facts[v.id].trust_state == :rejected}
                    class="mt-1.5 pl-8 text-xs text-zinc-400"
                  >
                    Rejected — dispatch refuses this version until you trust it again.
                  </p>

                  <.pending_notice
                    :if={@version_facts[v.id].trust_state == :pending}
                    version={v}
                    pack_id={pack.id}
                    fact={@version_facts[v.id]}
                    matched={@matched_actions[v.id]}
                    can_manage={Catalog.subject_can_manage_packs?(@current_subject)}
                  />
                </li>
              </ul>

              <%!-- A gentle, pack-level "update available" heads-up — said ONCE
                   for the whole pack (the successor is the same current shipped
                   version for every outdated row), not repeated per version.
                   Retirement takes precedence per row, so this stays silent
                   under a rose retired block. --%>
              <.update_available_note pack_id={pack.id} update={pack.update} />
            </li>
          </ul>

          <%!-- Family-standard count footer (runners/runs/approvals/audit all
               carry one). --%>
          <p :if={@pack_count > 0} class="mt-4 text-xs text-zinc-400">
            {count_footer(@pack_count, @version_count)}
          </p>

          <%!-- Discovery: the rest of the workspace's packs, by name, so a
               member can ask for the one they need. IDENTITY ONLY — the
               Catalog's projection carries pack ids here and nothing else, so
               there is no version row, trust state, contents, advertiser or
               control to render. Chips, not rows: nothing here is actionable,
               and a row shape would promise otherwise. --%>
          <section
            :if={@out_of_scope_pack_ids != []}
            class={if @pack_count == 0, do: "mt-6", else: "mt-12"}
          >
            <.section_header
              title="Outside your pack access"
              count={length(@out_of_scope_pack_ids)}
            >
              <:subtitle>
                Also running in this workspace. Ask an owner or admin for access to actions those
                packs provide.
              </:subtitle>
            </.section_header>
            <div class="mt-4 flex flex-wrap gap-2">
              <.chip :for={pack_id <- @out_of_scope_pack_ids} mono>{pack_id}</.chip>
            </div>
          </section>
        </div>

        <aside class="space-y-6">
          <.docs_rail
            title="How pack trust works"
            doc_href={~p"/docs/action-packs"}
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
            <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
              Housekeeping
            </h3>
            <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — self-contained control card, the team-security rail grammar --%>
            <div id="packs-cleanup" class="mt-3 rounded-xl border border-zinc-800/80 p-4">
              <h4 class="text-sm font-medium text-zinc-100">Automatic cleanup</h4>
              <p class="mt-1 text-xs leading-relaxed text-zinc-400">
                Remove pack versions no runner has advertised for the selected period. A daily
                sweep deletes them — trust decisions included — and a runner advertising one
                again re-inserts it as a fresh trust decision. Versions a connected runner
                still advertises are never removed.
              </p>
              <.gated_setting
                id="pack-retention"
                can_change?={@can_manage_pack_retention?}
                value={
                  pack_retention_value_label(@current_account.settings.pack_unseen_retention_days)
                }
                who_can_change="Only owners and admins with full pack access can change this."
                class="mt-3"
              >
                <form id="pack-retention-form" phx-change="set_pack_retention">
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
                    Deletes every pack version no runner has advertised in the last {days_phrase(
                      @current_account.settings.pack_unseen_retention_days
                    )} — trust decisions included. Versions a connected runner still
                    advertises are kept.
                  </:body>
                  Clean up now
                </.confirm_button>
              </.gated_setting>
            </div>
          </div>
        </aside>
      </div>

      <%!-- One selected-row dialog replaces the pack-level and per-version
           copies that used to dominate the initial LiveView diff. The open
           event resolves the row from the scoped cache; each mutation still
           re-authorizes and re-fetches in Catalog. --%>
      <div
        :if={@pending_pack_action}
        id={"pack-action-mount-#{@pending_pack_action.nonce}"}
        phx-mounted={show_confirm_dialog("pack-action")}
      >
        <.confirm_dialog
          id="pack-action"
          tone={if @pending_pack_action.action == "trust", do: :amber, else: :neutral}
          title={pack_action_title(@pending_pack_action)}
          confirm_label={pack_action_label(@pending_pack_action)}
          on_confirm={confirm_pack_action(@pending_pack_action)}
        >
          <:body>
            <%= case @pending_pack_action.action do %>
              <% "delete_pack" -> %>
                Removes every recorded version of <code>{@pending_pack_action.pack_id}</code>
                — trust decisions and advertised actions included. A runner still advertising it
                will re-insert it. Audit history is kept.
              <% "delete_version" -> %>
                Removes this version and its advertised actions from the catalog. If a runner
                still advertises it, it will reappear as a fresh trust decision. Audit history
                is kept.
              <% "revoke_trust" -> %>
                Dispatch refuses this version until it is trusted again. It stays listed as
                rejected, so you can restore trust later.
              <% "trust" -> %>
                <span :if={not is_nil(@pending_pack_action.version.pending_hash)}>
                  Adopts the refused contents — its actions may run on {advertiser_count(
                    @pending_pack_action.fact.advertising
                  )} advertising {advertiser_noun(@pending_pack_action.fact.advertising)}.
                </span>
                <span :if={is_nil(@pending_pack_action.version.pending_hash)}>
                  Restores trust in the previously recorded contents — its actions may dispatch
                  again.
                </span>
                <span :if={@pending_pack_action.fact.retired?} class="text-rose-300">
                  This version was retired by a newer release — trusting it also overrides that
                  retirement, so its actions run despite the fix.
                </span>
            <% end %>
          </:body>
        </.confirm_dialog>
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
    </.console_shell>
    """
  end

  defp version_count_label(versions) do
    n = length(versions)
    "#{n} #{if n == 1, do: "version", else: "versions"}"
  end

  defp pack_action_title(%{action: "delete_pack", pack_id: pack_id}),
    do: "Delete #{pack_id}?"

  defp pack_action_title(%{action: action, pack_id: pack_id, version: version}) do
    verb =
      case action do
        "trust" -> "Trust"
        "revoke_trust" -> "Revoke trust in"
        "delete_version" -> "Delete"
      end

    "#{verb} #{pack_id} v#{version.version}?"
  end

  defp pack_action_label(%{action: "delete_pack"}), do: "Delete pack"
  defp pack_action_label(%{action: "delete_version"}), do: "Delete version"
  defp pack_action_label(%{action: "revoke_trust"}), do: "Revoke trust"
  defp pack_action_label(%{action: "trust"}), do: "Trust pack"

  defp confirm_pack_action(%{action: "delete_pack", pack_id: pack_id}) do
    JS.push("delete_pack", value: %{pack_id: pack_id}) |> close_confirm("pack-action")
  end

  defp confirm_pack_action(%{action: action, version: version}) do
    JS.push(action, value: %{id: version.id}) |> close_confirm("pack-action")
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
      class="inline-flex shrink-0 items-center gap-0.5 text-[11px] text-zinc-400 transition-colors hover:text-zinc-300"
      title="Published in emisar's public pack registry — opens in a new tab"
    >
      Registry <.icon name="action.external_link" class="h-3 w-3" />
    </.link>
    """
  end

  defp registry_pack_url(pack_id) when is_binary(pack_id) do
    if Catalog.get_published_pack(pack_id), do: ~p"/packs/#{pack_id}", else: nil
  end

  # The diff block renders only when there's something to show — a re-advertised
  # hash whose action set moved vs the stored `trusted_manifest`. nil (dead
  # render, or a version with no manifest) and an all-empty diff render nothing.
  defp diff_has_changes?(%{added: [], removed: [], changed: []}), do: false
  defp diff_has_changes?(%{added: _, removed: _, changed: _}), do: true
  defp diff_has_changes?(nil), do: false

  # Which descriptor fields moved, minus the two the row already shows as
  # values: risk in the pills, kind in the arrow beside them. Without this the
  # operator is asked to re-trust a rewritten description, args_schema or
  # output_schema that the card never names.
  defp other_changed_fields(%{changed_fields: fields}), do: fields -- ["kind", "risk"]
end
