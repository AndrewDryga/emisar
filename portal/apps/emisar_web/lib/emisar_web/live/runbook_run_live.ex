defmodule EmisarWeb.RunbookRunLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, Runbooks}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id

    case Runbooks.get_runbook(account_id, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Runbook not found.")
         |> push_navigate(to: ~p"/app/runbooks")}

      runbook ->
        runners = Runners.list_runners_for_account(account_id)
        steps = Runbooks.expand(runbook)

        {:ok,
         socket
         |> assign(:page_title, "Run #{runbook.title}")
         |> assign(:runbook, runbook)
         |> assign(:runners, runners)
         |> assign(:steps, steps)
         |> assign(:runner_id, default_runner_id(runners))
         |> assign(:reason, "")}
    end
  end

  defp default_runner_id([]), do: nil
  defp default_runner_id([%{id: id} | _]), do: id

  def handle_event("validate", params, socket) do
    {:noreply,
     socket
     |> assign(:runner_id, params["runner_id"] || socket.assigns.runner_id)
     |> assign(:reason, params["reason"] || socket.assigns.reason)}
  end

  def handle_event("dispatch", params, socket) do
    Permissions.gated(socket, :dispatch_run, fn s ->
      do_dispatch(s, params)
    end)
  end

  defp do_dispatch(socket, params) do
    runner_id = params["runner_id"] || socket.assigns.runner_id
    reason = (params["reason"] || socket.assigns.reason || "") |> String.trim()

    cond do
      runner_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Pick a runner to execute this runbook on.")}

      reason == "" ->
        {:noreply,
         socket
         |> assign(:reason, reason)
         |> put_flash(:error, "Reason is required — describe why you're running this runbook.")}

      true ->
        case Runbooks.dispatch_runbook(socket.assigns.runbook, runner_id, socket.assigns.current_user.id, reason) do
          {:ok, _status, first_run} ->
            {:noreply,
             socket
             |> put_flash(:info, "Runbook started. Step 1 dispatched.")
             |> push_navigate(to: ~p"/app/runs/#{first_run.id}")}

          {:error, :denied_by_policy, policy_reason} ->
            {:noreply, put_flash(socket, :error, "Step 1 denied by policy: #{policy_reason}")}

          {:error, :empty_runbook} ->
            {:noreply, put_flash(socket, :error, "Runbook has no steps to run.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not start runbook: #{inspect(reason)}")}

          other ->
            {:noreply, put_flash(socket, :error, "Unexpected: #{inspect(other)}")}
        end
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
      <:title>Run <span class="font-mono text-base">{@runbook.title}</span></:title>

      <p class="-mt-4 mb-8 max-w-2xl text-sm text-zinc-400">
        Dispatches step 1 against the selected runner. Each successive step
        fires automatically when the previous step's run completes
        successfully. A failed step stops the runbook — pick it up from the
        run detail page.
      </p>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <.section_header title="Plan" />
          <%= if @steps == [] do %>
            <p class="mt-4 text-sm text-zinc-400">This runbook has no steps. Edit it first.</p>
          <% else %>
            <ol class="mt-4 space-y-2">
              <%= for {step, idx} <- Enum.with_index(@steps) do %>
                <li class="flex items-start gap-3 rounded-lg border border-zinc-800 bg-black/30 p-3">
                  <span class="grid h-6 w-6 flex-shrink-0 place-items-center rounded-full bg-zinc-800 text-xs font-semibold text-zinc-300">
                    {idx + 1}
                  </span>
                  <div class="min-w-0 flex-1 text-sm">
                    <div class="font-mono text-zinc-200">{step["action"] || step["action_id"] || "—"}</div>
                    <%= if step["description"] do %>
                      <p class="mt-1 text-xs text-zinc-400">{step["description"]}</p>
                    <% end %>
                  </div>
                </li>
              <% end %>
            </ol>
          <% end %>
        </.card>

        <.card>
          <.section_header title="Dispatch" />
          <form phx-change="validate" phx-submit="dispatch" class="mt-4 space-y-4">
            <div>
              <label class="block text-sm font-medium text-zinc-200">Runner</label>
              <%= if @runners == [] do %>
                <p class="mt-2 rounded-lg bg-zinc-900/60 p-3 text-xs text-zinc-400">
                  No runners registered. Connect one first.
                </p>
              <% else %>
                <select
                  name="runner_id"
                  class="mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100 ring-1 ring-inset ring-zinc-800 focus:ring-2 focus:ring-indigo-500"
                >
                  <option :for={r <- @runners} value={r.id} selected={r.id == @runner_id}>
                    {r.name} ({r.group})
                  </option>
                </select>
              <% end %>
            </div>

            <div>
              <label class="block text-sm font-medium text-zinc-200">Reason (required)</label>
              <textarea
                name="reason"
                rows="2"
                required
                placeholder="Why are you running this runbook now?"
                class="mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100 ring-1 ring-inset ring-zinc-800 focus:ring-2 focus:ring-indigo-500"
              ><%= @reason %></textarea>
              <p class="mt-1 text-xs text-zinc-500">Logged in audit + propagated to every step.</p>
            </div>

            <.button class="w-full" phx-disable-with="Starting...">
              Start runbook
            </.button>
          </form>
        </.card>
      </div>
    </.dashboard_shell>
    """
  end
end
