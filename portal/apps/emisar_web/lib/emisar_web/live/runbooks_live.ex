defmodule EmisarWeb.RunbooksLive do
  @moduledoc """
  Paginated list of the account's cloud-side runbooks. Each row links
  to the editor (`/runbooks/:id/edit`); published runbooks get a Run
  button that opens the parameterized dispatch form.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Catalog, Runbooks, Runs}
  alias EmisarWeb.LiveTable

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Runbooks.subscribe_account_runbooks(socket.assigns.current_account.id)

    {:ok, assign(socket, :page_title, "Runbooks")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/runbooks", params)}
  end

  def handle_info({:list_changed, :runbook, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket, params) do
    filters = Runbooks.Runbook.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Runbooks.list_runbooks(socket.assigns.current_subject, opts) do
      {:ok, list, meta} ->
        socket
        |> assign(:runbooks, list)
        |> assign(:runbook_risk, resolve_max_risks(list, socket.assigns.current_subject))
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — flag it
      # so the list says "couldn't load" instead of a silent empty list.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:runbooks, [])
        |> assign(:runbook_risk, %{})
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  # `%{runbook_id => most-severe step risk}` for the whole page in ONE catalog
  # read — gather every step's action across all listed runbooks, resolve their
  # risks in a single account-scoped query, then fold each runbook's worst from
  # that map (no per-runbook DB call — IL-1). A runbook whose steps' actions
  # aren't in the catalog yet is absent from the map, so its row shows no pill
  # (max_risk never returns a false low for unresolved steps).
  defp resolve_max_risks(runbooks, subject) do
    action_ids =
      runbooks
      |> Enum.flat_map(&runbook_action_ids/1)
      |> Enum.uniq()

    case Catalog.risk_by_action_ids(action_ids, subject) do
      {:ok, risk_by_action} ->
        Map.new(runbooks, fn runbook ->
          risks = Enum.map(runbook_action_ids(runbook), &Map.get(risk_by_action, &1))
          {runbook.id, Catalog.max_risk(risks)}
        end)

      {:error, _} ->
        %{}
    end
  end

  # The action id of each of a runbook's steps (steps use `action`/`action_id`
  # interchangeably, same as the dispatch path).
  defp runbook_action_ids(runbook),
    do: runbook |> Runbooks.expand() |> Enum.map(&(&1["action_id"] || &1["action"]))

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
      section={:runbooks}
      width={:table}
    >
      <:title>Runbooks</:title>
      <%!-- Hidden while the account-empty pitch carries its own Create CTA —
           two identical affordances on one screen. --%>
      <:actions :if={
        Runbooks.subject_can_manage_runbooks?(@current_subject) and
          not (@runbooks == [] and @metadata.count == 0 and
                 not LiveTable.has_active_filters?(@filter_params, @filters))
      }>
        <.button navigate={~p"/app/#{@current_account}/runbooks/new"} size={:md} icon="hero-plus">
          New runbook
        </.button>
      </:actions>

      <.page_intro>
        Published playbooks your operators and LLMs can run as one gated sequence; drafts stay
        private until you publish them. <.doc_link href="/docs/runbooks">Runbook docs</.doc_link>
      </.page_intro>

      <%!-- Account-empty (create CTA) only when there's genuinely nothing AND no
           filter is narrowing — otherwise a 0-match filter (e.g. ?status=draft)
           would hide the filter bar and trap the operator. With a filter active,
           the live_table renders its own "no matches" + the bar to clear it. --%>
      <%= cond do %>
        <% @load_error? -> %>
          <.empty_state
            tone={:danger}
            icon="hero-exclamation-triangle"
            title="Couldn't load your runbooks"
          >
            This is a load error, not an empty list — your runbooks may well exist. Refresh the
            page; if it persists, your access to this account may have changed.
          </.empty_state>
        <% @runbooks == [] && @metadata.count == 0 &&
             not LiveTable.has_active_filters?(@filter_params, @filters) -> %>
          <.empty_state variant={:bare} icon="hero-book-open" title="No runbooks yet.">
            Runbooks are cloud-side workflows that expand into ordered action dispatches.
            Compose multi-step procedures, publish them, and operators or LLMs can run them safely.
            <:cta
              :if={Runbooks.subject_can_manage_runbooks?(@current_subject)}
              navigate={~p"/app/#{@current_account}/runbooks/new"}
            >
              Create runbook
            </:cta>
          </.empty_state>
        <% true -> %>
          <%!-- Standalone live_table (self-framed cards panel) — matches runs/
             runners. The dashboard_shell already titles the page + holds the
             "New runbook" action, so no list_section wrapper here (it would
             double the heading and box the filter against a second border). --%>
          <LiveTable.live_table
            layout={:cards}
            id="runbooks"
            path={~p"/app/#{@current_account}/runbooks"}
            rows={@runbooks}
            metadata={@metadata}
            filter_params={@filter_params}
            filters={@filters}
            wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <%!-- Canvas rows; the per-row icon disc died with the island. --%>
            <:item :let={runbook}>
              <.list_row padding="py-4">
                <%!-- Row 1: title (managers → editor; everyone else plain —
                     linking a viewer into a form they can't save loses their
                     20 minutes to a denial flash) + status pill + version --%>
                <:title>
                  <.link
                    :if={Runbooks.subject_can_manage_runbooks?(@current_subject)}
                    navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/edit"}
                    class="truncate font-medium text-zinc-100 hover:text-brand-300"
                  >
                    {runbook.title}
                  </.link>
                  <span
                    :if={not Runbooks.subject_can_manage_runbooks?(@current_subject)}
                    class="truncate font-medium text-zinc-100"
                  >
                    {runbook.title}
                  </span>
                  <.status_badge status={runbook.status} />
                  <span class="font-mono text-[11px] text-zinc-500">v{runbook.version}</span>
                  <%!-- Headline risk — the most-severe step's risk, so the
                       operator sees how dangerous a runbook is before opening
                       it. Hidden when no step's action is in the catalog. --%>
                  <.risk_pill :if={@runbook_risk[runbook.id]} risk={@runbook_risk[runbook.id]} />
                </:title>
                <:meta>
                  <%!-- Row 2: description preview + slug --%>
                  <.meta_line>
                    <:seg :if={runbook.description && runbook.description != ""}>
                      {preview(runbook.description)}
                    </:seg>
                    <:seg><span class="font-mono">{runbook.slug}</span></:seg>
                  </.meta_line>
                </:meta>
                <:actions>
                  <%!-- Secondary: the page's ONE brand fill is "New runbook" —
                       a green per row turns the fill into wallpaper. --%>
                  <.button
                    :if={
                      runbook.status == :published and
                        Runs.subject_can_dispatch_run?(@current_subject)
                    }
                    navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/run"}
                    variant={:secondary}
                    size={:sm}
                  >
                    Run
                  </.button>
                </:actions>
              </.list_row>
            </:item>
            <:empty>No runbooks match these filters.</:empty>
          </LiveTable.live_table>
      <% end %>
    </.dashboard_shell>
    """
  end

  defp preview(text) when is_binary(text) and text != "" do
    if String.length(text) > 80, do: String.slice(text, 0, 80) <> "…", else: text
  end

  # description is nullable; catch nil / "" / non-binary.
  defp preview(_), do: "—"
end
