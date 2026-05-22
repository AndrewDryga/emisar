defmodule EmisarWeb.RunsLive do
  use EmisarWeb, :live_view

  alias Emisar.{PubSub, Runs}

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: PubSub.subscribe_account_runs(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> assign(:status_filter, nil)
     |> load_runs()}
  end

  def handle_info({:run_updated, _}, socket), do: {:noreply, load_runs(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("filter", %{"status" => status}, socket) do
    filter = if status == "", do: nil, else: status
    {:noreply, socket |> assign(:status_filter, filter) |> load_runs()}
  end

  defp load_runs(socket) do
    opts = if socket.assigns.status_filter, do: [status: socket.assigns.status_filter], else: []
    runs = Runs.list_runs_for_account(socket.assigns.current_account.id, opts ++ [limit: 100])
    assign(socket, :runs, runs)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runs}
    >
      <:title>Runs</:title>
      <:actions>
        <form phx-change="filter">
          <select
            name="status"
            class="rounded-lg border-0 bg-zinc-900 px-3 py-1.5 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
          >
            <option value="">All statuses</option>
            <option value="running">Running</option>
            <option value="success">Success</option>
            <option value="failed">Failed</option>
            <option value="awaiting_approval">Awaiting approval</option>
            <option value="cancelled">Cancelled</option>
          </select>
        </form>
      </:actions>

      <.list_table id="runs-body" rows={@runs} empty_message="No runs match this filter.">
        <:col :let={run} label="When">
          <span class="text-xs text-zinc-400">{relative_time(run.inserted_at)}</span>
        </:col>
        <:col :let={run} label="Action">
          <.link navigate={~p"/app/runs/#{run.id}"} class="font-mono text-sm hover:text-indigo-300">
            {run.action_id}
          </.link>
        </:col>
        <:col :let={run} label="Runner">
          <span class="text-xs text-zinc-400">{String.slice(run.runner_id, 0, 8)}</span>
        </:col>
        <:col :let={run} label="Source">
          <span class="text-xs text-zinc-400">{run.source}</span>
        </:col>
        <:col :let={run} label="Status">
          <.status_badge status={run.status} />
        </:col>
        <:col :let={run} label="Duration" align="right">
          <span class="text-xs text-zinc-400">{format_duration(run.duration_ms)}</span>
        </:col>
      </.list_table>
    </.dashboard_shell>
    """
  end

end
