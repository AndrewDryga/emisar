defmodule EmisarWeb.AuditLive do
  use EmisarWeb, :live_view

  alias Emisar.Audit

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     |> assign(:filter_type, "")
     |> assign(:filter_actor, "")
     |> load()}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_type, params["event_type"] || "")
     |> assign(:filter_actor, params["actor_kind"] || "")
     |> load()}
  end

  defp load(socket) do
    opts =
      []
      |> maybe_add(:event_type, blank_or_nil(socket.assigns.filter_type))
      |> maybe_add(:actor_kind, blank_or_nil(socket.assigns.filter_actor))
      |> Keyword.put(:limit, 200)

    events = Audit.list_events_for_account(socket.assigns.current_account.id, opts)
    assign(socket, :events, events)
  end

  defp blank_or_nil(""), do: nil
  defp blank_or_nil(s), do: s

  defp maybe_add(opts, _, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:audit}
    >
      <:title>Audit log</:title>
      <:actions>
        <form phx-change="filter" class="flex items-center gap-2">
          <input
            type="text"
            name="event_type"
            value={@filter_type}
            placeholder="event_type"
            class="rounded-lg border-0 bg-zinc-900 px-3 py-1.5 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
          />
          <select
            name="actor_kind"
            class="rounded-lg border-0 bg-zinc-900 px-3 py-1.5 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
          >
            <option value="">Any actor</option>
            <option value="user" selected={@filter_actor == "user"}>User</option>
            <option value="runner" selected={@filter_actor == "runner"}>Runner</option>
            <option value="api_key" selected={@filter_actor == "api_key"}>API key</option>
            <option value="runbook" selected={@filter_actor == "runbook"}>Runbook</option>
            <option value="system" selected={@filter_actor == "system"}>System</option>
          </select>
        </form>
      </:actions>

      <.list_table id="audit-events" rows={@events} empty_message="No events yet.">
        <:col :let={ev} label="When">
          <span class="text-xs text-zinc-400">{absolute_time(ev.occurred_at)}</span>
        </:col>
        <:col :let={ev} label="Event">
          <span class="font-mono text-xs">{ev.event_type}</span>
        </:col>
        <:col :let={ev} label="Actor">
          <span class="text-xs text-zinc-400">
            <%= if ev.actor_kind do %>
              {ev.actor_kind}<%= if ev.actor_id, do: ":" <> String.slice(ev.actor_id, 0, 8) %>
            <% else %>
              —
            <% end %>
          </span>
        </:col>
        <:col :let={ev} label="Subject">
          <span class="text-xs text-zinc-400">{ev.subject_label || ev.subject_kind || "—"}</span>
        </:col>
      </.list_table>
    </.dashboard_shell>
    """
  end

end
