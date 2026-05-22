defmodule EmisarWeb.RunbooksLive do
  use EmisarWeb, :live_view

  alias Emisar.Runbooks
  alias EmisarWeb.Permissions

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runbooks")
     |> load()}
  end

  defp load(socket) do
    runbooks = Runbooks.list_runbooks(socket.assigns.current_account.id)
    assign(socket, :runbooks, runbooks)
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
      <:actions>
        <%= if Permissions.can?(assigns, :manage_runbooks) do %>
          <.link
            navigate={~p"/app/runbooks/new"}
            class="rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
          >
            New runbook
          </.link>
        <% end %>
      </:actions>

      <%= if @runbooks == [] do %>
        <.empty_state icon="hero-book-open" title="No runbooks yet">
          Runbooks are cloud-side workflows that expand into ordered action dispatches.
          Compose multi-step procedures, publish them, and operators or LLMs can run them safely.
          <:cta :if={Permissions.can?(assigns, :manage_runbooks)} navigate={~p"/app/runbooks/new"}>
            Create runbook
          </:cta>
        </.empty_state>
      <% else %>
        <.list_table id="runbooks" rows={@runbooks}>
          <:col :let={rb} label="Title">
            <.link
              navigate={~p"/app/runbooks/#{rb.id}/edit"}
              class="font-medium text-zinc-100 hover:text-indigo-300"
            >
              {rb.title}
            </.link>
          </:col>
          <:col :let={rb} label="Slug">
            <span class="font-mono text-xs text-zinc-400">{rb.slug}</span>
          </:col>
          <:col :let={rb} label="Version">
            <span class="font-mono text-xs text-zinc-400">v{rb.version}</span>
          </:col>
          <:col :let={rb} label="Status">
            <.status_badge status={rb.status} />
          </:col>
          <:col :let={rb} label="Description">
            <span class="text-xs text-zinc-400">{preview(rb.description)}</span>
          </:col>
          <:action :let={rb}>
            <.link
              :if={rb.status == "published"}
              navigate={~p"/app/runbooks/#{rb.id}/run"}
              class="rounded px-2 py-1 text-xs font-medium text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/10"
            >
              Run
            </.link>
          </:action>
        </.list_table>
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
