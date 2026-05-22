defmodule EmisarWeb.ApprovalsLive do
  use EmisarWeb, :live_view

  alias Emisar.{Approvals, PubSub}

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: PubSub.subscribe_account_approvals(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:page_title, "Approvals")
     |> load()}
  end

  def handle_info({:approval_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    account_id = socket.assigns.current_account.id

    socket
    |> assign(:pending, Approvals.list_pending(account_id))
    |> assign(:recent, Approvals.list_for_account(account_id, limit: 25))
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:approvals}
    >
      <:title>Approvals</:title>

      <.card class="mb-6">
        <.section_header title="Pending decisions" />

        <%= if @pending == [] do %>
          <div class="mt-4">
            <.empty_state icon="hero-shield-check" title="Nothing pending">
              Approvals appear here when a policy gates a run.
            </.empty_state>
          </div>
        <% else %>
          <ul class="mt-4 space-y-3">
            <li :for={req <- @pending} class="rounded-xl border border-amber-500/30 bg-amber-500/5 p-4">
              <.link navigate={~p"/app/approvals/#{req.id}"} class="flex items-start justify-between gap-4 hover:opacity-90">
                <div>
                  <div class="text-sm font-semibold text-amber-100">Approval #{String.slice(req.id, 0, 8)}</div>
                  <div class="mt-1 text-xs text-zinc-400">
                    Action <span class="font-mono">{req.context["action_id"]}</span> on runner
                    <span class="font-mono">{String.slice(req.context["runner_id"] || "", 0, 8)}</span>
                  </div>
                  <%= if req.reason do %>
                    <div class="mt-2 text-xs italic text-zinc-400">"{req.reason}"</div>
                  <% end %>
                </div>
                <span class="text-xs text-zinc-500">{relative_time(req.requested_at)}</span>
              </.link>
            </li>
          </ul>
        <% end %>
      </.card>

      <.card>
        <.section_header title="Recent decisions" />

        <%= if @recent -- @pending == [] do %>
          <div class="mt-4">
            <.empty_state icon="hero-clock" title="No decisions yet">
              Decided approvals will be listed here.
            </.empty_state>
          </div>
        <% else %>
          <ul class="mt-4 divide-y divide-zinc-900">
            <li :for={req <- @recent -- @pending} class="flex items-center justify-between py-3 text-sm">
              <div>
                <.link navigate={~p"/app/approvals/#{req.id}"} class="font-mono text-xs hover:text-indigo-300">
                  {String.slice(req.id, 0, 12)}…
                </.link>
                <div class="text-xs text-zinc-500">{req.context["action_id"]}</div>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-xs text-zinc-500">{relative_time(req.decided_at || req.requested_at)}</span>
                <.status_badge status={req.status} />
              </div>
            </li>
          </ul>
        <% end %>
      </.card>
    </.dashboard_shell>
    """
  end

end
