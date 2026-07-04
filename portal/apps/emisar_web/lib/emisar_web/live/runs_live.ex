defmodule EmisarWeb.RunsLive do
  @moduledoc """
  Paginated, filterable list of every action run in the account. The
  `<.live_table>` shell drives all state through URL params so the
  browser back-button and a refresh both keep operators on the same
  page + filter set. Subscribed to the account-wide run channel so
  status changes flow in without a full reload.
  """
  use EmisarWeb, :live_view
  alias Emisar.{ApiKeys, Runners, Runs}
  alias EmisarWeb.LiveTable

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Runs.subscribe_account_runs(socket.assigns.current_account.id)

    # For the zero state's copy fork only — a runner-less account is told to
    # install a runner first, not to dispatch from pages that are also empty.
    any_runners? =
      connected?(socket) and Emisar.Runners.any_runners?(socket.assigns.current_subject)

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> assign(:any_runners?, any_runners?)}
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
    # Two pivots scope the feed to one entity, shown as a clearable chip (not a
    # visible filter): "View activity" from an agent key, "View all runs" from a
    # runner detail. Resolve each entity's name for its chip.
    api_key_id = params["api_key_id"]
    runner_id = params["runner_id"]
    subject = socket.assigns.current_subject

    socket =
      socket
      |> assign(:api_key_id, api_key_id)
      |> assign(:agent_label, agent_label_for(api_key_id, subject))
      |> assign(:runner_label, runner_label_for(runner_id, subject))

    run_opts =
      opts
      |> Keyword.put(:preload, [:runner, :api_key])
      |> Keyword.put(:api_key_id, api_key_id)
      |> Keyword.put(:runner_id, runner_id)

    case Runs.list_runs(socket.assigns.current_subject, run_opts) do
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

  defp agent_label_for(nil, _subject), do: nil

  defp agent_label_for(api_key_id, subject) do
    case ApiKeys.fetch_api_key_by_id(api_key_id, subject) do
      {:ok, key} -> key.name
      _ -> nil
    end
  end

  defp runner_label_for(nil, _subject), do: nil

  defp runner_label_for(runner_id, subject) do
    case Runners.fetch_runner_by_id(runner_id, subject) do
      {:ok, runner} -> runner.name
      _ -> nil
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
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
        output, and audit record. <.doc_link href="/docs/quickstart">Quickstart</.doc_link>
      </.page_intro>

      <%!-- "View activity" from an agent key / "View all runs" from a runner both
           pivot here scoped to that entity — the clearable chip says which one
           and gets back to the full feed. --%>
      <.pivot_chip
        :if={@agent_label}
        label="Agent"
        value={@agent_label}
        clear_to={~p"/app/#{@current_account}/runs"}
      />
      <.pivot_chip
        :if={@runner_label}
        label="Runner"
        value={@runner_label}
        clear_to={~p"/app/#{@current_account}/runs"}
      />

      <LiveTable.live_table
        id="runs"
        path={~p"/app/#{@current_account}/runs"}
        rows={@runs}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={@filters}
        responsive
        card_accent={fn run -> status_tone(run.status) end}
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
            <% not @any_runners? -> %>
              <%!-- Runner-less account: naming dispatch paths that don't exist
                 yet contradicts the product's own guidance — the first job is
                 a runner (the dashboard says the same). --%>
              <.empty_state variant={:bare} icon="hero-bolt" title="No runs yet.">
                Install a
                <.link
                  navigate={~p"/app/#{@current_account}/runners"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  runner
                </.link>
                first — actions dispatch to your own hosts, and every run lands
                here, gated and audited.
              </.empty_state>
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
                Runs from an
                <.link
                  navigate={~p"/app/#{@current_account}/settings/agents"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  LLM agent
                </.link>
                (over MCP) land here too.
              </.empty_state>
          <% end %>
        </:empty>
        <:col :let={run} label="When" class="w-24">
          <.local_time
            value={run.inserted_at}
            mode={:relative}
            class="text-xs text-zinc-400"
          />
        </:col>
        <:col :let={run} label="Action">
          <%!-- The action id is the row's headline — on a phone it wraps to show
               in full (break-all) rather than clipping mid-token to "…"; the
               desktop table cell still truncates to its column width. --%>
          <.link
            navigate={~p"/app/#{@current_account}/runs/#{run.id}"}
            class="block break-all font-mono text-sm hover:text-brand-300 sm:truncate"
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
        <%!-- card={false}: the mobile card already carries the origin via the
             in-cell badge under the action — a labeled SOURCE row doubled it. --%>
        <:col :let={run} label="Source" card={false} class="w-40 hidden lg:table-cell">
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
