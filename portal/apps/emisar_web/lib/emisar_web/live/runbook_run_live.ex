defmodule EmisarWeb.RunbookRunLive do
  @moduledoc """
  Preflight and durable staged execution detail for one runbook's live release
  or one explicitly marked draft test.

  The LiveView never reconstructs scheduler state from ActionRuns. It renders
  the bounded Runbooks result projection and re-reads it after exact execution
  notifications, so reloads and reconnects preserve approval, wait, halt, and
  peer-settlement state.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Approvals, Runbooks, Runs}
  alias EmisarWeb.{Permissions, RunbookMarkdown, RunbookWorkflowComponents}

  @preflight_delay_ms 300
  @item_page_size 25

  def mount(%{"id" => id} = params, _session, socket) do
    if Runs.subject_can_dispatch_run?(socket.assigns.current_subject) do
      if connected?(socket),
        do: mount_runbook(id, Map.has_key?(params, "execution_id"), socket),
        else: mount_disconnected(socket)
    else
      {:ok,
       socket
       |> put_flash(:info, "Running a runbook needs an operator role or above.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
    end
  end

  defp mount_disconnected(socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runbook")
     |> assign(:runbook, nil)
     |> assign(:loaded?, false)
     |> assign(:reason, "")
     |> assign(:input_raw, %{})
     |> assign(:input_errors, %{})
     |> assign(:touched_inputs, MapSet.new())
     |> assign(:target_selection_seed, nil)
     |> assign(:preflight_generation, 0)
     |> assign(:preflight, %{state: :idle, plan: nil, issues: [], checked_at: nil})
     |> assign(:result, nil)
     |> assign(:projection, nil)
     |> assign(:item_facts, %{})
     |> assign(:attempts_by_item, %{})
     |> assign(:events_by_attempt, %{})
     |> assign(:approval_request, nil)
     |> assign(:recent_executions, [])
     |> assign(:recent_executions_error?, false)
     |> assign(:expanded_plan_stages, MapSet.new())
     |> assign(:expanded_execution_stages, MapSet.new())
     |> assign(:subscribed_execution_id, nil)}
  end

  defp mount_runbook(id, execution_detail?, socket) do
    case Runbooks.fetch_runbook_by_id(id, socket.assigns.current_subject) do
      # Only the live release is dispatchable, so a runbook that has never
      # published one is sent back to the editor rather than a dead form.
      {:ok, %Runbooks.Runbook{live_version: nil} = runbook} when not execution_detail? ->
        {:ok,
         socket
         |> put_flash(:info, "Publish this runbook before running it.")
         |> push_navigate(
           to: ~p"/app/#{socket.assigns.current_account}/runbooks/#{runbook.id}/edit"
         )}

      {:ok, runbook} ->
        socket =
          socket
          |> assign(:page_title, "Run #{runbook.title}")
          |> assign(:runbook, runbook)
          |> assign(:loaded?, false)
          |> assign(:reason, "")
          |> assign(:input_raw, initial_input_raw(runbook.definition))
          |> assign(:input_errors, %{})
          |> assign(:touched_inputs, MapSet.new())
          |> assign(:target_selection_seed, Runbooks.new_target_selection_seed())
          |> assign(:preflight_generation, 0)
          |> assign(:preflight, %{state: :idle, plan: nil, issues: [], checked_at: nil})
          |> assign(:result, nil)
          |> assign(:projection, nil)
          |> assign(:item_facts, %{})
          |> assign(:attempts_by_item, %{})
          |> assign(:events_by_attempt, %{})
          |> assign(:approval_request, nil)
          |> assign(:recent_executions, [])
          |> assign(:recent_executions_error?, false)
          |> assign(:expanded_plan_stages, MapSet.new())
          |> assign(:expanded_execution_stages, MapSet.new())
          |> assign(:subscribed_execution_id, nil)

        {:ok, socket}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Runbook not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{runbook: nil}} = socket),
    do: {:noreply, socket}

  def handle_params(%{"execution_id" => execution_id}, _uri, socket) do
    {:noreply,
     socket
     |> subscribe_execution(execution_id)
     |> load_execution(execution_id)
     |> assign(:loaded?, true)}
  end

  def handle_params(%{"new" => "true"}, _uri, socket) do
    {:noreply,
     socket
     |> reset_run_form()
     |> load_recent_executions()
     |> assign(:loaded?, true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> reset_run_form()
     |> load_recent_executions()
     |> assign(:loaded?, true)}
  end

  def handle_event("run_form_changed", params, socket) do
    form_result =
      Runbooks.cast_form_inputs(socket.assigns.runbook.definition, params["inputs"] || %{})

    socket =
      socket
      |> mark_input_touched(params)
      |> assign(:reason, params["reason"] || "")

    {:noreply, apply_form_result(socket, form_result)}
  end

  def handle_event("start", _params, socket) do
    Permissions.gated(
      socket,
      Runs.subject_can_dispatch_run?(socket.assigns.current_subject),
      &start_execution/1
    )
  end

  def handle_event("cancel_execution", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_cancel_execution?(socket.assigns.current_subject),
      &cancel_execution/1
    )
  end

  def handle_event("run_again", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/app/#{socket.assigns.current_account}/runbooks/#{socket.assigns.runbook.id}/run?new=true"
     )}
  end

  def handle_event("toggle_plan_stage", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded_plan_stages, &toggle_set(&1, id))}
  end

  def handle_event("toggle_execution_stage", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded_execution_stages, &toggle_set(&1, id))}
  end

  def handle_info(
        {:run_preflight, generation},
        %{assigns: %{preflight_generation: generation}} = socket
      ) do
    {:noreply, run_preflight(socket)}
  end

  def handle_info({:run_preflight, _stale_generation}, socket), do: {:noreply, socket}

  def handle_info(
        {:runbook_execution_updated, execution_id},
        %{assigns: %{subscribed_execution_id: execution_id}} = socket
      ) do
    {:noreply, load_execution(socket, execution_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def terminate(_reason, socket) do
    _ = unsubscribe_execution(socket)
    :ok
  end

  defp start_execution(socket) do
    socket = touch_all_inputs(socket)

    case Runbooks.cast_form_inputs(socket.assigns.runbook.definition, socket.assigns.input_raw) do
      {:ok, %{values: input_values}} ->
        socket
        |> assign(:input_errors, %{})
        |> start_with_reason(input_values)

      {:error, %{field_errors: field_errors}} ->
        {:noreply,
         socket
         |> assign(:input_errors, field_errors)
         |> put_flash(:error, "Fix the input values before starting.")}
    end
  end

  defp start_with_reason(socket, input_values) do
    if String.trim(socket.assigns.reason) == "" do
      {:noreply, put_flash(socket, :error, "Add a reason before starting.")}
    else
      dispatch_runbook(socket, input_values)
    end
  end

  defp dispatch_runbook(socket, input_values) do
    case Runbooks.dispatch_runbook(
           socket.assigns.runbook,
           socket.assigns.reason,
           socket.assigns.current_subject,
           input_values: input_values,
           target_selection_seed: socket.assigns.target_selection_seed
         ) do
      {:ok, %{execution_id: execution_id}} ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/app/#{socket.assigns.current_account}/runbooks/#{socket.assigns.runbook.id}/runs/#{execution_id}"
         )}

      {:error, issues} when is_list(issues) ->
        {:noreply,
         assign(socket, :preflight, %{
           state: :error,
           plan: nil,
           issues: issues,
           checked_at: DateTime.utc_now()
         })}

      {:error, :not_live} ->
        {:noreply,
         socket
         |> put_flash(:info, "Publish this runbook before running it.")
         |> push_navigate(
           to:
             ~p"/app/#{socket.assigns.current_account}/runbooks/#{socket.assigns.runbook.id}/edit"
         )}

      {:error, :runbook_capacity_exceeded} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This account already has 1,024 active runbook items. Wait for an execution to finish or cancel one, then try again."
         )}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "The runbook did not start. Re-run preflight and try again.")}
    end
  end

  defp cancel_execution(%{assigns: %{result: %{execution: execution}}} = socket) do
    case Runbooks.cancel_execution(execution.id, socket.assigns.current_subject) do
      {:ok, _execution} ->
        {:noreply,
         socket
         |> load_execution(execution.id)
         |> put_flash(:info, "Runbook execution cancelled.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel this execution.")}
    end
  end

  defp cancel_execution(socket), do: {:noreply, socket}

  defp schedule_preflight(%{assigns: %{result: nil}} = socket) do
    generation = socket.assigns.preflight_generation + 1
    Process.send_after(self(), {:run_preflight, generation}, @preflight_delay_ms)

    socket
    |> assign(:preflight_generation, generation)
    |> assign(:preflight, %{socket.assigns.preflight | state: :loading})
  end

  defp schedule_preflight(socket), do: socket

  defp apply_form_result(socket, {:ok, %{form_values: form_values}}) do
    socket
    |> assign(:input_raw, form_values)
    |> assign(:input_errors, %{})
    |> schedule_preflight()
  end

  defp apply_form_result(
         socket,
         {:error, %{form_values: form_values, field_errors: field_errors, issues: issues}}
       ) do
    socket
    |> assign(:input_raw, form_values)
    |> assign(:input_errors, field_errors)
    |> assign(:preflight_generation, socket.assigns.preflight_generation + 1)
    |> assign(:preflight, %{
      state: :error,
      plan: nil,
      issues: issues,
      checked_at: DateTime.utc_now()
    })
  end

  defp run_preflight(socket) do
    case Runbooks.cast_form_inputs(socket.assigns.runbook.definition, socket.assigns.input_raw) do
      {:ok, %{values: input_values}} ->
        socket
        |> assign(:input_errors, %{})
        |> resolve_preflight_plan(input_values)

      {:error, %{issues: issues, field_errors: field_errors}} ->
        socket
        |> assign(:input_errors, field_errors)
        |> assign(:preflight, %{
          state: :error,
          plan: nil,
          issues: issues,
          checked_at: DateTime.utc_now()
        })
    end
  end

  defp resolve_preflight_plan(socket, input_values) do
    case Runbooks.resolve_plan(
           socket.assigns.runbook,
           input_values,
           socket.assigns.target_selection_seed,
           socket.assigns.current_subject
         ) do
      {:ok, %{plan: plan}} ->
        assign(socket, :preflight, %{
          state: :ready,
          plan: plan,
          issues: [],
          checked_at: DateTime.utc_now()
        })

      {:error, issues} when is_list(issues) ->
        assign(socket, :preflight, %{
          state: :error,
          plan: nil,
          issues: issues,
          checked_at: DateTime.utc_now()
        })

      {:error, _reason} ->
        assign(socket, :preflight, %{
          state: :error,
          plan: nil,
          issues: [issue("dispatch_failed", "", "Current preflight could not be completed.")],
          checked_at: DateTime.utc_now()
        })
    end
  end

  defp load_execution(socket, execution_id) do
    case Runbooks.fetch_execution_result(execution_id, socket.assigns.current_subject) do
      {:ok, result} when result.execution.runbook_id == socket.assigns.runbook.id ->
        projection = Runbooks.execution_projection(result)

        socket =
          socket
          |> assign(:result, result)
          |> assign(:projection, projection)
          |> assign(:item_facts, item_facts_by_id(projection))
          |> assign(
            :attempts_by_item,
            Map.new(result.latest_attempts, &{&1.runbook_execution_item_id, &1})
          )
          |> load_execution_approval_request(result)
          |> load_attempt_output_previews(result.latest_attempts)
          |> assign(:recent_executions, [])
          |> assign(:recent_executions_error?, false)
          |> assign(:page_title, execution_page_title(result))

        if projection.execution.waitable?,
          do: socket,
          else: unsubscribe_execution(socket)

      {:error, _reason} ->
        socket
        |> unsubscribe_execution()
        |> put_flash(:error, "This execution is no longer visible.")
        |> push_navigate(
          to: ~p"/app/#{socket.assigns.current_account}/runbooks/#{socket.assigns.runbook.id}/run"
        )

      {:ok, _other_runbook_result} ->
        socket
        |> unsubscribe_execution()
        |> put_flash(:error, "Execution not found for this runbook.")
        |> push_navigate(
          to: ~p"/app/#{socket.assigns.current_account}/runbooks/#{socket.assigns.runbook.id}/run"
        )
    end
  end

  # Each item's rendered row pairs the durable row with its projected facts.
  defp item_facts_by_id(projection),
    do: projection.stages |> Enum.flat_map(& &1.items) |> Map.new(&{&1.id, &1})

  defp reset_run_form(socket) do
    socket
    |> unsubscribe_execution()
    |> assign(:result, nil)
    |> assign(:projection, nil)
    |> assign(:item_facts, %{})
    |> assign(:attempts_by_item, %{})
    |> assign(:events_by_attempt, %{})
    |> assign(:approval_request, nil)
    |> assign(:reason, "")
    |> assign(:target_selection_seed, Runbooks.new_target_selection_seed())
    |> assign(:input_raw, initial_input_raw(socket.assigns.runbook.definition))
    |> assign(:touched_inputs, MapSet.new())
    |> schedule_preflight()
  end

  # Only the field the operator actually changed reveals its validation — a
  # change event carries EVERY field, so a required input they haven't reached
  # yet must stay quiet (forms reveal before they validate).
  defp mark_input_touched(socket, %{"_target" => ["inputs", id]}) when is_binary(id),
    do: update(socket, :touched_inputs, &MapSet.put(&1, id))

  defp mark_input_touched(socket, _params), do: socket

  # A submit attempt is the other reveal boundary: after it, every still-blank
  # required input may be named.
  defp touch_all_inputs(socket),
    do: assign(socket, :touched_inputs, MapSet.new(input_ids(socket.assigns.runbook.definition)))

  defp input_ids(%{"inputs" => declarations}) when is_list(declarations),
    do: Enum.map(declarations, & &1["id"])

  defp input_ids(_definition), do: []

  defp load_recent_executions(socket) do
    case Runbooks.list_recent_executions_for_runbook(
           socket.assigns.runbook,
           socket.assigns.current_subject
         ) do
      {:ok, executions} ->
        socket
        |> assign(:recent_executions, executions)
        |> assign(:recent_executions_error?, false)

      {:error, _reason} ->
        socket
        |> assign(:recent_executions, [])
        |> assign(:recent_executions_error?, true)
    end
  end

  defp load_attempt_output_previews(socket, attempts) do
    run_ids = Enum.map(attempts, & &1.id)

    case Runs.list_recent_events_for_runs(run_ids, 8, socket.assigns.current_subject) do
      {:ok, events_by_attempt} -> assign(socket, :events_by_attempt, events_by_attempt)
      {:error, _reason} -> assign(socket, :events_by_attempt, %{})
    end
  end

  defp load_execution_approval_request(socket, result) do
    case Approvals.list_requests_for_runbook_executions(
           [result.execution.id],
           socket.assigns.current_subject
         ) do
      {:ok, [request]} -> assign(socket, :approval_request, request)
      {:ok, []} -> assign(socket, :approval_request, nil)
      {:error, _reason} -> assign(socket, :approval_request, nil)
    end
  end

  defp subscribe_execution(socket, execution_id) do
    socket = unsubscribe_execution(socket)
    :ok = Runbooks.subscribe_execution(socket.assigns.current_account.id, execution_id)
    assign(socket, :subscribed_execution_id, execution_id)
  end

  defp unsubscribe_execution(%{assigns: %{subscribed_execution_id: execution_id}} = socket)
       when not is_nil(execution_id) do
    :ok = Runbooks.unsubscribe_execution(socket.assigns.current_account.id, execution_id)

    assign(socket, :subscribed_execution_id, nil)
  end

  # Nothing subscribed, including the case this clause exists for: mounting a
  # draft runbook or a missing one redirects before any of the execution assigns
  # are set, so `terminate/2` arrives here with the key ABSENT rather than nil.
  # Matching a nil value alone crashed the view on its way out.
  defp unsubscribe_execution(socket), do: socket

  # The domain owns the canonical form values, so a first paint and a reset both
  # render the declared defaults it stringifies — a blank form is not an error
  # yet, and both branches carry those values.
  defp initial_input_raw(definition), do: form_input_values(definition, %{})

  defp form_input_values(definition, form_input) do
    case Runbooks.cast_form_inputs(definition, form_input) do
      {:ok, %{form_values: form_values}} -> form_values
      {:error, %{form_values: form_values}} -> form_values
    end
  end

  defp input_type(%{"type" => "boolean"}), do: "select"
  defp input_type(%{"type" => "enum"}), do: "select"
  defp input_type(%{"sensitive" => true}), do: "password"
  defp input_type(%{"type" => type}) when type in ["integer", "number"], do: "number"
  defp input_type(_input), do: "text"

  defp input_options(%{"type" => "boolean"}),
    do: [{"Choose…", ""}, {"true", "true"}, {"false", "false"}]

  defp input_options(%{"type" => "enum", "enum" => values}),
    do: [{"Choose…", ""} | Enum.map(values, &{&1, &1})]

  defp input_options(_input), do: []

  defp input_step(%{"type" => "integer"}), do: "1"
  defp input_step(%{"type" => "number"}), do: "any"
  defp input_step(_input), do: nil

  defp issue(code, path, message), do: %{code: code, path: path, message: message}

  defp items_for_stage(result, stage),
    do: Enum.filter(result.execution.items, &(&1.runbook_execution_stage_id == stage.id))

  defp visible_items(items, expanded?, limit \\ @item_page_size) do
    if expanded?, do: items, else: Enum.take(items, limit)
  end

  defp hidden_item_count(items, expanded?, limit \\ @item_page_size) do
    if expanded?, do: 0, else: max(length(items) - limit, 0)
  end

  defp toggle_set(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp execution_duration_ms(%{completed_at: %DateTime{} = completed_at} = execution),
    do: DateTime.diff(completed_at, execution.inserted_at, :millisecond)

  defp execution_duration_ms(_execution), do: nil

  # Before anything ran, the outcome tally would read as eight premature
  # verdicts — size is the useful fact then; progress takes over once any
  # action has been attempted.
  defp stage_progress(items) do
    total = length(items)

    if Enum.any?(items, &(&1.attempt_count > 0)) do
      "#{Enum.count(items, &(&1.status == :succeeded))} of #{total} succeeded"
    else
      "#{total} #{if total == 1, do: "action", else: "actions"}"
    end
  end

  # The raw attempt status earns a row only when it adds a failure mode the
  # item's own badge doesn't carry (timed_out, refused, error…). "success" and
  # a same-word repeat are noise.
  defp attempt_status_differs?(attempt, item),
    do: to_string(attempt.status) not in ["success", to_string(item.status)]

  defp humanize_terminal_code(nil), do: nil

  defp humanize_terminal_code(code),
    do: code |> String.replace("_", " ") |> String.capitalize()

  defp stage_mode(%{mode: :parallel, max_parallel: max_parallel}),
    do: "parallel · up to #{max_parallel} at once"

  defp stage_mode(%{mode: :sequential}), do: "sequential"

  defp wait_label(%{status: :waiting, attempt_count: attempts, wait: wait}) when is_map(wait) do
    "#{attempts} of #{wait["max_attempts"]} observations"
  end

  defp wait_label(_item), do: nil

  defp can_start?(assigns) do
    assigns.preflight.state == :ready and String.trim(assigns.reason) != "" and
      assigns.input_errors == %{}
  end

  # The RENDERED preflight: identical to the raw result except that a pending
  # input's missing-value issue stays invisible. When only those remain, the
  # whole error state renders as neutral :awaiting_input guidance instead of a
  # rose block.
  defp preflight_view(%{state: :error} = preflight, pending_inputs) do
    pending_paths = Enum.map(pending_inputs, &"/input_values/#{&1}")
    {hidden, visible} = Enum.split_with(preflight.issues, &(&1.path in pending_paths))

    if visible == [] and hidden != [],
      do: %{preflight | state: :awaiting_input, issues: []},
      else: %{preflight | issues: visible}
  end

  defp preflight_view(preflight, _pending_inputs), do: preflight

  # An input the operator has not reached — still blank and never touched — is
  # guidance rather than an error: on first paint neither its plan issue nor its
  # field message renders, until the field is touched or a start is attempted.
  defp pending_input_ids(%{"inputs" => declarations}, input_raw, touched_inputs)
       when is_list(declarations) do
    for %{"id" => id} <- declarations,
        Map.get(input_raw, id) in [nil, ""],
        not MapSet.member?(touched_inputs, id),
        do: id
  end

  defp pending_input_ids(_definition, _input_raw, _touched_inputs), do: []

  defp output_rows(outputs), do: Enum.sort_by(outputs, &elem(&1, 0))

  defp execution_page_title(%{execution: %{kind: :draft_test}, runbook: runbook}),
    do: "Draft test · #{runbook.title}"

  defp execution_page_title(%{runbook: runbook}), do: "Run #{runbook.title}"

  defp header_title(%{result: %{execution: %{kind: :draft_test}}, runbook: runbook}),
    do: "Draft test · #{runbook.title}"

  defp header_title(%{runbook: runbook}) when not is_nil(runbook), do: runbook.title
  defp header_title(_assigns), do: "Runbook"

  # An item's terminal message counts as detail only when it says something the
  # execution-level halt block hasn't already said for the whole run.
  defp item_terminal_message(item, execution) do
    if item.terminal_message != execution.terminal_message, do: item.terminal_message
  end

  defp item_detail?(item, attempt, execution) do
    not is_nil(attempt) or not is_nil(item_terminal_message(item, execution)) or
      item.outputs != %{} or item.success_evidence != [] or not is_nil(wait_label(item)) or
      not is_nil(item.next_attempt_at)
  end

  defp evidence_label(%{kind: "condition", output: output, operator: operator})
       when is_binary(output) and is_binary(operator),
       do: "#{output} · #{String.replace(operator, "_", " ")}"

  defp evidence_label(%{output: output}) when is_binary(output), do: output
  defp evidence_label(%{kind: kind}) when is_binary(kind), do: String.replace(kind, "_", " ")
  defp evidence_label(_evidence), do: "Evidence"

  defp evidence_kind(%{kind: "condition"}), do: "Success condition"
  defp evidence_kind(%{kind: "extraction"}), do: "Output extraction"
  defp evidence_kind(_evidence), do: "Execution evidence"

  defp evidence_tone(status) when status in ["passed", "extracted"], do: :brand
  defp evidence_tone("failed"), do: :rose
  defp evidence_tone(status) when status in ["not met", "pending"], do: :amber
  defp evidence_tone(_status), do: :neutral

  def render(assigns) do
    ~H"""
    <.console_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_access_requests_count={@pending_access_requests_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      section={:runbooks}
      width={if @result, do: :detail, else: :table}
    >
      <:title>
        <%!-- A dispatch form or execution detail belongs to ONE runbook, so
              back climbs to it — never two levels up to the list. Before the
              connected mount resolves the runbook, degrade to the list. --%>
        <.detail_header
          back={if(@runbook, do: @runbook.title, else: "Runbooks")}
          navigate={
            if @runbook,
              do: ~p"/app/#{@current_account}/runbooks/#{@runbook.id}/edit",
              else: ~p"/app/#{@current_account}/runbooks"
          }
          title={header_title(assigns)}
        />
      </:title>
      <:actions>
        <.button
          :if={@projection && not @projection.execution.terminal?}
          variant={:secondary}
          tone={:rose}
          phx-click="cancel_execution"
          data-confirm="Cancel this runbook execution? Already-running actions receive a cancellation request."
        >
          Cancel execution
        </.button>
        <.button
          :if={
            @projection && @projection.execution.terminal? &&
              @result.execution.kind == :published
          }
          variant={:secondary}
          phx-click="run_again"
        >
          Run again
        </.button>
      </:actions>

      <div class="mt-4">
        <.empty_state
          :if={not @loaded?}
          icon="state.loading"
          title="Loading runbook…"
        >
          Reading the current plan and latest execution.
        </.empty_state>

        <.execution_result
          :if={@loaded? && @result}
          result={@result}
          item_facts={@item_facts}
          attempts_by_item={@attempts_by_item}
          events_by_attempt={@events_by_attempt}
          approval_request={@approval_request}
          expanded_stages={@expanded_execution_stages}
          current_account={@current_account}
        />

        <.run_form
          :if={@loaded? && is_nil(@result) && @runbook.live_version}
          runbook={@runbook}
          reason={@reason}
          input_raw={@input_raw}
          input_errors={@input_errors}
          touched_inputs={@touched_inputs}
          preflight={@preflight}
          expanded_stages={@expanded_plan_stages}
          can_start?={can_start?(assigns)}
          current_account={@current_account}
          recent_executions={@recent_executions}
          recent_executions_error?={@recent_executions_error?}
        />
      </div>
    </.console_shell>
    """
  end

  attr :runbook, :map, required: true
  attr :reason, :string, required: true
  attr :input_raw, :map, required: true
  attr :input_errors, :map, required: true
  attr :touched_inputs, :any, required: true
  attr :preflight, :map, required: true
  attr :expanded_stages, :any, required: true
  attr :can_start?, :boolean, required: true
  attr :current_account, :map, required: true
  attr :recent_executions, :list, required: true
  attr :recent_executions_error?, :boolean, default: false

  defp run_form(assigns) do
    pending_inputs =
      pending_input_ids(
        assigns.runbook.definition,
        assigns.input_raw,
        assigns.touched_inputs
      )

    assigns =
      assigns
      # The live definition is whatever was stored, not what the contract
      # requires today: a row published under an earlier shape carries no
      # "inputs" key. Normalize once — `definition["inputs"] != []` reads TRUE
      # for that nil, so the guard alone would still hand nil to the
      # comprehension below (`pending_input_ids/3` already has its own clause
      # for the same shape).
      |> assign(:inputs, assigns.runbook.definition["inputs"] || [])
      |> assign(:preflight_view, preflight_view(assigns.preflight, pending_inputs))
      |> assign(:visible_input_errors, Map.drop(assigns.input_errors, pending_inputs))

    ~H"""
    <div class="grid min-w-0 gap-x-12 gap-y-10 xl:grid-cols-[minmax(0,1fr)_22rem]">
      <main class="min-w-0 space-y-10">
        <section
          :if={String.trim(@runbook.definition["context_markdown"] || "") != ""}
          id="runbook-operator-context"
        >
          <.section_header title="Operator context" />
          <.artifact_panel>
            <RunbookMarkdown.render markdown={@runbook.definition["context_markdown"]} />
          </.artifact_panel>
        </section>

        <section id="runbook-start-execution">
          <.section_header title="Start execution">
            <:subtitle>
              Supply this execution's values and record why it should run now.
            </:subtitle>
          </.section_header>
          <form
            id="runbook-run-form"
            phx-change="run_form_changed"
            phx-submit="start"
            class="space-y-8"
          >
            <div class="space-y-5">
              <div :if={@inputs != []} class="grid gap-4 sm:grid-cols-2">
                <div :for={input <- @inputs}>
                  <.input
                    type={input_type(input)}
                    name={"inputs[#{input["id"]}]"}
                    value={@input_raw[input["id"]]}
                    label={input["id"]}
                    label_variant={:eyebrow}
                    options={input_options(input)}
                    step={input_step(input)}
                    required={input["required"]}
                    autocomplete={if(input["sensitive"], do: "off")}
                  />
                  <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
                    {input["description"]}
                    <span :if={input["sensitive"]} class="text-amber-300"> · sensitive</span>
                  </p>
                  <p :if={@visible_input_errors[input["id"]]} class="mt-1 text-xs text-rose-300">
                    {@visible_input_errors[input["id"]]}
                  </p>
                </div>
              </div>

              <div class="max-w-3xl">
                <.input
                  type="textarea"
                  name="reason"
                  value={@reason}
                  label="Reason"
                  label_variant={:eyebrow}
                  rows="3"
                  required
                  placeholder="Why this runbook should run now"
                />
              </div>
            </div>

            <.plan_details preflight={@preflight_view} expanded_stages={@expanded_stages} />

            <div class="flex flex-wrap items-center gap-4 border-t border-zinc-800/70 pt-4">
              <.button
                id="start-runbook-button"
                type="submit"
                variant={if @can_start?, do: :primary, else: :secondary}
                phx-disable-with="Starting…"
                disabled={not @can_start?}
              >
                Start runbook
              </.button>
              <p class="text-xs text-zinc-400">
                <%= cond do %>
                  <% @preflight_view.state == :loading -> %>
                    Checking the current plan…
                  <% @preflight_view.state == :awaiting_input -> %>
                    Fill in the required inputs to start this execution.
                  <% @preflight_view.state == :error -> %>
                    Resolve the plan issues above before starting.
                  <% String.trim(@reason) == "" -> %>
                    Add a reason to start this execution.
                  <% true -> %>
                    The frozen plan below will be dispatched exactly as shown.
                <% end %>
              </p>
            </div>
          </form>
        </section>
      </main>

      <aside id="runbook-start-rail" class="min-w-0 space-y-9">
        <section id="runbook-before-starting">
          <.section_header title="Before starting" />
          <p class="text-sm leading-6 text-zinc-400">
            Starting freezes this exact plan. If approval is required, one decision covers every
            listed action—there are no separate action approvals. Dispatch still stops if access,
            pack trust, or policy no longer permits an action.
          </p>
          <div class="mt-3">
            <.doc_link href="/docs/runbooks">Runbook execution guide</.doc_link>
          </div>
        </section>

        <.plan_summary preflight={@preflight_view} />

        <section id="runbook-execution-history">
          <.section_header title="Recent executions" />
          <RunbookWorkflowComponents.recent_executions
            executions={@recent_executions}
            load_error?={@recent_executions_error?}
            current_account={@current_account}
            runbook={@runbook}
          />
        </section>
      </aside>
    </div>
    """
  end

  attr :preflight, :map, required: true

  defp plan_summary(assigns) do
    ~H"""
    <section id="current-runbook-plan-summary">
      <.section_header title="Current plan" />

      <div
        :if={@preflight.state == :loading}
        class="flex items-center gap-2 text-sm text-zinc-400"
      >
        <.icon name="state.loading" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
        Checking current state…
      </div>

      <p :if={@preflight.state == :awaiting_input} class="text-sm leading-6 text-zinc-400">
        Waiting for the required inputs.
      </p>

      <p :if={@preflight.state == :error} class="text-sm leading-6 text-rose-300">
        Resolve the plan issues before starting.
      </p>

      <div :if={@preflight.state == :ready}>
        <dl class="grid grid-cols-2 gap-x-4 gap-y-3 text-xs">
          <div>
            <dt class="text-zinc-500">Actions</dt>
            <dd class="mt-0.5 font-medium tabular-nums text-zinc-200">
              {@preflight.plan["total_items"]}
            </dd>
          </div>
          <div>
            <dt class="text-zinc-500">Stages</dt>
            <dd class="mt-0.5 font-medium tabular-nums text-zinc-200">
              {length(@preflight.plan["stages"])}
            </dd>
          </div>
          <div>
            <dt class="text-zinc-500">Run approval</dt>
            <dd class="mt-0.5 font-medium text-zinc-200">
              {if @preflight.plan["approval_required"], do: "Required", else: "Not required"}
            </dd>
          </div>
          <div :if={@preflight.checked_at}>
            <dt class="text-zinc-500">Resolved</dt>
            <dd class="mt-0.5 text-zinc-300">
              <.local_time value={@preflight.checked_at} mode={:relative} />
            </dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  attr :preflight, :map, required: true
  attr :expanded_stages, :any, required: true

  defp plan_details(assigns) do
    ~H"""
    <section id="current-runbook-plan">
      <.section_header title="Plan" />

      <div
        :if={@preflight.state == :loading}
        class="flex items-center gap-2 text-sm text-zinc-400"
      >
        <.icon name="state.loading" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
        Resolving actions and runners…
      </div>

      <p :if={@preflight.state == :awaiting_input} class="text-sm leading-6 text-zinc-400">
        The plan resolves once the required inputs above are filled in.
      </p>

      <.event_block
        :if={@preflight.state == :error}
        icon="state.warning"
        tone={:rose}
        title="Plan blocked"
      >
        <:body>
          <ul class="space-y-2">
            <li :for={issue <- @preflight.issues}>
              <span class="text-xs font-medium text-zinc-200">
                {preflight_issue_label(issue.path)}
              </span>
              — {issue.message}
            </li>
          </ul>
        </:body>
      </.event_block>

      <div :if={@preflight.state == :ready} class="space-y-8">
        <.plan_stage
          :for={stage <- @preflight.plan["stages"]}
          stage={stage}
          expanded?={MapSet.member?(@expanded_stages, stage["id"])}
        />
      </div>
    </section>
    """
  end

  attr :stage, :map, required: true
  attr :expanded?, :boolean, required: true

  defp plan_stage(assigns) do
    assigns =
      assigns
      |> assign(:visible_items, visible_items(assigns.stage["items"], assigns.expanded?))
      |> assign(:hidden_count, hidden_item_count(assigns.stage["items"], assigns.expanded?))
      |> assign(:page_size, @item_page_size)

    ~H"""
    <div id={"preflight-stage-#{@stage["id"]}"}>
      <RunbookWorkflowComponents.plan_stage
        stage={@stage}
        items={@visible_items}
        item_count={length(@stage["items"])}
      />
      <.button
        :if={@hidden_count > 0 or (@expanded? and length(@stage["items"]) > @page_size)}
        type="button"
        variant={:ghost}
        size={:sm}
        phx-click="toggle_plan_stage"
        phx-value-id={@stage["id"]}
        class="mt-2"
      >
        {if @expanded?, do: "Show first #{@page_size}", else: "Show #{@hidden_count} more"}
      </.button>
    </div>
    """
  end

  defp preflight_issue_label(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["stages", stage, "steps", step | fields] ->
        "Stage #{one_based_index(stage)} · Step #{one_based_index(step)}#{preflight_field_suffix(fields)}"

      ["stages", stage | fields] ->
        "Stage #{one_based_index(stage)}#{preflight_field_suffix(fields)}"

      fields when fields != [] ->
        Enum.map_join(fields, " · ", &preflight_field_label/1)

      [] ->
        "Runbook"
    end
  end

  defp preflight_issue_label(_path), do: "Runbook"

  defp one_based_index(value) do
    case Integer.parse(value) do
      {index, ""} -> Integer.to_string(index + 1)
      _other -> value
    end
  end

  defp preflight_field_suffix([]), do: ""

  defp preflight_field_suffix(fields),
    do: " · " <> Enum.join(preflight_field_labels(fields), " · ")

  defp preflight_field_labels(["outputs", index | fields]),
    do: ["Output #{one_based_index(index)}" | Enum.map(fields, &preflight_field_label/1)]

  defp preflight_field_labels(["success", index | fields]),
    do: ["Condition #{one_based_index(index)}" | Enum.map(fields, &preflight_field_label/1)]

  defp preflight_field_labels(fields), do: Enum.map(fields, &preflight_field_label/1)

  defp preflight_field_label(field),
    do: field |> String.replace("_", " ") |> String.capitalize()

  attr :result, :map, required: true
  attr :item_facts, :map, required: true
  attr :attempts_by_item, :map, required: true
  attr :events_by_attempt, :map, required: true
  attr :approval_request, :any, default: nil
  attr :expanded_stages, :any, required: true
  attr :current_account, :map, required: true

  defp execution_result(assigns) do
    assigns = assign(assigns, :page_size, @item_page_size)

    ~H"""
    <div id="runbook-execution-result" class="space-y-12">
      <%!-- The STATUS block mirrors the run detail's grammar: the naked meta row
           carries the facts, the reason renders as the operator's own artifact,
           and only a held/dead outcome earns an attention event block. --%>
      <div>
        <div class="grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-14">
          <%!-- wrap: a badge is a composite, not a text run — truncation shears
           its pill instead of ellipsizing (§7.35). --%>
          <.meta_field label="Status" wrap>
            <.status_badge status={@result.execution.status} />
          </.meta_field>
          <.meta_field label="Started by">
            <%!-- Mirrors the run detail's Dispatched by cell; the domain owns
                 who/via (Runbooks.execution_who_via/1). --%>
            <% {who, via} = Runbooks.execution_who_via(@result.execution) %>
            <span class="block truncate">
              <span :if={who} class="text-zinc-200">{who}</span>
              <span :if={via} class={if who, do: "text-zinc-400", else: "text-zinc-200"}>
                {if who, do: "via #{via}", else: via}
              </span>
              <span :if={!who && !via} class="text-zinc-500">—</span>
            </span>
          </.meta_field>
          <.meta_field label="Duration">
            <% duration_ms = execution_duration_ms(@result.execution) %>
            <span :if={duration_ms} class="text-zinc-200">{format_duration(duration_ms)}</span>
            <span :if={is_nil(duration_ms)} class="text-zinc-500">—</span>
          </.meta_field>
          <.meta_field :if={@approval_request} label="Approval">
            <.link
              navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
              class="text-zinc-200 hover:text-brand-300"
            >
              {String.capitalize(to_string(@approval_request.status))}
            </.link>
          </.meta_field>
          <.meta_field label="Started" wrap>
            <.local_time
              value={@result.execution.inserted_at}
              mode={:forensic}
              class="tabular-nums text-zinc-200"
            />
          </.meta_field>
        </div>

        <div class="mt-6 max-w-3xl">
          <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
            Reason
          </div>
          <p class="mt-1.5 text-sm leading-6 text-zinc-300">{@result.execution.reason}</p>
        </div>

        <div
          :if={@result.execution.status in [:pending_approval, :halted, :cancelled]}
          class="mt-8 space-y-8"
        >
          <.event_block
            :if={@result.execution.status == :pending_approval}
            icon="state.awaiting_human"
            title="Waiting on approval"
          >
            <:body>
              This execution is held until an approver decides. One decision covers every
              listed action.
            </:body>
            <div :if={@approval_request} class="mt-4">
              <.button
                tone={:amber}
                size={:md}
                navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
              >
                View approval →
              </.button>
            </div>
          </.event_block>

          <.event_block
            :if={@result.execution.status == :halted}
            icon="state.warning"
            tone={:rose}
            title="Execution halted"
          >
            <:body>
              <span class="whitespace-pre-wrap">{@result.execution.terminal_message}</span>
            </:body>
          </.event_block>

          <.event_block
            :if={@result.execution.status == :cancelled}
            icon="state.cancelled"
            tone={:neutral}
            title="Execution cancelled"
          >
            <:body>
              <span :if={@result.execution.terminal_message} class="whitespace-pre-wrap">{@result.execution.terminal_message}</span>
              <span :if={is_nil(@result.execution.terminal_message)}>An operator pulled this execution back.</span>
            </:body>
          </.event_block>
        </div>
      </div>

      <section
        :for={stage <- @result.execution.stages}
        id={"execution-stage-#{stage.id}"}
      >
        <% stage_items = items_for_stage(@result, stage) %>
        <.section_header title={stage.title}>
          <:subtitle>{stage_mode(stage)}</:subtitle>
          <:actions>
            <span
              id={"execution-stage-#{stage.id}-progress"}
              class="text-xs tabular-nums text-zinc-400"
            >
              {stage_progress(stage_items)}
            </span>
          </:actions>
        </.section_header>

        <%!-- Only a stage-specific cause earns its own block — the execution-level
             halt above already explains a whole-run stop, and repeating it per
             stage buries the one real message. --%>
        <.event_block
          :if={
            stage.terminal_message &&
              stage.terminal_message != @result.execution.terminal_message
          }
          icon="state.warning"
          tone={:rose}
          title="Stage halted"
          class="mb-5"
        >
          <:body>{stage.terminal_message}</:body>
        </.event_block>

        <% expanded? = MapSet.member?(@expanded_stages, stage.id) %>
        <.steps
          variant={:plan}
          marker={if stage.mode == :parallel, do: :parallel, else: :number}
          class="mt-3"
        >
          <:step :for={item <- visible_items(stage_items, expanded?)}>
            <.execution_item
              item={item}
              fact={@item_facts[item.id]}
              execution={@result.execution}
              attempt={@attempts_by_item[item.id]}
              events={
                if @attempts_by_item[item.id],
                  do: Map.get(@events_by_attempt, @attempts_by_item[item.id].id, []),
                  else: []
              }
              current_account={@current_account}
            />
          </:step>
        </.steps>
        <% hidden_count = hidden_item_count(stage_items, expanded?) %>
        <.button
          :if={hidden_count > 0 or (expanded? and length(stage_items) > @page_size)}
          type="button"
          variant={:ghost}
          size={:sm}
          phx-click="toggle_execution_stage"
          phx-value-id={stage.id}
          class="mt-3"
        >
          {if expanded?, do: "Show first #{@page_size}", else: "Show #{hidden_count} more"}
        </.button>
      </section>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :fact, :map, required: true
  attr :execution, :map, required: true
  attr :attempt, :any, default: nil
  attr :events, :list, required: true
  attr :current_account, :map, required: true

  defp execution_item(assigns) do
    assigns =
      assign(
        assigns,
        :has_details?,
        item_detail?(assigns.item, assigns.attempt, assigns.execution)
      )

    ~H"""
    <div id={"execution-item-#{@item.id}"} class="min-w-0">
      <.execution_item_summary
        item={@item}
        projected_status={@fact.status}
        attempt={@attempt}
        current_account={@current_account}
      />
      <.execution_item_details
        :if={@has_details?}
        item={@item}
        fact={@fact}
        execution={@execution}
        attempt={@attempt}
        events={@events}
      />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :projected_status, :atom, required: true
  attr :attempt, :any, default: nil
  attr :current_account, :map, required: true

  defp execution_item_summary(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-mono text-sm text-zinc-100">{@item.action_id}</span>
          <%!-- The step's own name rides with the action it runs, as it does in
                the plan and the editor: a later step binds to `<id>.<output>`,
                so it is identity, not addressing. --%>
          <span class="text-zinc-500">·</span>
          <span class="font-mono text-xs text-zinc-500">{@item.step_id}</span>
          <.risk_pill :if={@item.risk} id={"execution-item-#{@item.id}-risk"} risk={@item.risk} />
        </div>
        <%!-- No leading glyph, matching the plan and the editor: a runner name
              says what it is, so an arrow would label nothing. --%>
        <p class="mt-1 text-xs text-zinc-300">
          {RunbookWorkflowComponents.runner_name(@item.runner_ref)}
          <span :if={@item.target_group} class="text-zinc-500">
            · selected from {@item.target_group}
          </span>
          <%!-- One attempt is the norm — only a repeat observation earns a mention. --%>
          <span :if={@item.attempt_count > 1} class="text-zinc-500">
            · {@item.attempt_count} attempts
          </span>
        </p>
      </div>
      <div class="flex items-center gap-3 sm:justify-end">
        <.status_badge status={@projected_status} />
        <span :if={@attempt && @attempt.duration_ms} class="text-xs tabular-nums text-zinc-400">
          {format_duration(@attempt.duration_ms)}
        </span>
        <.link
          :if={@attempt}
          navigate={~p"/app/#{@current_account}/runs/#{@attempt.id}"}
          class="text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View
        </.link>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :fact, :map, required: true
  attr :execution, :map, required: true
  attr :attempt, :any, default: nil
  attr :events, :list, required: true

  defp execution_item_details(assigns) do
    assigns =
      assign(
        assigns,
        :has_transcript?,
        assigns.attempt &&
          (is_binary(assigns.attempt.executed_command) or assigns.events != [])
      )

    ~H"""
    <div class="mt-4 space-y-4">
      <%!-- Only rows that ADD a fact: the summary already shows status and
           duration, so the raw attempt status appears only when it names a
           different failure mode. Natural-width cells keep each label beside
           its value instead of flinging values to the far edge. --%>
      <dl
        :if={
          (@attempt && attempt_status_differs?(@attempt, @item)) or
            not is_nil(wait_label(@item)) or not is_nil(@item.next_attempt_at)
        }
        class="flex flex-wrap gap-x-10 gap-y-2 text-xs"
      >
        <.kv :if={@attempt && attempt_status_differs?(@attempt, @item)} label="Action result">
          <.status_badge status={@attempt.status} />
        </.kv>
        <.kv :if={wait_label(@item)} label="Wait">{wait_label(@item)}</.kv>
        <.kv :if={@item.next_attempt_at} label="Next observation">
          <.local_time value={@item.next_attempt_at} mode={:relative} />
        </.kv>
      </dl>

      <% terminal_message = item_terminal_message(@item, @execution) %>
      <.event_block
        :if={terminal_message}
        icon="state.warning"
        tone={:rose}
        title={humanize_terminal_code(@item.terminal_code) || "Action failed"}
      >
        <:body>{terminal_message}</:body>
      </.event_block>

      <.output_preview
        :if={@has_transcript?}
        events={@events}
        command={@attempt.executed_command}
        command_truncated?={@attempt.executed_command_truncated}
        class="max-h-64"
      />

      <p :if={@attempt && not @has_transcript?} class="text-xs text-zinc-500">
        No command or output captured.
      </p>

      <div :if={@item.outputs != %{}}>
        <p class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
          Extracted outputs
        </p>
        <dl class="mt-2 space-y-2 text-xs">
          <.kv :for={{name, value} <- output_rows(@item.outputs)} label={name}>
            <code class="break-all text-[11px] text-zinc-200">{format_json(value)}</code>
          </.kv>
        </dl>
      </div>

      <div :if={@fact.evidence != []}>
        <p class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
          Success evidence
        </p>
        <ul class="mt-2 divide-y divide-zinc-800/70 border-y border-zinc-800/70">
          <li
            :for={evidence <- @fact.evidence}
            class="flex items-start justify-between gap-4 py-2.5"
          >
            <div class="min-w-0">
              <p class="break-words font-mono text-[11px] text-zinc-200">
                {evidence_label(evidence)}
              </p>
              <p class="mt-0.5 text-[11px] text-zinc-400">{evidence_kind(evidence)}</p>
            </div>
            <.status_badge
              status={evidence.status}
              tone={evidence_tone(evidence.status)}
              class="shrink-0"
            />
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
