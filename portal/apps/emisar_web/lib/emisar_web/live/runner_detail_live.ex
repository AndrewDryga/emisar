defmodule EmisarWeb.RunnerDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Catalog, Runners, Runs}
  alias EmisarWeb.{LiveTable, Permissions}

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id
    membership = socket.assigns.current_membership

    case Runners.fetch_runner_by_id(id, socket.assigns.current_subject) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Runner not found.")
         |> push_navigate(to: ~p"/app/runners")}

      {:ok, runner} ->
        # Per-user runner ACLs (#238): treat out-of-scope as not-found
        # rather than 403 — don't leak the existence of runners the
        # operator's scope doesn't grant access to.
        if Runners.runner_in_scope?(runner, membership) do
          if connected?(socket), do: Runners.subscribe_connections(account_id)

          {:ok,
           socket
           |> assign(:page_title, runner.name)
           |> assign(:runner, runner)}
        else
          {:ok,
           socket
           |> put_flash(:error, "Runner not found.")
           |> push_navigate(to: ~p"/app/runners")}
        end
    end
  end

  def handle_params(params, _uri, socket) do
    # mount may have redirected; on the post-redirect (which is the next
    # mount/handle_params cycle) the runner won't be in scope so this is
    # never reached. When we have a runner, load the paginated actions
    # list + the recent runs sidebar.
    case socket.assigns[:runner] do
      nil ->
        {:noreply, socket}

      runner ->
        subject = socket.assigns.current_subject
        opts = LiveTable.params_to_opts(params)

        {:ok, actions, meta} = Catalog.list_actions_for_runner(runner.id, subject, opts)

        {:ok, recent_runs, _} =
          Runs.list_recent_runs_for_runner(runner.id, subject, page: [limit: 20])

        {:noreply,
         socket
         |> assign(:actions, actions)
         |> assign(:actions_metadata, meta)
         |> assign(:recent_runs, recent_runs)
         |> assign(:filter_params, params)}
    end
  end

  # A runner connected/disconnected somewhere in the account — re-fetch
  # so the badge, action_load, and heartbeat refresh from presence.
  def handle_info(%{event: "presence_diff"}, socket) do
    case Runners.fetch_runner_by_id(socket.assigns.runner.id, socket.assigns.current_subject) do
      {:ok, runner} -> {:noreply, assign(socket, :runner, runner)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

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
         |> push_navigate(to: ~p"/app/runners")}
      end
    )
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runners}
    >
      <:title>
        <.back_link navigate={~p"/app/runners"}>Runners</.back_link>
        {@runner.name}
      </:title>
      <%!-- Connection meta strip — same shape as RunDetail /
           ApprovalDetail. Status leads so the connection state is the
           first thing the eye lands on; everything else (hostname,
           version, group, etc.) sits beside it for context. External
           ID dropped — it's debug-trace, not at-a-glance signal. --%>
      <.meta_strip cols={6}>
        <.meta_field label="Status">
          <.status_badge status={conn_status(@runner)} />
        </.meta_field>
        <.meta_field label="Hostname">
          <span class="truncate text-zinc-200">{@runner.hostname || "—"}</span>
        </.meta_field>
        <.meta_field label="Version">
          <span class="font-mono text-zinc-200">{@runner.runner_version || "—"}</span>
        </.meta_field>
        <.meta_field label="Group">
          <span class="truncate text-zinc-200">{@runner.group}</span>
        </.meta_field>
        <.meta_field label="Last heartbeat">
          <span class="text-zinc-200">{heartbeat_label(@runner)}</span>
        </.meta_field>
        <.meta_field label="Active runs">
          <span class="text-zinc-200">{@runner.action_load}</span>
        </.meta_field>
      </.meta_strip>

      <%!-- Labels + last-disconnect reason. Both are written to the DB
           and previously invisible. Labels show only when set;
           disconnect reason shows only when the runner is actually
           disconnected (otherwise it's just historical noise from the
           last drop). --%>
      <div
        :if={runner_labels(@runner) != [] or disconnect_note?(@runner)}
        class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl border border-zinc-900 bg-zinc-950/40 px-4 py-2.5 text-sm"
      >
        <div :if={runner_labels(@runner) != []} class="flex flex-wrap items-center gap-1.5">
          <span class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Labels</span>
          <span
            :for={{k, v} <- runner_labels(@runner)}
            class="rounded bg-zinc-900 px-1.5 py-0.5 font-mono text-[11px] text-zinc-300"
          >
            {k}={v}
          </span>
        </div>
        <div :if={disconnect_note?(@runner)} class="flex items-center gap-1.5 text-rose-300/90">
          <.icon name="hero-bolt-slash" class="h-3.5 w-3.5" />
          <span class="text-xs">
            Disconnect reason: <span class="font-mono">{@runner.last_disconnect_reason}</span>
          </span>
        </div>
      </div>

      <div class="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-3">
        <%!-- Recent runs in a sidebar — operator scanning a runner is
             usually trying to figure out "is this thing healthy?" so
             the catalog gets the wide column, recent runs sit
             alongside as a freshness check. --%>
        <section class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40 lg:col-span-2 lg:order-1">
          <header class="flex items-center justify-between border-b border-zinc-900 px-5 py-3">
            <h2 class="text-sm font-semibold text-zinc-100">Advertised actions</h2>
            <span class="text-xs text-zinc-500">
              {@actions_metadata.count} {if @actions_metadata.count == 1,
                do: "action",
                else: "actions"}
            </span>
          </header>

          <%= if @actions == [] do %>
            <.empty_state icon="hero-cpu-chip" title="No actions yet">
              This runner hasn't reported a catalog yet. Check the runner logs on the host.
            </.empty_state>
          <% else %>
            <ul class="divide-y divide-zinc-900">
              <li :for={action <- @actions} class="flex items-center gap-4 px-5 py-3">
                <div class="min-w-0 flex-1">
                  <span class="truncate font-mono text-sm text-zinc-100">{action.action_id}</span>
                  <div :if={action.title} class="truncate text-xs text-zinc-500">
                    {action.title}
                  </div>
                </div>
                <.risk_pill risk={action.risk} />
                <%!-- Dispatch only makes sense when the runner is online —
                     otherwise the run sits in `pending` until reconnect.
                     Gate the button visually so operators don't queue up
                     work against a disconnected/disabled runner. --%>
                <%= if @runner.online? do %>
                  <.link
                    navigate={~p"/app/runs/new/#{@runner.id}/#{action.action_id}"}
                    class="shrink-0 rounded-lg bg-indigo-500/10 px-2.5 py-1 text-xs font-semibold text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/20"
                  >
                    Run
                  </.link>
                <% else %>
                  <%!-- Offline: not a link. aria-disabled + a signal-slash
                       icon carry "can't run" without relying on the dimmed
                       color alone (a11y) or the hover-only title. --%>
                  <span
                    aria-disabled="true"
                    title={"Runner is #{conn_status(@runner)} — runs can't be dispatched from here until it reconnects"}
                    class="inline-flex shrink-0 cursor-not-allowed items-center gap-1 rounded-lg bg-zinc-900 px-2.5 py-1 text-xs font-semibold text-zinc-600 ring-1 ring-zinc-800"
                  >
                    <.icon name="hero-signal-slash" class="h-3.5 w-3.5" /> Run
                  </span>
                <% end %>
              </li>
            </ul>

            <div
              :if={@actions_metadata.previous_page_cursor || @actions_metadata.next_page_cursor}
              class="border-t border-zinc-900 px-5 py-3"
            >
              <LiveTable.paginator
                id="actions"
                path={~p"/app/runners/#{@runner.id}"}
                metadata={@actions_metadata}
                filter_params={@filter_params}
              />
            </div>
          <% end %>
        </section>

        <section class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40 lg:order-2">
          <header class="border-b border-zinc-900 px-5 py-3">
            <h2 class="text-sm font-semibold text-zinc-100">Recent runs</h2>
          </header>

          <%= if @recent_runs == [] do %>
            <div class="px-5 py-10 text-center text-sm text-zinc-500">
              Nothing dispatched yet.
            </div>
          <% else %>
            <ul class="divide-y divide-zinc-900">
              <li :for={run <- @recent_runs}>
                <.run_row run={run} />
              </li>
            </ul>
          <% end %>
        </section>
      </div>

      <%!-- Danger zone — destructive actions live in their own
           visually-distinct card so they can't be mistaken for the
           regular content above. Disable is the soft "stop". Delete is
           available for any runner that isn't currently connected
           (disconnected / disabled / pending) — that's how you clear a
           stale duplicate holding a name; a connected runner must be
           disabled first so a misclick can't wipe a live one. --%>
      <div
        :if={is_nil(@runner.disabled_at) and Runners.subject_can_manage_runners?(@current_subject)}
        class="mt-6"
      >
        <.danger_zone
          title="Disable this runner"
          confirm="Disable this runner? It will not be able to reconnect."
          phx-click="disable"
        >
          <:body>
            Removes it from the catalog and rejects future reconnects. Audit history is preserved.
          </:body>
          Disable runner
        </.danger_zone>
      </div>

      <%!-- Enable: the inverse of disable. Shown only while the runner is
           disabled (the disable zone above hides then). Positive styling —
           it's a restorative action, not a danger one. --%>
      <div
        :if={
          not is_nil(@runner.disabled_at) and Runners.subject_can_manage_runners?(@current_subject)
        }
        class="mt-6"
      >
        <section class="flex items-start justify-between gap-4 rounded-xl border border-emerald-500/30 bg-emerald-500/[0.04] p-5">
          <div>
            <h3 class="text-sm font-semibold text-emerald-100">Enable this runner</h3>
            <p class="mt-1 text-xs text-zinc-400">
              Clears the disabled flag so the host can reconnect and reappear in the catalog.
              Counts against your plan's runner limit.
            </p>
          </div>
          <div class="shrink-0">
            <button
              phx-click="enable"
              class="rounded-lg border border-emerald-500/40 px-3 py-1.5 text-sm font-medium text-emerald-200 hover:bg-emerald-500/10"
            >
              Enable runner
            </button>
          </div>
        </section>
      </div>

      <div
        :if={not @runner.online? and Runners.subject_can_manage_runners?(@current_subject)}
        class="mt-6"
      >
        <.danger_zone
          title="Delete this runner"
          confirm="Delete this runner row? The host can re-register on next connect."
          phx-click="delete"
        >
          <:body>
            Removes the runner row from your account. The host can re-register on its
            next connect (it will appear as a fresh runner with new tokens), which is
            the intended path when you want to recover from a wedged state or
            re-bootstrap a host. Run history and audit events are preserved.
          </:body>
          Delete runner
        </.danger_zone>
      </div>
    </.dashboard_shell>
    """
  end

  # Runner heartbeat is sent every 30s by the Go client. The WebSocket
  # connect itself is the first liveness signal — between handshake
  # and the first explicit heartbeat tick, `last_heartbeat_at` is
  # legitimately nil. Treat the connect time as a heartbeat so the
  # UI doesn't read "connected 23s ago … waiting for first heartbeat",
  # which is self-contradictory.
  defp heartbeat_label(%{last_heartbeat_at: %DateTime{} = ts}), do: relative_time(ts)

  defp heartbeat_label(%{last_connected_at: %DateTime{} = ts}), do: relative_time(ts)

  defp heartbeat_label(_), do: "—"

  # Labels are stored as a `:map` so the keys are strings and the order
  # is non-deterministic. Sort for stable rendering.
  defp runner_labels(%{labels: labels}) when is_map(labels) and labels != %{},
    do: labels |> Enum.sort_by(fn {k, _} -> k end)

  defp runner_labels(_), do: []

  # Map the derived connection state onto the status-badge vocabulary.
  defp conn_status(runner) do
    case Runners.connection_state(runner) do
      :online -> "connected"
      :offline -> "disconnected"
      :disabled -> "disabled"
      :pending -> "pending"
    end
  end

  # Show the last-disconnect reason note when the runner isn't online and
  # we actually have a reason on file.
  defp disconnect_note?(%{online?: true}), do: false

  defp disconnect_note?(%{last_disconnect_reason: r}) when is_binary(r) and r != "", do: true

  defp disconnect_note?(_), do: false
end
