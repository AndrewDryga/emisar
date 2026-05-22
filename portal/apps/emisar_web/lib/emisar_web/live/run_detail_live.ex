defmodule EmisarWeb.RunDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Approvals, PubSub, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id

    case Runs.get_run(account_id, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found.")
         |> push_navigate(to: ~p"/app/runs")}

      run ->
        if connected?(socket) do
          PubSub.subscribe_run(run.id)
        end

        events = Runs.list_events(run.id)
        approval_request = lookup_approval(account_id, run)

        {:ok,
         socket
         |> assign(:page_title, "Run #{run.action_id}")
         |> assign(:run, run)
         |> assign(:approval_request, approval_request)
         |> stream(:events, events)}
    end
  end

  defp lookup_approval(_account_id, %{requires_approval: false}), do: nil
  defp lookup_approval(account_id, run), do: Approvals.get_request_by_run(account_id, run.id)

  def handle_info({:run_updated, run}, socket) when run.id == socket.assigns.run.id do
    # If status flips to/from pending_approval, refresh the linked
    # approval row so the banner updates without a page reload.
    approval_request = lookup_approval(socket.assigns.current_account.id, run)

    {:noreply,
     socket
     |> assign(:run, run)
     |> assign(:approval_request, approval_request)}
  end

  def handle_info({:run_event, event}, socket),
    do: {:noreply, stream_insert(socket, :events, event)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    Permissions.gated(socket, :cancel_run, fn s ->
      case Runs.cancel(s.assigns.run, s.assigns.current_user.id, "operator cancelled") do
        {:ok, run} ->
          {:noreply, s |> assign(:run, run) |> put_flash(:info, "Cancel sent to runner.")}

        _ ->
          {:noreply, put_flash(s, :error, "Unable to cancel.")}
      end
    end)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runs}
    >
      <:title>
        <span class="font-mono text-base">{@run.action_id}</span>
      </:title>
      <:actions>
        <.status_badge status={@run.status} />
        <%= if @run.status in ["sent", "running", "pending"] and Permissions.can?(assigns, :cancel_run) do %>
          <button
            phx-click="cancel"
            data-confirm="Cancel this run? The runner will SIGTERM then SIGKILL."
            class="rounded-lg border border-rose-500/40 px-3 py-1.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10"
          >
            Cancel run
          </button>
        <% end %>
      </:actions>

      <%= if @run.status == "pending_approval" and @approval_request do %>
        <div class="mb-6 flex items-center justify-between gap-4 rounded-xl border border-amber-900/40 bg-amber-950/30 p-4">
          <div>
            <div class="text-sm font-semibold text-amber-100">Waiting on approval</div>
            <p class="mt-1 text-xs text-amber-200/80">
              This run is held until an approver decides.
              <%= if @run.policy_reason do %>
                Policy: <span class="font-mono">{@run.policy_reason}</span>.
              <% end %>
            </p>
          </div>
          <.link
            navigate={~p"/app/approvals/#{@approval_request.id}"}
            class="shrink-0 rounded-lg border border-amber-500/40 px-3 py-1.5 text-sm font-medium text-amber-100 hover:bg-amber-500/10"
          >
            Review approval →
          </.link>
        </div>
      <% end %>

      <%= if @run.reason && @run.reason != "" do %>
        <.card class="mb-6">
          <.section_header title="Reason" />
          <p class="mt-3 whitespace-pre-wrap text-sm leading-relaxed text-zinc-200">{@run.reason}</p>
        </.card>
      <% end %>

      <%= if @run.policy_decision do %>
        <.card class="mb-6">
          <.section_header title="Policy decision" />
          <dl class="mt-4 grid grid-cols-1 gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <.kv label="Decision">
              <span class={[
                "rounded px-1.5 py-0.5 font-mono text-xs",
                policy_decision_class(@run.policy_decision)
              ]}>{@run.policy_decision}</span>
            </.kv>
            <.kv label="Policy">
              <span class="text-zinc-200">{policy_label(@run)}</span>
            </.kv>
            <.kv label="Matched rules">
              <span class="font-mono text-xs text-zinc-300">{matched_rules_label(@run.matched_rules)}</span>
            </.kv>
          </dl>
          <%= if @run.policy_reason && @run.policy_reason != "" do %>
            <p class="mt-3 text-xs text-zinc-400">
              <span class="text-zinc-500">Why:</span> {@run.policy_reason}
            </p>
          <% end %>
        </.card>
      <% end %>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card>
          <.section_header title="Summary" />
          <dl class="mt-4 space-y-3 text-sm">
            <.kv label="Request ID"><span class="font-mono text-xs">{@run.request_id}</span></.kv>
            <.kv label="Runner">
              <.link
                navigate={~p"/app/runners/#{@run.runner_id}"}
                class="text-sm text-indigo-300 hover:text-indigo-200"
              >
                {runner_label(@run.runner)}
              </.link>
            </.kv>
            <.kv label="Source">{@run.source}</.kv>
            <.kv label="Exit code">{@run.exit_code || "—"}</.kv>
            <.kv label="Duration">{format_duration(@run.duration_ms)}</.kv>
            <.kv label="Args SHA256"><span class="font-mono text-xs">{String.slice(@run.args_sha256 || "", 0, 16)}…</span></.kv>
          </dl>
        </.card>

        <.card class="lg:col-span-2">
          <.section_header title="Arguments" />
          <pre class="mt-4 max-h-64 overflow-auto rounded-lg bg-black/40 p-4 font-mono text-xs text-zinc-300">{format_json(@run.args)}</pre>
        </.card>
      </div>

      <.card class="mt-6">
        <.section_header title="Output stream" />
        <div class="mt-4 max-h-[60vh] overflow-auto rounded-lg bg-black/60 p-4 font-mono text-xs leading-relaxed text-zinc-300" id="run-output" phx-update="stream">
          <div :for={{id, event} <- @streams.events} id={id} class={[
            "whitespace-pre-wrap",
            event.stream == "stderr" && "text-rose-300"
          ]}>{event_chunk(event)}</div>
        </div>
      </.card>

      <%= if @run.error_message do %>
        <div class="mt-6 rounded-xl border border-rose-900/40 bg-rose-950/30 p-6 text-rose-100">
          <h3 class="text-sm font-semibold">Error</h3>
          <p class="mt-2 text-sm">{@run.error_message}</p>
        </div>
      <% end %>
    </.dashboard_shell>
    """
  end

  defp format_json(nil), do: "{}"
  defp format_json(map), do: Jason.encode!(map, pretty: true)

  defp runner_label(%Emisar.Runners.Runner{name: name}) when is_binary(name) and name != "", do: name
  defp runner_label(%Emisar.Runners.Runner{hostname: host}) when is_binary(host) and host != "", do: host
  defp runner_label(_), do: "Unknown runner"

  defp policy_decision_class("allow"), do: "bg-emerald-500/10 text-emerald-300 ring-1 ring-emerald-500/30"
  defp policy_decision_class("require_approval"), do: "bg-amber-500/10 text-amber-300 ring-1 ring-amber-500/30"
  defp policy_decision_class("deny"), do: "bg-rose-500/10 text-rose-300 ring-1 ring-rose-500/30"
  defp policy_decision_class(_), do: "bg-zinc-700/40 text-zinc-300 ring-1 ring-zinc-700"

  defp policy_label(%{policy_id: nil}), do: "—"

  defp policy_label(%{policy_id: id, policy_version: ver}) when not is_nil(id) do
    short = String.slice(id, 0, 8)
    if ver, do: "#{short} v#{ver}", else: short
  end

  defp policy_label(_), do: "—"

  defp matched_rules_label(nil), do: "—"
  defp matched_rules_label([]), do: "—"
  defp matched_rules_label(rules) when is_list(rules), do: Enum.join(rules, ", ")

  # Output chunks live inside `payload["chunk"]` (the runner socket
  # writes them that way). Older events that pre-date the schema
  # migration may have written a top-level `chunk` directly; render
  # whichever we find.
  defp event_chunk(%{payload: %{"chunk" => chunk}}) when is_binary(chunk), do: chunk
  defp event_chunk(_), do: ""
end
