defmodule EmisarWeb.RunsLive do
  @moduledoc """
  Paginated, filterable list of every action run in the account. The
  `<.live_table>` shell drives all state through URL params so the
  browser back-button and a refresh both keep operators on the same
  page + filter set. Subscribed to the account-wide run channel so
  status changes flow in without a full reload.
  """
  use EmisarWeb, :live_view

  alias Emisar.Runs
  alias EmisarWeb.LiveTable

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Runs.subscribe_account_runs(socket.assigns.current_account.id)

    {:ok, assign(socket, :page_title, "Runs")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load_runs(socket, params)}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/runs", params)}
  end

  def handle_info({:run_updated, _run}, socket) do
    # A run in this account changed — re-run the current filter/page.
    {:noreply, load_runs(socket, socket.assigns.filter_params)}
  end

  # Total catch-all: the badge hooks forward EVERY account-topic broadcast
  # (runner connection, approval, pack updates) to every authenticated LV, so
  # any other shape is ignored — only a run change re-queries the runs list.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_runs(socket, params) do
    filters = Runs.ActionRun.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Runs.list_runs(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:runner, :api_key])
         ) do
      {:ok, runs, meta} ->
        socket
        |> assign(:runs, runs)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — flag it
      # so the feed says "couldn't load" instead of a silent empty list (which
      # would read "no runs yet" on the busiest page when the read actually failed).
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:runs, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load_runs(socket, %{})
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runs}
      width={:table}
    >
      <:title>Runs</:title>

      <.page_intro>
        Every action dispatched across your fleet, newest first — each row opens to its arguments,
        output, and audit record.
      </.page_intro>

      <LiveTable.live_table
        id="runs"
        path={~p"/app/#{@current_account}/runs"}
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
          <%= cond do %>
            <% @load_error? -> %>
              <.empty_state
                variant={:bare}
                tone={:danger}
                icon="hero-exclamation-triangle"
                title="Couldn't load your runs"
              >
                This is a load error, not an empty feed — runs may well exist. Refresh the page;
                if it persists, your access to this account may have changed.
              </.empty_state>
            <% any_filter_active?(@filter_params, @filters) -> %>
              <span class="text-zinc-500">No runs match these filters.</span>
            <% not connected?(@socket) -> %>
              <%!-- Dead/pre-connect render: don't commit to the onboarding
                   pitch before the live socket confirms the list is really
                   empty — a populated account would otherwise flash it. --%>
              <.loading_state />
            <% true -> %>
              <.empty_state variant={:bare} icon="hero-bolt" title="No runs yet.">
                Dispatch one from a
                <.link
                  navigate={~p"/app/#{@current_account}/runners"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  runner detail page
                </.link>
                or kick off a <.link
                  navigate={~p"/app/#{@current_account}/runbooks"}
                  class="text-brand-400 hover:text-brand-300"
                >runbook</.link>.
                Runs from an LLM (via the <.link
                  navigate={~p"/app/#{@current_account}/settings/agents"}
                  class="text-brand-400 hover:text-brand-300"
                >MCP API</.link>) land here too.
              </.empty_state>
          <% end %>
        </:empty>
        <:col :let={run} label="When" class="w-24">
          <.local_time
            value={run.inserted_at}
            mode={:relative}
            class="text-xs tabular-nums text-zinc-400"
          />
        </:col>
        <:col :let={run} label="Action">
          <.link
            navigate={~p"/app/#{@current_account}/runs/#{run.id}"}
            class="block max-w-[44vw] truncate font-mono text-sm hover:text-brand-300 sm:max-w-none"
          >
            {run.action_id}
          </.link>
          <%!-- Source is a column only at lg+; on a phone surface the origin here so an
               agent run still reads distinctly from a human one (the product's point). --%>
          <.source_badge
            source={run.source}
            label={run_actor(run)}
            class="mt-0.5 max-w-[44vw] text-[11px] lg:hidden"
          />
        </:col>
        <%!-- Runner drops on a phone so When + Action + Status (the run's outcome,
             the column you scan for) fit without a horizontal scroll; it's on the
             run detail and reappears at sm+. --%>
        <:col :let={run} label="Runner" class="hidden sm:table-cell">
          <span class="text-xs text-zinc-400">
            {(run.runner && run.runner.name) || String.slice(run.runner_id, 0, 8)}
          </span>
        </:col>
        <:col :let={run} label="Source" class="w-40 hidden lg:table-cell">
          <.source_badge source={run.source} label={run_actor(run)} class="max-w-[10rem] text-xs" />
        </:col>
        <:col :let={run} label="Status" class="w-32">
          <.status_badge status={run.status} />
        </:col>
        <:col :let={run} label="Duration" class="w-20 text-right hidden lg:table-cell">
          <span class="text-xs tabular-nums text-zinc-400">{format_duration(run.duration_ms)}</span>
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
