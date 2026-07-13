defmodule EmisarWeb.AuditLive do
  @moduledoc """
  Append-only audit log list. Actor + target columns resolve their
  display labels in a single batched pass (`Audit.resolve_references/1`)
  and render as links into the relevant detail page when one exists.
  Click a row to drill into the full event (payload, IP, user agent,
  request id) at `/app/audit/:id`.
  """
  use EmisarWeb, :live_view
  alias Emisar.{ApiKeys, Audit, Billing}
  alias EmisarWeb.{AuditSummary, LiveTable}

  def mount(params, _session, socket) do
    # Audit log is the canonical "what just happened" surface — any
    # mutation that commits an `Audit.Event` row in the same multi gets
    # auto-broadcast by `Repo.commit_multi`, so subscribing here is
    # enough to make the list fully live without per-domain plumbing.
    if connected?(socket) do
      Audit.subscribe_account_audit(socket.assigns.current_account.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     # The facet panel is collapsed by default — the trail leads the page. It
     # opens on MOUNT when the URL already carries an active facet (a shared
     # filtered link must never hide its controls); after that the flag is
     # purely operator-toggled, so applying/clearing filters doesn't snap the
     # panel around.
     |> assign(
       :filters_open?,
       LiveTable.has_active_filters?(params, Audit.Event.Query.filters())
     )}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info({:audit_event, _event}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("toggle_filters", _params, socket),
    do: {:noreply, update(socket, :filters_open?, &(!&1))}

  def handle_event("filter", params, socket) do
    # The filter form doesn't carry actor_id when the "by actor" picker is
    # hidden (it's set by clicking a row's actor), so merge it back or a
    # dropdown change would silently drop an active actor filter. From/To now
    # live in the form, so the form params carry them.
    preserved = Map.take(socket.assigns.filter_params, ["actor_id", "window"])
    merged = Map.merge(preserved, params)

    # A manually edited From/To supersedes the quick-range chip — its highlight
    # would lie about the bound otherwise.
    merged =
      if params["from"] != socket.assigns.filter_params["from"] or
           params["to"] != socket.assigns.filter_params["to"],
         do: Map.delete(merged, "window"),
         else: merged

    # Switching the actor kind invalidates a previously-picked actor (its id
    # belongs to the old kind), so drop it — else the new kind's picker reads
    # "All" while the stale id quietly filters to nothing. Normalize blank/nil
    # so an unrelated change doesn't drop a click-to-filter actor_id.
    merged =
      if blank_to_nil(params["actor_kind"]) !=
           blank_to_nil(socket.assigns.filter_params["actor_kind"]),
         do: Map.delete(merged, "actor_id"),
         else: merged

    # Same for the target picker — a changed target kind invalidates its pick.
    merged =
      if blank_to_nil(params["target_kind"]) !=
           blank_to_nil(socket.assigns.filter_params["target_kind"]),
         do: Map.delete(merged, "target_id"),
         else: merged

    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/audit", merged)}
  end

  def handle_event("preset", %{"window" => window}, socket) do
    # Quick relative-range chips set :from to (now − window) and clear :to, so
    # "Last 24h" is the last 24h up to NOW (a stale upper bound would make it a
    # weird window). Clicking the ACTIVE chip clears the range (a toggle).
    # Whitelisted window → an unknown (crafted) value is a no-op, never a crash
    # or an arbitrary bound. Other active filters are preserved.
    params = socket.assigns.filter_params

    merged =
      cond do
        params["window"] == window ->
          params |> Map.delete("window") |> Map.delete("from") |> Map.delete("to")

        from = preset_from(window) ->
          params |> Map.put("window", window) |> Map.put("from", from) |> Map.delete("to")

        true ->
          nil
      end

    if merged do
      {:noreply,
       LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/audit", merged)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_problems", _params, socket) do
    params = socket.assigns.filter_params

    merged =
      if problems_only?(params),
        do: Map.delete(params, "outcome"),
        else: Map.put(params, "outcome", ["danger", "warn"])

    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/audit", merged)}
  end

  # The download hands over exactly what the operator is looking at — the
  # active filter params ride the href; cursors don't (the download walks the
  # whole filtered set itself).
  defp audit_download_path(assigns) do
    query = Map.drop(assigns.filter_params, ["account_id_or_slug", "before", "after"])
    ~p"/app/#{assigns.current_account}/audit/download?#{query}"
  end

  # Quick relative-range presets for the audit date filter — re-adds the buttons
  # the date-unification dropped, now setting the unified bar's :from.
  defp audit_presets, do: [{"Last hour", "1h"}, {"Last 24 hours", "24h"}, {"Last 7 days", "7d"}]

  # The "Problems only" toggle is on when the Outcome filter is exactly the two
  # non-routine outcomes (failures + denials/removals) the audit dots color.
  defp problems_only?(params) do
    outcome = List.wrap(params["outcome"])
    "danger" in outcome and "warn" in outcome
  end

  # Window → the "YYYY-MM-DDTHH:MM" UTC string the :from datetime filter parses
  # (now minus the window). Computed at click time so the range stays anchored to
  # "now", not page-render time. Unknown window → nil (no-op).
  defp preset_from(window) do
    case preset_seconds(window) do
      nil ->
        nil

      seconds ->
        DateTime.utc_now()
        |> DateTime.add(-seconds, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")
    end
  end

  defp preset_seconds("1h"), do: 3600
  defp preset_seconds("24h"), do: 86_400
  defp preset_seconds("7d"), do: 604_800
  defp preset_seconds(_), do: nil

  # When exactly one actor kind is selected in the filter bar, surface a "filter
  # by actor" picker for that kind — its options are the distinct actors of that
  # kind already in the account's log. Render-only: actor_id still applies via
  # the opts path below, so it appears on demand instead of an always-empty
  # dropdown.
  defp actor_kind_filter(params, subject) do
    # `ensure` the currently-filtered actor into the options so a click-through
    # from Team "View activity" selects the member even when they have no events
    # yet (otherwise the picker would fall back to All).
    with kind when is_binary(kind) <- blank_to_nil(params["actor_kind"]),
         {:ok, [_ | _] = options} <-
           Audit.list_actor_options(kind, subject, ensure: blank_to_nil(params["actor_id"])) do
      [Audit.Event.Query.actor_filter(options)]
    else
      _ -> []
    end
  end

  # Same shape for the Target column: when a target kind is selected, surface a
  # "filter by target" picker for that kind (its distinct targets in the log).
  defp target_kind_filter(params, subject) do
    with kind when is_binary(kind) <- blank_to_nil(params["target_kind"]),
         {:ok, [_ | _] = options} <- Audit.list_target_options(kind, subject) do
      [Audit.Event.Query.target_filter(options)]
    else
      _ -> []
    end
  end

  defp load(socket, params) do
    # Request ID + Sign-in method only apply to some event types — drop them
    # when the selected Type can't carry them (or none is set), so the filter
    # panel shows only filters that can actually narrow the log.
    base_filters =
      Audit.Event.Query.applicable_filters(
        Audit.Event.Query.filters(),
        params["event_type"],
        params
      )

    # Render each dynamic picker right after its kind filter (the dependent
    # control belongs next to its trigger), not tacked on at the end.
    # base_filters stays the opts source; the actor/target pickers are
    # render-only — actor_id/target_id apply via the opts path below.
    subject = socket.assigns.current_subject
    actor_filter = actor_kind_filter(params, subject)
    target_filter = target_kind_filter(params, subject)

    filters =
      Enum.flat_map(base_filters, fn
        %{name: :actor_kind} = f -> [f | actor_filter]
        %{name: :target_kind} = f -> [f | target_filter]
        f -> [f]
      end)

    actor_id = blank_to_nil(params["actor_id"])
    target_id = blank_to_nil(params["target_id"])

    # actor_id rides as a URL param outside the form (set by clicking a row's
    # actor); target_id is set by its dynamic picker. Both aren't in
    # base_filters, so they're threaded into list_events directly. From/To are
    # LiveTable datetime filters — params_to_opts applies them via :filter.
    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_params, params)
      |> assign(:active_facet_count, LiveTable.count_active_filters(params, filters))
      |> assign(
        :active_facet_summary,
        params |> LiveTable.active_filter_labels(filters) |> Enum.join(" · ")
      )
      |> assign(:actor_id, actor_id)
      |> assign(:target_id, target_id)

    opts =
      params
      |> LiveTable.params_to_opts(base_filters)
      |> Keyword.merge(actor_id: actor_id, target_id: target_id)

    case Audit.list_events(socket.assigns.current_subject, opts) do
      {:ok, events, meta} ->
        socket
        |> assign(:events, events)
        |> assign(:metadata, meta)
        |> assign(:refs, Audit.resolve_references(events))
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — flag it
      # so the log says "couldn't load" instead of a silent empty list. Audit is
      # the receipt: "nothing happened" must never be confused with "read failed".
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:events, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:refs, %{})
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

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
      section={:audit}
      width={:table}
    >
      <:title>Audit log</:title>
      <%!-- Sub-feature side door — streaming config is its own page; its entry
           rides the TITLE row (the pattern for a page's secondary surface),
           not the intro prose and never below the rows. --%>
      <:actions>
        <%!-- :md, not :sm — a control on the 28px title row needs the full-size
             button to hold its own beside the H1. Export downloads the CURRENT
             FILTERED VIEW as CSV; both export surfaces are Team+ (the console
             trail is on every plan — taking the data OUT is paid). On a lower
             plan the control is a disabled lock button with a downward tooltip
             naming the gate; upgrading is the Billing nav item. --%>
        <%= if Billing.audit_export_available?(@current_account) do %>
          <.button variant={:secondary} size={:md} href={audit_download_path(assigns)} download>
            Export CSV
          </.button>
        <% else %>
          <.upgrade_button tip="CSV export is on the Team plan — upgrade to turn it on">
            Export CSV
          </.upgrade_button>
        <% end %>
        <%= if ApiKeys.subject_can_manage_api_keys?(@current_subject) do %>
          <%= if Billing.audit_export_available?(@current_account) do %>
            <.button
              variant={:secondary}
              size={:md}
              navigate={~p"/app/#{@current_account}/audit/export"}
            >
              Stream to SIEM
            </.button>
          <% else %>
            <.upgrade_button tip="SIEM streaming is on the Team plan — upgrade to turn it on">
              Stream to SIEM
            </.upgrade_button>
          <% end %>
        <% end %>
      </:actions>

      <.page_intro>
        The append-only record of every action, approval, and access change in this account —
        exportable to your SIEM for independent, long-term retention.
        <.doc_link href="/docs/audit-and-siem">Audit log docs</.doc_link>
      </.page_intro>

      <%!-- Quick relative-range presets — set the unified bar's From to
           (now − window); the date filter below consumes it. Re-adds the
           presets the date-unification dropped, without a second bar. --%>
      <div class="mb-2 flex flex-wrap items-center gap-1.5 text-xs">
        <span class="text-zinc-500">Quick filters:</span>
        <%!-- An active preset wears the brand active-filter tint and clicking
             it again clears the window — the chip is a TOGGLE, like every
             other filter control. Which chip is active rides a `window` URL
             param (the materialized From value can't be matched back to its
             preset a minute later); the From facet stays the visible source
             of truth for the actual bound. --%>
        <button
          :for={{label, window} <- audit_presets()}
          type="button"
          phx-click="preset"
          phx-value-window={window}
          aria-pressed={to_string(@filter_params["window"] == window)}
          class={[
            "rounded-md px-2 py-1 font-medium ring-1 transition",
            if(@filter_params["window"] == window,
              do: "bg-brand-500/10 text-brand-300 ring-brand-500/40",
              else: "bg-zinc-900 text-zinc-300 ring-zinc-800 hover:bg-zinc-800 hover:text-zinc-100"
            )
          ]}
        >
          {label}
        </button>
        <%!-- One-click "only the events that went wrong" — denials, removals, and
             failures (the danger+warn severities) — so the rows an operator hunts
             for surface out of a wall of routine sign-ins, without hand-building
             the Severity filter. Toggles the filter the panel already exposes. --%>
        <%!-- Active wears the BRAND active-filter tint like every other filter
             control — rose would say "something is wrong", but an engaged
             toggle is a filter state, not an alarm (the problem ROWS carry
             their own rose/amber). --%>
        <button
          type="button"
          phx-click="toggle_problems"
          aria-pressed={to_string(problems_only?(@filter_params))}
          class={[
            "rounded-md px-2 py-1 font-medium ring-1 transition",
            if(problems_only?(@filter_params),
              do: "bg-brand-500/10 text-brand-300 ring-brand-500/40",
              else: "bg-zinc-900 text-zinc-300 ring-zinc-800 hover:bg-zinc-800 hover:text-zinc-100"
            )
          ]}
        >
          Problems only
        </button>
      </div>

      <%!-- The facet drawer opens from a DISCLOSURE line, not a floating chip —
           the same fold grammar as the approval detail's raw-args row, so it
           reads as part of the document. Server-owned open state (a native
           <details> would snap shut on every live re-render); the chevron
           rotates, and a CLOSED line NARRATES its active facets as prose
           ("Filters — Type: Runner — all events") so nothing is ever silently
           narrowing the trail. --%>
      <button
        type="button"
        phx-click="toggle_filters"
        aria-expanded={to_string(@filters_open?)}
        class="group -mx-2 mb-2 flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-xs transition hover:bg-white/[0.04]"
      >
        <%!-- w-3 + gap-2 = 20px to the label — the SAME x as the row labels
             (8px dot + gap-3), so the fold sits on the table's rail. --%>
        <.icon
          name="hero-chevron-right"
          class={"h-3 w-3 shrink-0 transition-transform duration-150 #{if @filters_open?, do: "rotate-90 text-zinc-400", else: "text-zinc-600 group-hover:text-zinc-400"}"}
        />
        <span class={[
          "font-medium",
          if(@active_facet_count > 0 or @filters_open?,
            do: "text-brand-300",
            else: "text-zinc-400 group-hover:text-zinc-200"
          )
        ]}>
          Filters
        </span>
        <span :if={@active_facet_count > 0 and not @filters_open?} class="truncate text-zinc-500">
          — {@active_facet_summary}
        </span>
      </button>

      <%!-- The trail itself: one line per event, DAY-grouped, directly on the
           canvas — no table chrome. Each row is dot (outcome) + the event's
           human label (its ONE identity — the machine code lives on the
           detail page) + a quiet who/what/where meta fragment, with a
           UTC-forensic clock on the right edge. The whole page reads on one
           clock: group headers carry the UTC date, rows the UTC time, and the
           full stamp rides each row's title attribute — matching the UTC
           filter bounds (the old per-row local_time hook silently disagreed
           with them). --%>
      <LiveTable.live_table
        id="audit-events"
        path={~p"/app/#{@current_account}/audit"}
        rows={@events}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={@filters}
        filter_layout={:stacked}
        filter_visibility={:collapsible}
        filters_open={@filters_open?}
        layout={:cards}
        wrapper_class="divide-y divide-zinc-800/70"
      >
        <%!-- The day bands died with the switch to relative times (the exact
             stamp lives in each row's tooltip + the From/To bounds), so the
             column header is simply the list's first row — nothing floats
             above the table. Folds below xl with the columns. --%>
        <:list_header>
          <li class="hidden pb-2 xl:grid xl:grid-cols-[minmax(0,1fr)_11rem_11rem_7.5rem_5.5rem] xl:gap-4">
            <span class={audit_column_header_class()}>Event</span>
            <span class={audit_column_header_class()}>Actor</span>
            <span class={audit_column_header_class()}>Target</span>
            <span class={audit_column_header_class()}>Source IP</span>
            <span class={[audit_column_header_class(), "text-right"]}>When</span>
          </li>
        </:list_header>
        <:item :let={event}>
          <li id={"event-#{event.id}"}>
            <%!-- One row, two densities. Below xl: the folded who→what·pairs·ip
                 meta line. From xl: the forensic COLUMNS a reviewer scans down —
                 Actor (who did it), Target (what it acted on), Source IP (from
                 where) — with the payload pairs staying under the event label.
                 Event/Actor/Target share 14/20 type; supporting IP/When use
                 12/20, preserving the common line box without competing with
                 the identities. Every secondary line shares 12/16. Time is
                 relative for humans; the hook's tooltip carries the absolute
                 stamp with timezone for the record. --%>
            <.link
              navigate={~p"/app/#{@current_account}/audit/#{event.id}"}
              class="-mx-2 flex items-start gap-3 rounded-md px-2 py-3 transition hover:bg-white/[0.04] xl:grid xl:grid-cols-[minmax(0,1fr)_11rem_11rem_7.5rem_5.5rem] xl:items-start xl:gap-4"
            >
              <div class="flex min-w-0 flex-1 items-start gap-3 xl:flex-auto">
                <.status_dot tone={outcome_tone(event.event_type)} size={:md} class="mt-1" />
                <div class="min-w-0 flex-1">
                  <div
                    class={["truncate text-sm leading-5", event_title_class(event.event_type)]}
                    data-audit-event-primary
                  >
                    {format_event_type(event.event_type)}
                  </div>
                  <div class="mt-0.5 truncate text-xs leading-4 text-zinc-500 xl:hidden">
                    {event_meta(event, @refs)}
                  </div>
                  <div
                    :if={pairs_text(event) != ""}
                    class="mt-0.5 hidden truncate text-xs leading-4 text-zinc-500 xl:block"
                  >
                    {pairs_text(event)}
                  </div>
                </div>
              </div>
              <.audit_actor_cell
                kind={event.actor_kind}
                id={event.actor_id}
                label={event.actor_label}
                refs={@refs}
              />
              <.audit_cell
                value={target_text(event, @refs)}
                placeholder={if self_event?(event), do: "self", else: "—"}
              />
              <.audit_cell value={event.ip_address} mono />
              <.local_time
                id={"when-#{event.id}"}
                value={event.occurred_at}
                mode={:relative}
                styled_tooltip
                class="ml-auto shrink-0 whitespace-nowrap text-xs leading-5 text-zinc-500 xl:ml-0 xl:text-right"
              />
            </.link>
          </li>
        </:item>
        <:empty>
          <%!-- Filter-active stays a one-liner so it doesn't dominate
               when the operator is just over-filtering. Empty-account
               state gets richer copy that names the surfaces that
               actually produce events. --%>
          <%= cond do %>
            <% @load_error? -> %>
              <.empty_state
                tone={:danger}
                icon="hero-exclamation-triangle"
                title="Couldn't load the audit log"
              >
                This is a load error, not an empty log. Refresh the page; if it persists, your
                access to this account may have changed.
              </.empty_state>
            <% any_filter_active?(@filter_params, @filters) -> %>
              <span class="text-zinc-500">No events match these filters.</span>
            <% true -> %>
              <.empty_state icon="hero-document-text" title="No audit events yet.">
                They appear as soon as something happens — a
                <.link
                  navigate={~p"/app/#{@current_account}/runners"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  runner
                </.link>
                connects, an operator dispatches a <.link
                  navigate={~p"/app/#{@current_account}/runs"}
                  class="text-brand-400 hover:text-brand-300"
                >run</.link>,
                an approval is decided, or a pack is observed on the <.link
                  navigate={~p"/app/#{@current_account}/packs"}
                  class="text-brand-400 hover:text-brand-300"
                >Packs page</.link>.
              </.empty_state>
          <% end %>
        </:empty>
      </LiveTable.live_table>
    </.dashboard_shell>
    """
  end

  attr :tip, :string, required: true
  slot :inner_block, required: true

  # A plan-gated title-row action: the button is DISABLED and wears a lock icon —
  # a clear "not on your plan" marker, no color noise. A hover tooltip names the
  # gate; it opens DOWNWARD so it can't clip off the top of the viewport next to
  # the H1 (the bug that sank the first pass). Upgrading is the Billing nav item.
  defp upgrade_button(assigns) do
    ~H"""
    <.tooltip text={@tip} placement={:bottom} class="shrink-0">
      <.button variant={:secondary} size={:md} icon="hero-lock-closed" disabled>
        {render_slot(@inner_block)}
      </.button>
    </.tooltip>
    """
  end

  defp audit_column_header_class,
    do: "text-[11px] font-medium uppercase tracking-wider text-zinc-500"

  attr :value, :string, default: nil
  attr :mono, :boolean, default: false
  attr :placeholder, :string, default: "—"

  # An xl+ forensic column cell (Actor / Target / Source IP). An empty cell
  # renders its muted placeholder on its own span — the em-dash, or "self"
  # when an event's target IS its actor — never the value's styling.
  defp audit_cell(assigns) do
    ~H"""
    <div class="hidden min-w-0 xl:block">
      <span
        :if={@value}
        class={[
          "block truncate leading-5 text-zinc-400",
          if(@mono, do: "font-mono text-xs tabular-nums", else: "text-sm")
        ]}
        data-audit-cell-primary
        title={@value}
      >
        {@value}
      </span>
      <span :if={!@value} class="block text-sm leading-5 text-zinc-600" data-audit-cell-primary>
        {@placeholder}
      </span>
    </div>
    """
  end

  attr :kind, :string, default: nil
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :refs, :map, default: %{}

  # Actor accountability is a hierarchy, not a sentence: the human leads and
  # an API key/client sits beneath it as quieter credential context. Keeping
  # each on its own line lets both survive the fixed forensic column width.
  defp audit_actor_cell(assigns) do
    {who, credential} = actor_who_via(assigns.kind, assigns.id, assigns.label, assigns.refs)

    title =
      case {who, credential} do
        {nil, _credential} -> nil
        {who, nil} -> who
        {who, credential} -> "#{who} via #{credential}"
      end

    assigns = assign(assigns, who: who, credential: credential, title: title)

    ~H"""
    <div class="hidden min-w-0 xl:block" data-audit-actor title={@title}>
      <span :if={@who} class="block truncate text-sm leading-5 text-zinc-400" data-audit-primary>
        {@who}
      </span>
      <span
        :if={@credential}
        class="mt-0.5 block truncate text-xs leading-4 text-zinc-500"
        data-audit-secondary
      >
        {@credential}
      </span>
      <span :if={!@who} class="block text-sm leading-5 text-zinc-600" data-audit-primary>—</span>
    </div>
    """
  end

  # One quiet meta STRING per event — the accountable identity by name (the
  # kind prefix + the generic ACTOR/SUBJECT/IP columns died with the grid),
  # then "→ target" only when the event acted ON something other than its
  # actor (a sign-in acts on itself; a role change acts on a teammate), then
  # the payload's notable pairs, then the source IP. Plain text on purpose:
  # the row's one link is the row itself (→ the event detail).
  defp event_meta(event, refs) do
    # Actor and its target bind into ONE "who → what" segment (a middot
    # between them read as two unrelated facts); the arrow appears only when
    # the event acted on something other than its actor.
    who =
      [
        actor_label_text(event.actor_kind, event.actor_id, event.actor_label, refs),
        target_text(event, refs)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" → ")

    [blank_to_nil(who), blank_to_nil(pairs_text(event)), event.ip_address]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # "via magic_link" reads as prose, and "action" renders as the bare command
  # identity (`caddy.access_log_tail · duration_ms: 260ms` — the WHAT of a run
  # row, not a k: v fact about it); every other pair stays forensic "k: v".
  defp pairs_text(event) do
    AuditSummary.summary_pairs(event)
    |> Enum.map_join(" · ", fn
      {"via", v} -> "via #{v}"
      {"action", v} -> v
      {k, v} -> "#{k}: #{v}"
    end)
  end

  defp target_text(event, refs) do
    if self_event?(event),
      do: nil,
      else: party_text(event.target_kind, event.target_id, event.target_label, refs)
  end

  # An event whose target IS its actor (a sign-in, a runner connect) — the
  # meta line omits it; the Target column says "self". An event with NO
  # target at all is not "self", it just has no target (em-dash).
  defp self_event?(%{target_kind: nil}), do: false

  defp self_event?(event),
    do: event.target_kind == event.actor_kind and event.target_id == event.actor_id

  defp party_text(nil, _id, _label, _refs), do: nil

  defp party_text(kind, nil, _label, _refs) when kind in ["system", "scheduler", "runbook"],
    do: kindless_label(kind)

  defp party_text(kind, id, label, refs), do: resolve_label(refs, kind, id, label)

  # User-first ACTOR rendering: the accountable HUMAN leads, the credential is
  # secondary `via` context. An api_key/MCP actor resolves its owner (the key
  # creator) as `who` and the key name as `via`; when the owner can't be
  # resolved (deleted, or a legacy row) it degrades to the key name alone.
  # Every other actor kind is already human — `via` is nil.
  defp actor_who_via("api_key", id, label, refs) when not is_nil(id) do
    key_name = resolve_label(refs, "api_key", id, label)
    owner = refs |> Map.get("api_key_owner", %{}) |> Map.get(id)

    if owner, do: {owner, key_name}, else: {key_name, nil}
  end

  defp actor_who_via(kind, id, label, refs), do: {party_text(kind, id, label, refs), nil}

  # The single-string actor label for the folded list's narrative meta line.
  # The xl forensic column uses `audit_actor_cell/1`'s two-level hierarchy.
  defp actor_label_text(kind, id, label, refs) do
    case actor_who_via(kind, id, label, refs) do
      {nil, _via} -> nil
      {who, nil} -> who
      {who, via} -> "#{who} via #{via}"
    end
  end

  # -- Reference rendering (shared with AuditDetailLive) ---------------

  attr :kind, :string, default: nil
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :refs, :map, default: %{}
  # When true, the value links to this actor's filtered audit view
  # (`?actor_id=…`) — "what did this identity do" — instead of the
  # actor's own resource page. Used for the actor column.
  attr :audit_link?, :boolean, default: false
  # When true, render human-first: an api_key/MCP actor leads with its owner
  # and shows the key/client on a second muted line (the Actor card, not targets).
  attr :actor?, :boolean, default: false
  attr :current_account, :map, required: true

  def ref(%{kind: nil} = assigns), do: ~H[<span class="text-sm leading-5 text-zinc-500">—</span>]

  # System/scheduler/runbook actors don't have an identifying row in
  # another table — render them as a clean label without a colon-id
  # pair (which would be `system: —`).
  def ref(%{kind: kind, id: nil} = assigns) when kind in ["system", "scheduler", "runbook"] do
    assigns = assign(assigns, :label_text, kindless_label(kind))

    ~H"""
    <span class="text-sm leading-5 text-zinc-300">{@label_text}</span>
    """
  end

  def ref(assigns) do
    {text, via} =
      if assigns.actor?,
        do: actor_who_via(assigns.kind, assigns.id, assigns.label, assigns.refs),
        else: {resolve_label(assigns.refs, assigns.kind, assigns.id, assigns.label), nil}

    title = if via, do: "#{assigns.kind}: #{text} · via #{via}", else: "#{assigns.kind}: #{text}"
    assigns = assign(assigns, text: text, via: via, title: title, href: ref_href(assigns))

    ~H"""
    <%!-- The accountable identity owns the first line. For an api_key actor,
         its key/client gets a second muted line instead of competing inside the
         same truncating sentence. The full forensic relationship stays in the
         hover title. Targets have no secondary line and retain the compact shape. --%>
    <div class="min-w-0 max-w-full" title={@title}>
      <span class="block break-words text-sm leading-5 text-zinc-300" data-audit-primary>
        <%= if @href do %>
          <%!-- Neutral value, emerald on hover — emerald is the pass/accent token,
               not a generic link color, so a green value always means "succeeded". --%>
          <.link navigate={@href} class="text-zinc-300 hover:text-brand-300">{@text}</.link>
        <% else %>
          {@text}
        <% end %>
      </span>
      <span
        :if={@via}
        class="mt-0.5 block break-words text-xs leading-4 text-zinc-500"
        data-audit-secondary
      >
        {@via}
      </span>
    </div>
    """
  end

  defp kindless_label("system"), do: "System"
  defp kindless_label("scheduler"), do: "Scheduler"
  defp kindless_label("runbook"), do: "Runbook"

  @doc """
  Outcome → house tone for the audit event's `<.status_dot>` — failures `:rose`,
  denials/removals `:amber`, pass verdicts `:brand`, routine events `:neutral`.
  Keyed off `Audit.Event.Query.outcome/1` so the dot + the "Severity" filter
  never disagree. Public because the detail page's title dot must match the
  list (same sharing mechanism as `ref/1`).
  """
  def outcome_tone(event_type) do
    case Audit.Event.Query.outcome(event_type) do
      :danger -> :rose
      :warn -> :amber
      :pass -> :brand
      :neutral -> :neutral
    end
  end

  # Tint the event title by outcome so the rows an operator hunts for — a failure
  # (rose), a denial/removal/expiry (amber) — pop out of a wall of routine sign-ins
  # (which stay neutral zinc). The title carries the color, not just the 2px dot,
  # so the signal reads at a glance without making every row loud.
  # Pass verdicts keep the neutral title ON PURPOSE: the brand dot already says
  # "the gate said yes", and an agent ripping through fifty successful runs
  # must not paint the trail green — problems shout (dot + title), passes nod
  # (dot only), routine stays silent.
  defp event_title_class(event_type) do
    case Audit.Event.Query.outcome(event_type) do
      :danger -> "font-medium text-rose-200"
      :warn -> "text-amber-200"
      :pass -> "text-zinc-200"
      :neutral -> "text-zinc-200"
    end
  end

  # Look up the live label from `refs` first (the freshest); fall back
  # to the label that was stamped on the event at write time; finally
  # to a short slice of the UUID. The event might predate any rename,
  # and the underlying record might have been deleted.
  defp resolve_label(refs, kind, id, fallback_label) do
    live = kind && id && refs |> Map.get(kind, %{}) |> Map.get(id)

    cond do
      live -> live
      fallback_label && fallback_label != "" -> fallback_label
      is_binary(id) -> String.slice(id, 0, 8)
      true -> "—"
    end
  end

  # From/To now live in `filters`, so the shared LiveTable check covers them;
  # actor_id is the one filter outside the bar (set by a row click), so it's
  # tested explicitly.
  defp any_filter_active?(params, filters),
    do: blank_to_nil(params["actor_id"]) != nil or LiveTable.has_active_filters?(params, filters)

  # The pivot carries the KIND too: the facet panel's dynamic Actor picker only
  # exists under a kind, and it (highlighted + counted, panel auto-opened) is
  # the pivot's ONE visible control now — the old dismissable chip died.
  defp ref_href(%{audit_link?: true, kind: kind, id: id, current_account: account})
       when not is_nil(id),
       do: ~p"/app/#{account}/audit?#{[actor_kind: kind, actor_id: id]}"

  defp ref_href(%{kind: kind, id: id, current_account: account}), do: ref_path(account, kind, id)

  defp ref_path(account, "runner", id) when is_binary(id), do: ~p"/app/#{account}/runners/#{id}"
  # "action_run" targets exist only on HISTORICAL rows (run events now target
  # the runner and carry the run in payload); the trail renders history as
  # written, so the branch stays.
  defp ref_path(account, "action_run", id) when is_binary(id), do: ~p"/app/#{account}/runs/#{id}"

  defp ref_path(account, "approval_request", id) when is_binary(id),
    do: ~p"/app/#{account}/approvals/#{id}"

  # Runbooks have an edit route but no detail page; route to the edit
  # page so the operator can see the current state of the runbook the
  # event references.
  defp ref_path(account, "runbook", id) when is_binary(id),
    do: ~p"/app/#{account}/runbooks/#{id}/edit"

  defp ref_path(account, "policy", _id), do: ~p"/app/#{account}/policies"
  defp ref_path(account, "account", _id), do: ~p"/app/#{account}/settings/team"
  defp ref_path(account, "enrollment_key", _id), do: ~p"/app/#{account}/runners/keys"
  defp ref_path(account, "api_key", _id), do: ~p"/app/#{account}/agents"
  defp ref_path(account, "approval_grant", _id), do: ~p"/app/#{account}/approvals"
  defp ref_path(account, "user", _id), do: ~p"/app/#{account}/settings/team"
  defp ref_path(_account, _, _), do: nil
end
