defmodule EmisarWeb.ApprovalDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Approvals, PubSub, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id

    case Approvals.get_request(account_id, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Approval not found.")
         |> push_navigate(to: ~p"/app/approvals")}

      req ->
        if connected?(socket), do: PubSub.subscribe_account_approvals(account_id)

        run = Runs.get_run(account_id, req.run_id)

        {:ok,
         socket
         |> assign(:page_title, "Approval #{String.slice(req.id, 0, 8)}")
         |> assign(:request, req)
         |> assign(:run, run)
         |> assign(:decision_reason, "")}
    end
  end

  def handle_info({:approval_updated, %{id: id} = updated}, socket)
      when id == socket.assigns.request.id,
      do: {:noreply, assign(socket, :request, updated)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("approve", %{"reason" => reason}, socket) do
    Permissions.gated(socket, :decide_approval, fn s ->
      case Approvals.approve(s.assigns.request, s.assigns.current_user.id, blank_or(reason)) do
        {:ok, {req, _run}} ->
          {:noreply, s |> assign(:request, req) |> put_flash(:info, "Approved.")}

        _ ->
          {:noreply, put_flash(s, :error, "Could not approve.")}
      end
    end)
  end

  def handle_event("deny", %{"reason" => reason}, socket) do
    Permissions.gated(socket, :decide_approval, fn s ->
      case Approvals.deny(s.assigns.request, s.assigns.current_user.id, blank_or(reason)) do
        {:ok, {req, _run}} ->
          {:noreply, s |> assign(:request, req) |> put_flash(:info, "Denied.")}

        _ ->
          {:noreply, put_flash(s, :error, "Could not deny.")}
      end
    end)
  end

  defp blank_or(""), do: nil
  defp blank_or(s), do: s

  defp format_json(nil), do: "{}"
  defp format_json(map), do: Jason.encode!(map, pretty: true)

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:approvals}
    >
      <:title>Approval request</:title>
      <:actions>
        <.status_badge status={@request.status} />
      </:actions>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <.section_header title="What's being asked" />

          <dl class="mt-4 space-y-1 text-sm">
            <.kv label="Action"><span class="font-mono">{@request.context["action_id"]}</span></.kv>
            <.kv label="Runner"><span class="font-mono text-xs">{@request.context["runner_id"]}</span></.kv>
            <.kv label="Args SHA"><span class="font-mono text-xs">{String.slice(@request.context["args_sha256"] || "", 0, 16)}…</span></.kv>
            <.kv label="Requested by">{@request.requested_by_id || "—"}</.kv>
            <.kv label="When">{absolute_time(@request.requested_at)}</.kv>
          </dl>

          <%= if @request.reason do %>
            <div class="mt-6 rounded-lg border border-zinc-800 bg-black/30 p-4">
              <div class="text-xs uppercase tracking-wider text-zinc-500">Operator's reason</div>
              <div class="mt-2 text-sm whitespace-pre-wrap">{@request.reason}</div>
            </div>
          <% end %>

          <%= if @run && @run.policy_reason do %>
            <div class="mt-4 rounded-lg border border-amber-900/40 bg-amber-950/20 p-4">
              <div class="text-xs uppercase tracking-wider text-amber-400/80">Why approval is required</div>
              <div class="mt-2 text-sm text-amber-100">{@run.policy_reason}</div>
              <%= if @run.matched_rules && @run.matched_rules != [] do %>
                <div class="mt-2 text-xs text-amber-300/70">
                  Matched rules: <span class="font-mono">{Enum.join(@run.matched_rules, ", ")}</span>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @run && @run.args && @run.args != %{} do %>
            <div class="mt-6">
              <div class="text-xs uppercase tracking-wider text-zinc-500">Arguments</div>
              <pre class="mt-2 max-h-64 overflow-auto rounded-lg bg-black/40 p-4 font-mono text-xs text-zinc-300">{format_json(@run.args)}</pre>
            </div>
          <% end %>

          <%= if @run do %>
            <div class="mt-6">
              <.link navigate={~p"/app/runs/#{@run.id}"} class="text-sm text-indigo-400 hover:text-indigo-300">
                View run →
              </.link>
            </div>
          <% end %>
        </.card>

        <%= if @request.status == "pending" do %>
          <.card>
            <.section_header title="Decision" />
            <p class="mt-2 text-xs text-zinc-500">
              Your decision and reason are logged in audit.
            </p>

            <%= if Permissions.can?(assigns, :decide_approval) do %>
              <form phx-submit="approve" class="mt-4">
                <input type="text" name="reason" placeholder="Optional reason" value={@decision_reason}
                  class="mb-3 w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 placeholder:text-zinc-600 focus:ring-indigo-500"
                />
                <button class="w-full rounded-lg bg-emerald-500 px-3 py-2 text-sm font-semibold text-zinc-950 hover:bg-emerald-400">
                  Approve and send
                </button>
              </form>

              <form phx-submit="deny" class="mt-3">
                <input type="hidden" name="reason" value={@decision_reason} />
                <button class="w-full rounded-lg border border-rose-500/40 px-3 py-2 text-sm font-medium text-rose-200 hover:bg-rose-500/10">
                  Deny
                </button>
              </form>
            <% else %>
              <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
                Viewers can't decide approvals.
              </p>
            <% end %>
          </.card>
        <% else %>
          <.card>
            <.section_header title="Decision history" />
            <dl class="mt-4 space-y-1 text-sm">
              <.kv label="Status">{@request.status}</.kv>
              <.kv label="Decided at">{absolute_time(@request.decided_at)}</.kv>
              <.kv label="Decided by">{@request.decided_by_id || "—"}</.kv>
            </dl>
          </.card>
        <% end %>
      </div>
    </.dashboard_shell>
    """
  end

end
