defmodule EmisarWeb.AuditLive do
  @moduledoc """
  Append-only audit log list. Actor + subject columns resolve their
  display labels in a single batched pass (`Audit.resolve_references/1`)
  and render as links into the relevant detail page when one exists.
  Click a row to drill into the full event (payload, IP, user agent,
  request id) at `/app/audit/:id`.
  """
  use EmisarWeb, :live_view
  alias Emisar.{ApiKeys, Audit}
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
    preserved = Map.take(socket.assigns.filter_params, ["actor_id"])
    merged = Map.merge(preserved, params)

    # Switching the actor kind invalidates a previously-picked actor (its id
    # belongs to the old kind), so drop it — else the new kind's picker reads
    # "All" while the stale id quietly filters to nothing. Normalize blank/nil
    # so an unrelated change doesn't drop a click-to-filter actor_id.
    merged =
      if blank_to_nil(params["actor_kind"]) !=
           blank_to_nil(socket.assigns.filter_params["actor_kind"]),
         do: Map.delete(merged, "actor_id"),
         else: merged

    # Same for the subject picker — a changed subject kind invalidates its pick.
    merged =
      if blank_to_nil(params["subject_kind"]) !=
           blank_to_nil(socket.assigns.filter_params["subject_kind"]),
         do: Map.delete(merged, "subject_id"),
         else: merged

    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/audit", merged)}
  end

  def handle_event("preset", %{"window" => window}, socket) do
    # Quick relative-range chips set :from to (now − window) and clear :to, so
    # "Last 24h" is the last 24h up to NOW (a stale upper bound would make it a
    # weird window). Whitelisted window → an unknown (crafted) value is a no-op,
    # never a crash or an arbitrary bound. Other active filters are preserved.
    case preset_from(window) do
      nil ->
        {:noreply, socket}

      from ->
        merged = socket.assigns.filter_params |> Map.put("from", from) |> Map.delete("to")

        {:noreply,
         LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/audit", merged)}
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
    with kind when is_binary(kind) <- blank_to_nil(params["actor_kind"]),
         {:ok, [_ | _] = options} <- Audit.list_actor_options(kind, subject) do
      [Audit.Event.Query.actor_filter(options)]
    else
      _ -> []
    end
  end

  # Same shape for the Subject column: when a subject kind is selected, surface a
  # "filter by subject" picker for that kind (its distinct subjects in the log).
  defp subject_kind_filter(params, subject) do
    with kind when is_binary(kind) <- blank_to_nil(params["subject_kind"]),
         {:ok, [_ | _] = options} <- Audit.list_subject_options(kind, subject) do
      [Audit.Event.Query.subject_filter(options)]
    else
      _ -> []
    end
  end

  defp load(socket, params) do
    # Request ID + Sign-in method only apply to some event types — drop them
    # when the selected Type can't carry them (or none is set), so the filter
    # panel shows only filters that can actually narrow the log.
    base_filters =
      Audit.Event.Query.applicable_filters(Audit.Event.Query.filters(), params["event_type"])

    # Render each dynamic picker right after its kind filter (the dependent
    # control belongs next to its trigger), not tacked on at the end.
    # base_filters stays the opts source; the actor/subject pickers are
    # render-only — actor_id/subject_id apply via the opts path below.
    subject = socket.assigns.current_subject
    actor_filter = actor_kind_filter(params, subject)
    subject_filter = subject_kind_filter(params, subject)

    filters =
      Enum.flat_map(base_filters, fn
        %{name: :actor_kind} = f -> [f | actor_filter]
        %{name: :subject_kind} = f -> [f | subject_filter]
        f -> [f]
      end)

    actor_id = blank_to_nil(params["actor_id"])
    subject_id = blank_to_nil(params["subject_id"])

    # actor_id rides as a URL param outside the form (set by clicking a row's
    # actor); subject_id is set by its dynamic picker. Both aren't in
    # base_filters, so they're threaded into list_events directly. From/To are
    # LiveTable datetime filters — params_to_opts applies them via :filter.
    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_params, params)
      |> assign(:active_facet_count, LiveTable.count_active_filters(params, filters))
      |> assign(:actor_id, actor_id)
      |> assign(:subject_id, subject_id)

    opts =
      params
      |> LiveTable.params_to_opts(base_filters)
      |> Keyword.merge(actor_id: actor_id, subject_id: subject_id)

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
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:audit}
      width={:full}
    >
      <:title>Audit log</:title>
      <%!-- Sub-feature side door — streaming config is its own page; its entry
           rides the TITLE row (the pattern for a page's secondary surface),
           not the intro prose and never below the rows. --%>
      <:actions :if={ApiKeys.subject_can_manage_api_keys?(@current_subject)}>
        <%!-- :md, not :sm — a control on the 28px title row needs the full-size
             button to hold its own beside the H1. --%>
        <.button
          variant={:secondary}
          size={:md}
          navigate={~p"/app/#{@current_account}/audit/export"}
        >
          Stream to SIEM
        </.button>
      </:actions>

      <.page_intro>
        The append-only record of every action, approval, and access change in this account —
        exportable to your SIEM for independent, long-term retention.
        <.doc_link href="/docs/audit-and-siem">Audit log docs</.doc_link>
      </.page_intro>

      <%!-- Quick relative-range presets — set the unified bar's From to
           (now − window); the date filter below consumes it. Re-adds the
           presets the date-unification dropped, without a second bar. --%>
      <div class="mb-4 flex flex-wrap items-center gap-1.5 text-xs">
        <span class="text-zinc-500">Quick filters:</span>
        <button
          :for={{label, window} <- audit_presets()}
          type="button"
          phx-click="preset"
          phx-value-window={window}
          class="rounded-md bg-zinc-900 px-2 py-1 font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-800 hover:text-zinc-100"
        >
          {label}
        </button>
        <%!-- One-click "only the events that went wrong" — denials, removals, and
             failures (the danger+warn severities) — so the rows an operator hunts
             for surface out of a wall of routine sign-ins, without hand-building
             the Severity filter. Toggles the filter the panel already exposes. --%>
        <button
          type="button"
          phx-click="toggle_problems"
          aria-pressed={to_string(problems_only?(@filter_params))}
          class={[
            "rounded-md px-2 py-1 font-medium ring-1 transition",
            if(problems_only?(@filter_params),
              do: "bg-rose-500/15 text-rose-200 ring-rose-500/40",
              else: "bg-zinc-900 text-zinc-300 ring-zinc-800 hover:bg-zinc-800 hover:text-zinc-100"
            )
          ]}
        >
          Problems only
        </button>
        <%!-- The facet panel toggle. The active-facet count rides the label
             ("Filters · 2") so a CLOSED panel still says filters are narrowing
             the list — collapsing controls must never hide the fact that the
             trail is filtered. Brand tint = the active-filter convention. --%>
        <button
          type="button"
          phx-click="toggle_filters"
          aria-expanded={to_string(@filters_open?)}
          class={[
            "inline-flex items-center gap-1.5 rounded-md px-2 py-1 font-medium ring-1 transition",
            if(@active_facet_count > 0 or @filters_open?,
              do: "bg-brand-500/10 text-brand-300 ring-brand-500/40",
              else: "bg-zinc-900 text-zinc-300 ring-zinc-800 hover:bg-zinc-800 hover:text-zinc-100"
            )
          ]}
        >
          Filters<span
            :if={@active_facet_count > 0}
            class="tabular-nums"
          >· {@active_facet_count}</span>
        </button>
      </div>

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
        wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
        group_by={&DateTime.to_date(&1.occurred_at)}
      >
        <%!-- Column headers for the xl+ forensic grid — the SAME template as
             the rows so labels sit over their values; below xl the columns
             fold into the meta line and the header folds with them. --%>
        <:list_header>
          <li class="hidden py-2 xl:grid xl:grid-cols-[minmax(0,1fr)_11rem_11rem_7.5rem_5.5rem] xl:gap-4">
            <span class={audit_column_header_class()}>Event</span>
            <span class={audit_column_header_class()}>Actor</span>
            <span class={audit_column_header_class()}>Target</span>
            <span class={audit_column_header_class()}>Source IP</span>
            <span class={[audit_column_header_class(), "text-right"]}>When</span>
          </li>
        </:list_header>
        <:group_header :let={date}>
          <li class="pb-1.5 pt-5 first:pt-3">
            <span class="text-[11px] font-medium uppercase tracking-wider text-zinc-500">
              <span class="tabular-nums">{Date.to_iso8601(date)}</span>
              · {Calendar.strftime(date, "%A")} · UTC
            </span>
          </li>
        </:group_header>
        <:item :let={event}>
          <li id={"event-#{event.id}"}>
            <%!-- One row, two densities. Below xl: the folded who→what·pairs·ip
                 meta line. From xl: the forensic COLUMNS a reviewer scans down —
                 Actor (who did it), Target (what it acted on), Source IP (from
                 where) — with the payload pairs staying under the event label.
                 Time is relative for humans; the hook's tooltip carries the
                 absolute stamp with timezone for the record. --%>
            <.link
              navigate={~p"/app/#{@current_account}/audit/#{event.id}"}
              class="-mx-2 flex items-start gap-3 rounded-md px-2 py-3 transition hover:bg-white/[0.04] xl:grid xl:grid-cols-[minmax(0,1fr)_11rem_11rem_7.5rem_5.5rem] xl:items-center xl:gap-4"
            >
              <div class="flex min-w-0 flex-1 items-start gap-3 xl:flex-auto">
                <.status_dot tone={outcome_tone(event.event_type)} size={:md} class="mt-1" />
                <div class="min-w-0 flex-1">
                  <div class={["text-sm leading-5", event_title_class(event.event_type)]}>
                    {format_event_type(event.event_type)}
                  </div>
                  <div class="truncate text-xs text-zinc-500 xl:hidden">
                    {event_meta(event, @refs)}
                  </div>
                  <div
                    :if={pairs_text(event) != ""}
                    class="hidden truncate text-xs text-zinc-500 xl:block"
                  >
                    {pairs_text(event)}
                  </div>
                </div>
              </div>
              <.audit_cell value={
                party_text(event.actor_kind, event.actor_id, event.actor_label, @refs)
              } />
              <.audit_cell value={subject_text(event, @refs)} />
              <.audit_cell value={event.ip_address} mono />
              <.local_time
                value={event.occurred_at}
                mode={:relative}
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
                variant={:bare}
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
              <.empty_state variant={:bare} icon="hero-document-text" title="No audit events yet.">
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

  defp audit_column_header_class,
    do: "text-[11px] font-medium uppercase tracking-wider text-zinc-500"

  attr :value, :string, default: nil
  attr :mono, :boolean, default: false

  # An xl+ forensic column cell (Actor / Target / Source IP). An empty cell
  # renders the muted em-dash on its own span — never the value's styling.
  defp audit_cell(assigns) do
    ~H"""
    <div class="hidden min-w-0 xl:block">
      <span
        :if={@value}
        class={["block truncate text-xs text-zinc-400", @mono && "font-mono tabular-nums"]}
        title={@value}
      >
        {@value}
      </span>
      <span :if={!@value} class="text-xs text-zinc-600">—</span>
    </div>
    """
  end

  # One quiet meta STRING per event — the accountable identity by name (the
  # kind prefix + the generic ACTOR/SUBJECT/IP columns died with the grid),
  # then "→ subject" only when the event acted ON something other than its
  # actor (a sign-in acts on itself; a role change acts on a teammate), then
  # the payload's notable pairs, then the source IP. Plain text on purpose:
  # the row's one link is the row itself (→ the event detail).
  defp event_meta(event, refs) do
    # Actor and its subject bind into ONE "who → what" segment (a middot
    # between them read as two unrelated facts); the arrow appears only when
    # the event acted on something other than its actor.
    who =
      [
        party_text(event.actor_kind, event.actor_id, event.actor_label, refs),
        subject_text(event, refs)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" → ")

    [blank_to_nil(who), blank_to_nil(pairs_text(event)), event.ip_address]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # "via magic_link" reads as prose; every other pair stays forensic "k: v".
  defp pairs_text(event) do
    AuditSummary.summary_pairs(event)
    |> Enum.map_join(" · ", fn {k, v} -> if(k == "via", do: "via #{v}", else: "#{k}: #{v}") end)
  end

  defp subject_text(event, refs) do
    if event.subject_kind == event.actor_kind and event.subject_id == event.actor_id,
      do: nil,
      else: party_text(event.subject_kind, event.subject_id, event.subject_label, refs)
  end

  defp party_text(nil, _id, _label, _refs), do: nil

  defp party_text(kind, nil, _label, _refs) when kind in ["system", "scheduler", "runbook"],
    do: kindless_label(kind)

  defp party_text(kind, id, label, refs), do: resolve_label(refs, kind, id, label)

  # -- Reference rendering (shared with AuditDetailLive) ---------------

  attr :kind, :string, default: nil
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :refs, :map, default: %{}
  # When true, the value links to this actor's filtered audit view
  # (`?actor_id=…`) — "what did this identity do" — instead of the
  # actor's own resource page. Used for the actor column.
  attr :audit_link?, :boolean, default: false
  attr :current_account, :map, required: true

  def ref(%{kind: nil} = assigns), do: ~H[<span class="text-xs text-zinc-500">—</span>]

  # System/scheduler/runbook actors don't have an identifying row in
  # another table — render them as a clean label without a colon-id
  # pair (which would be `system: —`).
  def ref(%{kind: kind, id: nil} = assigns) when kind in ["system", "scheduler", "runbook"] do
    assigns = assign(assigns, :label_text, kindless_label(kind))

    ~H"""
    <span class="text-xs text-zinc-300">{@label_text}</span>
    """
  end

  def ref(assigns) do
    assigns =
      assign(assigns,
        text: resolve_label(assigns.refs, assigns.kind, assigns.id, assigns.label),
        href: ref_href(assigns)
      )

    ~H"""
    <%!-- One truncating line: a short actor (email/name) shows in full; a long
         unresolved value (e.g. an approval_request UUID) ellipsis-clips instead of
         wrapping to 2-3 lines. The full value is on hover via title. --%>
    <span class="block max-w-[16rem] truncate text-xs text-zinc-400" title={"#{@kind}: #{@text}"}>
      <%!-- The "kind:" prefix is a plain label — only the value links. --%>
      <span class="text-zinc-500">{@kind}:</span>
      <%= if @href do %>
        <%!-- Neutral value, emerald on hover — emerald is the pass/accent token,
             not a generic link color, so a green value always means "succeeded". --%>
        <.link navigate={@href} class="text-zinc-300 hover:text-brand-300">{@text}</.link>
      <% else %>
        {@text}
      <% end %>
    </span>
    """
  end

  defp kindless_label("system"), do: "System"
  defp kindless_label("scheduler"), do: "Scheduler"
  defp kindless_label("runbook"), do: "Runbook"

  @doc """
  Outcome → house tone for the audit event's `<.status_dot>` — failures `:rose`,
  denials/removals `:amber`, routine events `:neutral`. Keyed off
  `Audit.Event.Query.outcome/1` so the dot + the "Outcome" filter never
  disagree. Public because the detail page's title dot must match the list
  (same sharing mechanism as `ref/1`).
  """
  def outcome_tone(event_type) do
    case Audit.Event.Query.outcome(event_type) do
      :danger -> :rose
      :warn -> :amber
      :neutral -> :neutral
    end
  end

  # Tint the event title by outcome so the rows an operator hunts for — a failure
  # (rose), a denial/removal/expiry (amber) — pop out of a wall of routine sign-ins
  # (which stay neutral zinc). The title carries the color, not just the 2px dot,
  # so the signal reads at a glance without making every row loud.
  defp event_title_class(event_type) do
    case Audit.Event.Query.outcome(event_type) do
      :danger -> "font-medium text-rose-200"
      :warn -> "text-amber-200"
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
  defp ref_path(account, "auth_key", _id), do: ~p"/app/#{account}/settings/runners/auth-keys"
  defp ref_path(account, "api_key", _id), do: ~p"/app/#{account}/settings/agents"
  defp ref_path(account, "approval_grant", _id), do: ~p"/app/#{account}/approvals"
  defp ref_path(account, "user", _id), do: ~p"/app/#{account}/settings/team"
  defp ref_path(_account, _, _), do: nil
end
