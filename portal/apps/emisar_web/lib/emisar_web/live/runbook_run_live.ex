defmodule EmisarWeb.RunbookRunLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, Runbooks}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    case Runbooks.fetch_runbook_by_id(id, socket.assigns.current_subject) do
      {:ok, runbook} ->
        {:ok, runners, _} = Runners.list_runners_for_account(socket.assigns.current_subject)
        steps = Runbooks.expand(runbook)

        {:ok,
         socket
         |> assign(:page_title, "Run #{runbook.title}")
         |> assign(:runbook, runbook)
         |> assign(:runners, runners)
         |> assign(:steps, steps)
         |> assign(:runner_id, default_runner_id(runners))
         |> assign(:reason, "")}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Runbook not found.")
         |> push_navigate(to: ~p"/app/runbooks")}
    end
  end

  defp default_runner_id([]), do: nil
  defp default_runner_id([%{id: id} | _]), do: id

  defp format_reason(%Ecto.Changeset{} = cs), do: humanize_errors(cs)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp format_reason(_), do: "unknown error"

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
        case Runbooks.dispatch_runbook(socket.assigns.runbook, runner_id, reason, socket.assigns.current_subject) do
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
            {:noreply, put_flash(socket, :error, "Could not start runbook: #{format_reason(reason)}")}

          _other ->
            {:noreply, put_flash(socket, :error, "Could not start runbook. Try again.")}
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

      <div class="mx-auto max-w-3xl space-y-6">
        <%!-- How-it-works strip — short paragraph, replaces the
             stranded `-mt-4` lead-in that fought the page padding. --%>
        <p class="text-sm leading-relaxed text-zinc-400">
          Step 1 dispatches against the selected runner; each successive step fires
          when the previous step succeeds. A failed step stops the runbook — pick it
          up from the run detail page.
        </p>

        <%!-- Plan — ordered numbered list, terminal-y. Empty state
             tells the operator to edit first instead of dispatching
             nothing. --%>
        <section class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40">
          <header class="flex items-center justify-between border-b border-zinc-900 px-5 py-3">
            <h2 class="text-sm font-semibold text-zinc-100">Plan</h2>
            <span class="text-xs text-zinc-500">
              {length(@steps)} {if length(@steps) == 1, do: "step", else: "steps"}
            </span>
          </header>

          <%= if @steps == [] do %>
            <div class="px-5 py-10 text-center text-sm text-zinc-500">
              No steps defined.
              <.link
                navigate={~p"/app/runbooks/#{@runbook.id}/edit"}
                class="text-indigo-400 hover:text-indigo-300"
              >Edit the runbook</.link>
              first.
            </div>
          <% else %>
            <ol class="divide-y divide-zinc-900">
              <li
                :for={{step, idx} <- Enum.with_index(@steps)}
                class="flex items-start gap-3 px-5 py-3"
              >
                <span class="grid h-6 w-6 flex-shrink-0 place-items-center rounded-full bg-zinc-800 text-xs font-semibold text-zinc-300">
                  {idx + 1}
                </span>
                <div class="min-w-0 flex-1 text-sm">
                  <div class="truncate font-mono text-zinc-200">
                    {step["action"] || step["action_id"] || "—"}
                  </div>
                  <p :if={step["description"]} class="mt-0.5 truncate text-xs text-zinc-500">
                    {step["description"]}
                  </p>
                </div>
              </li>
            </ol>
          <% end %>
        </section>

        <%!-- Dispatch form — full width below the plan. Runner select
             + reason textarea + big start button. --%>
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <h2 class="text-sm font-semibold text-zinc-100">Dispatch</h2>

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
        </section>
      </div>
    </.dashboard_shell>
    """
  end
end
