defmodule EmisarWeb.RunnerDetailLive do
  use EmisarWeb, :live_view
  alias Emisar.{Catalog, Runners, Runs}
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions, TransportReason, UrlHelpers}

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id
    membership = socket.assigns.current_membership

    case Runners.fetch_runner_by_id(id, socket.assigns.current_subject) do
      # A denied role and a missing runner are indistinguishable — never leak
      # existence, never crash on {:error, :unauthorized}.
      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Runner not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}

      {:ok, runner} ->
        # Per-user runner ACLs (#238): treat out-of-scope as not-found
        # rather than 403 — don't leak the existence of runners the
        # operator's scope doesn't grant access to.
        if Runners.runner_in_scope?(runner, membership) do
          if connected?(socket), do: Runners.subscribe_connections(account_id)

          {:ok,
           socket
           |> assign(:page_title, runner.name)
           |> assign(:base_url, UrlHelpers.derive_base_url(socket))
           |> assign(:runner, runner)
           |> ConfirmDialog.init()}
        else
          {:ok,
           socket
           |> put_flash(:error, "Runner not found.")
           |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
        end
    end
  end

  def handle_params(params, _uri, socket) do
    # mount may have redirected; on the post-redirect cycle the runner won't be
    # in scope so this branch is never reached.
    case socket.assigns[:runner] do
      nil -> {:noreply, socket}
      runner -> {:noreply, load_lists(socket, runner, params)}
    end
  end

  # The paginated actions table + the recent-runs sidebar. Gated on connected?
  # so the two reads run once on the live mount, not also on the dead render
  # (IL-18) — the dead render shows <.loading_state>. Both reads tolerate an
  # {:error, …} (a hand-edited page/filter URL, a permission tightened
  # mid-session) and degrade to empty rather than raising a MatchError that
  # would crash the whole LiveView.
  defp load_lists(socket, runner, params) do
    if connected?(socket) do
      subject = socket.assigns.current_subject

      socket
      |> assign(:loading?, false)
      |> assign(:recent_runs, recent_runs(runner, subject))
      |> load_actions(runner, subject, params)
    else
      assign(socket, :loading?, true)
    end
  end

  defp load_actions(socket, runner, subject, params) do
    filters = action_filters(runner, subject)
    opts = LiveTable.params_to_opts(params, filters)
    socket = assign(socket, :action_filters, filters)

    case Catalog.list_actions_for_runner(runner.id, subject, opts) do
      {:ok, actions, meta} ->
        socket
        |> assign(:actions, actions)
        |> assign(:actions_metadata, meta)
        |> assign(:filter_params, params)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} when map_size(params) > 0 ->
        load_actions(socket, runner, subject, %{})

      {:error, _} ->
        socket
        |> assign(:actions, [])
        |> assign(:actions_metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
    end
  end

  # The action catalog's filters (the LiveTable %Filter{} grammar) with the Pack
  # picker's options injected — the packs THIS runner advertises, resolved per
  # render like the runs page's Runner picker. Search + Risk carry their own
  # static definitions from the Query module.
  defp action_filters(runner, subject) do
    pack_options =
      case Catalog.list_action_pack_options_for_runner(runner.id, subject) do
        {:ok, options} -> options
        _ -> []
      end

    Enum.map(Catalog.RunnerAction.Query.filters(), fn
      %{name: :pack_id} = filter -> %{filter | values: pack_options}
      filter -> filter
    end)
  end

  defp recent_runs(runner, subject) do
    case Runs.list_recent_runs_for_runner(runner.id, subject, page: [limit: 20]) do
      {:ok, recent_runs, _} -> recent_runs
      {:error, _} -> []
    end
  end

  # A runner connected/disconnected somewhere in the account — re-fetch
  # so the status badge and heartbeat refresh from presence.
  def handle_info(%{event: "presence_diff"}, socket) do
    case Runners.fetch_runner_by_id(socket.assigns.runner.id, socket.assigns.current_subject) do
      {:ok, runner} -> {:noreply, assign(socket, :runner, runner)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # Filtering is a URL patch (handle_params re-runs the catalog read, which is
  # `view_catalog`-gated in the context) — no mutation, so no gate here.
  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/runners/#{socket.assigns.runner.id}",
       params
     )}
  end

  def handle_event("disable", _params, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_runners?(socket.assigns.current_subject),
      fn socket ->
        {:ok, runner} =
          Runners.disable_runner(socket.assigns.runner, socket.assigns.current_subject)

        {:noreply, socket |> put_flash(:info, "Runner disabled.") |> assign(:runner, runner)}
      end
    )
  end

  def handle_event("enable", _params, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_runners?(socket.assigns.current_subject),
      fn socket ->
        case Runners.enable_runner(socket.assigns.runner, socket.assigns.current_subject) do
          {:ok, runner} ->
            {:noreply, socket |> put_flash(:info, "Runner enabled.") |> assign(:runner, runner)}

          {:error, :over_limit, _plan, limit} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Can't enable — you're at your runner limit (#{limit}). Upgrade your plan or remove another runner first."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not enable runner.")}
        end
      end
    )
  end

  def handle_event("delete", _params, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_runners?(socket.assigns.current_subject),
      fn socket ->
        {:ok, _runner} =
          Runners.delete_runner(socket.assigns.runner, socket.assigns.current_subject)

        {:noreply,
         socket
         |> put_flash(:info, "Runner deleted. The host can re-register on next connect.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
      end
    )
  end

  # Typed-confirm state for the "Delete this runner" dialog (UX friction only —
  # `delete` above stays the server gate).
  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

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
      section={:runners}
      width={:table}
    >
      <:title>
        <%!-- Runners / {group} / {name}. The name is a hostname-ish machine id,
             so it renders mono like every identifier-titled detail page. --%>
        <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
        <%!-- The group is CONTEXT, not a link — there's no per-group page and the
             runners list has no group filter, so a link would go nowhere. Render
             it dimmer than the clickable "Runners" so it doesn't read as one. --%>
        <span class="inline-flex items-center text-zinc-500">
          <span class="font-medium">{@runner.group}</span>
          <span class="mx-2 text-zinc-700" aria-hidden="true">/</span>
        </span>
        <span class="font-mono text-lg tracking-tight text-zinc-50 sm:text-xl">{@runner.name}</span>
      </:title>
      <:actions>
        <%!-- This runner's slice of the audit trail (events whose target is it):
             registrations, trust decisions, state changes. A BUTTON — the
             title-row action slot speaks one grammar across detail pages (run
             detail pairs it with Copy id/Cancel; a lone text link here would
             make the same action read differently page to page). --%>
        <.button
          navigate={
            ~p"/app/#{@current_account}/audit?#{[target_kind: "runner", target_id: @runner.id]}"
          }
          variant={:secondary}
          size={:md}
        >
          View activity
        </.button>
      </:actions>

      <%!-- The page owns its own rhythm: ONE space-y-12 wrapper makes the shell's
           space-y-6 a no-op (a single child) and sets a generous 48px between the
           major blocks. A per-block `mt-*` on a shell child can't do this — the
           shell's space-y wins on specificity and collapses every gap but the
           first back to 24px, so the air silently vanishes. Approvals owns its
           rhythm the same way. The `mt-4` is the one gap the wrapper still owns:
           breathing room under the page title before the vital-stats grid (the
           shell starts content tight, right under the title). --%>
      <div class="mt-4 space-y-12">
        <%!-- Identity: the vital-stats grid and the labels/disconnect row are ONE
             block — the row is a hairline continuation of the grid — so they stay
             tight together, above the 48px gap to the next section. --%>
        <div>
          <%!-- Connection facts on the CANVAS — a naked meta row, no island. Status
               leads so the connection state is the first thing the eye lands on.
               ONE row at sm+ (five fields at natural width fit the 7xl column
               with room to spare); phones keep the tidy 2-col grid, where the
               hostname's `wrap` spans both columns so it reads in one line. --%>
          <div class="grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-16">
            <.meta_field label="Status">
              <.status_badge status={connection_status(Runners.connection_state(@runner))} />
            </.meta_field>
            <.meta_field label="Hostname" wrap>
              <.copyable_id :if={@runner.hostname} value={@runner.hostname} class="text-zinc-200" />
              <span :if={!@runner.hostname} class="text-zinc-500">—</span>
            </.meta_field>
            <.meta_field label="Version" wrap>
              <span class="inline-flex items-center gap-2">
                <span class="font-mono text-zinc-200">{@runner.runner_version || "—"}</span>
                <.version_chip
                  kind={:runner}
                  version={@runner.runner_version}
                  id={"runner-version-#{@runner.id}"}
                />
              </span>
            </.meta_field>
            <.meta_field label="Group">
              <span class="truncate text-zinc-200">{@runner.group}</span>
            </.meta_field>
            <%!-- No "Active runs" cell: most actions complete in milliseconds,
                 so a live count is a permanent 0 — dead information. The
                 runners LIST surfaces `action_load` only while it's > 0
                 (a genuinely long-running action), which is the right home. --%>
            <.meta_field label="Last heartbeat">
              <span class="text-zinc-200">
                <.local_time value={heartbeat_at(@runner)} mode={:relative} />
              </span>
            </.meta_field>
          </div>

          <%!-- Why it's down — a status fact that EXPLAINS the Status badge in
               the grid above, so it lives in the connection register right under
               it, NOT tucked beside the identity labels (labels say what the
               runner IS; this says why it dropped). Only while it's down — else
               it's stale noise from the last drop. --%>
          <% disconnect_message = disconnect_message(@runner) %>
          <div
            :if={disconnect_message}
            class="mt-4 flex items-center gap-1.5 text-rose-300/90"
          >
            <.icon name="hero-bolt-slash" class="h-3.5 w-3.5" />
            <span class="text-xs">{disconnect_message}</span>
          </div>

          <%!-- Labels on their own hairline row — identity metadata, not a
               status event; a naked chip strip, not a second bordered band. --%>
          <div
            :if={runner_labels(@runner) != []}
            class="mt-8 flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-zinc-800/70 pt-5"
          >
            <span class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
              Labels
            </span>
            <.chip :for={{k, v} <- runner_labels(@runner)} mono>{k}={v}</.chip>
          </div>

          <.version_upgrade_notice
            id="runner-upgrade"
            kind={:runner}
            scope={:single}
            versions={[@runner.runner_version]}
            base_url={@base_url}
            class="mt-8"
          />

          <%!-- Packs this runner's loader skipped, as it advertised them —
             without this the pack just silently vanishes from the catalog
             while the runner looks healthy. --%>
          <.callout
            :if={@runner.degraded_packs != []}
            id="degraded-packs"
            tone={:amber}
            icon="hero-exclamation-triangle"
            title={degraded_packs_title(@runner.degraded_packs)}
            class="mt-8"
          >
            <div class="space-y-3">
              <p :for={degraded <- @runner.degraded_packs}>
                <span class="font-mono text-zinc-200">{degraded["pack"]}</span>
                <span class="text-zinc-500">— {degraded["reason"]}</span>
              </p>
              <p>
                Reinstall the pack on the host (<code class="rounded bg-black/30 px-1 font-mono text-xs text-zinc-200">emisar pack install &lt;name&gt;</code>) or re-run the installer; the runner
                re-advertises on its next reload.
              </p>
            </div>
          </.callout>
        </div>

        <%!-- A signature-enforcing runner has locked the portal out: it verifies a
           client signature on every run, so operator/runbook/API dispatch from
           here is refused. Surfacing it up top keeps the disabled Run buttons
           below from reading as a bug. --%>
        <%!-- Naked status line on the canvas, not a boxed callout — a note ABOUT
           this runner's posture (it's signed-only), the shield lead carrying
           the brand tint, aligned with everything else below. --%>
        <.status_note
          :if={@runner.enforce_signatures}
          icon="hero-shield-check"
          tone={:brand}
          title="Signed dispatch only"
          primary
        >
          This runner verifies a client signature on every run and refuses unsigned ones, so
          the portal can't dispatch to it. Runs and runbooks must come from an MCP client
          configured with a signing key and certificate — mint them with
          <code class="rounded bg-black/30 px-1 font-mono text-xs text-zinc-200">
            emisar signing init
          </code>
          on the host.
        </.status_note>

        <.loading_state :if={@loading?} />

        <%!-- Advertised actions (the wide column) + recent runs (a freshness
           check beside it) as CANVAS sections. Actions leads in the DOM — it is
           the runner's capabilities, the page's primary job, so a phone (and a
           screen reader) reaches the SEARCHABLE catalog first instead of
           scrolling past 20 recent runs (UI-014); the identity block's Status +
           heartbeat above already answer "is it healthy?". On desktop EXPLICIT
           placement (col-start/row-start) pins both to row 1 so their headers
           sit on the same line, unchanged; `items-start` keeps a short empty
           column from stretching to the tall one. --%>
        <div
          :if={not @loading?}
          class="grid grid-cols-1 gap-x-12 gap-y-12 lg:grid-cols-3 lg:items-start"
        >
          <section class="lg:col-span-2 lg:col-start-1 lg:row-start-1">
            <.section_header title="Advertised actions" count={@actions_metadata.count} />

            <%!-- The catalog runs the shared LiveTable :cards shell so its Search
               + Pack + Risk filters render in the standard bar and the list stays
               paginated — a 58-82-action catalog is undiscoverable as a flat
               scroll. --%>
            <LiveTable.live_table
              layout={:cards}
              id="actions"
              path={~p"/app/#{@current_account}/runners/#{@runner.id}"}
              rows={@actions}
              metadata={@actions_metadata}
              filter_params={@filter_params}
              filters={@action_filters}
              wrapper_class="divide-y divide-zinc-800/70"
            >
              <:item :let={action}>
                <.list_row>
                  <:title>
                    <span class="truncate font-mono text-sm text-zinc-100">{action.action_id}</span>
                  </:title>
                  <:meta :if={action.title}>
                    {action.title}
                  </:meta>
                  <:actions>
                    <.risk_pill risk={action.risk} />
                    <%!-- Dispatch only makes sense when the runner is online AND
                       accepts portal dispatch — otherwise the run sits in
                       `pending` until reconnect, or (for a signature-enforcing
                       runner) the portal can't dispatch at all. Gate the button
                       visually so operators don't queue work that won't run. --%>
                    <%= cond do %>
                      <% not Runs.subject_can_dispatch_run?(@current_subject) -> %>
                        <%!-- Viewers read the catalog; the Run affordance isn't
                           theirs to have (§4 — hidden, not dead). --%>
                        <span></span>
                      <% @runner.enforce_signatures -> %>
                        <%!-- Signed-only: the portal can't dispatch here. aria-disabled
                           (focusable, so the title explains WHY) + the lock icon carry
                           it without relying on color alone (a11y) — not real `disabled`,
                           which drops focus and hides the explanation. --%>
                        <.button
                          size={:sm}
                          variant={:secondary}
                          aria-disabled="true"
                          icon="hero-lock-closed"
                          title="Signed dispatch only — run this from your MCP client; the portal can't dispatch to this runner"
                          class="shrink-0 cursor-not-allowed opacity-60"
                        >
                          Run
                        </.button>
                      <% @runner.online? -> %>
                        <%!-- Secondary: a brand fill per catalog row out-shouts the
                           page's real primary; the row's affordance is enough. --%>
                        <.button
                          navigate={
                            ~p"/app/#{@current_account}/runs/new/#{@runner.id}/#{action.action_id}"
                          }
                          variant={:secondary}
                          size={:sm}
                          class="shrink-0"
                        >
                          Run
                        </.button>
                      <% true -> %>
                        <%!-- Offline: aria-disabled (focusable, title explains why) + a
                           signal-slash icon carry "can't run" without relying on the
                           dimmed color alone (a11y). --%>
                        <.button
                          size={:sm}
                          variant={:secondary}
                          aria-disabled="true"
                          icon="hero-signal-slash"
                          title={"Runner is #{connection_status(Runners.connection_state(@runner))} — runs can't be dispatched from here until it reconnects"}
                          class="shrink-0 cursor-not-allowed opacity-60"
                        >
                          Run
                        </.button>
                    <% end %>
                  </:actions>
                </.list_row>
              </:item>
              <:empty>
                <%!-- Two-state empty: an over-filter stays a quiet one-liner; a
                   genuinely empty catalog gets the onboarding box (floored to the
                   recent-runs placeholder height in the mixed side-by-side view). --%>
                <%= if LiveTable.has_active_filters?(@filter_params, @action_filters) do %>
                  <span class="text-zinc-500">No actions match these filters.</span>
                <% else %>
                  <.empty_state
                    icon="hero-cpu-chip"
                    title="No actions yet"
                    class="lg:flex lg:min-h-[16rem] lg:flex-col lg:items-center lg:justify-center"
                  >
                    This runner hasn't reported a catalog yet. Check the runner logs on the host.
                  </.empty_state>
                <% end %>
              </:empty>
            </LiveTable.live_table>
          </section>

          <section class="lg:col-start-3 lg:row-start-1">
            <.section_header title="Recent runs">
              <:actions :if={@recent_runs != []}>
                <.link
                  navigate={~p"/app/#{@current_account}/runs?#{[runner_id: @runner.id]}"}
                  class="group inline-flex items-center gap-1 text-xs font-medium text-brand-400 hover:text-brand-300"
                >
                  View all <.cta_arrow />
                </.link>
              </:actions>
            </.section_header>

            <%= if @recent_runs == [] do %>
              <%!-- Shared min-height + centered content so this narrow (1/3)
                   placeholder matches the wide "No actions yet" box beside it —
                   their descriptions wrap to different line counts, so a bare box
                   would be two different heights. A fixed floor doesn't couple to
                   the neighbor the way items-stretch would in the mixed (one
                   column full) state. --%>
              <.empty_state
                icon="hero-bolt"
                title="No runs yet"
                class="lg:flex lg:min-h-[16rem] lg:flex-col lg:items-center lg:justify-center"
              >
                Nothing dispatched to this runner yet — runs land here as they happen.
              </.empty_state>
            <% else %>
              <ul class="divide-y divide-zinc-800/70">
                <li :for={run <- @recent_runs}>
                  <.run_row run={run} current_account={@current_account} />
                </li>
              </ul>
            <% end %>
          </section>
        </div>

        <%!-- Danger zone — destructive/restorative actions as canvas hairline
           rows under their own section, not rose-boxed islands. Disable is the
           soft "stop"; Enable is its restorative inverse (shown only while
           disabled); Delete is available for any runner that isn't currently
           connected (that's how you clear a stale duplicate holding a name; a
           connected runner must be disabled first so a misclick can't wipe a
           live one). Rendered only for a manager, who always has at least one
           of these. --%>
        <section :if={not @loading? and Runners.subject_can_manage_runners?(@current_subject)}>
          <.section_header title="Danger zone" />
          <div class="divide-y divide-zinc-800/70">
            <.confirm_zone
              :if={is_nil(@runner.disabled_at)}
              id="disable-runner"
              title="Disable this runner"
              confirm="It will not be able to reconnect until you enable it again. Audit history is preserved."
              confirm_label="Disable runner"
              on_confirm={JS.push("disable")}
            >
              <:body>
                Removes it from the catalog and rejects future reconnects. Audit history is preserved.
              </:body>
              Disable runner
            </.confirm_zone>

            <.confirm_zone
              :if={not is_nil(@runner.disabled_at)}
              tone={:success}
              title="Enable this runner"
              phx-click="enable"
            >
              <:body>
                Clears the disabled flag so the host can reconnect and reappear in the catalog.
                Counts against your plan's runner limit.
              </:body>
              Enable runner
            </.confirm_zone>

            <%!-- IRREVERSIBLE — typed-confirm modal instead of data-confirm. The
               button only OPENS the dialog; `delete` still fires from Confirm
               and stays server-authz-gated (Runners.subject_can_manage_runners?). --%>
            <.confirm_zone
              :if={not @runner.online?}
              title="Delete this runner"
              phx-click={show_confirm_dialog("delete-runner")}
            >
              <:body>
                Removes the runner row from your account. The host can re-register on its
                next connect (it will appear as a fresh runner with new tokens), which is
                the intended path when you want to recover from a wedged state or
                re-bootstrap a host. Run history and audit events are preserved.
              </:body>
              Delete runner
            </.confirm_zone>
          </div>

          <.confirm_dialog
            :if={not @runner.online?}
            id="delete-runner"
            title="Delete this runner"
            confirm_label="Delete runner"
            confirm_token={@runner.name}
            typed={@typed}
            on_confirm={JS.push("delete") |> hide_confirm_dialog("delete-runner")}
          >
            <:body>
              Removes <span class="font-medium text-zinc-200">{@runner.name}</span>
              from your account. The host can re-register on its next connect as a fresh
              runner with new tokens. Run history and audit events are preserved.
            </:body>
          </.confirm_dialog>
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  # Runner heartbeat is sent every 30s by the Go client. The WebSocket
  # connect itself is the first liveness signal — between handshake
  # and the first explicit heartbeat tick, `last_heartbeat_at` is
  # legitimately nil. Treat the connect time as a heartbeat so the
  # UI doesn't read "connected 23s ago … waiting for first heartbeat",
  # which is self-contradictory. nil falls through to <.local_time>'s
  # placeholder.
  defp heartbeat_at(%{last_heartbeat_at: %DateTime{} = ts}), do: ts

  defp heartbeat_at(%{last_connected_at: %DateTime{} = ts}), do: ts

  defp heartbeat_at(_), do: nil

  # Labels are stored as a `:map` so the keys are strings and the order
  # is non-deterministic. Sort for stable rendering.
  defp runner_labels(%{labels: labels}) when is_map(labels) and labels != %{},
    do: labels |> Enum.sort_by(fn {k, _} -> k end)

  defp runner_labels(_), do: []

  # Socket termination values are diagnostic data, not customer copy. Keep the
  # same stable wording as the audit list; raw reasons remain in diagnostics.
  defp disconnect_message(%{online?: true}), do: nil

  defp disconnect_message(%{last_disconnect_reason: reason}),
    do: TransportReason.disconnect_message(reason)

  defp disconnect_message(_runner), do: nil

  defp degraded_packs_title([_single]), do: "A pack failed to load on this runner"

  defp degraded_packs_title(degraded),
    do: "#{length(degraded)} packs failed to load on this runner"
end
