defmodule EmisarWeb.RunbookVersionsLive do
  @moduledoc """
  Immutable version history of one runbook slug family, newest first. Every
  save is its own version row: each links to the editor for inspection, and
  a published version can be dispatched exactly as saved.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Runbooks, Runs}
  alias EmisarWeb.LiveTable

  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket),
      do: Runbooks.subscribe_account_runbooks(socket.assigns.current_account.id)

    {:ok, socket |> assign(:slug, slug) |> assign(:page_title, "Runbook versions")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info({:list_changed, :runbook, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:page_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket, params) do
    opts = LiveTable.params_to_opts(params)

    case Runbooks.list_runbook_versions(socket.assigns.slug, socket.assigns.current_subject, opts) do
      # A whole-family count of zero means the slug doesn't resolve for this
      # subject — unknown, deleted, or another account's; all read the same.
      {:ok, _versions, %{count: 0}} ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")

      {:ok, versions, metadata} ->
        socket
        |> assign(:versions, versions)
        |> assign(:metadata, metadata)
        |> assign(:page_params, params)

      # Bad cursor params from a hand-edited URL — retry once, clean.
      {:error, _} when map_size(params) > 0 ->
        load(socket, %{})

      {:error, _} ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")
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
      <:title>
        <.detail_header
          back="Runbooks"
          navigate={~p"/app/#{@current_account}/runbooks"}
          title={@slug}
          mono
        />
      </:title>

      <LiveTable.live_table
        layout={:cards}
        id="runbook-versions"
        path={~p"/app/#{@current_account}/runbooks/#{@slug}/versions"}
        rows={@versions}
        metadata={@metadata}
        wrapper_class="divide-y divide-zinc-800/70"
      >
        <:item :let={runbook}>
          <.list_row padding="py-4">
            <%!-- Every role can inspect the structured definition; the editor
             itself removes mutation controls for viewers. --%>
            <:title>
              <.link
                navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/edit"}
                class="truncate font-medium text-zinc-100 hover:text-brand-300"
              >
                {runbook.title}
              </.link>
              <.status_badge status={runbook.status} />
              <span class="font-mono text-[11px] text-zinc-400">v{runbook.version}</span>
            </:title>
            <:meta>
              <.meta_line>
                <:seg>
                  saved{" "}
                  <.local_time
                    id={"runbook-version-#{runbook.id}-saved"}
                    value={runbook.inserted_at}
                    mode={:relative}
                  />
                </:seg>
              </.meta_line>
            </:meta>
            <:actions>
              <%!-- Dispatches this exact immutable version, not the family's
               newest — that's the point of reaching it from history. --%>
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
        <:empty>No versions on this page.</:empty>
      </LiveTable.live_table>
    </.dashboard_shell>
    """
  end
end
