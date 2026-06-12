defmodule EmisarWeb.RunbookRunLive do
  use EmisarWeb, :live_view

  alias Emisar.{Catalog, Runbooks, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    case Runbooks.fetch_runbook_by_id(id, socket.assigns.current_subject) do
      {:ok, runbook} ->
        # The runbook fetch above gates render/redirect, so it stays in
        # mount. The runner list + step expansion are heavier reads only
        # the connected page needs — defer them behind `connected?/1` so
        # they don't run twice (IL-18). The dead pass renders an empty
        # plan + target select.
        socket =
          socket
          |> assign(:page_title, "Run #{runbook.title}")
          |> assign(:runbook, runbook)
          |> assign(:reason, "")
          |> assign(:errors, %{})
          |> assign(:execution, nil)
          |> assign(:run_statuses, %{})
          |> stream(:execution_runs, [])

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
    subject = socket.assigns.current_subject
    {:ok, runners, _} = Runners.list_runners_for_account(subject)
    {:ok, runner_actions} = Catalog.list_all_actions_for_account(subject)

    # Execution runs stream in over the account topic as the engine
    # creates + transitions them (`{:run_updated, run}`).
    Runs.subscribe_account_runs(socket.assigns.current_account.id)

    socket
    |> assign(:runners, runners)
    |> assign(:groups, runner_groups(runners))
    |> assign(:steps, Runbooks.expand(runbook))
    # action_id → risk, so the plan can show which steps are read-only
    # (low) vs which will stop for approval before a fleet-wide dispatch.
    |> assign(:action_risk, Map.new(runner_actions, &{&1.action_id, &1.risk}))
    |> assign(:target, default_target(runners))
  end

  defp empty_run_form(socket) do
    socket
    |> assign(:runners, [])
    |> assign(:groups, [])
    |> assign(:steps, [])
    |> assign(:action_risk, %{})
    |> assign(:target, nil)
  end

  # Risk of a plan step's action, or nil when the catalog hasn't observed
  # it (no connected runner advertises it yet) — the pill then hides.
  defp step_risk(action_risk, step),
    do: Map.get(action_risk, step["action_id"] || step["action"])

  # Groups with at least one enabled runner — mirrors what a group
  # dispatch would actually resolve to.
  defp runner_groups(runners) do
    runners
    |> Enum.reject(& &1.disabled_at)
    |> Enum.map(& &1.group)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp default_target([]), do: nil
  defp default_target([%{id: id} | _]), do: "runner:" <> id

  defp parse_target("runner:" <> runner_id), do: {:runner, runner_id}
  defp parse_target("group:" <> group), do: {:group, group}
  defp parse_target(_), do: nil

  # Per-field validation of the operator-entered run parameters. Keyed by the
  # form field so the LiveView can render each message inline under its input.
  defp run_param_errors(target, reason) do
    %{}
    |> put_error(
      :target,
      parse_target(target) == nil,
      "Pick a runner or group to execute this runbook on."
    )
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
  defp clear_resolved_errors(errors, target, reason) do
    resolved = run_param_errors(target, reason)
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
    target = params["target"] || socket.assigns.target
    reason = params["reason"] || socket.assigns.reason

    {:noreply,
     socket
     |> assign(:target, target)
     |> assign(:reason, reason)
     # Clear each field's error as soon as the operator fills it in. We only
     # *remove* errors here (never add) — a blank field shouldn't show "required"
     # until the operator actually tries to dispatch.
     |> assign(:errors, clear_resolved_errors(socket.assigns.errors, target, reason))}
  end

  def handle_event("dispatch", params, socket) do
    Permissions.gated(
      socket,
      Runs.subject_can_dispatch_run?(socket.assigns.current_subject),
      &do_dispatch(&1, params)
    )
  end

  defp do_dispatch(socket, params) do
    target = params["target"] || socket.assigns.target
    reason = (params["reason"] || socket.assigns.reason || "") |> String.trim()
    errors = run_param_errors(target, reason)

    # Missing target / reason are validations of operator-entered run parameters,
    # so they render inline under their field, not in a flash.
    if errors != %{} do
      {:noreply, socket |> assign(:reason, reason) |> assign(:errors, errors)}
    else
      case Runbooks.dispatch_runbook(
             socket.assigns.runbook,
             parse_target(target),
             reason,
             socket.assigns.current_subject
           ) do
        {:ok, execution} ->
          # The run rows stream in via the account-runs subscription (the
          # engine broadcast each create before this returned), so the
          # stream only needs resetting for a re-run.
          {:noreply,
           socket
           |> assign(:execution, execution)
           |> assign(:run_statuses, %{})
           |> stream(:execution_runs, [], reset: true)
           |> put_flash(:info, "Runbook dispatched — #{execution.total} runs planned.")
           |> flash_dispatch_errors(execution.errors)}

        {:error, :empty_runbook} ->
          {:noreply, put_flash(socket, :error, "Runbook has no steps to run.")}

        {:error, :no_runners_in_group} ->
          {:noreply, put_flash(socket, :error, "No active runners in that group.")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not start runbook: #{format_reason(reason)}")}
      end
    end
  end

  defp flash_dispatch_errors(socket, []), do: socket

  defp flash_dispatch_errors(socket, [first | _] = errors) do
    put_flash(
      socket,
      :error,
      "#{length(errors)} of the first wave's runs failed to dispatch: #{format_reason(first)}"
    )
  end

  def handle_info({:run_updated, run}, socket) do
    execution = socket.assigns.execution

    if execution && run.runbook_execution_id == execution.execution_id do
      {:noreply,
       socket
       |> assign(:run_statuses, Map.put(socket.assigns.run_statuses, run.id, run.status))
       |> stream_insert(:execution_runs, run)}
    else
      {:noreply, socket}
    end
  end

  # The shared badge hooks forward account-topic broadcasts to every
  # authenticated LiveView — swallow whatever this page doesn't render.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp finished_count(run_statuses),
    do: Enum.count(run_statuses, fn {_id, status} -> run_settled?(status) end)

  defp failed_count(run_statuses),
    do: Enum.count(run_statuses, fn {_id, status} -> run_failed?(status) end)

  # "denied" never reaches a terminal transition but is as settled as a
  # run gets — count it alongside the terminal states.
  defp run_settled?(status), do: Runs.ActionRun.terminal?(status) or status == :denied

  defp run_failed?(status), do: run_settled?(status) and status != :success

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
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
          Steps dispatch in parallel waves of five against the selected runner — or every
          active runner in the selected group. A failed run stops the waves behind it;
          results stream in below as they arrive.
        </p>

        <%!-- One table, not two. Idle: the plan (numbered steps). Once
             dispatched: the live runs replace those rows in place, while
             the planned-step count stays in the header for context — a
             step fans out to one run per targeted runner, so there can be
             more runs than steps. --%>
        <section
          id="execution"
          class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
        >
          <header class="flex items-center justify-between border-b border-zinc-900 px-5 py-3">
            <h2 class="text-sm font-semibold text-zinc-100">
              {if @execution, do: "Execution", else: "Plan"}
            </h2>
            <span class="text-xs text-zinc-500">
              {length(@steps)} {if length(@steps) == 1, do: "step", else: "steps"}
              <span :if={@execution}>
                · {finished_count(@run_statuses)}/{@execution.total} finished
                <span :if={failed_count(@run_statuses) > 0} class="text-rose-400">
                  · {failed_count(@run_statuses)} failed
                </span>
              </span>
            </span>
          </header>

          <%!-- Live runs once dispatched. Each row updates in place as its
               run transitions (the status badge flips to success / failed). --%>
          <ul
            :if={@execution}
            id="execution-runs"
            phx-update="stream"
            class="divide-y divide-zinc-900"
          >
            <li
              :for={{dom_id, run} <- @streams.execution_runs}
              id={dom_id}
              class="flex items-center gap-3 px-5 py-2.5 text-sm"
            >
              <.status_badge status={run.status} />
              <div class="min-w-0 flex-1">
                <span class="truncate font-mono text-zinc-200">{run.action_id}</span>
                <span class="ml-2 truncate text-xs text-zinc-500">
                  on {run.runner.name}
                </span>
              </div>
              <span :if={run.duration_ms} class="text-xs tabular-nums text-zinc-500">
                {run.duration_ms} ms
              </span>
              <.link
                navigate={~p"/app/runs/#{run.id}"}
                class="text-xs text-indigo-400 hover:text-indigo-300"
              >
                View
              </.link>
            </li>
          </ul>

          <%!-- Plan steps, shown until the first dispatch. --%>
          <ol :if={!@execution && @steps != []} class="divide-y divide-zinc-900">
            <li
              :for={{step, idx} <- Enum.with_index(@steps)}
              class="flex items-start gap-3 px-5 py-3"
            >
              <span class="grid h-6 w-6 flex-shrink-0 place-items-center rounded-full bg-zinc-800 text-xs font-semibold text-zinc-300">
                {idx + 1}
              </span>
              <div class="min-w-0 flex-1 text-sm">
                <div class="flex items-center gap-2">
                  <span class="truncate font-mono text-zinc-200">
                    {step["action"] || step["action_id"] || "—"}
                  </span>
                  <.risk_pill
                    :if={step_risk(@action_risk, step)}
                    risk={step_risk(@action_risk, step)}
                    class="flex-none"
                  />
                </div>
                <p :if={step["description"]} class="mt-0.5 truncate text-xs text-zinc-500">
                  {step["description"]}
                </p>
              </div>
            </li>
          </ol>

          <%!-- Nothing to run — nudge to the editor instead of dispatching
               an empty runbook. --%>
          <div
            :if={!@execution && @steps == []}
            class="px-5 py-10 text-center text-sm text-zinc-500"
          >
            No steps defined.
            <.link
              navigate={~p"/app/runbooks/#{@runbook.id}/edit"}
              class="text-indigo-400 hover:text-indigo-300"
            >
              Edit the runbook
            </.link>
            first.
          </div>
        </section>

        <%!-- Dispatch form — full width below the plan. Target select
             (groups + runners) + reason textarea + big start button. --%>
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <h2 class="text-sm font-semibold text-zinc-100">Dispatch</h2>

          <form phx-change="validate" phx-submit="dispatch" class="mt-4 space-y-4">
            <div>
              <label class="block text-sm font-medium text-zinc-200">Run on</label>
              <%= if @runners == [] do %>
                <p class="mt-2 rounded-lg bg-zinc-900/60 p-3 text-xs text-zinc-400">
                  No runners registered. Connect one first.
                </p>
              <% else %>
                <select name="target" class={field_class(@errors[:target])}>
                  <optgroup :if={@groups != []} label="Runner groups">
                    <option
                      :for={group <- @groups}
                      value={"group:" <> group}
                      selected={@target == "group:" <> group}
                    >
                      {group} (group)
                    </option>
                  </optgroup>
                  <optgroup label="Runners">
                    <option
                      :for={runner <- @runners}
                      value={"runner:" <> runner.id}
                      selected={@target == "runner:" <> runner.id}
                    >
                      {runner.name} ({runner.group})
                    </option>
                  </optgroup>
                </select>
                <.error :if={@errors[:target]}>{@errors[:target]}</.error>
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
