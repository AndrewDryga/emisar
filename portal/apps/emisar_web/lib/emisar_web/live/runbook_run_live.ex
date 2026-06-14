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
        # they don't run twice (IL-18). The dead pass renders an empty plan.
        socket =
          socket
          |> assign(:page_title, "Run #{runbook.title}")
          |> assign(:runbook, runbook)
          |> assign(:reason, "")
          |> assign(:errors, %{})
          |> assign(:execution, nil)
          |> assign(:run_statuses, %{})
          # run_id => run, so a presence change can re-insert the streamed
          # rows to refresh their offline markers (streams don't re-render
          # on a bare assign change).
          |> assign(:run_index, %{})
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

    # Execution runs stream in over the account topic as the engine creates +
    # transitions them (`{:run_updated, run}`); the connection feed lets a row
    # flag its runner dropping mid-execution (why an in-flight wave stalled).
    Runs.subscribe_account_runs(socket.assigns.current_account.id)
    Runners.subscribe_connections(socket.assigns.current_account.id)

    socket
    # Runners back the per-step target labels (runner-id selectors resolve
    # to names) — each step carries its own target, set in the editor.
    |> assign(:runners, runners)
    |> assign(:steps, Runbooks.expand(runbook))
    # action_id → risk, so the plan can show which steps are read-only
    # (low) vs which will stop for approval before a fleet-wide dispatch.
    # Most-severe across runners — a group target hits every member, so
    # showing the recent-but-lower risk would under-warn.
    |> assign(:action_risk, Catalog.most_severe_risk_by_action(runner_actions))
  end

  defp empty_run_form(socket) do
    socket
    |> assign(:runners, [])
    |> assign(:steps, [])
    |> assign(:action_risk, %{})
  end

  # Risk of a plan step's action, or nil when the catalog hasn't observed
  # it (no connected runner advertises it yet) — the pill then hides.
  defp step_risk(action_risk, step),
    do: Map.get(action_risk, step["action_id"] || step["action"])

  # Where a plan step will run, from its own runner_selector: group names
  # as-is, runner ids resolved to names against the loaded runner list.
  # nil when the step has no target (a draft being test-run).
  defp step_target_label(step, runners) do
    case Runbooks.StepSelector.parse(step["runner_selector"]) do
      {"group", [_ | _] = groups} ->
        "group: " <> Enum.join(groups, ", ")

      {"runner_id", [_ | _] = ids} ->
        names = runner_names(ids, runners)
        if names == [], do: nil, else: Enum.join(names, ", ")

      _ ->
        nil
    end
  end

  defp runner_names(ids, runners),
    do: runners |> Enum.filter(&(&1.id in ids)) |> Enum.map(& &1.name)

  # Per-field validation of the operator-entered run parameters. Keyed by the
  # form field so the LiveView can render each message inline under its input.
  # Targets now come from the steps, so reason is the only run-time input.
  defp run_param_errors(reason) do
    %{}
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
  defp clear_resolved_errors(errors, reason) do
    resolved = run_param_errors(reason)
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
    reason = params["reason"] || socket.assigns.reason

    {:noreply,
     socket
     |> assign(:reason, reason)
     # Clear the error as soon as the operator fills the field in. We only
     # *remove* errors here (never add) — a blank field shouldn't show "required"
     # until the operator actually tries to dispatch.
     |> assign(:errors, clear_resolved_errors(socket.assigns.errors, reason))}
  end

  def handle_event("dispatch", params, socket) do
    Permissions.gated(
      socket,
      Runs.subject_can_dispatch_run?(socket.assigns.current_subject),
      &do_dispatch(&1, params)
    )
  end

  defp do_dispatch(socket, params) do
    reason = (params["reason"] || socket.assigns.reason || "") |> String.trim()
    errors = run_param_errors(reason)

    # A missing reason is a validation of the one operator-entered run
    # parameter, so it renders inline under the field, not in a flash.
    if errors != %{} do
      {:noreply, socket |> assign(:reason, reason) |> assign(:errors, errors)}
    else
      case Runbooks.dispatch_runbook(
             socket.assigns.runbook,
             reason,
             socket.assigns.current_subject
           ) do
        {:ok, execution} ->
          # Render the whole plan as placeholder rows up front (one per
          # step×runner the execution will run), then flip each in place to
          # its live run as it streams in via the account-runs subscription —
          # matched by (step_id, runner_id). The list is static; only statuses
          # change. Reset clears a prior run's rows on a re-dispatch.
          {:noreply,
           socket
           |> assign(:execution, execution)
           |> assign(:run_statuses, %{})
           |> assign(:run_index, %{})
           |> stream(:execution_runs, plan_rows(execution.plan, socket.assigns.runners),
             reset: true
           )
           |> put_flash(:info, "Runbook dispatched — #{execution.total} runs planned.")
           |> flash_dispatch_errors(execution.errors)}

        {:error, :empty_runbook} ->
          {:noreply, put_flash(socket, :error, "Runbook has no steps to run.")}

        {:error, {:step_no_runners, step_number}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Step #{step_number} has no available runners — its group is empty or its " <>
               "runners are offline. Edit the runbook's targets and try again."
           )}

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
      # Same dom_id as the placeholder (step_id, runner_id) → replaces it in
      # place rather than appending a new row.
      {:noreply,
       socket
       |> assign(:run_statuses, Map.put(socket.assigns.run_statuses, run.id, run.status))
       |> assign(:run_index, Map.put(socket.assigns.run_index, run.id, run))
       |> stream_insert(:execution_runs, live_row(run))}
    else
      {:noreply, socket}
    end
  end

  # A runner connected/disconnected — streamed rows don't re-render on a bare
  # assign change, so re-insert the execution's runs to refresh each row's
  # offline marker against current presence.
  def handle_info(%{event: "presence_diff"}, socket) do
    socket =
      Enum.reduce(Map.values(socket.assigns.run_index), socket, fn run, socket ->
        stream_insert(socket, :execution_runs, live_row(run))
      end)

    {:noreply, socket}
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

  # An in-flight run whose runner's socket is currently gone — surfaces *why*
  # a wave stalled instead of leaving the row looking merely slow.
  defp offline_mid_run?(%{status: status} = run) when status in [:pending, :sent, :running],
    do: not Runners.online?(run.account_id, run.runner_id)

  defp offline_mid_run?(_), do: false

  # The execution table streams unified row structs (not raw runs): a
  # `:planned` placeholder per planned (step, runner), each flipped to its
  # live run by a shared dom_id. `run` is nil until the run arrives.
  defp plan_rows(plan, runners), do: Enum.map(plan, &plan_row(&1, runners))

  defp plan_row(item, runners) do
    %{
      id: row_dom_id(item.step_id, item.runner_id),
      action_id: item.action_id,
      runner_name: runner_name(item.runner_id, runners),
      status: :planned,
      run: nil
    }
  end

  defp live_row(run) do
    %{
      id: row_dom_id(run.runbook_step_id, run.runner_id),
      action_id: run.action_id,
      runner_name: run.runner.name,
      status: run.status,
      run: run
    }
  end

  defp row_dom_id(step_id, runner_id), do: "run-#{step_id}-#{runner_id}"

  defp runner_name(runner_id, runners) do
    case Enum.find(runners, &(&1.id == runner_id)) do
      nil -> "(unknown runner)"
      runner -> runner.name
    end
  end

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
          Steps dispatch in parallel waves of five, each against the runner — or group — it
          targets. A failed run stops the waves behind it; results stream in below as they
          arrive.
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
              :for={{dom_id, row} <- @streams.execution_runs}
              id={dom_id}
              class="flex items-center gap-3 px-5 py-2.5 text-sm"
            >
              <.status_badge status={row.status} />
              <div class="min-w-0 flex-1">
                <span class="truncate font-mono text-zinc-200">{row.action_id}</span>
                <span class="ml-2 truncate text-xs text-zinc-500">
                  on {row.runner_name}
                </span>
                <span
                  :if={row.run && offline_mid_run?(row.run)}
                  class="ml-1 inline-flex items-center gap-1 text-xs text-amber-400"
                  title="Runner offline — this run may stall until it reconnects or times out"
                >
                  <.icon name="hero-signal-slash" class="h-3 w-3" /> offline
                </span>
              </div>
              <span :if={row.run && row.run.duration_ms} class="text-xs tabular-nums text-zinc-500">
                {row.run.duration_ms} ms
              </span>
              <.link
                :if={row.run}
                navigate={~p"/app/runs/#{row.run.id}"}
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
                <% target = step_target_label(step, @runners) %>
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
                <p :if={target} class="mt-0.5 truncate text-xs text-indigo-300/70">
                  → {target}
                </p>
                <p :if={!target} class="mt-0.5 truncate text-xs text-amber-400/80">
                  → no target set
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

        <%!-- Dispatch form — full width below the plan. Targets come from
             the steps now, so this is just the reason + start button. --%>
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <h2 class="text-sm font-semibold text-zinc-100">Dispatch</h2>

          <form phx-change="validate" phx-submit="dispatch" class="mt-4 space-y-4">
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
