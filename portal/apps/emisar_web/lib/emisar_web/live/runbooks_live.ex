defmodule EmisarWeb.RunbooksLive do
  @moduledoc """
  Paginated list of the account's cloud-side runbooks. Each row links
  to the editor (`/runbooks/:id/edit`); published runbooks get a Run
  button that opens the parameterized dispatch form.
  """
  use EmisarWeb, :live_view

  alias Emisar.Runbooks
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
    {:noreply, LiveTable.apply_filter(socket, ~p"/app/runbooks", params)}
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
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      # A clean reload can fail too (e.g. a tightened list permission) —
      # degrade to an empty page rather than recursing forever.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:runbooks, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
    >
      <:title>Runbooks</:title>
      <:actions :if={Runbooks.subject_can_manage_runbooks?(@current_subject)}>
        <.button navigate={~p"/app/runbooks/new"} size="md" icon="hero-plus">
          New runbook
        </.button>
      </:actions>

      <%!-- Account-empty (create CTA) only when there's genuinely nothing AND no
           filter is narrowing — otherwise a 0-match filter (e.g. ?status=draft)
           would hide the filter bar and trap the operator. With a filter active,
           the live_table renders its own "no matches" + the bar to clear it. --%>
      <%= if @runbooks == [] && @metadata.count == 0 &&
               not LiveTable.has_active_filters?(@filter_params, @filters) do %>
        <.empty_state icon="hero-book-open" title="No runbooks yet">
          Runbooks are cloud-side workflows that expand into ordered action dispatches.
          Compose multi-step procedures, publish them, and operators or LLMs can run them safely.
          <:cta
            :if={Runbooks.subject_can_manage_runbooks?(@current_subject)}
            navigate={~p"/app/runbooks/new"}
          >
            Create runbook
          </:cta>
        </.empty_state>
      <% else %>
        <%!-- Standalone live_table (self-framed cards panel) — matches runs/
             runners. The dashboard_shell already titles the page + holds the
             "New runbook" action, so no list_section wrapper here (it would
             double the heading and box the filter against a second border). --%>
        <div class="mx-auto max-w-5xl">
          <LiveTable.live_table
            layout={:cards}
            id="runbooks"
            path={~p"/app/runbooks"}
            rows={@runbooks}
            metadata={@metadata}
            filter_params={@filter_params}
            filters={@filters}
          >
            <:item :let={runbook}>
              <.list_row icon="hero-book-open">
                <%!-- Row 1: title (link to editor) + status pill + version --%>
                <:title>
                  <.link
                    navigate={~p"/app/runbooks/#{runbook.id}/edit"}
                    class="truncate font-medium text-zinc-100 hover:text-indigo-300"
                  >
                    {runbook.title}
                  </.link>
                  <.status_badge status={runbook.status} />
                  <span class="font-mono text-[11px] text-zinc-500">v{runbook.version}</span>
                </:title>
                <:meta>
                  <%!-- Row 2: description preview + slug --%>
                  <span :if={runbook.description && runbook.description != ""}>
                    {preview(runbook.description)} ·
                  </span>
                  <span class="font-mono">{runbook.slug}</span>
                </:meta>
                <:actions>
                  <.link
                    :if={runbook.status == :published}
                    navigate={~p"/app/runbooks/#{runbook.id}/run"}
                    class="rounded-lg bg-indigo-500/10 px-2.5 py-1 text-xs font-semibold text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/20"
                  >
                    Run →
                  </.link>
                </:actions>
              </.list_row>
            </:item>
            <:empty>No runbooks match these filters.</:empty>
          </LiveTable.live_table>
        </div>
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
