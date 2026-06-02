defmodule EmisarWeb.AuditLive do
  @moduledoc """
  Append-only audit log list. Actor + subject columns resolve their
  display labels in a single batched pass (`Audit.resolve_references/1`)
  and render as links into the relevant detail page when one exists.
  Click a row to drill into the full event (payload, IP, user agent,
  request id) at `/app/audit/:id`.
  """
  use EmisarWeb, :live_view

  alias Emisar.{ApiKeys, Audit, PubSub}
  alias Emisar.Audit.Event
  alias EmisarWeb.{AuditSummary, LiveTable, Permissions, UrlHelpers}

  def mount(_params, _session, socket) do
    # Audit log is the canonical "what just happened" surface — any
    # mutation that commits an `Audit.Event` row in the same multi gets
    # auto-broadcast by `Repo.commit_multi`, so subscribing here is
    # enough to make the list fully live without per-domain plumbing.
    if connected?(socket) do
      PubSub.subscribe_account_audit(socket.assigns.current_account.id)
      # Live SIEM-token list too — minting/revoking on this page flows
      # via api_key.* broadcasts.
      PubSub.subscribe_account_api_keys(socket.assigns.current_account.id)
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

  def handle_event("revoke_export_key", %{"id" => id}, socket) do
    Permissions.gated(socket, :manage_api_keys, fn s ->
      case ApiKeys.fetch_api_key_by_id(id, s.assigns.current_subject) do
        {:ok, key} ->
          {:ok, _} = ApiKeys.revoke_api_key(key, s.assigns.current_subject)
          {:noreply, s |> put_flash(:info, "Export token revoked.") |> assign_export_keys()}

        {:error, _} ->
          {:noreply, s}
      end
    end)
  end

  def handle_event("create_export_key", _params, socket) do
    # Audit-export keys are admin-only AND distinct from MCP keys:
    # they carry `audit:read` (not `actions:*`), expose `/api/audit`,
    # and live on the audit page rather than the agents page so the
    # SIEM-export use case isn't mixed in with the LLM-bridge one.
    Permissions.gated(socket, :manage_api_keys, fn s ->
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
    end)
  end

  def handle_event("dismiss_export_secret", _params, socket),
    do: {:noreply, assign(socket, :export_secret, nil)}

  defp assign_export_keys(socket) do
    case ApiKeys.list_audit_export_keys_for_account(socket.assigns.current_subject, page_size: 50) do
      {:ok, keys, _meta} -> assign(socket, :export_keys, keys)
      _ -> assign(socket, :export_keys, [])
    end
  end

  defp load(socket, params) do
    filters = Event.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Audit.list_events(socket.assigns.current_subject, opts) do
      {:ok, events, meta} ->
        refs = Audit.resolve_references(events)

        socket
        |> assign(:events, events)
        |> assign(:metadata, meta)
        |> assign(:refs, refs)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      {:error, _} ->
        load(socket, %{})
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:audit}
    >
      <:title>Audit log</:title>

      <LiveTable.live_table
        id="audit-events"
        path={~p"/app/audit"}
        rows={@events}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={@filters}
        row_id={fn ev -> "ev-#{ev.id}" end}
        row_click={fn ev -> JS.navigate(~p"/app/audit/#{ev.id}") end}
      >
        <:col :let={ev} label="When" class="w-40">
          <.local_time value={ev.occurred_at} class="text-xs text-zinc-400" />
        </:col>
        <:col :let={ev} label="Event">
          <div class="text-sm text-zinc-200">{format_event_type(ev.event_type)}</div>
          <div class="font-mono text-[10px] text-zinc-500">{ev.event_type}</div>
          <.event_summary :let={pair} pairs={AuditSummary.summary_pairs(ev)}>
            <span class="font-mono text-zinc-400">{elem(pair, 0)}:</span>
            <span class="text-zinc-300">{elem(pair, 1)}</span>
          </.event_summary>
        </:col>
        <:col :let={ev} label="Actor">
          <.ref kind={ev.actor_kind} id={ev.actor_id} label={ev.actor_label} refs={@refs} />
        </:col>
        <:col :let={ev} label="Subject">
          <.ref kind={ev.subject_kind} id={ev.subject_id} label={ev.subject_label} refs={@refs} />
        </:col>
        <:col :let={ev} label="IP" class="w-32">
          <span class="font-mono text-xs text-zinc-500">{ev.ip_address || "—"}</span>
        </:col>
        <:empty>
          <%!-- Filter-active stays a one-liner so it doesn't dominate
               when the operator is just over-filtering. Empty-account
               state gets richer copy that names the surfaces that
               actually produce events. --%>
          <%= if any_filter_active?(@filter_params, @filters) do %>
            <span class="text-zinc-500">No events match these filters.</span>
          <% else %>
            <div class="mx-auto max-w-md">
              <.icon name="hero-document-text" class="mx-auto h-8 w-8 text-zinc-700" />
              <p class="mt-3 text-zinc-300">No audit events yet.</p>
              <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                They appear as soon as something happens — a
                <.link navigate={~p"/app/runners"} class="text-indigo-400 hover:text-indigo-300">runner</.link>
                connects, an operator dispatches a
                <.link navigate={~p"/app/runs"} class="text-indigo-400 hover:text-indigo-300">run</.link>,
                an approval is decided, or a pack is observed on the
                <.link navigate={~p"/app/packs"} class="text-indigo-400 hover:text-indigo-300">Packs page</.link>.
              </p>
            </div>
          <% end %>
        </:empty>
      </LiveTable.live_table>

      <%!-- SIEM-export panel rendered AFTER the table so the audit log
           itself leads the page. Admin-only `audit:read` tokens live
           here, not on the Agents page (which is for LLM bridges).
           Lists existing tokens with revoke + the mint affordance. --%>
      <section
        :if={Permissions.can?(assigns, :manage_api_keys)}
        id="siem-export"
        class="mt-8 overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
      >
        <header class="flex flex-wrap items-start justify-between gap-3 px-5 py-3">
          <div>
            <h2 class="text-sm font-semibold text-zinc-100">SIEM export</h2>
            <p class="mt-0.5 text-xs leading-relaxed text-zinc-500">
              Stream audit events as NDJSON to your SIEM. Mint an
              <code class="font-mono text-zinc-300">audit:read</code>
              token below, then point your collector at
              <code class="font-mono text-zinc-300">{@base_audit_url}</code>.
            </p>
          </div>
          <button
            :if={is_nil(@export_secret)}
            type="button"
            phx-click="create_export_key"
            class="shrink-0 rounded-lg border border-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-200 hover:bg-zinc-900"
          >
            <.icon name="hero-key" class="mr-1 inline h-3.5 w-3.5" /> Mint export token
          </button>
        </header>

        <%!-- One-shot reveal. The raw secret only ever exists in the
             socket assigns — refreshing the page hides it for good,
             same one-time-use pattern as the agents page snippets. --%>
        <div
          :if={@export_secret}
          class="border-t border-amber-500/30 bg-amber-500/[0.05] px-5 py-4"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-information-circle" class="mt-0.5 h-4 w-4 flex-none text-amber-300" />
            <div class="min-w-0 flex-1">
              <p class="text-xs font-semibold text-amber-100">
                Copy this token now — we won't show it again.
              </p>
              <div class="mt-2 overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
                <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-3 py-2">
                  <p class="font-mono text-[10px] text-zinc-500">audit:read token</p>
                  <button
                    type="button"
                    id="copy-export-token"
                    class="rounded bg-zinc-800/80 px-2 py-0.5 text-[11px] font-medium text-zinc-200 hover:bg-zinc-700"
                    onclick="const el = document.getElementById('export-token'); navigator.clipboard.writeText(el.textContent.trim()); const orig = this.innerText; this.innerText = 'Copied'; setTimeout(() => { this.innerText = orig; }, 1500);"
                  >
                    Copy
                  </button>
                </div>
                <pre
                  id="export-token"
                  class="overflow-x-auto p-3 font-mono text-xs leading-5 text-zinc-200 break-all"
                ><%= @export_secret %></pre>
              </div>
              <p class="mt-2 text-[11px] text-zinc-500">
                Use with: <code class="font-mono text-zinc-300">curl -H "Authorization: Bearer &lt;token&gt;" {@base_audit_url}</code>
              </p>
            </div>
            <button
              type="button"
              phx-click="dismiss_export_secret"
              class="shrink-0 text-xs font-medium text-zinc-400 hover:text-zinc-200"
            >
              Dismiss
            </button>
          </div>
        </div>

        <%!-- Existing export tokens — listed with revoke. The agents
             page filters these out so SIEM-export tokens live here
             exclusively. --%>
        <div :if={@export_keys != []} class="border-t border-zinc-900">
          <ul class="divide-y divide-zinc-900">
            <li :for={key <- @export_keys} class="flex items-start gap-4 px-5 py-3">
              <span class="grid h-7 w-7 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                <.icon name="hero-document-text" class="h-3.5 w-3.5" />
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="truncate text-sm font-medium text-zinc-100">{key.name}</span>
                  <span class="inline-flex items-center rounded-md bg-indigo-500/10 px-1.5 py-0.5 font-mono text-[10px] text-indigo-200 ring-1 ring-indigo-500/30">
                    audit:read
                  </span>
                  <span
                    :if={key.revoked_at}
                    class="inline-flex items-center rounded-md bg-rose-500/10 px-1.5 py-0.5 text-[10px] text-rose-200 ring-1 ring-rose-500/30"
                  >
                    Revoked
                  </span>
                </div>
                <div class="mt-0.5 truncate font-mono text-[11px] text-zinc-500">
                  {key.key_prefix}… · last used {last_used(key.last_used_at)}
                  <span :if={key.created_by}>· by {key.created_by.email}</span>
                </div>
              </div>
              <button
                :if={is_nil(key.revoked_at)}
                phx-click="revoke_export_key"
                phx-value-id={key.id}
                data-confirm="Revoke this export token? Any active SIEM collector using it will start receiving 401s."
                class="shrink-0 rounded-lg border border-rose-500/40 px-2.5 py-1 text-xs font-medium text-rose-200 hover:bg-rose-500/10"
              >
                Revoke
              </button>
            </li>
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
        href: ref_path(assigns.kind, assigns.id)
      )

    ~H"""
    <%= if @href do %>
      <.link navigate={@href} class="text-xs text-indigo-300 hover:text-indigo-200">
        <span class="text-zinc-500">{@kind}:</span> {@text}
      </.link>
    <% else %>
      <span class="text-xs text-zinc-400">
        <span class="text-zinc-500">{@kind}:</span> {@text}
      </span>
    <% end %>
    """
  end

  defp kindless_label("system"), do: "System"
  defp kindless_label("scheduler"), do: "Scheduler"
  defp kindless_label("runbook"), do: "Runbook"

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

  defp any_filter_active?(params, filters) do
    Enum.any?(filters, fn f ->
      case Map.get(params, to_string(f.name)) do
        nil -> false
        "" -> false
        _ -> true
      end
    end)
  end

  defp ref_path("runner", id) when is_binary(id), do: ~p"/app/runners/#{id}"
  defp ref_path("action_run", id) when is_binary(id), do: ~p"/app/runs/#{id}"
  defp ref_path("approval_request", id) when is_binary(id), do: ~p"/app/approvals/#{id}"
  # Runbooks have an edit route but no detail page; route to the edit
  # page so the operator can see the current state of the runbook the
  # event references.
  # Runbooks have an edit route but no detail page; route to the edit
  # page so the operator can see the current state of the runbook the
  # event references.
  defp ref_path("runbook", id) when is_binary(id), do: ~p"/app/runbooks/#{id}/edit"
  defp ref_path("policy", _id), do: ~p"/app/policies"
  defp ref_path("account", _id), do: ~p"/app/settings/team"
  defp ref_path("auth_key", _id), do: ~p"/app/settings/runners/auth-keys"
  defp ref_path("api_key", _id), do: ~p"/app/agents"
  defp ref_path("approval_grant", _id), do: ~p"/app/approvals"
  defp ref_path("user", _id), do: ~p"/app/settings/team"
  defp ref_path(_, _), do: nil
end
