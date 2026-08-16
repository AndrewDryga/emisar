defmodule EmisarWeb.RunbooksLive do
  @moduledoc """
  Paginated list of the account's runbooks — one row each. The live release
  rides the Run button's label, and waiting unpublished changes are a quiet
  amber dot with a tooltip. Every row links to the editor; a runbook with a
  live release also gets the Run button that opens its dispatch form.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Runbooks, Runs}
  alias EmisarWeb.{LiveTable, RunbookWorkflowComponents}

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Runbooks.subscribe_account_runbooks(socket.assigns.current_account.id)

    {:ok, assign(socket, :page_title, "Runbooks")}
  end

  # IL-18: the dead render shows `<.loading_state />`, so the family list, its
  # risk/target batches, and the recent-executions read were paid twice per
  # first paint.
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      {:noreply, load(socket, params)}
    else
      {:noreply, prepare_disconnected(socket, params)}
    end
  end

  defp prepare_disconnected(socket, params) do
    socket
    |> assign(:runbooks, [])
    |> assign(:runbook_risk, %{})
    |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
    |> assign(:filter_params, params)
    |> assign(:filters, Runbooks.runbook_filters())
    |> assign(:load_error?, false)
    |> assign(:recent_executions, [])
    |> assign(:recent_executions_error?, false)
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/runbooks", params)}
  end

  def handle_info({:list_changed, :runbook, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket, params) do
    filters = Runbooks.runbook_filters()
    opts = LiveTable.params_to_opts(params, filters)

    socket =
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

    load_recent_executions(socket)
  end

  defp load_recent_executions(socket) do
    case Runbooks.list_recent_executions(socket.assigns.current_subject, 5) do
      {:ok, executions} ->
        socket
        |> assign(:recent_executions, executions)
        |> assign(:recent_executions_error?, false)

      {:error, _reason} ->
        socket
        |> assign(:recent_executions, [])
        |> assign(:recent_executions_error?, true)
    end
  end

  # `%{runbook_id => most-severe step risk}` for the whole page in ONE read. A
  # runbook with any step the catalog can't resolve is nil there, so its row
  # shows no pill rather than a false low.
  defp resolve_max_risks(runbooks, subject) do
    case Runbooks.risk_by_runbooks(runbooks, subject) do
      {:ok, risk_by_runbook} -> risk_by_runbook
      {:error, _reason} -> %{}
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
      width={:table}
    >
      <:title>Runbooks</:title>
      <:actions :if={Runbooks.subject_can_manage_runbooks?(@current_subject)}>
        <.button
          navigate={~p"/app/#{@current_account}/runbooks/import"}
          variant={:secondary}
          size={:md}
          icon="hero-arrow-up-tray"
        >
          Import runbook
        </.button>
        <.button navigate={~p"/app/#{@current_account}/runbooks/new"} size={:md} icon="hero-plus">
          New runbook
        </.button>
      </:actions>

      <%!-- Defines the noun and names who can dispatch it; the rail beside the list
           owns the EXECUTION semantics (stages, what stops a run) and the docs link,
           so neither is repeated here. --%>
      <.page_intro>
        A runbook is a multi-step procedure saved as one versioned unit — an operator or an
        LLM agent dispatches it on demand, and only the published release ever runs.
      </.page_intro>

      <div class="grid min-w-0 gap-x-12 gap-y-10 xl:grid-cols-[minmax(0,1fr)_20rem]">
        <main id="runbooks-primary" class="min-w-0">
          <%!-- Account-empty (create CTA) only when there's genuinely nothing AND no
               filter is narrowing — otherwise a 0-match filter (e.g. ?state=draft)
               would hide the filter bar and trap the operator. With a filter active,
               the live_table renders its own "no matches" + the bar to clear it. --%>
          <%= cond do %>
            <% not connected?(@socket) -> %>
              <.loading_state />
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
              <%!-- The intro above defines what a runbook is, so this says the one
                   thing it can add: the two ways to get a first one, matching the
                   header's two buttons. --%>
              <.empty_state icon="hero-book-open" title="No runbooks yet.">
                Compose one from your fleet's actions, or import a definition you already have.
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
                wrapper_class="divide-y divide-zinc-800/70"
              >
                <%!-- Canvas rows; the per-row icon disc died with the island. --%>
                <:item :let={runbook}>
                  <.list_row padding="py-4">
                    <%!-- Row 1: every role can inspect the structured definition;
                     the editor itself removes mutation controls for viewers. --%>
                    <:title>
                      <.link
                        navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/edit"}
                        class="truncate font-medium text-zinc-100 hover:text-brand-300"
                      >
                        {runbook.title}
                      </.link>
                      <%!-- The live version rides the Run button that uses it, so
                       the title line carries no Live chip. A runbook with nothing
                       live is ALL unpublished — the amber signal is reserved for a
                       live release someone has already edited past. --%>
                      <.chip :if={is_nil(runbook.live_version)} tone={:neutral}>
                        Never published
                      </.chip>
                      <.tooltip
                        :if={runbook.live_version && runbook.draft_definition}
                        id={"runbook-#{runbook.id}-draft-tip"}
                        text="Unpublished changes — open the runbook to review and publish them."
                        aria_label="Unpublished changes"
                        align={:left}
                        class="shrink-0"
                      >
                        <.status_dot tone={:amber} size={:md} />
                      </.tooltip>
                      <%!-- Headline risk — the most-severe step's risk, so the
                       operator sees how dangerous a runbook is before opening
                       it. Hidden when no step's action is in the catalog. --%>
                      <.risk_pill
                        :if={@runbook_risk[runbook.id]}
                        id={"runbook-#{runbook.id}-risk"}
                        risk={@runbook_risk[runbook.id]}
                      />
                    </:title>
                    <:meta>
                      <%!-- Row 2: description preview + slug --%>
                      <%!-- The slug is the runbook's machine handle — an operator
                           types it into MCP and the CLI, so a tail clipped off it
                           is unusable. The description is the elastic half: it
                           takes the slack and ellipsizes, the slug reads whole. --%>
                      <.meta_line>
                        <:seg :if={runbook.description && runbook.description != ""} truncate>
                          {preview(runbook.description)}
                        </:seg>
                        <:seg><span class="font-mono">{runbook.slug}</span></:seg>
                      </.meta_line>
                    </:meta>
                    <:actions>
                      <%!-- Navigation, but it shares this row with the bordered Run
                           button, and a row wears ONE button grammar (§7.47). --%>
                      <.button
                        navigate={
                          ~p"/app/#{@current_account}/audit?#{[target_kind: "runbook", target_id: runbook.id]}"
                        }
                        variant={:secondary}
                        size={:sm}
                      >
                        View activity
                      </.button>
                      <%!-- Secondary: the page's ONE brand fill is "New runbook" —
                       a green per row turns the fill into wallpaper. Only the
                       live release runs, so a runbook with nothing published
                       offers no Run. --%>
                      <.button
                        :if={runbook.live_version && Runs.subject_can_dispatch_run?(@current_subject)}
                        navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/run"}
                        variant={:secondary}
                        size={:sm}
                      >
                        Run v{runbook.live_version}
                      </.button>
                    </:actions>
                  </.list_row>
                </:item>
                <:empty>No runbooks match these filters.</:empty>
              </LiveTable.live_table>
          <% end %>
        </main>

        <aside id="runbooks-reading-rail" class="min-w-0 space-y-9">
          <section id="runbooks-docs-rail">
            <.section_header title="How runbooks work" />
            <p class="text-sm leading-6 text-zinc-400">
              Build stages in execution order. Every action in a stage must succeed before the
              next stage starts; a denial, timeout, cancellation, or failure stops the run.
            </p>
            <div class="mt-3">
              <.doc_link href="/docs/runbooks">Read the runbook docs</.doc_link>
            </div>
          </section>

          <section id="recent-runbook-runs">
            <.section_header title="Recent runs" />
            <RunbookWorkflowComponents.recent_executions
              executions={@recent_executions}
              load_error?={@recent_executions_error?}
              current_account={@current_account}
              show_runbook?
            />
          </section>
        </aside>
      </div>
    </.dashboard_shell>
    """
  end

  defp preview(text) when is_binary(text) and text != "" do
    if String.length(text) > 80, do: String.slice(text, 0, 80) <> "…", else: text
  end

  # description is nullable; catch nil / "" / non-binary.
  defp preview(_), do: "—"
end
