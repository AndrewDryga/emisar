defmodule EmisarWeb.RunbookRunLive do
  use EmisarWeb, :live_view
  alias Emisar.{Catalog, Policies, Runbooks, Runners, Runs}
  alias EmisarWeb.Permissions

  # The blast-radius assign's resting shape, so the render reads it without a
  # nil-guard: `counts` (step_index => runner count), `total`/`waves` (nil until
  # resolved), `no_runners_step` (the step a `group:` empties to, or nil), `plan`
  # (the resolved %{step_index, action_id, runner_id} work-list, reused to predict
  # each step's policy decision).
  @empty_blast %{counts: %{}, total: nil, waves: nil, no_runners_step: nil, plan: []}

  # Tail of a finished run's output shown inline on its execution row — a
  # glanceable preview, not the full terminal (that's the run-detail page).
  @output_preview_lines 8

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
          # False until the connected pass loads the plan + rehydrates any active
          # run, so the dead render shows a loading state instead of flashing the
          # empty plan + dispatch form (which then flip to the live execution).
          |> assign(:loaded?, false)
          |> assign(:reason, "")
          |> assign(:errors, %{})
          |> assign(:execution, nil)
          |> assign(:run_statuses, %{})
          # run_id => run, so a presence change can re-insert the streamed
          # rows to refresh their offline markers (streams don't re-render
          # on a bare assign change).
          |> assign(:run_index, %{})
          # run_id => tail events, fetched once per run as it finishes, so
          # its output preview survives a presence re-render of the row.
          |> assign(:run_outputs, %{})
          |> stream(:execution_runs, [])

        if connected?(socket) do
          {:ok,
           socket
           |> load_run_form(runbook)
           |> maybe_rehydrate_execution(runbook)
           |> assign(:loaded?, true)}
        else
          {:ok, empty_run_form(socket)}
        end

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Runbook not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
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

    action_risk = Catalog.most_severe_risk_by_action(runner_actions)
    blast_radius = build_blast_radius(runbook, subject)

    socket
    # Runners back the per-step target labels (runner-id selectors resolve
    # to names) — each step carries its own target, set in the editor.
    |> assign(:runners, runners)
    |> assign(:steps, Runbooks.expand(runbook))
    # action_id → risk, so the plan can show which steps are read-only
    # (low) vs which will stop for approval before a fleet-wide dispatch.
    # Most-severe across runners — a group target hits every member, so
    # showing the recent-but-lower risk would under-warn.
    |> assign(:action_risk, action_risk)
    # Blast radius: resolve the work-list NOW (no dispatch) so the operator sees
    # how many runs each step fans out to + the wave total before pressing Start.
    |> assign(:blast_radius, blast_radius)
    # step_index => :require_approval | :deny — the decision dispatch's policy
    # will reach for that step, so the operator isn't surprised mid-run by a
    # step queueing for a human (or being blocked) instead of running.
    |> assign(
      :step_decisions,
      predict_step_decisions(blast_radius.plan, runners, action_risk, subject)
    )
  end

  defp empty_run_form(socket) do
    socket
    |> assign(:runners, [])
    |> assign(:steps, [])
    |> assign(:action_risk, %{})
    |> assign(:blast_radius, @empty_blast)
    |> assign(:step_decisions, %{})
  end

  # Normalize `Runbooks.resolve_plan/2` for the render: per-step runner counts
  # keyed by step index (so the plan rows match), the run + wave totals, or a
  # `no_runners_step` warning when a step's target resolves to nothing (dispatch
  # would refuse it — better the operator sees that here than after Start). The
  # resting `@empty_blast` when the runbook can't resolve (empty / unauthorized).
  defp build_blast_radius(runbook, subject) do
    case Runbooks.resolve_plan(runbook, subject) do
      {:ok, %{plan: plan, total: total, waves: waves}} ->
        %{
          @empty_blast
          | counts: Enum.frequencies_by(plan, & &1.step_index),
            total: total,
            waves: waves,
            plan: plan
        }

      {:error, {:step_no_runners, step_number}} ->
        %{@empty_blast | no_runners_step: step_number}

      {:error, _} ->
        @empty_blast
    end
  end

  # step_index => :require_approval | :deny — the policy verdict dispatch will
  # reach for each step. Built from the SAME (runner, group, action, risk) inputs
  # dispatch feeds `Policies.evaluate_with_policy/3`, through `predict_decisions/2`
  # (one policy read per distinct runner — no N+1), so the plan's prediction
  # matches the real verdict. A step is gated by the MOST-restrictive decision
  # across its target runners (a group fans out to all members): deny > approval.
  defp predict_step_decisions([], _runners, _action_risk, _subject), do: %{}

  defp predict_step_decisions(plan, runners, action_risk, subject) do
    runner_groups = Map.new(runners, &{&1.id, &1.group})

    targets =
      Enum.map(plan, fn item ->
        %{
          runner_id: item.runner_id,
          group: Map.get(runner_groups, item.runner_id),
          action_id: item.action_id,
          risk: Map.get(action_risk, item.action_id)
        }
      end)

    case Policies.predict_decisions(targets, subject) do
      {:ok, decisions} ->
        Enum.reduce(plan, %{}, fn item, acc ->
          decision = Map.get(decisions, {item.runner_id, item.action_id})
          merge_step_decision(acc, item.step_index, decision)
        end)

      {:error, _} ->
        %{}
    end
  end

  # Keep only the surprising verdicts (a planned `:allow` runs as expected, so
  # it gets no marker), and let the most-restrictive one per step win.
  defp merge_step_decision(acc, _step_index, :allow), do: acc
  defp merge_step_decision(acc, _step_index, nil), do: acc

  defp merge_step_decision(acc, step_index, decision) do
    Map.update(acc, step_index, decision, &more_restrictive(&1, decision))
  end

  defp more_restrictive(:deny, _), do: :deny
  defp more_restrictive(_, :deny), do: :deny
  defp more_restrictive(current, _), do: current

  # A live execution survives a refresh / reconnect — mount otherwise resets to
  # the idle plan and the running execution vanishes. Re-query the runbook's
  # latest in-flight execution and rebuild the streamed rows + counts from its
  # persisted runs. The plan is re-resolved for the placeholders; if a step's
  # group emptied since dispatch (resolve_plan errors), fall back to the runs
  # alone so the operator still sees the live execution.
  defp maybe_rehydrate_execution(socket, runbook) do
    case Runs.fetch_active_runbook_execution(runbook.id, socket.assigns.current_subject) do
      {:ok, %{execution_id: execution_id, runs: runs}} ->
        plan = rehydrated_plan(runbook, socket.assigns.current_subject)
        # Load the tail output of any run that already settled before this
        # refresh, so its rehydrated terminal row shows the preview too.
        socket = Enum.reduce(runs, socket, &maybe_load_output(&2, &1))

        rows =
          merged_execution_rows(plan, socket.assigns.runners, runs, socket.assigns.run_outputs)

        socket
        |> assign(:execution, %{
          execution_id: execution_id,
          total: rehydrated_total(plan, runs),
          plan: plan,
          runs: [],
          errors: []
        })
        |> assign(:run_statuses, Map.new(runs, &{&1.id, &1.status}))
        |> assign(:run_index, Map.new(runs, &{&1.id, &1}))
        # ONE ordered pass, in plan order. Streaming the placeholders and THEN
        # re-inserting the runs (the old shape) shoved every dispatched run to
        # the end of the list on reload — scrambling the step order.
        |> stream(:execution_runs, rows, reset: true)

      {:error, :not_found} ->
        socket
    end
  end

  defp rehydrated_plan(runbook, subject) do
    case Runbooks.resolve_plan(runbook, subject) do
      {:ok, %{plan: plan}} -> plan
      {:error, _} -> []
    end
  end

  defp rehydrated_total([], runs), do: length(runs)
  defp rehydrated_total(plan, _runs), do: length(plan)

  # Risk of a plan step's action, or nil when the catalog hasn't observed
  # it (no connected runner advertises it yet) — the pill then hides.
  defp step_risk(action_risk, step),
    do: Map.get(action_risk, step["action_id"] || step["action"])

  # The predicted policy decision for a step by index (`:require_approval` /
  # `:deny`), or nil when it runs straight through (an `:allow`, or the plan
  # couldn't resolve) — the marker then hides.
  defp step_decision(step_decisions, idx), do: Map.get(step_decisions, idx)

  # The runbook's headline risk: the most-severe risk across its steps, so the
  # operator sees the worst this run can do before pressing Start. nil (the pill
  # hides) when no step's action is in the catalog yet — never a false low.
  defp plan_max_risk(action_risk, steps),
    do: steps |> Enum.map(&step_risk(action_risk, &1)) |> Catalog.max_risk()

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

  # Genuine, non-field dispatch failures (policy denial, runner offline, a
  # run-row constraint) are surfaced in a concise flash — they aren't a single
  # input the operator can correct in place.
  defp format_reason(%Ecto.Changeset{}), do: "the run could not be created"
  defp format_reason(reason) when is_binary(reason), do: reason

  # Operator-reachable atoms get a real sentence in the operator's vocabulary —
  # the generic underscore-replace below would leak schema jargon ("runner
  # requires attestation").
  defp format_reason(:runner_requires_attestation) do
    "a target runner only accepts signed runs from an MCP client — the portal can't dispatch to it"
  end

  defp format_reason(:pack_untrusted),
    do: "a target runner is advertising an untrusted version of the action's pack"

  defp format_reason(:duplicate_step_ids),
    do: "two steps share the same ID — give each step a unique ID in the editor before running"

  defp format_reason({:fan_out_too_large, max}) do
    "this runbook would fan out to more than #{max} runs — narrow the steps' targets " <>
      "or split it across several runbooks"
  end

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
           |> assign(:run_outputs, %{})
           |> stream(
             :execution_runs,
             plan_rows(execution.plan, socket.assigns.runners, execution.errors),
             reset: true
           )
           |> flash_dispatch_result(execution)}

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

  defp flash_dispatch_result(socket, %{errors: []} = execution),
    do: put_flash(socket, :info, "Runbook dispatched — #{execution.total} runs planned.")

  # Some of the first wave failed to dispatch — one honest flash (not a green
  # "dispatched" beside a red "failed"); the failed rows are marked below.
  defp flash_dispatch_result(socket, %{errors: errors} = execution) do
    put_flash(
      socket,
      :error,
      "Runbook dispatched — #{execution.total} runs planned, but #{length(errors)} of the " <>
        "first wave failed to dispatch (marked below)."
    )
  end

  def handle_info({:run_updated, run}, socket) do
    execution = socket.assigns.execution

    if execution && run.runbook_execution_id == execution.execution_id do
      # Same dom_id as the placeholder (step_id, runner_id) → replaces it in
      # place rather than appending a new row.
      socket =
        socket
        |> assign(:run_statuses, Map.put(socket.assigns.run_statuses, run.id, run.status))
        |> assign(:run_index, Map.put(socket.assigns.run_index, run.id, run))
        |> maybe_load_output(run)

      {:noreply,
       stream_insert(socket, :execution_runs, live_row(run, socket.assigns.run_outputs))}
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
        stream_insert(socket, :execution_runs, live_row(run, socket.assigns.run_outputs))
      end)

    {:noreply, socket}
  end

  # The shared badge hooks forward account-topic broadcasts to every
  # authenticated LiveView — swallow whatever this page doesn't render.
  def handle_info(_message, socket), do: {:noreply, socket}

  # Fetch a finished run's tail output once, the first time it settles — so
  # the row can show an inline preview. In-flight runs and already-fetched
  # ones are left alone (lazy: one read per run, not on every transition).
  defp maybe_load_output(socket, run) do
    if run_settled?(run.status) and not Map.has_key?(socket.assigns.run_outputs, run.id) do
      case Runs.list_recent_events_for_run(
             run.id,
             @output_preview_lines,
             socket.assigns.current_subject
           ) do
        {:ok, events} ->
          assign(socket, :run_outputs, Map.put(socket.assigns.run_outputs, run.id, events))

        {:error, _} ->
          socket
      end
    else
      socket
    end
  end

  defp finished_count(run_statuses),
    do: Enum.count(run_statuses, fn {_id, status} -> run_settled?(status) end)

  defp failed_count(run_statuses),
    do: Enum.count(run_statuses, fn {_id, status} -> run_failed?(status) end)

  # The engine stops launching waves once a run in the current wave failed/
  # denied, so the planned-but-undispatched runs never get a row's worth of
  # progress. Report how many that is — but only once the wave that gates the
  # next batch has fully settled (no run still in flight) and a failure exists,
  # so we don't cry "halted" during a normal between-waves lull. 0 = not halted.
  defp halted_count(run_statuses, total) do
    dispatched = map_size(run_statuses)
    undispatched = total - dispatched

    if undispatched > 0 and failed_count(run_statuses) > 0 and
         finished_count(run_statuses) == dispatched do
      undispatched
    else
      0
    end
  end

  # True while a dispatched run is still in flight — finished_count hasn't caught
  # up to the planned total and the engine hasn't halted between waves. Drives
  # hiding the dispatch/re-run form mid-run (no double-dispatch); flips false once
  # the run completes or halts, so the form returns as the re-run form.
  defp run_in_progress?(nil, _run_statuses), do: false

  defp run_in_progress?(execution, run_statuses) do
    finished_count(run_statuses) < execution.total and
      halted_count(run_statuses, execution.total) == 0
  end

  # "denied" never reaches a terminal transition but is as settled as a
  # run gets — count it alongside the terminal states.
  defp run_settled?(status), do: Runs.ActionRun.terminal?(status)

  defp run_failed?(status), do: run_settled?(status) and status != :success

  # An in-flight run whose runner's socket is currently gone — surfaces *why*
  # a wave stalled instead of leaving the row looking merely slow.
  defp offline_mid_run?(%{status: status} = run) when status in [:pending, :sent, :running],
    do: not Runners.online?(run.account_id, run.runner_id)

  defp offline_mid_run?(_), do: false

  # Pre-Start offline preflight: the distinct planned target runners that are
  # currently offline. Dispatch to an offline runner QUEUES (waits for reconnect)
  # rather than failing, so this is a heads-up before Start, not a hard blocker.
  defp offline_planned_runners(plan, runners, account_id) do
    names = Map.new(runners, &{&1.id, &1.name})

    plan
    |> Enum.map(& &1.runner_id)
    |> Enum.uniq()
    |> Enum.reject(&Runners.online?(account_id, &1))
    |> Enum.map(&Map.get(names, &1, "a runner"))
  end

  defp offline_preflight_message([name]),
    do: "Target runner #{name} is offline — its steps will queue until it reconnects."

  defp offline_preflight_message(names) do
    "#{length(names)} target runners are offline (#{Enum.join(names, ", ")}) — those steps will queue until they reconnect."
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  # The execution table streams unified row structs (not raw runs): a
  # `:planned` placeholder per planned (step, runner), each flipped to its
  # live run by a shared dom_id. `run` is nil until the run arrives.
  defp plan_rows(plan, runners, errors) do
    failed = Map.new(errors, &{{&1.step_id, &1.runner_id}, &1.reason})
    Enum.map(plan, &plan_row(&1, runners, failed))
  end

  # Rehydrate rows in PLAN order: each (step, runner) slot shows its run if one
  # was dispatched (matched by the shared step_id/runner_id), else its
  # placeholder. Runs whose plan slot no longer resolves (a step's group changed
  # since dispatch) are appended in dispatch order so nothing the operator saw
  # disappears. Built as one ordered list so a single `stream(reset: true)`
  # renders it — no follow-up `stream_insert` to reshuffle the order.
  defp merged_execution_rows(plan, runners, runs, outputs) do
    by_slot = Map.new(runs, &{{&1.runbook_step_id, &1.runner_id}, &1})
    planned_slots = MapSet.new(plan, &{&1.step_id, &1.runner_id})

    plan_part =
      Enum.map(plan, fn item ->
        case Map.fetch(by_slot, {item.step_id, item.runner_id}) do
          {:ok, run} -> live_row(run, outputs)
          :error -> plan_row(item, runners, %{})
        end
      end)

    orphan_part =
      runs
      |> Enum.reject(&MapSet.member?(planned_slots, {&1.runbook_step_id, &1.runner_id}))
      |> Enum.map(&live_row(&1, outputs))

    plan_part ++ orphan_part
  end

  defp plan_row(item, runners, failed) do
    # A (step, runner) the first wave couldn't dispatch never gets a run, so
    # mark its placeholder `:dispatch_failed` (+ why) instead of leaving it grey.
    {status, dispatch_error} =
      case Map.fetch(failed, {item.step_id, item.runner_id}) do
        {:ok, reason} -> {:dispatch_failed, format_reason(reason)}
        :error -> {:planned, nil}
      end

    %{
      id: row_dom_id(item.step_id, item.runner_id),
      action_id: item.action_id,
      runner_name: runner_name(item.runner_id, runners),
      status: status,
      run: nil,
      output: [],
      dispatch_error: dispatch_error
    }
  end

  defp live_row(run, outputs) do
    %{
      id: row_dom_id(run.runbook_step_id, run.runner_id),
      action_id: run.action_id,
      runner_name: run.runner.name,
      status: run.status,
      run: run,
      output: Map.get(outputs, run.id, []),
      dispatch_error: nil
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
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
      width={:form}
    >
      <:title>
        <.detail_header back="Runbooks" navigate={~p"/app/#{@current_account}/runbooks"}>
          Run {@runbook.title}
          <:meta>
            <span class="font-mono">v{@runbook.version} · {@runbook.status}</span>
          </:meta>
        </.detail_header>
      </:title>

      <div class="space-y-6">
        <%!-- How-it-works strip — short paragraph, replaces the
             stranded `-mt-4` lead-in that fought the page padding. --%>
        <p class="text-sm leading-relaxed text-zinc-400">
          Steps dispatch in parallel waves, each against the runner — or group — it
          targets. A failed run stops the waves behind it.
        </p>

        <%!-- Dead/pre-connect render: the plan + active-run state load on
             connect, so show a neutral placeholder rather than the empty plan
             and dispatch form (which would flash, then flip to the live run). --%>
        <.loading_state :if={not @loaded?} />

        <%!-- One table, not two. Idle: the plan (numbered steps). Once
             dispatched: the live runs replace those rows in place, while
             the planned-step count stays in the header for context — a
             step fans out to one run per targeted runner, so there can be
             more runs than steps. --%>
        <.panel
          :if={@loaded?}
          id="execution"
          variant={:split}
          title={if @execution, do: "Execution", else: "Plan"}
        >
          <%!-- Headline risk: the most-severe step's risk, so the operator
               sees the worst this runbook can do at a glance. Hidden when no
               step's action is in the catalog yet (never a false low). --%>
          <:badge>
            <.risk_pill
              :if={plan_max_risk(@action_risk, @steps)}
              risk={plan_max_risk(@action_risk, @steps)}
              class="flex-none"
            />
          </:badge>
          <:annotation>
            {length(@steps)} {if length(@steps) == 1, do: "step", else: "steps"}
            <span :if={!@execution && @blast_radius.total} class="text-zinc-400">
              → {@blast_radius.total} {pluralize(@blast_radius.total, "run")} in {@blast_radius.waves} {pluralize(
                @blast_radius.waves,
                "wave"
              )}
            </span>
            <span :if={@execution}>
              · {finished_count(@run_statuses)}/{@execution.total} finished
              <span :if={failed_count(@run_statuses) > 0} class="text-rose-400">
                · {failed_count(@run_statuses)} failed
              </span>
            </span>
          </:annotation>

          <%!-- The engine stops launching waves after a failed/denied run, so
               the remaining placeholder rows never dispatch — without this they
               sit grey and the page reads as stuck/broken. In-flight runs still
               finish; only the un-launched waves are dropped. --%>
          <.callout
            :if={@execution && halted_count(@run_statuses, @execution.total) > 0}
            tone={:amber}
            variant={:strip}
          >
            Halted — {halted_count(@run_statuses, @execution.total)} of the planned runs won't
            dispatch because an earlier step failed. Any in-flight runs will still finish.
          </.callout>

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
              class="px-5 py-2.5 text-sm"
            >
              <div class="flex items-center gap-3">
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
                  <%!-- Why this (step, runner) never started — humanized from the
                       dispatch error, so the rose "dispatch failed" badge isn't mute. --%>
                  <span
                    :if={row.dispatch_error}
                    class="ml-1 inline-flex items-center gap-1 text-xs text-rose-400"
                  >
                    <.icon name="hero-exclamation-triangle" class="h-3 w-3" /> {row.dispatch_error}
                  </span>
                </div>
                <span :if={row.run && row.run.duration_ms} class="text-xs tabular-nums text-zinc-500">
                  {row.run.duration_ms} ms
                </span>
                <.link
                  :if={row.run}
                  navigate={~p"/app/#{@current_account}/runs/#{row.run.id}"}
                  class="text-xs text-brand-400 hover:text-brand-300"
                >
                  View
                </.link>
              </div>
              <%!-- Tail of the run's output once it finishes — a glanceable
                   preview; the full terminal is on the run-detail page. --%>
              <.output_preview events={row.output} class="ml-9 mt-1.5 max-h-32" />
            </li>
          </ul>

          <%!-- A group step that resolves to zero active runners makes dispatch
               refuse the whole runbook — surface that here, before Start. --%>
          <.callout :if={!@execution && @blast_radius.no_runners_step} tone={:amber} variant={:strip}>
            Step {@blast_radius.no_runners_step}'s target has no active runners — dispatch
            will refuse it until one connects.
          </.callout>

          <%!-- Offline preflight: a planned target that's offline queues (doesn't
               fail) until it reconnects — surface it before Start so a half-dark
               fleet isn't a surprise mid-run. --%>
          <% offline_targets =
            offline_planned_runners(@blast_radius.plan, @runners, @current_account.id) %>
          <.callout
            :if={!@execution && offline_targets != []}
            tone={:amber}
            variant={:strip}
            icon="hero-signal-slash"
          >
            {offline_preflight_message(offline_targets)}
          </.callout>

          <%!-- Plan steps, shown until the first dispatch. --%>
          <.steps :if={!@execution && @steps != []} variant={:plan}>
            <:step :for={{step, idx} <- Enum.with_index(@steps)}>
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
                <%!-- What this step's policy will decide at dispatch, so a
                     mid-run pause (or a refusal) isn't a surprise. "Pauses for
                     approval" is the POLICY stance — a standing grant could let
                     it run without pausing, so the tooltip avoids a false
                     promise. A `:deny` step would FAIL on dispatch; flag it too. --%>
                <span
                  :if={step_decision(@step_decisions, idx) == :require_approval}
                  class="flex-none"
                  title="Per policy, this step queues for human approval before it runs. A standing grant may let it run without pausing."
                >
                  <.chip upcase tone={:amber}>Pauses for approval</.chip>
                </span>
                <span
                  :if={step_decision(@step_decisions, idx) == :deny}
                  class="flex-none"
                  title="Policy denies this step — dispatch will refuse it. Edit the policy or the runbook's targets."
                >
                  <.chip upcase tone={:rose}>Blocked by policy</.chip>
                </span>
              </div>
              <p :if={step["description"]} class="mt-0.5 truncate text-xs text-zinc-500">
                {step["description"]}
              </p>
              <% count = @blast_radius.counts[idx] %>
              <p :if={target} class="mt-0.5 truncate text-xs text-zinc-400">
                → {target}<span :if={count}>
                  · {count} {if count == 1, do: "runner", else: "runners"}</span>
              </p>
              <p :if={!target} class="mt-0.5 truncate text-xs text-amber-400/80">
                → no target set
              </p>
            </:step>
          </.steps>

          <%!-- Nothing to run — nudge to the editor instead of dispatching
               an empty runbook. --%>
          <div
            :if={!@execution && @steps == []}
            class="px-5 py-10 text-center text-sm text-zinc-500"
          >
            No steps defined.
            <.link
              navigate={~p"/app/#{@current_account}/runbooks/#{@runbook.id}/edit"}
              class="text-brand-400 hover:text-brand-300"
            >
              Edit the runbook
            </.link>
            first.
          </div>
        </.panel>

        <%!-- Dispatch form — full width below the plan; doubles as the re-run
             form once a run settles. Hidden while a run is IN PROGRESS so a
             stray submit can't double-dispatch mid-run (a "running" note takes
             its place); it returns when every run finishes or the run halts. --%>
        <.panel :if={@loaded? and not run_in_progress?(@execution, @run_statuses)} title="Run">
          <form phx-change="validate" phx-submit="dispatch" class="space-y-4">
            <div>
              <%!-- Non-FormField field: `reason` posts a top-level key and its
                   error is a plain map entry (set only on dispatch, never on
                   `validate`), so pass value/errors explicitly. List.wrap turns
                   the single message into the list `<.input>`'s `<.error>`s want. --%>
              <.input
                type="textarea"
                name="reason"
                value={@reason}
                label="Reason (required)"
                errors={List.wrap(@errors[:reason])}
                rows="2"
                required
                placeholder="Why are you running this runbook now?"
              />
              <p class="mt-1 text-xs text-zinc-500">Logged in audit and propagated to every step.</p>
            </div>

            <%!-- Re-dispatching resets the execution stream above, so confirm
                 while one's already showing — otherwise a stray click wipes the
                 run an operator is watching. --%>
            <.button
              phx-disable-with="Starting..."
              data-confirm={
                @execution && "A run is already showing above — start a new one and replace it?"
              }
            >
              Run runbook
            </.button>
          </form>
        </.panel>

        <%!-- Stands in for the dispatch form while a run is in progress, so the
             form's absence reads as intentional rather than missing. --%>
        <.panel :if={@loaded? and run_in_progress?(@execution, @run_statuses)} title="Run">
          <p class="flex items-center gap-2 text-sm text-zinc-400">
            <.icon name="hero-arrow-path" class="h-4 w-4 flex-none animate-spin text-brand-400" />
            Runbook is running — you can start another run once it finishes.
          </p>
        </.panel>
      </div>
    </.dashboard_shell>
    """
  end
end
