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

  def handle_event("filter", params, socket) do
    {:noreply, LiveTable.apply_filter(socket, ~p"/app/runs", params)}
  end

  def handle_info({_event, _}, socket) do
    # PubSub-driven refresh — re-run the current filter/page.
    {:noreply, load_runs(socket, socket.assigns.filter_params)}
  end

  # Total catch-all: the badge hooks forward account-topic broadcasts to every
  # authenticated LV, so any other shape must be ignored, not crash.
  def handle_info(_msg, socket), do: {:noreply, socket}

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
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
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
        <:empty>
          <%!-- Two-state empty: "you have a filter set" stays a quiet
               one-liner, "you have an actually empty list" gets the
               onboarding pitch (icon + concrete next step + links to
               the two surfaces that produce runs). The richer state
               only shows on a brand-new account so it's not noisy. --%>
          <%= if any_filter_active?(@filter_params, @filters) do %>
            <span class="text-zinc-500">No runs match these filters.</span>
          <% else %>
            <div class="mx-auto max-w-md">
              <.icon name="hero-bolt" class="mx-auto h-8 w-8 text-zinc-700" />
              <p class="mt-3 text-zinc-300">No runs yet.</p>
              <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                Dispatch one from a
                <.link navigate={~p"/app/runners"} class="text-indigo-400 hover:text-indigo-300">
                  runner detail page
                </.link>
                or kick off a <.link
                  navigate={~p"/app/runbooks"}
                  class="text-indigo-400 hover:text-indigo-300"
                >runbook</.link>.
                Runs from an LLM (via the <.link
                  navigate={~p"/app/agents"}
                  class="text-indigo-400 hover:text-indigo-300"
                >MCP API</.link>) land here too.
              </p>
            </div>
          <% end %>
        </:empty>
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
        <:col :let={run} label="Source" class="w-28">
          <span class="text-xs text-zinc-400">{run_actor(run)}</span>
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
