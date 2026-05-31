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
        {:ok, recent_runs, _} = Runs.list_recent_runs_for_runner(runner.id, subject, page: [limit: 20])

        {:noreply,
         socket
         |> assign(:actions, actions)
         |> assign(:actions_metadata, meta)
         |> assign(:recent_runs, recent_runs)
         |> assign(:filter_params, params)}
    end
  end

  def handle_info({:runner_updated, %{id: id} = updated}, socket) when id == socket.assigns.runner.id,
    do: {:noreply, assign(socket, :runner, updated)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("disable", _params, socket) do
    Permissions.gated(socket, :manage_runners, fn s ->
      {:ok, runner} = Runners.disable_runner(s.assigns.runner, s.assigns.current_subject)
      {:noreply, s |> put_flash(:info, "Runner disabled.") |> assign(:runner, runner)}
    end)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runners}
    >
      <:title>
        <.back_link navigate={~p"/app/runners"}>Runners</.back_link>
        {@runner.name}
      </:title>
      <:actions>
        <.status_badge status={@runner.status} />
      </:actions>

      <%!-- Connection meta strip — same shape as RunDetail /
           ApprovalDetail. Six facts an operator wants at a glance:
           hostname, version, group, external id, last heartbeat,
           active actions. --%>
      <.meta_strip cols={6}>
        <.meta_field label="Hostname">
          <span class="truncate text-zinc-200">{@runner.hostname || "—"}</span>
        </.meta_field>
        <.meta_field label="Version">
          <span class="font-mono text-zinc-200">{@runner.runner_version || "—"}</span>
        </.meta_field>
        <.meta_field label="Group">
          <span class="truncate text-zinc-200">{@runner.group}</span>
        </.meta_field>
        <.meta_field label="External ID">
          <span class="truncate font-mono text-xs text-zinc-400">
            {@runner.external_id || "—"}
          </span>
        </.meta_field>
        <.meta_field label="Last heartbeat">
          <span class="text-zinc-200">{heartbeat_label(@runner)}</span>
        </.meta_field>
        <.meta_field label="Active runs">
          <span class="text-zinc-200">{@runner.action_load}</span>
        </.meta_field>
      </.meta_strip>

      <div class="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-3">
        <%!-- Recent runs in a sidebar — operator scanning a runner is
             usually trying to figure out "is this thing healthy?" so
             the catalog gets the wide column, recent runs sit
             alongside as a freshness check. --%>
        <section class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40 lg:col-span-2 lg:order-1">
          <header class="flex items-center justify-between border-b border-zinc-900 px-5 py-3">
            <h2 class="text-sm font-semibold text-zinc-100">Advertised actions</h2>
            <span class="text-xs text-zinc-500">
              {@actions_metadata.count} {if @actions_metadata.count == 1, do: "action", else: "actions"}
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
                  <div class="flex items-center gap-2">
                    <span class="truncate font-mono text-sm text-zinc-100">{action.action_id}</span>
                    <%!-- "Mutates state" indicator: any non-empty
                         side_effects list means this action is not
                         read-only. Yellow dot with tooltip — operators
                         scan the list and immediately know which rows
                         are merely-observe vs. actually-change-things. --%>
                    <span
                      :if={action.side_effects && action.side_effects != []}
                      title={"Side effects: " <> Enum.join(action.side_effects, ", ")}
                      class="inline-flex h-1.5 w-1.5 shrink-0 rounded-full bg-amber-400"
                    >
                    </span>
                  </div>
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

            <div :if={@actions_metadata.previous_page_cursor || @actions_metadata.next_page_cursor} class="border-t border-zinc-900 px-5 py-3">
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
           regular content above. --%>
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
    </.dashboard_shell>
    """
  end


  # Runner heartbeat is sent every 30s by the Go client. Between
  # initial WebSocket handshake (status flips to "connected" via
  # `runner_socket init/1`) and the first heartbeat tick, the column
  # is legitimately nil — show the connect time + a clear hint
  # instead of a bare em-dash, which reads as "broken".
  defp heartbeat_label(%{last_heartbeat_at: %DateTime{} = ts}), do: relative_time(ts)

  defp heartbeat_label(%{last_connected_at: %DateTime{} = ts}) do
    "connected #{relative_time(ts)} · waiting for first heartbeat"
  end

  defp heartbeat_label(_), do: "—"
end
