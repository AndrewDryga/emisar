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
  alias EmisarWeb.{AuditSummary, LiveTable, Permissions, UrlHelpers}

  def mount(_params, _session, socket) do
    # Audit log is the canonical "what just happened" surface — any
    # mutation that commits an `Audit.Event` row in the same multi gets
    # auto-broadcast by `Repo.commit_multi`, so subscribing here is
    # enough to make the list fully live without per-domain plumbing.
    if connected?(socket) do
      Audit.subscribe_account_audit(socket.assigns.current_account.id)
      # Live SIEM-token list too — minting/revoking on this page flows
      # via api_key.* broadcasts.
      ApiKeys.subscribe_account_api_keys(socket.assigns.current_account.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     |> assign(:export_secret, nil)
     |> assign(:base_audit_url, UrlHelpers.derive_base_url(socket) <> "/api/audit")
     |> assign_export_keys()}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info({:audit_event, _event}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info({:list_changed, :api_key, _event_type, _id}, socket),
    do: {:noreply, assign_export_keys(socket)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("revoke_export_key", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      fn s ->
        case ApiKeys.fetch_api_key_by_id(id, s.assigns.current_subject) do
          {:ok, key} ->
            {:ok, _} = ApiKeys.revoke_api_key(key, s.assigns.current_subject)
            {:noreply, s |> put_flash(:info, "Export token revoked.") |> assign_export_keys()}

          {:error, _} ->
            {:noreply, s}
        end
      end
    )
  end

  def handle_event("create_export_key", _params, socket) do
    # Audit-export keys are admin-only AND distinct from MCP keys:
    # they carry `audit:read` (not `actions:*`), expose `/api/audit`,
    # and live on the audit page rather than the agents page so the
    # SIEM-export use case isn't mixed in with the LLM-bridge one.
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      fn s ->
        attrs = %{
          name: "Audit export — #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")}",
          description: "Read-only token for shipping audit events to a SIEM.",
          scopes: ["audit:read"]
        }

        case ApiKeys.create_key(attrs, s.assigns.current_subject) do
          {:ok, raw, _key} ->
            {:noreply, s |> assign(:export_secret, raw) |> assign_export_keys()}

          {:error, _} ->
            {:noreply, put_flash(s, :error, "Could not mint the export key.")}
        end
      end
    )
  end

  def handle_event("dismiss_export_secret", _params, socket),
    do: {:noreply, assign(socket, :export_secret, nil)}

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

  defp assign_export_keys(socket) do
    case ApiKeys.list_audit_export_keys_for_account(socket.assigns.current_subject,
           page_size: 50,
           preload: [:created_by]
         ) do
      {:ok, keys, _meta} -> assign(socket, :export_keys, keys)
      _ -> assign(socket, :export_keys, [])
    end
  end

  # Quick relative-range presets for the audit date filter — re-adds the buttons
  # the date-unification dropped, now setting the unified bar's :from.
  defp audit_presets, do: [{"Last hour", "1h"}, {"Last 24h", "24h"}, {"Last 7 days", "7d"}]

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
    base_filters = Audit.Event.Query.filters()

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
      |> assign(:actor_id, actor_id)

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
        |> assign(:actor_label, actor_label_for(actor_id, events))

      # A clean reload can fail too (e.g. a tightened list permission) —
      # degrade to an empty page rather than recursing forever.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:events, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:refs, %{})
        |> assign(:actor_label, actor_id)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp actor_label_for(nil, _events), do: nil

  defp actor_label_for(actor_id, events) do
    Enum.find_value(events, actor_id, fn e -> e.actor_id == actor_id && e.actor_label end)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:audit}
    >
      <:title>Audit log</:title>

      <%!-- Row-click "what did X do" chip with a one-click clear. Date range +
           everything else live in the unified LiveTable filter bar below. --%>
      <div
        :if={@actor_id}
        class="mb-4 flex w-max items-center gap-2 rounded-lg bg-indigo-500/10 px-3 py-1.5 text-xs text-indigo-200 ring-1 ring-indigo-500/30"
      >
        <span>Actor: <span class="font-medium">{@actor_label}</span></span>
        <.link
          patch={~p"/app/#{@current_account}/audit?#{Map.drop(@filter_params, ["actor_id"])}"}
          class="font-semibold text-indigo-300 hover:text-indigo-100"
          aria-label="Clear actor filter"
        >
          ✕
        </.link>
      </div>

      <%!-- Quick relative-range presets — set the unified bar's From to
           (now − window); the date filter below consumes it. Re-adds the
           presets the date-unification dropped, without a second bar. --%>
      <div class="mb-4 flex w-max items-center gap-1.5 text-xs">
        <span class="text-zinc-500">Quick range:</span>
        <button
          :for={{label, window} <- audit_presets()}
          type="button"
          phx-click="preset"
          phx-value-window={window}
          class="rounded-md bg-zinc-900 px-2 py-1 font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-800 hover:text-zinc-100"
        >
          {label}
        </button>
      </div>

      <LiveTable.live_table
        id="audit-events"
        path={~p"/app/#{@current_account}/audit"}
        rows={@events}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={@filters}
        row_id={fn event -> "event-#{event.id}" end}
        row_click={&JS.navigate(~p"/app/#{@current_account}/audit/#{&1.id}")}
      >
        <:col :let={event} label="When" class="w-40">
          <.local_time value={event.occurred_at} class="text-xs text-zinc-400" />
        </:col>
        <:col :let={event} label="Event">
          <div class="flex items-start gap-2">
            <span
              class={["mt-1.5 h-1.5 w-1.5 flex-none rounded-full", tone_dot(event.event_type)]}
              aria-hidden="true"
            >
            </span>
            <div class="min-w-0">
              <div class="text-sm text-zinc-200">{format_event_type(event.event_type)}</div>
              <div class="font-mono text-[10px] text-zinc-500">{event.event_type}</div>
              <.event_summary :let={pair} pairs={AuditSummary.summary_pairs(event)}>
                <span class="font-mono text-zinc-400">{elem(pair, 0)}:</span>
                <span class="text-zinc-300">{elem(pair, 1)}</span>
              </.event_summary>
            </div>
          </div>
        </:col>
        <:col :let={event} label="Actor">
          <.ref
            kind={event.actor_kind}
            id={event.actor_id}
            label={event.actor_label}
            refs={@refs}
            current_account={@current_account}
            audit_link?={true}
          />
        </:col>
        <:col :let={event} label="Subject" class="hidden lg:table-cell">
          <.ref
            kind={event.subject_kind}
            id={event.subject_id}
            label={event.subject_label}
            refs={@refs}
            current_account={@current_account}
          />
        </:col>
        <:col :let={event} label="IP" class="w-32 hidden lg:table-cell">
          <span class="font-mono text-xs text-zinc-500">{event.ip_address || "—"}</span>
        </:col>
        <:empty>
          <%!-- Filter-active stays a one-liner so it doesn't dominate
               when the operator is just over-filtering. Empty-account
               state gets richer copy that names the surfaces that
               actually produce events. --%>
          <%= if any_filter_active?(@filter_params, @filters) do %>
            <span class="text-zinc-500">No events match these filters.</span>
          <% else %>
            <.empty_state variant={:bare} icon="hero-document-text" title="No audit events yet.">
              They appear as soon as something happens — a
              <.link
                navigate={~p"/app/#{@current_account}/runners"}
                class="text-indigo-400 hover:text-indigo-300"
              >
                runner
              </.link>
              connects, an operator dispatches a <.link
                navigate={~p"/app/#{@current_account}/runs"}
                class="text-indigo-400 hover:text-indigo-300"
              >run</.link>,
              an approval is decided, or a pack is observed on the <.link
                navigate={~p"/app/#{@current_account}/packs"}
                class="text-indigo-400 hover:text-indigo-300"
              >Packs page</.link>.
            </.empty_state>
          <% end %>
        </:empty>
      </LiveTable.live_table>

      <%!-- SIEM-export panel rendered AFTER the table so the audit log
           itself leads the page. Admin-only `audit:read` tokens live
           here, not on the LLM agents page (which is for MCP connections).
           Lists existing tokens with revoke + the mint affordance. --%>
      <section
        :if={ApiKeys.subject_can_manage_api_keys?(@current_subject)}
        id="siem-export"
        class="mt-8 overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
      >
        <header class="flex flex-wrap items-start justify-between gap-3 px-5 py-3">
          <div>
            <h2 class="text-sm font-semibold text-zinc-100">SIEM export</h2>
            <p class="mt-0.5 text-xs leading-relaxed text-zinc-500">
              Stream audit events as NDJSON to your SIEM. Mint an
              <code class="font-mono text-zinc-300">audit:read</code>
              token below, then point your collector at <code class="font-mono text-zinc-300">{@base_audit_url}</code>.
            </p>
          </div>
          <.button
            :if={is_nil(@export_secret)}
            variant="secondary"
            size="md"
            class="shrink-0"
            type="button"
            icon="hero-key"
            phx-click="create_export_key"
          >
            Mint export token
          </.button>
        </header>

        <%!-- One-shot reveal. The raw secret only ever exists in the
             socket assigns — refreshing the page hides it for good,
             same one-time-use pattern as the agents page snippets. --%>
        <%!-- The minted token, shown once via the shared <.secret_reveal>
             — the single reviewed shown-once surface (same as agents +
             install), not a third hand-rolled copy. Lives only in socket
             assigns; a refresh hides it for good. --%>
        <.secret_reveal
          :if={@export_secret}
          title="Copy this token now — we won't show it again"
          secret={@export_secret}
          on_dismiss="dismiss_export_secret"
        >
          A read-only <span class="font-mono">audit:read</span>
          token for shipping audit
          events to a SIEM.
          <:install_command label="Use with">
            curl -H "Authorization: Bearer {@export_secret}" {@base_audit_url}
          </:install_command>
        </.secret_reveal>

        <%!-- Existing export tokens — listed with revoke. The agents
             page filters these out so SIEM-export tokens live here
             exclusively. --%>
        <div :if={@export_keys != []} class="border-t border-zinc-900">
          <ul class="divide-y divide-zinc-900">
            <.list_row :for={key <- @export_keys} icon="hero-document-text">
              <:title>
                <span class="truncate text-sm font-medium text-zinc-100">{key.name}</span>
              </:title>
              <:chips>
                <span class="inline-flex items-center rounded-md bg-indigo-500/10 px-1.5 py-0.5 font-mono text-[10px] text-indigo-200 ring-1 ring-indigo-500/30">
                  audit:read
                </span>
                <span
                  :if={key.revoked_at}
                  class="inline-flex items-center rounded-md bg-rose-500/10 px-1.5 py-0.5 text-[10px] text-rose-200 ring-1 ring-rose-500/30"
                >
                  Revoked
                </span>
              </:chips>
              <:meta>
                {key.key_prefix}… · last used{" "}<.local_time
                  value={key.last_used_at}
                  mode={:relative}
                  placeholder="never"
                />
                <span :if={key.created_by}>· by {key.created_by.email}</span>
              </:meta>
              <:actions>
                <.button
                  :if={is_nil(key.revoked_at)}
                  variant="danger"
                  size="sm"
                  class="shrink-0"
                  phx-click="revoke_export_key"
                  phx-value-id={key.id}
                  data-confirm="Revoke this export token? Any active SIEM collector using it will start receiving 401s."
                >
                  Revoke
                </.button>
              </:actions>
            </.list_row>
          </ul>
        </div>
      </section>
    </.dashboard_shell>
    """
  end

  # Inline chip strip used by the list + detail to summarize the
  # "interesting bit" of an event's payload — role from→to, count of
  # sessions revoked, MFA-failed reason, etc. Each pair is rendered
  # inside its own pill via the inner_block. Hidden when the event
  # has no notable summary (most action_run.* terminal states have
  # already-meaningful labels).
  attr :pairs, :list, default: []
  slot :inner_block, required: true

  def event_summary(assigns) do
    ~H"""
    <div :if={@pairs != []} class="mt-1 flex flex-wrap gap-1.5">
      <span
        :for={pair <- @pairs}
        class="inline-flex items-center gap-1 rounded-md bg-zinc-900/80 px-1.5 py-0.5 text-[10px] ring-1 ring-zinc-800"
      >
        {render_slot(@inner_block, pair)}
      </span>
    </div>
    """
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
    <span class="text-xs text-zinc-400">
      <%!-- The "kind:" prefix is a plain label — only the value links. --%>
      <span class="text-zinc-500">{@kind}:</span>
      <%= if @href do %>
        <.link navigate={@href} class="text-indigo-300 hover:text-indigo-200">{@text}</.link>
      <% else %>
        {@text}
      <% end %>
    </span>
    """
  end

  defp kindless_label("system"), do: "System"
  defp kindless_label("scheduler"), do: "Scheduler"
  defp kindless_label("runbook"), do: "Runbook"

  # Colour for the leading outcome dot in the Event column — failures rose,
  # denials/removals amber, routine events a muted neutral. Keyed off
  # `Audit.Event.Query.outcome/1` so the dot + the "Outcome" filter never disagree.
  defp tone_dot(event_type) do
    case Audit.Event.Query.outcome(event_type) do
      :danger -> "bg-rose-400"
      :warn -> "bg-amber-400"
      :neutral -> "bg-zinc-700"
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

  defp ref_href(%{audit_link?: true, id: id, current_account: account}) when not is_nil(id),
    do: ~p"/app/#{account}/audit?actor_id=#{id}"

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
