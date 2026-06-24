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

  alias Emisar.{Catalog, Runners}
  alias EmisarWeb.ConfirmDialog

  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, "Packs")

    # Trusted versions' actions are loaded lazily, one query per opened
    # "View contents" disclosure (see `inspect_pack`), keyed by version id —
    # trusted versions can be many, so we never eagerly look them all up.
    socket = assign(socket, :inspected_actions, %{})

    # Reject is IRREVERSIBLE-feeling (the trusted/pending decision flips
    # dispatch authorization), so it routes through a typed-confirm modal. The
    # pack rows live in a `phx-update="stream"` (static once pushed), so the
    # dialog can't live per-row — instead one page-level dialog reads the pack
    # being rejected from `@reject_target`, set by the `open_reject` event.
    socket = socket |> ConfirmDialog.init() |> assign(:reject_target, nil)

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
        pending = Enum.count(rows, &(&1.trust_state == :pending))
        groups = group_by_pack(rows)

        socket
        |> assign(:load_error?, false)
        |> assign(:pack_count, length(groups))
        |> assign(:pending_count, pending)
        # Keep the sidebar badge in step after Trust/Reject on this page.
        |> assign(:pending_packs_count, pending)
        |> assign(:advertising, advertising_runners(rows, socket.assigns.current_subject))
        |> assign_pending_pack_actions(rows)
        |> stream(:packs, groups, reset: true)

      # A failed read must read as an error, not an empty inventory — "No packs
      # reported yet" would wrongly imply the fleet advertises nothing.
      :error ->
        socket
        |> assign(:load_error?, true)
        |> assign(:pack_count, 0)
        |> assign(:pending_count, 0)
        |> assign(:advertising, %{})
        |> assign(:pack_actions, %{})
        |> assign(:pack_diffs, %{})
        |> stream(:packs, [], reset: true)
    end
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

  # Blast radius of a pending trust decision: which runners advertise each
  # pending version (so the operator sees one canary box vs the whole fleet).
  # Keyed by pack_version id; only pending versions are looked up.
  defp advertising_runners(rows, subject) do
    runners_by_id =
      case Runners.list_runners_for_account(subject) do
        {:ok, runners, _meta} -> Map.new(runners, &{&1.id, &1})
        _ -> %{}
      end

    rows
    |> Enum.filter(&(&1.trust_state == :pending))
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
           page: [limit: 500]
         ) do
      # A `:rejected` row persists in the DB so dispatch fails closed (a missing
      # row would read as trusted), but the list shows only actionable versions
      # — pending (needs a decision) and trusted. When the runner re-advertises
      # a rejected pack, `judge_drift` flips it back to `:pending` and it
      # reappears here for another review.
      {:ok, rows, _meta} -> {:ok, Enum.reject(rows, &(&1.trust_state == :rejected))}
      {:error, _} -> :error
    end
  end

  defp pending_review_title(1), do: "1 pack version needs trust review."
  defp pending_review_title(count), do: "#{count} pack versions need trust review."

  def handle_event("trust", %{"id" => id}, socket) do
    case Catalog.trust_pack_version(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Trusted #{pack_version.pack_id} v#{pack_version.version}.")
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Nothing pending on that pack.")}

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
         |> put_flash(
           :info,
           "Rejected drift on #{pack_version.pack_id} v#{pack_version.version}. The runner advertising the new hash will re-broadcast — if it's still set, this will re-surface."
         )
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Nothing pending on that pack.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to reject packs.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reject pack — try again.")}
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

  # Lazily load a trusted version's action set the first time its "View
  # contents" disclosure is opened (one query per opened disclosure, not per
  # page — trusted versions can be many). The result is cached in
  # `inspected_actions` keyed by version id; the disclosure renders the actions
  # once present and stays open thereafter. We re-insert the affected pack
  # group so the stream child re-renders against the new assign (a stream item
  # is otherwise static once pushed). The Catalog read re-checks `view_catalog`
  # itself (IL-15) — `pack_id`/`version` come from the rendered row, so a
  # crafted event can't reach another account's actions.
  def handle_event(
        "inspect_pack",
        %{"id" => id, "pack-id" => pack_id, "version" => version},
        socket
      ) do
    if Map.has_key?(socket.assigns.inspected_actions, id) do
      {:noreply, socket}
    else
      actions =
        case Catalog.list_pack_actions(pack_id, version, socket.assigns.current_subject) do
          {:ok, actions} -> actions
          _ -> []
        end

      socket = update(socket, :inspected_actions, &Map.put(&1, id, actions))
      {:noreply, reinsert_pack_group(socket, pack_id)}
    end
  end

  # Re-render one pack group's stream item against the current assigns (a
  # stream child is static once pushed, so the just-loaded `inspected_actions`
  # only appears after a re-insert). One query for the group's versions; unlike
  # `restream_pack` this doesn't recompute the pending panels — inspecting a
  # trusted version changes nothing about what's pending.
  defp reinsert_pack_group(socket, pack_id) do
    case fetch_rows(socket) do
      {:ok, rows} ->
        versions = rows |> Enum.filter(&(&1.pack_id == pack_id)) |> sort_versions()

        if versions == [] do
          socket
        else
          stream_insert(socket, :packs, %{id: pack_id, versions: versions})
        end

      :error ->
        socket
    end
  end

  # After a Trust/Reject, recompute just the affected pack group and update
  # the stream in place: `stream_delete` if no displayable version of the pack
  # remains (a never-trusted custom pack's only version was Rejected → hidden
  # from the list by `fetch_rows`, though the row persists for the dispatch
  # gate), otherwise `stream_insert` the regrouped versions. The `pending_count`
  # (and sidebar badge) are recomputed from the full set.
  defp restream_pack(socket, pack_id) do
    case fetch_rows(socket) do
      {:ok, rows} ->
        pending = Enum.count(rows, &(&1.trust_state == :pending))
        pack_count = rows |> Enum.map(& &1.pack_id) |> Enum.uniq() |> length()
        versions = rows |> Enum.filter(&(&1.pack_id == pack_id)) |> sort_versions()

        socket =
          socket
          |> assign(:pack_count, pack_count)
          |> assign(:pending_count, pending)
          |> assign(:pending_packs_count, pending)
          |> assign(:advertising, advertising_runners(rows, socket.assigns.current_subject))
          |> assign_pending_pack_actions(rows)

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

  defp pack_action_list(assigns) do
    ~H"""
    <ul class="mt-1 space-y-1">
      <li :for={action <- @actions} class="flex items-center gap-2 text-[11px]">
        <.risk_pill risk={action.risk} class="flex-none" />
        <span class="font-mono text-zinc-300">{action.action_id}</span>
        <span :if={action.title} class="truncate text-zinc-500">{action.title}</span>
      </li>
    </ul>
    """
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:packs}
      width={:table}
    >
      <:title>Packs</:title>

      <.page_intro>
        A pack is a versioned set of actions a runner is allowed to run. Each <em>(pack, version)</em>
        has a pinned trusted hash. Runners advertising the same
        contents match the pin; a different hash flips the pack into
        <strong class="text-amber-300">pending</strong>
        — dispatch refuses runs against it until
        you Trust (adopt the new contents) or Reject (keep the pinned hash).
      </.page_intro>

      <.notice
        :if={@pending_count > 0}
        variant={:warning}
        icon="hero-shield-exclamation"
        title={pending_review_title(@pending_count)}
        class="mt-4"
      >
        Dispatch against these versions is blocked until an admin reviews the new hash.
      </.notice>

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
        :if={@pack_count == 0 and not @load_error? and not @loading?}
        icon="hero-cube"
        title="No packs reported yet"
        class="mt-8"
      >
        A pack is the bundle of actions a runner can run. Connect a runner and the packs
        it loads appear here to trust or reject.
      </.empty_state>

      <ul id="packs" phx-update="stream" class="mt-6 space-y-4">
        <%!-- Sanctioned hand-rolled card (see .agent/rules/ui-shared-components.md):
             a stream <li> wrapping a nested version list, so it can't be a <div>
             <.card> and isn't a flat <.list_row>. Keep the card chrome inline. --%>
        <li
          :for={{dom_id, pack} <- @streams.packs}
          id={dom_id}
          class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
        >
          <header class="flex items-center justify-between gap-4 border-b border-zinc-900 px-5 py-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-cube" class="h-4 w-4 text-zinc-500" />
              <h2 class="font-mono text-sm text-zinc-100">{pack.id}</h2>
              <span class="text-xs text-zinc-500">·</span>
              <span class="text-xs text-zinc-500">{version_count_label(pack.versions)}</span>
              <.chip :if={any_pending?(pack.versions)} upcase tone={:amber} class="ml-2">
                Pending
              </.chip>
            </div>
          </header>

          <ul class="divide-y divide-zinc-900">
            <li :for={v <- pack.versions} class="flex flex-col gap-3 px-5 py-3">
              <div class="flex items-center justify-between gap-4">
                <div class="flex items-center gap-3 min-w-0">
                  <span class="rounded bg-zinc-900 px-1.5 py-0.5 font-mono text-xs text-zinc-200">
                    v{v.version}
                  </span>
                  <span class="truncate font-mono text-[11px] text-zinc-500" title={v.hash}>
                    sha256:{short_hash(v.hash)}
                  </span>
                  <.chip :if={v.trust_state == :trusted} upcase tone={:brand}>Trusted</.chip>
                  <.chip :if={v.trust_state == :pending} upcase tone={:amber}>Pending</.chip>
                </div>
                <div class="shrink-0 text-right text-xs text-zinc-500">
                  <div>last seen <.local_time value={v.last_seen_at} class="text-zinc-300" /></div>
                  <div
                    :if={v.first_seen_at && v.first_seen_at != v.last_seen_at}
                    class="text-[10px] text-zinc-400"
                  >
                    first seen <.local_time value={v.first_seen_at} class="inline" />
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
                  <span
                    :for={r <- @advertising[v.id]}
                    class="ml-1 inline-block rounded bg-amber-900/40 px-1.5 py-0.5 font-mono text-amber-200"
                  >
                    {r.name}<span class="text-amber-400/70"> · {r.group}</span>
                  </span>
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
                  <.pack_action_list actions={@pack_actions[v.id]} />
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
                  <.button
                    variant="caution"
                    size="sm"
                    phx-click="trust"
                    phx-value-id={v.id}
                    data-confirm={
                      if is_nil(v.hash) do
                        "Trust #{pack.id} v#{v.version}? Cloud will allow its actions to run on #{length(@advertising[v.id] || [])} advertising runner(s)."
                      else
                        "Adopt the new hash as trusted for #{pack.id} v#{v.version}? It authorizes dispatch on #{length(@advertising[v.id] || [])} advertising runner(s)."
                      end
                    }
                  >
                    {if is_nil(v.hash), do: "Trust pack", else: "Trust new contents"}
                  </.button>
                  <%!-- IRREVERSIBLE-feeling — typed-confirm modal instead of
                       data-confirm. The button only OPENS the page-level dialog
                       (stashing this version as the target); `reject` still fires
                       from Confirm and stays server-authz-gated (manage_catalog). --%>
                  <.button
                    variant="secondary"
                    size="sm"
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

              <%!-- A trusted version's contents stay auditable after the Trust
                   decision: a collapsed disclosure that lazily loads the
                   action + risk set (one query when first opened — see
                   `inspect_pack`) so an operator can re-inspect what's
                   authorized without waiting for a re-advertise. --%>
              <details
                :if={v.trust_state == :trusted}
                class="group rounded border border-zinc-900 bg-zinc-950/40"
              >
                <summary
                  phx-click="inspect_pack"
                  phx-value-id={v.id}
                  phx-value-pack-id={pack.id}
                  phx-value-version={v.version}
                  class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-[11px] text-zinc-400 hover:text-zinc-200"
                >
                  <.icon
                    name="hero-chevron-right"
                    class="h-3.5 w-3.5 transition-transform group-open:rotate-90"
                  />
                  <span class="group-open:hidden">View contents</span>
                  <span class="hidden group-open:inline">Trusted contents</span>
                </summary>
                <div class="border-t border-zinc-900 px-3 py-2">
                  <p :if={is_nil(@inspected_actions[v.id])} class="text-[11px] text-zinc-500">
                    Loading…
                  </p>
                  <p
                    :if={@inspected_actions[v.id] == []}
                    class="text-[11px] text-zinc-500"
                  >
                    No actions advertised for this version right now.
                  </p>
                  <.pack_action_list
                    :if={@inspected_actions[v.id] not in [nil, []]}
                    actions={@inspected_actions[v.id]}
                  />
                </div>
              </details>
            </li>
          </ul>
        </li>
      </ul>

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
          Rejects <span class="font-mono font-medium text-rose-100">
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

  defp short_hash(nil), do: "—"
  defp short_hash(h) when is_binary(h), do: String.slice(h, 0, 12)

  # The diff block renders only when there's something to show — a re-advertised
  # hash whose action set moved vs the stored `trusted_manifest`. nil (dead
  # render, or a version with no manifest) and an all-empty diff render nothing.
  defp diff_has_changes?(%{added: [], removed: [], changed: []}), do: false
  defp diff_has_changes?(%{added: _, removed: _, changed: _}), do: true
  defp diff_has_changes?(nil), do: false
end
