defmodule EmisarWeb.RunnersLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, PubSub}
  alias EmisarWeb.RunnerPresence

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket) do
      PubSub.subscribe_account_runners(account_id)
      Phoenix.PubSub.subscribe(Emisar.PubSub.Server, "presence:account:#{account_id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Runners")
     |> load()}
  end

  def handle_info({:runner_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:runner_connected, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:runner_disconnected, _}, socket), do: {:noreply, load(socket)}
  def handle_info(%{event: "presence_diff"}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    account = socket.assigns.current_account
    runners = Runners.list_runners_for_account(account.id)
    groups = Runners.list_groups_for_account(account.id)

    online = RunnerPresence.list_for_account(account.id)

    socket
    |> assign(:runners, runners)
    |> assign(:groups, groups)
    |> assign(:online, online)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runners}
    >
      <:title>Runners</:title>
      <:actions>
        <.link navigate={~p"/app/settings/runners/auth-keys"} class="rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400">
          New auth key
        </.link>
      </:actions>

      <%= if @runners == [] do %>
        <.empty_state icon="hero-cpu-chip" title="No runners yet">
          Issue an auth key, then run the emisar installer on a host to bootstrap the runner.
          <:cta navigate={~p"/app/settings/runners/auth-keys"}>Issue an auth key</:cta>
        </.empty_state>
      <% else %>
        <div :for={{group, count} <- @groups} class="mb-6">
          <h2 class="text-xs uppercase tracking-wider text-zinc-500">
            {group} <span class="ml-1 text-zinc-700">({count})</span>
          </h2>
          <div class="mt-3">
            <.list_table id={"runners-#{group}"} rows={filter_group(@runners, group)}>
              <:col :let={runner} label="Runner">
                <.link navigate={~p"/app/runners/#{runner.id}"} class="font-medium hover:text-indigo-300">
                  {runner.name}
                </.link>
                <div class="text-xs text-zinc-500">{runner.hostname || runner.external_id}</div>
              </:col>
              <:col :let={runner} label="Status">
                <.status_badge status={derived_status(runner, @online)} />
              </:col>
              <:col :let={runner} label="Version">
                <span class="font-mono text-xs text-zinc-400">{runner.runner_version || "—"}</span>
              </:col>
              <:col :let={runner} label="Last heartbeat">
                <span class="text-xs text-zinc-400">{relative_time(runner.last_heartbeat_at)}</span>
              </:col>
              <:col :let={runner} label="Load">
                <span class="text-xs text-zinc-400">{runner.action_load} active</span>
              </:col>
            </.list_table>
          </div>
        </div>
      <% end %>
    </.dashboard_shell>
    """
  end

  defp filter_group(runners, group), do: Enum.filter(runners, &(&1.group == group))

  defp derived_status(runner, online) do
    cond do
      Map.has_key?(online, runner.id) -> "connected"
      true -> runner.status
    end
  end

end
