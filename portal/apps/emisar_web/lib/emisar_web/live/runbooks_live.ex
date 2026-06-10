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

  def handle_info({:list_changed, :runbook, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket, params) do
    opts = LiveTable.params_to_opts(params)

    case Runbooks.list_runbooks(socket.assigns.current_subject, opts) do
      {:ok, list, meta} ->
        socket
        |> assign(:runbooks, list)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)

      {:error, _} ->
        # Invalid cursor → fall back to first page.
        load(socket, %{})
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
      section={:runbooks}
    >
      <:title>Runbooks</:title>
      <:actions :if={Runbooks.subject_can_manage_runbooks?(@current_subject)}>
        <.link
          navigate={~p"/app/runbooks/new"}
          class="inline-flex items-center gap-1.5 rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
        >
          <.icon name="hero-plus" class="h-4 w-4" /> New runbook
        </.link>
      </:actions>

      <%= if @runbooks == [] && @metadata.count == 0 do %>
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
        <div class="mx-auto max-w-5xl space-y-4">
          <.list_section title="Runbooks" count={@metadata.count} noun="runbook">
            <LiveTable.live_table
              layout={:cards}
              id="runbooks"
              path={~p"/app/runbooks"}
              rows={@runbooks}
              metadata={@metadata}
              filter_params={@filter_params}
              class="rounded-none border-0"
            >
              <:item :let={rb}>
                <.list_row icon="hero-book-open">
                  <%!-- Row 1: title (link to editor) + status pill + version --%>
                  <:title>
                    <.link
                      navigate={~p"/app/runbooks/#{rb.id}/edit"}
                      class="truncate font-medium text-zinc-100 hover:text-indigo-300"
                    >
                      {rb.title}
                    </.link>
                    <.status_badge status={rb.status} />
                    <span class="font-mono text-[11px] text-zinc-500">v{rb.version}</span>
                  </:title>
                  <:meta>
                    <%!-- Row 2: description preview + slug --%>
                    <span :if={rb.description && rb.description != ""}>
                      {preview(rb.description)} ·
                    </span>
                    <span class="font-mono">{rb.slug}</span>
                  </:meta>
                  <:actions>
                    <.link
                      :if={rb.status == :published}
                      navigate={~p"/app/runbooks/#{rb.id}/run"}
                      class="rounded-lg bg-indigo-500/10 px-2.5 py-1 text-xs font-semibold text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/20"
                    >
                      Run →
                    </.link>
                  </:actions>
                </.list_row>
              </:item>
            </LiveTable.live_table>
          </.list_section>
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
