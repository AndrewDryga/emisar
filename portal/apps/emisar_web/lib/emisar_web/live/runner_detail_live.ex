defmodule EmisarWeb.RunnerDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, Catalog, PubSub, Runs}
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
        if not Emisar.Accounts.runner_in_scope?(runner, membership) do
          {:ok,
           socket
           |> put_flash(:error, "Runner not found.")
           |> push_navigate(to: ~p"/app/runners")}
        else
          if connected?(socket), do: PubSub.subscribe_account_runners(account_id)

          {:ok,
           socket
           |> assign(:page_title, runner.name)
           |> assign(:runner, runner)}
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

  def handle_info({:runner_updated, %{id: id} = updated}, socket)
      when id == socket.assigns.runner.id,
      do: {:noreply, assign(socket, :runner, updated)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("disable", _params, socket) do
    Permissions.gated(socket, :manage_runners, fn s ->
      {:ok, runner} = Runners.disable_runner(s.assigns.runner, s.assigns.current_subject)
      {:noreply, s |> put_flash(:info, "Runner disabled.") |> assign(:runner, runner)}
    end)
  end

  def handle_event("delete", _params, socket) do
    Permissions.gated(socket, :manage_runners, fn s ->
      {:ok, _runner} = Runners.delete_runner(s.assigns.runner, s.assigns.current_subject)

      {:noreply,
       s
       |> put_flash(:info, "Runner deleted. The host can re-register on next connect.")
       |> push_navigate(to: ~p"/app/runners")}
    end)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
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
          <.status_badge status={@runner.status} />
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
                <%= if @runner.status == "connected" do %>
                  <.link
                    navigate={~p"/app/runs/new/#{@runner.id}/#{action.action_id}"}
                    class="shrink-0 rounded-lg bg-indigo-500/10 px-2.5 py-1 text-xs font-semibold text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/20"
                  >
                    Run
                  </.link>
                <% else %>
                  <span
                    title={"Runner is #{@runner.status} — runs queue until it reconnects"}
                    class="shrink-0 cursor-not-allowed rounded-lg bg-zinc-900 px-2.5 py-1 text-xs font-semibold text-zinc-600 ring-1 ring-zinc-800"
                  >
                    Run
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
                <.link
                  navigate={~p"/app/runs/#{run.id}"}
                  class="flex items-center justify-between gap-3 px-5 py-3 text-sm transition hover:bg-zinc-900/40"
                >
                  <div class="min-w-0">
                    <div class="truncate font-mono text-sm text-zinc-200">{run.action_id}</div>
                    <div class="truncate text-xs text-zinc-500">{relative_time(run.inserted_at)}</div>
                  </div>
                  <.status_badge status={run.status} class="shrink-0" />
                </.link>
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
        :if={@runner.status != "disabled" and Permissions.can?(assigns, :manage_runners)}
        class="mt-6"
      >
        <.danger_zone title="Disable this runner">
          <:body>
            Removes it from the catalog and rejects future reconnects. Audit history is preserved.
          </:body>
          <:button>
            <button
              phx-click="disable"
              data-confirm="Disable this runner? It will not be able to reconnect."
              class="rounded-lg border border-rose-500/40 px-3 py-1.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10"
            >
              Disable runner
            </button>
          </:button>
        </.danger_zone>
      </div>

      <div
        :if={@runner.status != "connected" and Permissions.can?(assigns, :manage_runners)}
        class="mt-6"
      >
        <.danger_zone title="Delete this runner">
          <:body>
            Removes the runner row from your account. The host can re-register on its
            next connect (it will appear as a fresh runner with new tokens), which is
            the intended path when you want to recover from a wedged state or
            re-bootstrap a host. Run history and audit events are preserved.
          </:body>
          <:button>
            <button
              phx-click="delete"
              data-confirm="Delete this runner row? The host can re-register on next connect."
              class="rounded-lg border border-rose-500/40 px-3 py-1.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10"
            >
              Delete runner
            </button>
          </:button>
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

  defp disconnect_note?(%{status: status, last_disconnect_reason: r})
       when status in ["disconnected", "disabled"] and is_binary(r) and r != "",
       do: true

  defp disconnect_note?(_), do: false
end
