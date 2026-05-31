defmodule EmisarWeb.AuditLive do
  @moduledoc """
  Append-only audit log list. Actor + subject columns resolve their
  display labels in a single batched pass (`Audit.resolve_references/1`)
  and render as links into the relevant detail page when one exists.
  Click a row to drill into the full event (payload, IP, user agent,
  request id) at `/app/audit/:id`.
  """
  use EmisarWeb, :live_view

  alias Emisar.Audit
  alias Emisar.Audit.Event
  alias EmisarWeb.LiveTable

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Audit log")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  defp load(socket, params) do
    filters = Event.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Audit.list_events(socket.assigns.current_subject, opts) do
      {:ok, events, meta} ->
        refs = Audit.resolve_references(events)

        socket
        |> assign(:events, events)
        |> assign(:metadata, meta)
        |> assign(:refs, refs)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      {:error, _} ->
        load(socket, %{})
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:audit}
    >
      <:title>Audit log</:title>

      <LiveTable.live_table
        id="audit-events"
        path={~p"/app/audit"}
        rows={@events}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={@filters}
        row_id={fn ev -> "ev-#{ev.id}" end}
        row_click={fn ev -> JS.navigate(~p"/app/audit/#{ev.id}") end}
      >
        <:col :let={ev} label="When" class="w-40">
          <.local_time value={ev.occurred_at} class="text-xs text-zinc-400" />
        </:col>
        <:col :let={ev} label="Event">
          <div class="text-sm text-zinc-200">{format_event_type(ev.event_type)}</div>
          <div class="font-mono text-[10px] text-zinc-500">{ev.event_type}</div>
        </:col>
        <:col :let={ev} label="Actor">
          <.ref kind={ev.actor_kind} id={ev.actor_id} label={ev.actor_label} refs={@refs} />
        </:col>
        <:col :let={ev} label="Subject">
          <.ref kind={ev.subject_kind} id={ev.subject_id} label={ev.subject_label} refs={@refs} />
        </:col>
        <:col :let={ev} label="IP" class="w-32">
          <span class="font-mono text-xs text-zinc-500">{ev.ip_address || "—"}</span>
        </:col>
        <:empty>{empty_message(@filter_params, @filters)}</:empty>
      </LiveTable.live_table>
    </.dashboard_shell>
    """
  end

  # -- Reference rendering (shared with AuditDetailLive) ---------------

  attr :kind, :string, default: nil
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :refs, :map, default: %{}

  def ref(%{kind: nil} = assigns), do: ~H[<span class="text-xs text-zinc-500">—</span>]

  # System/scheduler/runbook actors don't have an identifying row in
  # another table — render them as a clean label without a colon-id
  # pair (which would be `system: —`).
  def ref(%{kind: kind, id: nil} = assigns) when kind in ["system", "scheduler", "runbook"] do
    assigns = assign(assigns, :label_text, kindless_label(kind))

    ~H"""
    <span class="text-xs text-zinc-300">{@label_text}</span>
    """
  end

  def ref(assigns) do
    assigns =
      assign(assigns,
        text: resolve_label(assigns.refs, assigns.kind, assigns.id, assigns.label),
        href: ref_path(assigns.kind, assigns.id)
      )

    ~H"""
    <%= if @href do %>
      <.link navigate={@href} class="text-xs text-indigo-300 hover:text-indigo-200">
        <span class="text-zinc-500">{@kind}:</span> {@text}
      </.link>
    <% else %>
      <span class="text-xs text-zinc-400">
        <span class="text-zinc-500">{@kind}:</span> {@text}
      </span>
    <% end %>
    """
  end

  defp kindless_label("system"), do: "System"
  defp kindless_label("scheduler"), do: "Scheduler"
  defp kindless_label("runbook"), do: "Runbook"

  # Look up the live label from `refs` first (the freshest); fall back
  # to the label that was stamped on the event at write time; finally
  # to a short slice of the UUID. The event might predate any rename,
  # and the underlying record might have been deleted.
  defp resolve_label(refs, kind, id, fallback_label) do
    live = kind && id && refs |> Map.get(kind, %{}) |> Map.get(id)

    cond do
      live -> live
      fallback_label && fallback_label != "" -> fallback_label
      is_binary(id) -> String.slice(id, 0, 8)
      true -> "—"
    end
  end

  # Distinguish "no rows in the table at all" from "no rows match the
  # filters you set". The default `No X match these filters.` lies to a
  # brand-new account whose log is just empty.
  defp empty_message(params, filters) do
    if any_filter_active?(params, filters) do
      "No events match these filters."
    else
      "No audit events yet — they appear here as soon as something happens (runner connect, run dispatch, approval, etc.)."
    end
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

  defp ref_path("runner", id) when is_binary(id), do: ~p"/app/runners/#{id}"
  defp ref_path("action_run", id) when is_binary(id), do: ~p"/app/runs/#{id}"
  defp ref_path("approval_request", id) when is_binary(id), do: ~p"/app/approvals/#{id}"
  defp ref_path("auth_key", _id), do: ~p"/app/settings/runners/auth-keys"
  defp ref_path("api_key", _id), do: ~p"/app/agents"
  defp ref_path("user", _id), do: ~p"/app/settings/team"
  defp ref_path(_, _), do: nil
end
