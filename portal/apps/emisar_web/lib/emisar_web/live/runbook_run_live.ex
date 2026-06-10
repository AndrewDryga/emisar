defmodule EmisarWeb.RunbookRunLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runbooks, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    case Runbooks.fetch_runbook_by_id(id, socket.assigns.current_subject) do
      {:ok, runbook} ->
        # The runbook fetch above gates render/redirect, so it stays in
        # mount. The runner list + step expansion are heavier reads only
        # the connected page needs — defer them behind `connected?/1` so
        # they don't run twice (IL-18). The dead pass renders an empty
        # plan + runner select.
        socket =
          socket
          |> assign(:page_title, "Run #{runbook.title}")
          |> assign(:runbook, runbook)
          |> assign(:reason, "")
          |> assign(:errors, %{})

        if connected?(socket) do
          {:ok, load_run_form(socket, runbook)}
        else
          {:ok, empty_run_form(socket)}
        end

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Runbook not found.")
         |> push_navigate(to: ~p"/app/runbooks")}
    end
  end

  defp load_run_form(socket, runbook) do
    {:ok, runners, _} = Runners.list_runners_for_account(socket.assigns.current_subject)

    socket
    |> assign(:runners, runners)
    |> assign(:steps, Runbooks.expand(runbook))
    |> assign(:runner_id, default_runner_id(runners))
  end

  defp empty_run_form(socket) do
    socket
    |> assign(:runners, [])
    |> assign(:steps, [])
    |> assign(:runner_id, nil)
  end

  defp default_runner_id([]), do: nil
  defp default_runner_id([%{id: id} | _]), do: id

  # Per-field validation of the operator-entered run parameters. Keyed by the
  # form field so the LiveView can render each message inline under its input.
  defp run_param_errors(runner_id, reason) do
    %{}
    |> put_error(:runner_id, runner_id in [nil, ""], "Pick a runner to execute this runbook on.")
    |> put_error(
      :reason,
      String.trim(reason || "") == "",
      "Reason is required — describe why you're running this runbook."
    )
  end

  defp put_error(errors, _field, false, _msg), do: errors
  defp put_error(errors, field, true, msg), do: Map.put(errors, field, msg)

  # Drop a field's inline error once it's been filled in — leaves any still-
  # blank field's error in place so a partial fix doesn't hide the rest.
  defp clear_resolved_errors(errors, runner_id, reason) do
    resolved = run_param_errors(runner_id, reason)
    Map.filter(errors, fn {field, _msg} -> Map.has_key?(resolved, field) end)
  end

  # Dispatch-field classes, swapping in the rose ring when the field has an
  # inline error — same border-highlight treatment `<.input>` applies.
  @field_base "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100 ring-1 ring-inset focus:ring-2"

  defp field_class(nil), do: [@field_base, "ring-zinc-800 focus:ring-indigo-500"]
  defp field_class(_error), do: [@field_base, "ring-rose-500/50 focus:ring-rose-500"]

  # Genuine, non-field dispatch failures (policy denial, runner offline, a
  # run-row constraint) are surfaced in a concise flash — they aren't a single
  # input the operator can correct in place.
  defp format_reason(%Ecto.Changeset{}), do: "the run could not be created"
  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_reason(_), do: "unknown error"

  def handle_event("validate", params, socket) do
    runner_id = params["runner_id"] || socket.assigns.runner_id
    reason = params["reason"] || socket.assigns.reason

    {:noreply,
     socket
     |> assign(:runner_id, runner_id)
     |> assign(:reason, reason)
     # Clear each field's error as soon as the operator fills it in. We only
     # *remove* errors here (never add) — a blank field shouldn't show "required"
     # until the operator actually tries to dispatch.
     |> assign(:errors, clear_resolved_errors(socket.assigns.errors, runner_id, reason))}
  end

  def handle_event("dispatch", params, socket) do
    Permissions.gated(
      socket,
      Runs.subject_can_dispatch_run?(socket.assigns.current_subject),
      fn s ->
        do_dispatch(s, params)
      end
    )
  end

  defp do_dispatch(socket, params) do
    runner_id = params["runner_id"] || socket.assigns.runner_id
    reason = (params["reason"] || socket.assigns.reason || "") |> String.trim()
    errors = run_param_errors(runner_id, reason)

    # Missing runner / reason are validations of operator-entered run parameters,
    # so they render inline under their field, not in a flash.
    if errors != %{} do
      {:noreply, socket |> assign(:reason, reason) |> assign(:errors, errors)}
    else
      case Runbooks.dispatch_runbook(
             socket.assigns.runbook,
             runner_id,
             reason,
             socket.assigns.current_subject
           ) do
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
          {:noreply,
           put_flash(socket, :error, "Could not start runbook: #{format_reason(reason)}")}

        _other ->
          {:noreply, put_flash(socket, :error, "Could not start runbook. Try again.")}
      end
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
              >
                Edit the runbook
              </.link>
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
                <select name="runner_id" class={field_class(@errors[:runner_id])}>
                  <option :for={r <- @runners} value={r.id} selected={r.id == @runner_id}>
                    {r.name} ({r.group})
                  </option>
                </select>
                <.error :if={@errors[:runner_id]}>{@errors[:runner_id]}</.error>
              <% end %>
            </div>

            <div>
              <label class="block text-sm font-medium text-zinc-200">Reason (required)</label>
              <textarea
                name="reason"
                rows="2"
                required
                placeholder="Why are you running this runbook now?"
                class={field_class(@errors[:reason])}
              ><%= @reason %></textarea>
              <.error :if={@errors[:reason]}>{@errors[:reason]}</.error>
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
