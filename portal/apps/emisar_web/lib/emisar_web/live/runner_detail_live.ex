defmodule EmisarWeb.RunnerDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, Catalog, PubSub, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id

    case Runners.get_runner(account_id, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Runner not found.")
         |> push_navigate(to: ~p"/app/runners")}

      runner ->
        if connected?(socket), do: PubSub.subscribe_account_runners(account_id)

        {:ok,
         socket
         |> assign(:page_title, runner.name)
         |> assign(:runner, runner)
         |> assign(:actions, Catalog.list_actions_for_agent(runner.id))
         |> assign(:recent_runs, Runs.list_recent_runs_for_agent(runner.id, 20))}
    end
  end

  def handle_info({:runner_updated, %{id: id} = updated}, socket) when id == socket.assigns.runner.id,
    do: {:noreply, assign(socket, :runner, updated)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("disable", _params, socket) do
    Permissions.gated(socket, :manage_runners, fn s ->
      {:ok, runner} = Runners.disable_runner(s.assigns.runner, s.assigns.current_user.id)
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
      <:title>{@runner.name}</:title>
      <:actions>
        <.status_badge status={@runner.status} />
      </:actions>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card>
          <.section_header title="Connection" />
          <dl class="mt-4 space-y-3 text-sm">
            <.kv label="Hostname">{@runner.hostname || "—"}</.kv>
            <.kv label="Version">{@runner.runner_version || "—"}</.kv>
            <.kv label="Group">{@runner.group}</.kv>
            <.kv label="External ID"><span class="font-mono text-xs">{@runner.external_id}</span></.kv>
            <.kv label="Last heartbeat">{relative_time(@runner.last_heartbeat_at)}</.kv>
            <.kv label="Action load">{@runner.action_load}</.kv>
          </dl>
        </.card>

        <.card class="lg:col-span-2">
          <.section_header title="Advertised actions">
            <span class="text-xs text-zinc-500">{length(@actions)} total</span>
          </.section_header>

          <%= if @actions == [] do %>
            <.empty_state
              icon="hero-cube-transparent"
              title="No actions advertised"
              class="mt-4 border-0 bg-transparent p-6"
            >
              This runner hasn't reported a catalog yet. Check the runner logs on the host.
            </.empty_state>
          <% else %>
            <ul class="mt-4 divide-y divide-zinc-900">
              <li :for={action <- @actions} class="flex items-center justify-between py-3">
                <div>
                  <div class="font-mono text-sm">{action.action_id}</div>
                  <div class="text-xs text-zinc-500">{action.title}</div>
                </div>
                <div class="flex items-center gap-3">
                  <.risk_pill risk={action.risk} />
                  <.link
                    navigate={~p"/app/runs/new/#{@runner.id}/#{action.action_id}"}
                    class="rounded bg-indigo-500/10 px-3 py-1 text-xs font-semibold text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/20"
                  >
                    Run
                  </.link>
                </div>
              </li>
            </ul>
          <% end %>
        </.card>
      </div>

      <.card class="mt-6">
        <.section_header title="Recent runs" />
        <%= if @recent_runs == [] do %>
          <.empty_state
            icon="hero-bolt"
            title="No runs yet"
            class="mt-4 border-0 bg-transparent p-6"
          >
            Dispatch one from the advertised actions above.
          </.empty_state>
        <% else %>
          <ul class="mt-4 divide-y divide-zinc-900">
            <li :for={run <- @recent_runs} class="flex items-center justify-between py-3 text-sm">
              <.link navigate={~p"/app/runs/#{run.id}"} class="font-mono hover:text-indigo-300">
                {run.action_id}
              </.link>
              <div class="flex items-center gap-4">
                <span class="text-xs text-zinc-500">{relative_time(run.inserted_at)}</span>
                <.status_badge status={run.status} />
              </div>
            </li>
          </ul>
        <% end %>
      </.card>

      <%= if @runner.status != "disabled" and Permissions.can?(assigns, :manage_runners) do %>
        <div class="mt-6 rounded-xl border border-rose-900/40 bg-rose-950/20 p-6">
          <h3 class="text-sm font-semibold text-rose-200">Danger zone</h3>
          <p class="mt-1 text-xs text-rose-300/70">
            Disabling removes this runner from the catalog and rejects future reconnects.
            Audit history is preserved.
          </p>
          <button
            phx-click="disable"
            data-confirm="Disable this runner? It will not be able to reconnect."
            class="mt-3 rounded-lg border border-rose-500/40 px-3 py-1.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10"
          >
            Disable runner
          </button>
        </div>
      <% end %>
    </.dashboard_shell>
    """
  end

end
