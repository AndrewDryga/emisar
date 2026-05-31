defmodule EmisarWeb.RunsLive do
  @moduledoc """
  Paginated, filterable list of every action run in the account. The
  `<.live_table>` shell drives all state through URL params so the
  browser back-button and a refresh both keep operators on the same
  page + filter set. Subscribed to the account-wide run channel so
  status changes flow in without a full reload.
  """
  use EmisarWeb, :live_view

  alias Emisar.{PubSub, Runs}
  alias Emisar.Runs.ActionRun
  alias EmisarWeb.LiveTable

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: PubSub.subscribe_account_runs(socket.assigns.current_account.id)

    {:ok, assign(socket, :page_title, "Runs")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load_runs(socket, params)}
  end

  def handle_info({_event, _}, socket) do
    # PubSub-driven refresh — re-run the current filter/page.
    {:noreply, load_runs(socket, socket.assigns.filter_params)}
  end

  defp load_runs(socket, params) do
    filters = ActionRun.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Runs.list_runs(socket.assigns.current_subject, opts) do
      {:ok, runs, meta} ->
        socket
        |> assign(:runs, runs)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      {:error, _} ->
        # Invalid cursor or bad filter — fall back to first page.
        load_runs(socket, %{})
    end
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

      <LiveTable.live_table
        id="runs"
        path={~p"/app/runs"}
        rows={@runs}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={@filters}
      >
        <:empty>{empty_message(@filter_params, @filters)}</:empty>
        <:col :let={run} label="When" class="w-24">
          <span class="text-xs text-zinc-400">{relative_time(run.inserted_at)}</span>
        </:col>
        <:col :let={run} label="Action">
          <.link navigate={~p"/app/runs/#{run.id}"} class="font-mono text-sm hover:text-indigo-300">
            {run.action_id}
          </.link>
        </:col>
        <:col :let={run} label="Runner">
          <span class="text-xs text-zinc-400">
            {(run.runner && run.runner.name) || String.slice(run.runner_id, 0, 8)}
          </span>
        </:col>
        <:col :let={run} label="Source" class="w-20">
          <span class="text-xs text-zinc-400">{run.source}</span>
        </:col>
        <:col :let={run} label="Status" class="w-32">
          <.status_badge status={run.status} />
        </:col>
        <:col :let={run} label="Duration" class="w-20 text-right">
          <span class="text-xs text-zinc-400">{format_duration(run.duration_ms)}</span>
        </:col>
      </LiveTable.live_table>
    </.dashboard_shell>
    """
  end

  # Honest empty-state copy: "no runs yet" when the operator is on a
  # bare URL with no filter active, "no runs match these filters" only
  # when at least one filter is set.
  defp empty_message(params, filters) do
    if any_filter_active?(params, filters) do
      "No runs match these filters."
    else
      "No runs yet — dispatch one from a runner detail page or kick off a runbook."
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
end
