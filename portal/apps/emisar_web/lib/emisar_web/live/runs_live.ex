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
    subject = socket.assigns.current_subject

    # ONE filters list feeds both the rendered bar and params_to_opts: a
    # dispatched-by child that isn't visible isn't in the list, so its param
    # can never narrow the feed from a hidden control.
    filters =
      Runs.ActionRun.Query.filters()
      |> put_runner_options(subject)
      |> resolve_dispatcher_children(params, subject)

    opts = LiveTable.params_to_opts(params, filters)
    run_opts = Keyword.put(opts, :preload, [:runner, :api_key, :requested_by])

    case Runs.list_runs(subject, run_opts) do
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

  # The Runner filter's options are per-account, so inject the account's runners
  # (id → name, sorted) into the static filter def — the searchable select needs
  # them to render its choices and to resolve a deep-linked runner_id to a name.
  defp put_runner_options(filters, subject) do
    options =
      case Runners.list_all_runners_for_account(subject) do
        {:ok, runners} -> runners |> Enum.sort_by(& &1.name) |> Enum.map(&{&1.id, &1.name})
        _ -> []
      end

    Enum.map(filters, fn
      %{name: :runner_id} = filter -> %{filter | values: options}
      filter -> filter
    end)
  end

  # Which "who exactly" child each Dispatched-by kind reveals.
  @dispatcher_children %{
    "mcp" => :api_key_id,
    "operator" => :requested_by_id,
    "runbook" => :runbook_id
  }

  # "Dispatched by" reveals its WHO picker (the audit actor-kind grammar):
  # LLM agent → Agent, Operator → team member, Runbook → runbook. A child also
  # stays visible while its OWN value is set (an `?api_key_id=…` deep link
  # applies and reads active even before the kind is picked); the two hidden
  # children drop out of the list entirely.
  defp resolve_dispatcher_children(filters, params, subject) do
    Enum.flat_map(filters, fn
      %{name: name} = filter when name in [:api_key_id, :requested_by_id, :runbook_id] ->
        if dispatcher_child_visible?(name, params),
          do: [%{filter | values: dispatcher_child_options(name, subject)}],
          else: []

      filter ->
        [filter]
    end)
  end

  defp dispatcher_child_visible?(name, params) do
    @dispatcher_children[params["source"]] == name or
      params[to_string(name)] not in [nil, ""]
  end

  # Revoked keys stay pickable — their run history is exactly what gets
  # audited. Operator/runbook options are the DISTINCT dispatchers already in
  # the account's runs, so the picker never offers a choice that matches nothing.
  defp dispatcher_child_options(:api_key_id, subject) do
    sorted_options(ApiKeys.list_key_options(subject))
  end

  defp dispatcher_child_options(:requested_by_id, subject) do
    sorted_options(Runs.list_run_operator_options(subject))
  end

  defp dispatcher_child_options(:runbook_id, subject) do
    sorted_options(Runs.list_run_runbook_options(subject))
  end

  defp sorted_options({:ok, options}), do: Enum.sort_by(options, fn {_id, label} -> label end)
  defp sorted_options(_), do: []

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runs}
      width={:table}
    >
      <:title>Runs</:title>

      <.page_intro>
        Every action dispatched across your fleet, newest first. Open a row for its arguments,
        output, and audit record — secret values are redacted in the output before it leaves the
        host. <.doc_link href="/docs/quickstart">Quickstart</.doc_link>
      </.page_intro>

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
                tone={:danger}
                icon="hero-exclamation-triangle"
                title="Couldn't load your runs"
              >
                This is a load error, not an empty feed — runs may well exist. Refresh the page;
                if it persists, your access to this account may have changed.
              </.empty_state>
            <% any_filter_active?(@filter_params, @filters) -> %>
              <span class="text-zinc-400">No runs match these filters.</span>
            <% not connected?(@socket) -> %>
              <%!-- Dead/pre-connect render: don't commit to the onboarding
                   pitch before the live socket confirms the list is really
                   empty — a populated account would otherwise flash it. --%>
              <.loading_state />
            <% not @any_runners? -> %>
              <%!-- Runner-less account: naming dispatch paths that don't exist
                 yet contradicts the product's own guidance — the first job is
                 a runner (the dashboard says the same). --%>
              <.empty_state icon="hero-bolt" title="No runs yet.">
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
              <.empty_state icon="hero-bolt" title="No runs yet.">
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
                  navigate={~p"/app/#{@current_account}/agents"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  LLM agent
                </.link>
                (over MCP) land here too.
              </.empty_state>
          <% end %>
        </:empty>
        <%!-- The phone card (below sm): a compact TWO-LINE scan row, not the old
             five-labeled-rows dump. Line 1 is the scan line — action id + its
             status, the two facts an operator compares down the list; line 2 is
             subordinate origin · runner · time (the source badge keeps an agent
             run reading distinctly from a human one, the product's point). The
             left spine (card_accent) already carries the status colour. --%>
        <:card :let={run}>
          <div class="flex items-start justify-between gap-3">
            <.link
              navigate={~p"/app/#{@current_account}/runs/#{run.id}"}
              class="min-w-0 flex-1 break-all font-mono text-sm leading-5 text-zinc-100 hover:text-brand-300"
            >
              {run.action_id}
            </.link>
            <.status_badge status={run.status} class="shrink-0" />
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs leading-5 text-zinc-400">
            <.source_badge source={run.source} label={run_actor(run)} class="max-w-[60vw] text-xs" />
            <span aria-hidden="true">·</span>
            <span>{(run.runner && run.runner.name) || String.slice(run.runner_id, 0, 8)}</span>
            <span aria-hidden="true">·</span>
            <.local_time value={run.inserted_at} mode={:relative} />
          </div>
        </:card>
        <%!-- No row-stable id: this responsive table renders each :col TWICE
             (desktop <td> + mobile card), so a value-based id would duplicate.
             local_time falls back to a per-render unique id; dropping
             phx-update="ignore" is what keeps the WHEN correct across a patch. --%>
        <:col :let={run} label="When" class="w-24">
          <.local_time value={run.inserted_at} mode={:relative} class="text-xs text-zinc-400" />
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
        <%!-- Desktop/tablet table only — the phone card renders the origin in
             its own line 2 (the responsive table is hidden below sm). --%>
        <:col :let={run} label="Dispatched by" class="w-40 hidden lg:table-cell">
          <.source_badge
            source={run.source}
            label={run_actor(run)}
            class="max-w-[10rem] text-xs"
          />
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
