defmodule EmisarWeb.RunbooksLive do
  @moduledoc """
  Paginated list of the account's cloud-side runbooks. Each row links
  to the editor (`/runbooks/:id/edit`); published runbooks get a Run
  button that opens the parameterized dispatch form.
  """
  use EmisarWeb, :live_view

  alias Emisar.Runbooks
  alias EmisarWeb.{LiveTable, Permissions}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Runbooks")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

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
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runbooks}
    >
      <:title>Runbooks</:title>
      <:actions :if={Permissions.can?(assigns, :manage_runbooks)}>
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
          <:cta :if={Permissions.can?(assigns, :manage_runbooks)} navigate={~p"/app/runbooks/new"}>
            Create runbook
          </:cta>
        </.empty_state>
      <% else %>
        <div class="mx-auto max-w-5xl space-y-4">
          <.list_section title="Runbooks" count={@metadata.count} noun="runbook">
            <ul class="divide-y divide-zinc-900">
              <li :for={rb <- @runbooks} class="flex items-start gap-4 px-5 py-4">
                <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                  <.icon name="hero-book-open" class="h-4 w-4" />
                </span>

                <div class="min-w-0 flex-1">
                  <%!-- Row 1: title (link to editor) + status pill + version --%>
                  <div class="flex flex-wrap items-center gap-2">
                    <.link
                      navigate={~p"/app/runbooks/#{rb.id}/edit"}
                      class="truncate font-medium text-zinc-100 hover:text-indigo-300"
                    >
                      {rb.title}
                    </.link>
                    <.status_badge status={rb.status} />
                    <span class="font-mono text-[11px] text-zinc-500">v{rb.version}</span>
                  </div>

                  <%!-- Row 2: description preview + slug --%>
                  <div class="mt-1 truncate text-xs text-zinc-500">
                    <span :if={rb.description && rb.description != ""}>
                      {preview(rb.description)} ·
                    </span>
                    <span class="font-mono">{rb.slug}</span>
                  </div>
                </div>

                <.link
                  :if={rb.status == "published"}
                  navigate={~p"/app/runbooks/#{rb.id}/run"}
                  class="shrink-0 rounded-lg bg-indigo-500/10 px-2.5 py-1 text-xs font-semibold text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/20"
                >
                  Run →
                </.link>
              </li>
            </ul>
          </.list_section>

          <LiveTable.paginator
            id="runbooks"
            path={~p"/app/runbooks"}
            metadata={@metadata}
            filter_params={@filter_params}
          />
        </div>
      <% end %>
    </.dashboard_shell>
    """
  end

  defp preview(nil), do: "—"
  defp preview(""), do: "—"

  defp preview(text) when is_binary(text) do
    if String.length(text) > 80, do: String.slice(text, 0, 80) <> "…", else: text
  end
end
