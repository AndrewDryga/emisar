defmodule EmisarWeb.ApprovalDetailLive do
  use EmisarWeb, :live_view
  alias Emisar.{Approvals, Audit, Catalog, Runners, Runs}
  alias EmisarWeb.{Permissions, RunbookWorkflowComponents}

  # The full grant-reuse duration menu (label + posted value), in display order.
  # `grant_duration_options/1` narrows it to what the account's lifetime cap
  # permits before it reaches the form.
  @grant_duration_options [
    {"Just this call (no grant)", "once"},
    {"Next 1 hour", "one_hour"},
    {"Next 24 hours", "one_day"},
    {"Next 30 days", "thirty_days"},
    {"Next 90 days", "ninety_days"}
  ]

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: mount_connected(id, socket), else: mount_disconnected(socket)
  end

  defp mount_disconnected(socket) do
    {:ok,
     socket
     |> assign(:loaded?, false)
     |> assign(:page_title, "Approval")
     |> assign(:request, nil)
     |> assign(:request_facts, nil)
     |> assign(:run, nil)
     |> assign(:execution_plan, nil)
     |> assign(:execution_request?, false)
     |> assign(:action_args, %{})
     |> assign(:action_risk, nil)
     |> assign(:action_description, nil)
     |> assign(:executed_command, nil)
     |> assign(:runner_connection, :unknown)
     |> assign(:user_labels, %{})
     |> assign(:decisions, [])
     |> assign(:decisions_error?, false)
     |> assign(:approval_event_refs, %{final: nil, decisions: %{}})
     |> assign(:approved_count, 0)
     |> assign(:already_decided?, false)
     |> assign(:self_blocked?, false)
     |> assign(:unavailable_action_id, nil)
     |> assign_decision_fields(%{})
     |> assign(:grant_duration_options, [])}
  end

  defp mount_connected(id, socket) do
    account_id = socket.assigns.current_account.id
    subject = socket.assigns.current_subject

    case Approvals.fetch_approval_request_by_id(id, subject) do
      # A denied role and a missing approval are indistinguishable — never
      # leak existence, never crash on {:error, :unauthorized}.
      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Approval not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/approvals")}

      {:ok, request} ->
        Approvals.subscribe_request(account_id, request.id)

        run = fetch_action_run(request, socket.assigns.current_subject)
        execution_plan = execution_plan(request)
        execution_request? = not is_nil(execution_plan)

        title = "Approval · " <> request_title(request)

        # The plain-English "what this does", the command preview, and whether
        # the action is still advertised all need the catalog row itself
        # (display-only, connected pass; nil if it's no longer advertised).
        action = fetch_action_for(request.context, socket.assigns.current_subject)

        {:ok,
         socket
         |> assign(:loaded?, true)
         |> assign(:page_title, title)
         |> assign_request(request)
         |> assign(:run, run)
         |> assign(:execution_plan, execution_plan)
         |> assign(:execution_request?, execution_request?)
         |> assign(:action_args, visible_action_args(run, subject))
         |> assign(:action_risk, request_risk(request, subject))
         |> assign(:action_description, action && action.description)
         # The exact command the runner will execute, arguments resolved into
         # the action's template — shown only when our published pack is
         # provably byte-for-byte the runner's.
         |> assign(:executed_command, build_command_preview(action, run, subject))
         |> assign(:runner_connection, runner_connection(run))
         # Approve re-resolves the action's trusted contract and fails closed
         # when it is gone, so an unresolvable action means the panel must not
         # promise a send.
         |> assign(
           :unavailable_action_id,
           unavailable_action_id(request, execution_request?, action)
         )
         |> assign_decisions(request)
         # Every operator-entered decision field is tracked server-side. A
         # co-approver's broadcast, the expiry countdown, or a refused decision
         # all re-render this panel, and LiveView only preserves the value of
         # the input that happens to be focused — an untracked field would drop
         # a half-written denial justification on the floor. They stay bare
         # top-level params (not a namespaced form) because the submit buttons
         # post `decision=approve|deny` alongside them.
         |> assign_decision_fields(%{})
         # Only offer durations the account's lifetime cap allows, so an
         # approver can't pick one the server would reject (the cap is account
         # config, fixed for this session — compute it once at mount).
         |> assign(
           :grant_duration_options,
           if(execution_request?,
             do: [{"This run only", "once"}],
             else: grant_duration_options(account_id)
           )
         )}
    end
  end

  defp fetch_action_run(%{run_id: run_id}, subject) when is_binary(run_id) do
    case Runs.fetch_run_by_id(run_id, subject, preload: [:runner, :attribution]) do
      {:ok, run} -> run
      {:error, _} -> nil
    end
  end

  defp fetch_action_run(_request, _subject), do: nil

  defp execution_plan(%{context: %{"kind" => "runbook_execution", "plan" => plan}})
       when is_map(plan),
       do: plan

  defp execution_plan(_request), do: nil

  # The section header already says "Why", so a lone REASON key stacked under it
  # prints one thing twice (§7.43). The keys earn their place the moment a second
  # fact — evidence, the expected outcome, the policy that gated it — joins them.
  defp lone_reason?(%Approvals.Request{} = request, run) do
    request.evidence in [nil, ""] and request.expected in [nil, ""] and
      (is_nil(run) or is_nil(run.policy_reason))
  end

  # Approvals owns the name (one derivation for the queue, the dashboard, and the
  # audit trail); the id is this page's own last resort, because a request whose
  # frozen context names neither a runbook nor an action still has to be
  # addressable in a page title.
  defp request_title(%Approvals.Request{} = request),
    do: Approvals.request_name(request) || request.id

  # One tier for either shape — a direct action's advertised risk or the worst
  # across a frozen execution plan — owned by the Approvals context.
  defp request_risk(request, subject) do
    case Approvals.risk_by_request_ids([request.id], subject) do
      {:ok, risks} -> risks[request.id]
      {:error, _reason} -> nil
    end
  end

  defp execution_work_label(%{"stages" => stages}) when is_list(stages) do
    items = Enum.flat_map(stages, &Map.get(&1, "items", []))
    runners = items |> Enum.map(& &1["runner_ref"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    "#{length(stages)} #{plural(length(stages), "stage")} · " <>
      "#{length(items)} #{plural(length(items), "action")} · " <>
      "#{length(runners)} #{plural(length(runners), "runner")}"
  end

  defp execution_work_label(_plan), do: "—"

  defp plural(1, noun), do: noun
  defp plural(_count, noun), do: noun <> "s"
  defp target_noun(true), do: "runbook execution"
  defp target_noun(false), do: "action"

  defp execution_action_label("draft_test", action),
    do: "#{action} draft test"

  defp execution_action_label(_execution_kind, action), do: "#{action} runbook"

  # The labels + posted values are the web's; which durations may be offered is
  # the account's cap, owned by Approvals — so this only converts its atoms to
  # the strings the select posts, it never interprets operator input.
  defp grant_duration_options(account_id) do
    allowed = Enum.map(Approvals.allowed_grant_durations(account_id), &Atom.to_string/1)

    Enum.filter(@grant_duration_options, fn {_label, value} -> value in allowed end)
  end

  # Loads the recorded votes + the distinct-approve tally and derives the two
  # server-side flags the decision panel reads — whether THIS user already
  # decided, and whether self-approval is forbidden for them. The context still
  # re-checks both on the decision event (IL-15); these only drive the UI.
  # Deferred behind connected?/1 (like the requester/decider/risk lookups) so the
  # dead render does no DB work — the connected pass and exact-request update
  # handler (always connected) load the real data.
  defp assign_decisions(socket, request) do
    if connected?(socket) do
      load_decisions(socket, request)
    else
      socket
      |> assign(:decisions, [])
      |> assign(:approved_count, 0)
      |> assign(:already_decided?, false)
      |> assign(:self_blocked?, false)
    end
  end

  defp load_decisions(socket, request) do
    subject = socket.assigns.current_subject

    # A failed read here is not "nobody has voted": it would print "0 of 3" to
    # the approver deciding on a quorum, and drop the vote trail that shows who
    # already signed off. Carry the failure so the tally reads as unknown.
    {decisions, decisions_failed?} =
      case Approvals.list_decisions_for_request(request, subject) do
        {:ok, list} -> {list, false}
        {:error, _} -> {[], true}
      end

    {approved_count, count_failed?} =
      case Approvals.approved_count_for_request(request, subject) do
        {:ok, n} -> {n, false}
        {:error, _} -> {0, true}
      end

    actor_id = subject.actor && subject.actor.id

    socket
    |> assign(:decisions, decisions)
    |> assign(:decisions_error?, decisions_failed? or count_failed?)
    |> assign(:approval_event_refs, approval_event_refs(request, subject))
    |> assign(:user_labels, user_labels_for(request, decisions, subject))
    |> assign(:approved_count, approved_count)
    |> assign(:already_decided?, Enum.any?(decisions, &(&1.decider_id == actor_id)))
    |> assign(
      :self_blocked?,
      not request.allow_self_approval and request.requested_by_id == actor_id
    )
  end

  defp approval_event_refs(request, subject) do
    case Audit.approval_event_refs([request.id], subject) do
      {:ok, refs} -> Map.get(refs, request.id, %{final: nil, decisions: %{}})
      {:error, _reason} -> %{final: nil, decisions: %{}}
    end
  end

  defp user_labels_for(request, decisions, subject) do
    decision_ids = Enum.map(decisions, & &1.decider_id)
    ids = [request.requested_by_id, request.decided_by_id | decision_ids]

    case Approvals.actor_labels_for_ids(ids, subject) do
      {:ok, labels} -> labels
      {:error, _reason} -> %{}
    end
  end

  defp fetch_action_for(%{"action_id" => action_id, "runner_id" => runner_id}, subject)
       when is_binary(action_id) and is_binary(runner_id) do
    case Catalog.fetch_action_by_id(action_id, runner_id, subject) do
      {:ok, action} -> action
      {:error, _} -> nil
    end
  end

  defp fetch_action_for(_context, _subject), do: nil

  # The snapshotted action id an approve can no longer bind to a trusted
  # contract — nil whenever the request is still approvable. A runbook
  # execution carries its own frozen plan and re-check, so it never lands here.
  defp unavailable_action_id(_request, true, _action), do: nil
  defp unavailable_action_id(_request, false, %Catalog.RunnerAction{}), do: nil

  defp unavailable_action_id(%{context: %{"action_id" => action_id}}, false, nil)
       when is_binary(action_id),
       do: action_id

  defp unavailable_action_id(_request, false, _action), do: nil

  # Runs owns the trust proof, the rendering, and the masking; a preview it
  # can't stand behind renders no command card at all — the raw Arguments card
  # still carries the detail.
  defp build_command_preview(%Catalog.RunnerAction{} = action, %Runs.ActionRun{} = run, subject) do
    case Runs.project_action_command(run.id, action, subject) do
      {:ok, line} -> line
      {:error, _reason} -> nil
    end
  end

  defp build_command_preview(_action, _run, _subject), do: nil

  # Runs owns the decode + sensitivity replacement; an unauthorized or
  # undecodable projection renders no Arguments card at all.
  defp visible_action_args(%Runs.ActionRun{} = run, subject) do
    case Runs.project_action_args(run, subject) do
      {:ok, args} -> args
      {:error, _reason} -> %{}
    end
  end

  defp visible_action_args(_run, _subject), do: %{}

  # The request and the lifecycle facts the page renders move together, so a
  # broadcast, a lapse, or a decision can never leave the two disagreeing.
  defp assign_request(socket, request) do
    socket
    |> assign(:request, request)
    |> assign(:request_facts, Approvals.request_facts(request, DateTime.utc_now()))
  end

  # Server-rendered fallback for the live countdown (no-JS, and the first paint
  # before the hook mounts), from the remaining seconds Approvals projected.
  # Coarse on purpose — the ExpiryCountdown hook replaces it with the ticking
  # MM:SS within a second.
  defp countdown_fallback(seconds) when seconds <= 0, do: "Expired"
  defp countdown_fallback(seconds) when seconds < 3600, do: "Expires in #{div(seconds, 60)}m"
  defp countdown_fallback(seconds), do: "Expires in #{div(seconds, 3600)}h"

  def handle_info({:approval_request_updated, %{id: id} = updated}, socket)
      when id == socket.assigns.request.id do
    {:noreply,
     socket
     |> assign_request(updated)
     |> assign_decisions(updated)}
  end

  def handle_info(%{event: "presence_diff"} = event, socket) do
    connection =
      Runners.project_connection(
        socket.assigns.runner_connection,
        runner_id(socket.assigns.run),
        Runners.normalize_connection_change(event)
      )

    {:noreply, assign(socket, :runner_connection, connection)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("grant_form_changed", params, socket) do
    {:noreply, assign_decision_fields(socket, params)}
  end

  # The live countdown reached zero client-side. Re-fetch so the terminal "Expired"
  # panel replaces the Approve form right away instead of waiting for the expiry
  # job's broadcast. Server-authoritative: the re-fetch and the facts Approvals
  # projects for it decide against the server clock — a skewed client clock can
  # only trigger the re-check, never force the outcome (the decide context also
  # refuses an expired approve, IL-15).
  def handle_event("expiry_lapsed", _params, socket) do
    case Approvals.fetch_approval_request_by_id(
           socket.assigns.request.id,
           socket.assigns.current_subject
         ) do
      {:ok, request} ->
        {:noreply, socket |> assign_request(request) |> assign_decisions(request)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # ONE form, one note field, two submit buttons — the button's value routes.
  def handle_event("decide", %{"decision" => "approve"} = params, socket),
    do: handle_event("approve", params, socket)

  def handle_event("decide", %{"decision" => "deny"} = params, socket),
    do: handle_event("deny", params, socket)

  def handle_event("approve", params, socket) do
    Permissions.gated(
      socket,
      Approvals.subject_can_decide_approval?(socket.assigns.current_subject),
      fn socket ->
        # The raw form goes to the context untouched — it owns what a duration,
        # a match scope, and a use cap mean, and rejects anything else.
        case Approvals.approve_request(
               socket.assigns.request,
               socket.assigns.current_subject,
               blank_or(params["reason"]),
               params
             ) do
          # Threshold met — finalized + dispatched.
          {:ok, {request, :runbook_execution}} ->
            {:noreply,
             socket
             |> assign_request(request)
             |> assign_decisions(request)
             |> put_flash(:info, "Runbook approved. Eligible actions are being dispatched.")}

          {:ok, {request, %_{} = _run}} ->
            {:noreply,
             socket
             |> assign_request(request)
             |> assign_decisions(request)
             |> put_flash(:info, approval_flash(params))}

          # Recorded but below the distinct-approver threshold — still pending.
          {:ok, {request, :pending}} ->
            socket = assign_decisions(socket, request)

            msg =
              "Recorded — #{socket.assigns.approved_count} of #{request.min_approvals} approvals."

            {:noreply, socket |> assign_request(request) |> put_flash(:info, msg)}

          {:error, %Ecto.Changeset{} = changeset} ->
            grant_input_failed(socket, changeset, params)

          {:error, reason} ->
            decision_failed(socket, reason, params)
        end
      end
    )
  end

  def handle_event("deny", params, socket) do
    Permissions.gated(
      socket,
      Approvals.subject_can_decide_approval?(socket.assigns.current_subject),
      fn socket ->
        case Approvals.deny_request(
               socket.assigns.request,
               socket.assigns.current_subject,
               blank_or(params["reason"])
             ) do
          {:ok, {request, _run}} ->
            {:noreply,
             socket
             |> assign_request(request)
             |> assign_decisions(request)
             |> put_flash(:info, "Denied.")}

          {:error, reason} ->
            decision_failed(socket, reason, params)
        end
      end
    )
  end

  # Carries the decision form's operator-entered values back into the render, so
  # any re-render puts them where the operator left them — including the reuse
  # window, which drives whether the Match / Limit-to fields show at all. Any
  # re-entry into the form clears a previous rejection's message.
  defp assign_decision_fields(socket, params) do
    socket
    |> assign(:decision_reason, params["reason"] || "")
    |> assign(:grant_duration, params["duration"] || "once")
    |> assign(:grant_scope, params["scope"] || "exact_args")
    |> assign(:grant_max_uses, params["max_uses"] || "")
    |> assign(:grant_input_error, nil)
    |> assign(:decision_reason_error, nil)
  end

  # The grant choices didn't validate, so nothing was decided and the request is
  # untouched: keep the panel live with everything the operator typed and name
  # the control they have to fix, inline at the form.
  defp grant_input_failed(socket, %Ecto.Changeset{} = changeset, params) do
    {:noreply,
     socket
     |> assign_decision_fields(params)
     |> assign(:grant_input_error, grant_input_error(changeset))}
  end

  defp grant_input_error(%Ecto.Changeset{} = changeset) do
    changeset.errors |> Keyword.keys() |> List.first() |> grant_field_error()
  end

  defp grant_field_error(:duration), do: "Pick a reuse window from the list."
  defp grant_field_error(:scope), do: "Pick how this grant matches arguments."

  defp grant_field_error(:max_uses),
    do: "Limit to must be a whole number of uses, at least 1. Leave it blank for unlimited."

  defp grant_field_error(_field), do: "Check the reuse settings, then decide again."

  # A self-approval refusal isn't a stale-state race — leave the panel as-is
  # (don't re-fetch), just flash the cause. The form stays live so they can still
  # Deny, so the note they wrote has to come back with it.
  defp decision_failed(socket, :self_approval_forbidden, params) do
    {:noreply,
     socket
     |> assign_decision_fields(params)
     |> put_flash(:error, "You can't approve your own request.")}
  end

  # The note is too long to store. Nothing was decided and the request is
  # untouched, and it is the one refusal here the operator fixes by editing what
  # they just typed — so it belongs inline at the textarea, not in a flash on a
  # re-fetched page. Their note comes back with it.
  defp decision_failed(socket, :decision_reason_too_long, params) do
    {:noreply,
     socket
     |> assign_decision_fields(params)
     |> assign(
       :decision_reason_error,
       "Shorten the note to #{Approvals.max_decision_reason_length()} characters or fewer."
     )}
  end

  # The request can leave this member's current runner or pack access while an
  # approval page is already open. The context re-checks that access inside the
  # decision transaction; once it answers as absent, remove the stale controls
  # instead of leaving a page that keeps offering a decision it cannot record.
  defp decision_failed(socket, :not_found, _params) do
    {:noreply,
     socket
     |> put_flash(:error, "Approval is no longer available under your current access.")
     |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/approvals")}
  end

  # The approve gate re-resolved the action's trusted contract and refused. The
  # request is untouched and still deniable, so keep the panel live (and the
  # note they wrote) and flip it to the unavailable state — the same thing a
  # fresh mount would show now.
  defp decision_failed(socket, reason, params)
       when reason in [:action_not_found, :pack_untrusted, :pack_retired, :action_unavailable] do
    {:noreply,
     socket
     |> assign_decision_fields(params)
     |> assign(:unavailable_action_id, socket.assigns.request.context["action_id"])
     |> put_flash(:error, decision_error_message(reason))}
  end

  # An approve/deny that didn't take: the request expired or was decided
  # between render and this click (the live exact-request broadcast can
  # race a fast click). Re-fetch so the panel flips to decision-history, then
  # flash the real cause instead of leaving the form interactive.
  defp decision_failed(socket, reason, _params) do
    {:noreply,
     socket
     |> refetch_request()
     |> put_flash(:error, decision_error_message(reason))}
  end

  defp refetch_request(socket) do
    case Approvals.fetch_approval_request_by_id(
           socket.assigns.request.id,
           socket.assigns.current_subject
         ) do
      {:ok, request} ->
        socket
        |> assign_request(request)
        |> assign_decisions(request)

      {:error, _} ->
        socket
    end
  end

  defp decision_error_message(:expired), do: "This request expired before your decision landed."
  defp decision_error_message(:already_decided), do: "Someone else already decided this request."

  defp decision_error_message(reason) when reason in [:run_cancelled, :run_not_pending_approval],
    do: "The run was cancelled before approval, so there's nothing left to approve."

  defp decision_error_message(:runbook_execution_not_approvable),
    do: "The runbook execution is no longer awaiting approval. Refresh to see its current state."

  defp decision_error_message(reason)
       when reason in [:action_not_found, :pack_untrusted, :pack_retired, :action_unavailable] do
    "The trusted contract for this action is no longer available, so there's nothing left to " <>
      "approve. Deny this request and re-issue it once the action is available again."
  end

  defp decision_error_message(:attestation_stale) do
    "This signed request expired before approval — its signature is now outside the runner's " <>
      "freshness window, so the runner would refuse it. Re-issue it from your MCP client and " <>
      "approve the fresh one."
  end

  defp decision_error_message(:grant_exceeds_account_max_lifetime) do
    "This grant's duration exceeds your account's maximum grant-lifetime cap. " <>
      "Pick a shorter window."
  end

  defp decision_error_message(_),
    do: "Your decision didn't record. Refresh to see the request's current state, then try again."

  # Echo exactly what was granted. The approve that just succeeded validated
  # these same params, so the confirmation reads the typed choices back out of
  # the context's own contract rather than re-reading the operator's strings.
  defp approval_flash(params) do
    case Approvals.decision_input(params) do
      {:ok, input} -> grant_flash(input)
      {:error, _changeset} -> "Approved."
    end
  end

  defp grant_flash(%{duration: :once}), do: "Approved for this call only."

  defp grant_flash(%{duration: duration} = input) do
    "Approved. Standing grant active for #{grant_window(duration)} " <>
      "(#{scope_label(input.scope)}#{uses_suffix(input.max_uses)})." <> revoke_hint(duration)
  end

  defp grant_window(:one_hour), do: "the next hour"
  defp grant_window(:one_day), do: "the next 24 hours"
  defp grant_window(:thirty_days), do: "the next 30 days"
  defp grant_window(:ninety_days), do: "the next 90 days"

  # Only a long window is worth pointing at the revoke surface for.
  defp revoke_hint(duration) when duration in [:thirty_days, :ninety_days],
    do: " Revoke from the Approvals page."

  defp revoke_hint(_duration), do: ""

  # Echo the reuse cap so the approver sees exactly what they granted — an
  # unlimited grant (nil) reads as the duration window alone.
  defp uses_suffix(nil), do: ""
  defp uses_suffix(n), do: ", up to #{n} #{if n == 1, do: "use", else: "uses"}"

  defp scope_label(:any_args), do: "any arguments"
  defp scope_label(_), do: "same arguments only"

  defp blank_or(""), do: nil
  defp blank_or(value), do: value

  defp user_label(labels, id) when is_binary(id), do: Map.get(labels, id, "Former member")
  defp user_label(_labels, _id), do: "—"

  # Hover context for the source qualifier. `:operator` (a human from the
  # console) carries no qualifier at all — the requester name says it; `:mcp`
  # is the one that matters, an autonomous LLM agent reaching the gate.
  # Only reached for a non-:operator source — the qualifier renders nowhere else.
  defp dispatch_source_meaning(:mcp), do: "Dispatched by an LLM agent over the MCP API"
  defp dispatch_source_meaning(:runbook), do: "Dispatched as a step in a runbook run"

  # The dispatch channel qualifier comes from Runs' attribution projection, so
  # approval never reinterprets API-key ownership or association load state.
  defp approval_channel(%{source: :mcp} = run) do
    {_who, via} = Runs.run_who_via(run)
    via
  end

  defp approval_channel(%{source: source}), do: format_source(source)

  # An action only leaves the queue when its runner is connected. The
  # decision panel surfaces this so an operator doesn't approve into a
  # dead runner and then wonder why the run never moved.
  defp runner_connection(%{runner: %{id: id, account_id: account_id}}),
    do: if(Runners.online?(account_id, id), do: :online, else: :offline)

  defp runner_connection(_), do: :unknown

  defp runner_id(%{runner_id: id}), do: id
  defp runner_id(_run), do: nil

  def render(assigns) do
    ~H"""
    <.console_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      section={:approvals}
      width={:table}
    >
      <:title>
        <%!-- No "Approval ·" prefix — the breadcrumb already says where you are;
             the action id IS the entity. --%>
        <.detail_header
          back="Approvals"
          navigate={~p"/app/#{@current_account}/approvals"}
          title={if @loaded?, do: request_title(@request), else: "Approval"}
          mono={@loaded? and not @execution_request?}
        />
      </:title>
      <:actions>
        <.button
          :if={@execution_request?}
          navigate={
            ~p"/app/#{@current_account}/runbooks/#{@request.context["runbook"]["id"]}/runs/#{@request.runbook_execution_id}"
          }
          variant={:secondary}
          size={:md}
        >
          {if(@request.context["execution_kind"] == "draft_test",
            do: "View draft test",
            else: "View runbook execution"
          )}
        </.button>
        <%!-- BUTTONS, one grammar per actions row (the run/runner-detail
             correction): the run this request gates, and its audit-trail
             slice (requested / approved / denied / expired — subject-scoped
             by the audit page, the link only pre-filters). --%>
        <.button
          :if={@run}
          navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
          variant={:secondary}
          size={:md}
        >
          View run
        </.button>
        <.button
          :if={@loaded?}
          navigate={
            ~p"/app/#{@current_account}/audit?#{[target_kind: "approval_request", target_id: @request.id]}"
          }
          variant={:secondary}
          size={:md}
        >
          View activity
        </.button>
      </:actions>
      <.loading_state :if={not @loaded?} />
      <%!-- The page owns its rhythm (§3.3): ONE space-y-12 child, mt-4 for air
           under the title. The status field is the compact verdict; human
           decision provenance lives once in the Decisions ledger below. --%>
      <div :if={@loaded?} class="mt-4 space-y-12">
        <div>
          <%!-- Request facts on the CANVAS — the naked meta row (run-detail
               grammar), no island. Status leads; one flex row at sm+, 2-col
               grid on phones (the action id + forensic timestamp span both
               columns via `wrap`). --%>
          <div class="grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-14">
            <%!-- The NORMALIZED verdict, not the raw DB status: a lapsed request
                 the sweeper hasn't auto-denied yet is still :pending in the DB,
                 and "Status: pending" above an "Expired — auto-denied" verdict
                 block contradicts the page. --%>
            <%!-- wrap: a badge is a composite, not a text run — truncation shears
             its pill instead of ellipsizing (§7.35). --%>
            <.meta_field label="Status" wrap>
              <span data-shot="approval-verdict">
                <.status_badge status={@request_facts.status} />
              </span>
            </.meta_field>
            <%!-- No ACTION/RUNBOOK meta field: its value was `request_title/1`, the
             very string the page title above already prints in full (mono for an
             action id) — a label:value row whose value restates the heading says
             one thing twice (§7.43). The risk tier is a genuinely separate fact,
             so it keeps its place, next to the status it qualifies. `wrap`: a pill
             is a composite, and scalar truncation shears it (§7.35). --%>
            <.meta_field :if={@action_risk} label="Risk" wrap>
              <.risk_pill id={"approval-#{@request.id}-risk"} risk={@action_risk} />
            </.meta_field>
            <.meta_field :if={not @execution_request?} label="Runner">
              <%= if @run && @run.runner do %>
                <%!-- Identity only — run-detail's Runner meta is the same shape.
                 A wordless colored dot said "connectivity" by color alone;
                 the offline case already escalates in the Decide panel. --%>
                <.link
                  navigate={~p"/app/#{@current_account}/runners/#{@run.runner.id}"}
                  class="truncate text-zinc-200 hover:text-brand-300"
                >
                  {@run.runner.name}
                </.link>
              <% else %>
                <%!-- The frozen dispatch-time runner id, in full — the container
                     truncates for display and the title recovers the whole value. --%>
                <% runner_id = @request.context["runner_id"] %>
                <span
                  :if={runner_id}
                  class="truncate font-mono text-xs text-zinc-400"
                  title={runner_id}
                >
                  {runner_id}
                </span>
                <span :if={is_nil(runner_id)} class="text-zinc-500">—</span>
              <% end %>
            </.meta_field>
            <.meta_field :if={@execution_request?} label="Frozen work">
              <span class="text-zinc-200">{execution_work_label(@execution_plan)}</span>
            </.meta_field>
            <%!-- Who (the accountable human) AND what asked: a request from an
             autonomous LLM agent (MCP) is the reason the gate exists and
             warrants more scrutiny than an operator's own dispatch. --%>
            <%!-- wrap: the source qualifier explains itself through a <.tooltip>,
             whose bubble scalar truncation would clip away. --%>
            <.meta_field label="Requested by" wrap>
              <span class="block">
                <span class="text-zinc-200">
                  {user_label(@user_labels, @request.requested_by_id)}
                </span>
                <%!-- The source qualifier is quiet TYPE after the name (the
                     run-detail "Dispatched by" grammar), never a filled chip —
                     who asked is metadata, not a status. "· Claude Code" doesn't
                     say an LLM dispatched this, so the tooltip carries that where
                     a touch or keyboard approver can reach it. --%>
                <.tooltip
                  :if={@run && @run.source != :operator}
                  id={"approval-#{@request.id}-source"}
                  align={:left}
                  text={dispatch_source_meaning(@run.source)}
                  class="text-zinc-400"
                >
                  · {approval_channel(@run)}
                </.tooltip>
              </span>
            </.meta_field>
            <%!-- wrap: the forensic timestamp is a machine value — on a phone it takes
             the full row and wraps rather than clipping to "…" (and never leaves
             the adjacent half-cell empty while truncating). --%>
            <.meta_field label="When" wrap>
              <.local_time
                value={@request.requested_at}
                mode={:forensic}
                class="tabular-nums text-zinc-200"
              />
            </.meta_field>
            <%!-- Only surface the tally for a multi-approver gate; a 1-of-1
             request reads no differently than the single-approver flow. --%>
            <.meta_field :if={@request.min_approvals > 1} label="Approvals">
              <span :if={@decisions_error?} class="text-zinc-200">
                {@request.min_approvals} required · tally unavailable
              </span>
              <span :if={not @decisions_error?} class="text-zinc-200">
                {@approved_count} of {@request.min_approvals}
              </span>
            </.meta_field>
            <%!-- Expiry isn't a meta field: for a held request the live countdown
               owns it in the decide panel (more prominent + ticking); a decided
               request's expiry is moot. --%>
          </div>

          <% verdict = @request_facts.status %>
          <p :if={verdict == :expired} class="mt-5 max-w-prose text-sm leading-relaxed text-zinc-400">
            <span class="font-medium text-zinc-200">Expired — auto-denied.</span>
            No one decided before the deadline, so the {target_noun(@execution_request?)} will not
            run. The requester can re-issue it if it's still needed.
          </p>
          <p
            :if={verdict == :cancelled}
            class="mt-5 max-w-prose text-sm leading-relaxed text-zinc-400"
          >
            This request was withdrawn before a decision, so the {target_noun(@execution_request?)} did not run.
          </p>
        </div>

        <%!-- On the pending state the 340px rail already caps the record column
             (~4xl at the 7xl page width); a decided page has no rail, so cap the
             record itself — a one-line command in a 7xl-wide artifact box reads
             stretched on a large screen. --%>
        <div class={[
          "grid grid-cols-1 gap-x-12 gap-y-12",
          if(verdict == :pending, do: "xl:grid-cols-[minmax(0,1fr)_340px]", else: "max-w-4xl")
        ]}>
          <%!-- Left: the decision record — the artifact (what will run), the raw
             args one click away, ONE why-cluster, then the vote trail. --%>
          <div class="space-y-10">
            <section :if={@execution_request?}>
              <.section_header title="Frozen runbook plan">
                <:subtitle>
                  Review every action, runner, and visible argument. One approval covers the
                  complete execution.
                </:subtitle>
              </.section_header>
              <div class="space-y-8">
                <RunbookWorkflowComponents.plan_stage
                  :for={stage <- @execution_plan["stages"] || []}
                  id={"approval-plan-stage-#{stage["id"]}"}
                  stage={stage}
                  items={stage["items"] || []}
                />
              </div>
            </section>

            <%!-- What will run: the plain-English effect from the pack manifest
               as NAKED prose (a note about the artifact never lives inside the
               artifact's box), then the exact command in the standard
               code_panel ARTIFACT — the only box here, earned by the code it
               holds. The command shows only when our compiled pack is provably
               the runner's (pinned hash, or advertised version); otherwise the
               raw arguments ARE the artifact. Sensitive args are masked. --%>
            <section :if={@executed_command || @action_description || @action_args != %{}}>
              <p
                :if={@action_description}
                class="mb-4 max-w-prose text-sm leading-relaxed text-zinc-400"
              >
                {@action_description}
              </p>
              <.code_panel
                :if={@executed_command}
                id={"approval-command-#{@request.id}"}
                label="Command"
                annotation="what the runner will execute"
                prompt
                code={@executed_command}
              />
              <.code_panel
                :if={is_nil(@executed_command) && @action_args != %{}}
                id={"approval-raw-args-#{@request.id}"}
                label="Arguments"
                annotation="what the runner will receive"
                max_h="max-h-64"
                code={format_json(@action_args)}
              />
            </section>

            <%!-- The raw args stay one click away once the command carries the
               detail — redundant with the resolved template, but the approver
               verifying the exact payload (against its logged sha) needs them. --%>
            <.disclosure
              :if={@executed_command && @action_args != %{}}
              id={"approval-args-#{@request.id}"}
              class="-mt-7"
            >
              <:summary>
                Raw arguments
                <span
                  :if={@request.context["args_sha256"]}
                  class="ml-1 min-w-0 truncate font-mono text-zinc-400"
                  title={"sha256:#{@request.context["args_sha256"]}"}
                >sha256:{@request.context["args_sha256"]}</span>
              </:summary>
              <pre
                tabindex="0"
                aria-label="Raw arguments"
                class="max-h-64 overflow-auto rounded-b-lg bg-black/40 px-4 py-3 font-mono text-xs leading-relaxed text-zinc-300"
              >{format_json(@action_args)}</pre>
            </.disclosure>

            <%!-- ONE why-cluster: the reason given and what gated it, together —
               not a Reason card and a policy callout competing at equal weight.
               Eyebrows stay zinc (R2) — urgency lives in the verdict panel. --%>
            <%!-- ONE why-cluster ON THE CANVAS (the run-detail grammar) — plain
               field keys, both alike (one icon on one label read as two kinds
               of fact). --%>
            <section :if={
              (@request.reason && @request.reason != "") ||
                (@request.evidence && @request.evidence != "") ||
                (@request.expected && @request.expected != "") || (@run && @run.policy_reason)
            }>
              <.section_header title="Why" />
              <dl class="space-y-5">
                <div :if={@request.reason && @request.reason != ""}>
                  <dt
                    :if={not lone_reason?(@request, @run)}
                    class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400"
                  >
                    Reason
                  </dt>
                  <dd class={[
                    "text-sm leading-relaxed text-zinc-200",
                    not lone_reason?(@request, @run) && "mt-1"
                  ]}>
                    {@request.reason}
                  </dd>
                </div>
                <%!-- The agent's justification chain, snapshotted on the request:
                     what it observed, then the outcome it expected. An approver
                     reads it before deciding; shown only when the agent gave it. --%>
                <div :if={@request.evidence && @request.evidence != ""}>
                  <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                    Evidence
                  </dt>
                  <dd class="mt-1 text-sm leading-relaxed text-zinc-200">
                    <span class="whitespace-pre-wrap">{@request.evidence}</span>
                  </dd>
                </div>
                <div :if={@request.expected && @request.expected != ""}>
                  <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                    Expected
                  </dt>
                  <dd class="mt-1 text-sm leading-relaxed text-zinc-200">
                    <span class="whitespace-pre-wrap">{@request.expected}</span>
                  </dd>
                </div>
                <div :if={@run && @run.policy_reason}>
                  <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                    Policy
                  </dt>
                  <dd class="mt-1 text-sm leading-relaxed text-zinc-200">{@run.policy_reason}</dd>
                  <dd
                    :if={@run.matched_rules && @run.matched_rules != []}
                    class="mt-1.5 text-xs text-zinc-400"
                  >
                    Matched rules:
                    <span class="font-mono">{Enum.join(@run.matched_rules, ", ")}</span>
                  </dd>
                </div>
              </dl>
            </section>

            <%!-- One canonical human decision ledger. Pending single-approver
                 requests have no decision to show; terminal single-approver
                 requests use the request's final decision as a fallback for
                 records created before per-vote rows existed. --%>
            <% displayed_decisions = displayed_decisions(@request, @decisions, @decisions_error?) %>
            <section
              :if={
                (displayed_decisions != [] or @decisions_error?) and
                  (@request.min_approvals > 1 or verdict in [:approved, :denied])
              }
              data-shot="approval-decisions"
            >
              <.section_header title="Decisions">
                <:subtitle :if={@request.min_approvals > 1 and not @decisions_error?}>
                  {@approved_count} of {@request.min_approvals} approvals
                </:subtitle>
              </.section_header>
              <%!-- Who has already signed off is what an approver reads before
                   adding their own vote — never present a failed read as an
                   untouched quorum. --%>
              <.empty_state
                :if={@decisions_error?}
                variant={:hint}
                tone={:danger}
                icon="hero-exclamation-triangle"
                title={
                  if(displayed_decisions == [],
                    do: "Couldn't load the decisions",
                    else: "Full decision history unavailable"
                  )
                }
              >
                <%= if displayed_decisions == [] do %>
                  This is a load error, not an untouched request — approvals may already be
                  recorded. Refresh the page before deciding.
                <% else %>
                  The final decision is shown below, but earlier votes may be missing. Refresh
                  the page to load the complete history.
                <% end %>
              </.empty_state>
              <ul :if={displayed_decisions != []} class="divide-y divide-zinc-800/70">
                <li
                  :for={decision <- displayed_decisions}
                  class="flex items-start gap-3 py-3 text-sm"
                >
                  <.icon
                    name={decision_icon(decision.decision)}
                    class={"mt-0.5 h-4 w-4 flex-none " <> decision_icon_class(decision.decision)}
                  />
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                      <span class="min-w-0 flex-1 truncate text-zinc-200">
                        {user_label(@user_labels, decision.decider_id)}
                      </span>
                      <span class="text-xs text-zinc-400">{decision_verb(decision.decision)}</span>
                      <.local_time
                        id={"decision-when-#{decision.id}"}
                        value={decision.decided_at}
                        mode={:forensic}
                        class="text-xs tabular-nums text-zinc-400"
                      />
                      <% event_id = decision_event_id(@approval_event_refs, @request, decision) %>
                      <.link
                        :if={event_id}
                        navigate={~p"/app/#{@current_account}/audit/#{event_id}"}
                        class="inline-flex min-h-10 items-center text-xs font-medium text-brand-400 hover:text-brand-300"
                      >
                        View audit record
                      </.link>
                    </div>
                    <p
                      :if={decision_reason(@request, decision)}
                      class="mt-1.5 text-sm leading-relaxed text-zinc-300"
                    >
                      “{decision_reason(@request, decision)}”
                    </p>
                  </div>
                </li>
              </ul>
            </section>
          </div>

          <%!-- Right: the decision panel, only while the request is genuinely live
             (sticky on desktop so it stays in reach past a long args/reason). A
             decided or lapsed request has no rail, so the column goes full-width. --%>
          <aside :if={verdict == :pending} class="xl:sticky xl:top-6 xl:self-start">
            <.decision_panel
              can_decide?={Approvals.subject_can_decide_approval?(@current_subject)}
              decision_reason={@decision_reason}
              grant_duration={@grant_duration}
              grant_scope={@grant_scope}
              grant_max_uses={@grant_max_uses}
              grant_input_error={@grant_input_error}
              decision_reason_error={@decision_reason_error}
              grant_duration_options={@grant_duration_options}
              runner_state={@runner_connection}
              unavailable_action_id={@unavailable_action_id}
              execution_request?={@execution_request?}
              execution_kind={@request.context["execution_kind"]}
              self_blocked?={@self_blocked?}
              already_decided?={@already_decided?}
              approved_count={@approved_count}
              decisions_error?={@decisions_error?}
              min_approvals={@request.min_approvals}
              expires_at={@request_facts.expires_at}
              expires_in_seconds={@request_facts.expires_in_seconds}
              request_id={@request.id}
              current_account={@current_account}
            />
          </aside>
        </div>
      </div>
    </.console_shell>
    """
  end

  attr :can_decide?, :boolean, required: true
  # The operator's in-progress decision input, tracked server-side so a
  # re-render restores it rather than clearing it.
  attr :decision_reason, :string, default: ""
  attr :grant_scope, :string, default: "exact_args"
  attr :grant_max_uses, :string, default: ""
  # Set when the context rejected the grant choices — nothing was decided, so
  # the form stays live and carries the message for the control to fix.
  attr :grant_input_error, :string, default: nil
  attr :decision_reason_error, :string, default: nil
  # Drives the reuse-window UI: the Match / Limit-to fields only show
  # once a real grant is being minted (duration != "once"). Defaulted so
  # a caller that forgets to thread it through can't crash the panel.
  attr :grant_duration, :string, default: "once"
  # The duration menu, already narrowed to the account's lifetime cap by the
  # caller. Defaulted to the full menu so a caller that forgets to thread it
  # through degrades to the server-backstopped behavior, not a crash.
  attr :grant_duration_options, :list, default: @grant_duration_options
  # Connection state of the target runner (:online | :offline | :unknown)
  # so the operator knows whether an approval will actually dispatch.
  attr :runner_state, :atom, default: :unknown
  # Set to the snapshotted action id once no trusted contract resolves for it.
  # Approve would be refused by the context, so the panel drops it and the
  # reuse controls and leaves Deny as the way out.
  attr :unavailable_action_id, :string, default: nil
  attr :execution_request?, :boolean, default: false
  attr :execution_kind, :string, default: nil
  # Server-computed UI gates. self_blocked? hides Approve when this user is the
  # requester and self-approval is forbidden; already_decided? hides both forms
  # once they've voted. The CONTEXT re-checks both (IL-15) — these are cosmetic.
  attr :self_blocked?, :boolean, default: false
  attr :already_decided?, :boolean, default: false
  attr :approved_count, :integer, default: 0
  attr :decisions_error?, :boolean, default: false
  attr :min_approvals, :integer, default: 1
  attr :expires_at, :any, default: nil
  # Seconds left on the deadline, projected by Approvals — the no-JS fallback
  # renders from this rather than diffing the timestamp here.
  attr :expires_in_seconds, :integer, default: nil
  attr :request_id, :string, required: true
  attr :current_account, :map, required: true

  defp decision_panel(assigns) do
    ~H"""
    <%!-- NAKED on the canvas — a form's fields are self-contained controls
         (the runbook editor / every create flow already sit boxless); the
         panel island read as one more wash box. --%>
    <section>
      <%!-- No subtitle: the note field's own placeholder already says the
           decision is logged — a header line restating it is double copy. --%>
      <.section_header title="Decide" />

      <%!-- Live countdown so the operator decides against the clock, not a static
           "expires in 3h". Ticks client-side (ExpiryCountdown hook); at zero it
           pushes `expiry_lapsed`, which re-fetches and flips to the terminal Expired
           panel — the server re-checks expires_at, so the clock only triggers it. --%>
      <div
        :if={@expires_at}
        id={"expiry-countdown-#{@request_id}"}
        phx-hook="ExpiryCountdown"
        phx-update="ignore"
        data-expires-at={DateTime.to_iso8601(@expires_at)}
        data-lapsed-event="expiry_lapsed"
        class="mb-4 flex items-center gap-1.5 text-xs font-medium tabular-nums text-zinc-400"
      >
        <.icon name="hero-clock" class="h-3.5 w-3.5" />
        <span data-countdown-text>{countdown_fallback(@expires_in_seconds)}</span>
      </div>

      <p :if={@min_approvals > 1} class="text-xs leading-relaxed text-zinc-400">
        This {target_noun(@execution_request?)} needs
        <strong class="text-zinc-100">{@min_approvals} distinct approvals</strong>
        <span :if={not @decisions_error?}>— {@approved_count} so far.</span>
        <span :if={@decisions_error?}>— the current tally couldn't be read.</span>
      </p>

      <.event_block
        :if={
          not @execution_request? and @runner_state == :offline and
            is_nil(@unavailable_action_id)
        }
        icon="hero-bolt-slash"
        tone={:amber}
        title="Runner offline"
        class="mt-4"
      >
        <:body>
          You can still approve — the action queues and runs once the runner reconnects, or
          expires if it doesn't.
        </:body>
      </.event_block>

      <%= cond do %>
        <% not @can_decide? -> %>
          <p class="mt-4 text-xs leading-relaxed text-zinc-400">
            Viewers can't decide approvals.
          </p>
        <% @already_decided? -> %>
          <p class="mt-4 text-xs leading-relaxed text-zinc-400">
            You've already recorded your decision on this request. Waiting on the remaining approvers.
          </p>
        <% true -> %>
          <%!-- No trusted contract resolves for this action any more, so an
               approve would be refused. Say which action, and point at the one
               move left — Deny, then re-issue. --%>
          <.event_block
            :if={@unavailable_action_id}
            icon="hero-exclamation-triangle"
            tone={:rose}
            title="Action no longer available"
            class="mt-4"
          >
            <:body>
              Emisar can't find a trusted contract for
              <span class="font-mono text-zinc-200">{@unavailable_action_id}</span>
              any more, so this request can't be approved. Deny it, then re-issue the request once
              the action is available again.
            </:body>
          </.event_block>
          <%!-- Approve form. Hidden when this user is the requester and the
               policy forbids self-approval — the context refuses it anyway
               (IL-15), this just removes the dead button. They can still Deny
               their own request. --%>
          <p
            :if={@self_blocked? and is_nil(@unavailable_action_id)}
            class="mt-4 text-xs leading-relaxed text-zinc-400"
          >
            You can't approve your own request — a different operator must approve it.
          </p>
          <p :if={is_nil(@unavailable_action_id)} class="mt-4 text-xs leading-relaxed text-zinc-400">
            {decision_intro(@execution_request?, @self_blocked?, @grant_duration_options)}
            <.doc_link href={~p"/docs/policies-and-approvals"}>Approvals docs</.doc_link>
          </p>
          <%!-- ONE decision form: a single note field logged with whichever
               decision is taken (two competing optional textareas doubled the
               form, and the deny box under Approve read as a note for the
               approval just taken). Default approve state = one-shot ("just
               this call"), no grant. --%>
          <form
            id="approval-decision-form"
            phx-submit="decide"
            phx-change="grant_form_changed"
            class="mt-4 space-y-4"
          >
            <%!-- Bare top-level name (the submit buttons post `decision=…`
                 beside it, so a namespaced form would collide) with the value
                 tracked server-side, so a co-approver's broadcast or a refused
                 decision can't wipe a half-written note. `aria-label` names it
                 for AT (the placeholder is not an accessible name); `min-h-0`
                 undoes the component's default min-height for a compact 2-row box. --%>
            <.input
              type="textarea"
              name="reason"
              value={@decision_reason}
              rows="2"
              maxlength={Approvals.max_decision_reason_length()}
              aria-label="Decision note"
              placeholder="Note — logged with your decision (optional)"
              class="min-h-0 resize-none"
            />
            <.error :if={@decision_reason_error}>{@decision_reason_error}</.error>

            <%!-- Standing grants disabled (account cap 0) → the reuse menu
                 would be a dead one-option select; a quiet line says why the
                 affordance is gone. --%>
            <p
              :if={
                not @execution_request? and not @self_blocked? and
                  is_nil(@unavailable_action_id) and length(@grant_duration_options) <= 1
              }
              class="text-[11px] leading-relaxed text-zinc-400"
            >
              Standing grants are disabled for this account — every approval is single-use.
            </p>
            <.disclosure :if={
              not @execution_request? and not @self_blocked? and
                is_nil(@unavailable_action_id) and length(@grant_duration_options) > 1
            }>
              <:summary>
                <.icon name="hero-clock" class="h-3.5 w-3.5 text-zinc-400" />
                Allow the LLM to reuse this approval
              </:summary>
              <div class="space-y-3">
                <div>
                  <.input
                    name="duration"
                    type="select"
                    label="For"
                    label_variant={:eyebrow}
                    value={@grant_duration}
                    options={@grant_duration_options}
                  />
                </div>
                <%!-- Match / Limit-to only matter when an actual grant is
                   being minted. With duration="once" no grant is created,
                   so showing these fields was asking the operator to
                   configure parameters that get discarded. The form's
                   phx-change handler tracks duration → re-renders this
                   block. --%>
                <div :if={@grant_duration != "once"}>
                  <%!-- Value-bound like the note: picking a wider match and then
                       adjusting the duration re-renders this field, which would
                       silently snap the choice back to the narrow default. --%>
                  <.input
                    name="scope"
                    type="select"
                    label="Match"
                    label_variant={:eyebrow}
                    value={@grant_scope}
                    options={[
                      {"Same arguments only", "exact_args"},
                      {"Any arguments for this action", "any_args"}
                    ]}
                  />
                </div>
                <div :if={@grant_duration != "once"}>
                  <%!-- Explicit `id` so the eyebrow label's `for` associates;
                       value-bound so a duration change doesn't clear the cap the
                       operator just typed. --%>
                  <.input
                    type="number"
                    id="grant_max_uses"
                    name="max_uses"
                    value={@grant_max_uses}
                    label="Limit to (optional)"
                    label_variant={:eyebrow}
                    min="1"
                    placeholder="unlimited"
                  />
                  <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
                    Cap how many times this grant can be used within the window. Leave blank for unlimited.
                    Grants are reviewable + revocable on the <.link
                      navigate={~p"/app/#{@current_account}/approvals"}
                      class="text-brand-400 hover:text-brand-300"
                    >approvals page</.link>.
                  </p>
                </div>
              </div>
            </.disclosure>

            <%!-- The rejection sits with the controls it names, not in a
                 top-of-page flash the operator has to scroll back from —
                 nothing was decided, so the form is still the place to fix. --%>
            <.error :if={@grant_input_error}>{@grant_input_error}</.error>

            <%!-- Approve stays gated for the self-blocked requester; deny is
                 always available (denying your own request is fine). --%>
            <.button
              :if={not @self_blocked? and is_nil(@unavailable_action_id)}
              name="decision"
              value="approve"
              class="w-full"
              icon="hero-check"
              phx-disable-with="Approving…"
            >
              {if(@execution_request?,
                do: execution_action_label(@execution_kind, "Approve"),
                else: "Approve and send"
              )}
            </.button>
            <.button
              name="decision"
              value="deny"
              variant={:secondary}
              tone={:rose}
              class="w-full"
              icon="hero-x-mark"
              phx-disable-with="Denying…"
            >
              Deny
            </.button>
          </form>
      <% end %>
    </section>
    """
  end

  # Self-blocked requester: only Deny renders, so the intro must not explain
  # an Approve button they'll never see — the paragraph above already says a
  # different operator has to approve.
  defp decision_intro(_execution_request?, true, _options) do
    "You can still deny your own request — your decision is logged."
  end

  defp decision_intro(true, false, _options) do
    "Approve once to release every action shown here. This execution will not ask for another " <>
      "approval. If policy changes to deny the work, runner access is removed, or a trusted " <>
      "pack is no longer available before dispatch, Emisar stops the execution."
  end

  defp decision_intro(false, false, options) do
    "Approve runs this action once#{reuse_clause(options)} decision is logged."
  end

  # The middle clause of the decide-form lead line. The reuse-window offer
  # appears only when the standing-grant menu itself does — the account allows a
  # duration past "once" (`grant_duration_options` has more than one entry) —
  # so the copy never names an affordance the form doesn't show.
  defp reuse_clause([_, _ | _]) do
    " — or pick a reuse window to issue a standing grant. Either"
  end

  defp reuse_clause(_options), do: ". Your"

  # Decision-list rendering helpers (the enum loads as an atom).
  defp decision_icon(:approve), do: "hero-check-circle"
  defp decision_icon(:deny), do: "hero-x-circle"

  defp decision_icon_class(:approve), do: "text-brand-400"
  defp decision_icon_class(:deny), do: "text-rose-400"

  defp decision_verb(:approve), do: "approved"
  defp decision_verb(:deny), do: "denied"

  defp displayed_decisions(%Approvals.Request{} = request, [], _decisions_error?)
       when request.status in [:approved, :denied] do
    [
      %{
        id: request.id,
        decider_id: request.decided_by_id,
        decision: if(request.status == :approved, do: :approve, else: :deny),
        decided_at: request.decided_at
      }
    ]
  end

  defp displayed_decisions(_request, decisions, false), do: decisions

  defp displayed_decisions(%Approvals.Request{} = request, _decisions, true)
       when request.status in [:approved, :denied],
       do: displayed_decisions(request, [], true)

  defp displayed_decisions(_request, _decisions, true), do: []

  defp decision_event_id(refs, request, decision)
       when request.status in [:approved, :denied] and
              decision.decider_id == request.decided_by_id,
       do: refs.final || refs.decisions[decision.decider_id]

  defp decision_event_id(refs, _request, decision), do: refs.decisions[decision.decider_id]

  defp decision_reason(request, decision)
       when request.status in [:approved, :denied] and
              decision.decider_id == request.decided_by_id and
              is_binary(request.decision_reason) and request.decision_reason != "",
       do: request.decision_reason

  defp decision_reason(_request, _decision), do: nil
end
