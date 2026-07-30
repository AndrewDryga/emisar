defmodule EmisarWeb.ApprovalDetailLive do
  use EmisarWeb, :live_view
  alias Emisar.{Approvals, Catalog, Runners, Runs, Users}
  alias EmisarWeb.{CommandPreview, PacksRegistry, Permissions, RunbookWorkflowComponents}
  alias EmisarWeb.MCP.RawJSON
  alias EmisarWeb.RunnerPresence

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
     |> assign(:run, nil)
     |> assign(:execution_plan, nil)
     |> assign(:execution_request?, false)
     |> assign(:action_args, %{})
     |> assign(:action_risk, nil)
     |> assign(:action_description, nil)
     |> assign(:executed_command, nil)
     |> assign(:runner_connection, :unknown)
     |> assign(:requested_by, nil)
     |> assign(:decided_by, nil)
     |> assign(:decisions, [])
     |> assign(:approved_count, 0)
     |> assign(:already_decided?, false)
     |> assign(:self_blocked?, false)
     |> assign_decision_fields(%{})
     |> assign(:grant_duration, "once")
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
        Runners.subscribe_connections(account_id)

        run = fetch_action_run(request, socket.assigns.current_subject)
        execution_plan = execution_plan(request)
        execution_request? = not is_nil(execution_plan)

        title = "Approval · " <> request_title(request)

        requested_by = lookup_user(request.requested_by_id)
        decided_by = lookup_user(request.decided_by_id)

        # Risk + the plain-English "what this does" are the approver's headline
        # signals but aren't on the request — look the action up from the catalog
        # (display-only, connected pass; nil if it's no longer advertised).
        action = fetch_action_for(request.context, socket.assigns.current_subject)

        {:ok,
         socket
         |> assign(:loaded?, true)
         |> assign(:page_title, title)
         |> assign(:request, request)
         |> assign(:run, run)
         |> assign(:execution_plan, execution_plan)
         |> assign(:execution_request?, execution_request?)
         |> assign(:action_args, visible_action_args(run))
         |> assign(:action_risk, (action && action.risk) || execution_risk(execution_plan))
         |> assign(:action_description, action && action.description)
         # The exact command the runner will execute, arguments resolved into
         # the action's template — shown only when our compiled pack is provably
         # the runner's (its pinned hash, or advertised version when unpinned).
         |> assign(:executed_command, build_command_preview(action, run))
         |> assign(:runner_connection, runner_connection(run))
         |> assign(:requested_by, requested_by)
         |> assign(:decided_by, decided_by)
         |> assign_decisions(request)
         # Every operator-entered decision field is tracked server-side. A
         # co-approver's broadcast, the expiry countdown, or a refused decision
         # all re-render this panel, and LiveView only preserves the value of
         # the input that happens to be focused — an untracked field would drop
         # a half-written denial justification on the floor. They stay bare
         # top-level params (not a namespaced form) because the submit buttons
         # post `decision=approve|deny` alongside them.
         |> assign_decision_fields(%{})
         # Tracks the duration the operator picked in the grant-reuse
         # disclosure. "once" (the default) means "no grant" — in that
         # mode the Match / Limit-to fields are irrelevant and hidden.
         |> assign(:grant_duration, "once")
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
    case Runs.fetch_run_by_id(run_id, subject, preload: [:runner, :api_key]) do
      {:ok, run} -> run
      {:error, _} -> nil
    end
  end

  defp fetch_action_run(_request, _subject), do: nil

  defp execution_plan(%{context: %{"kind" => "runbook_execution", "plan" => plan}})
       when is_map(plan),
       do: plan

  defp execution_plan(_request), do: nil

  defp request_title(%{
         context: %{"kind" => "runbook_execution", "runbook" => runbook}
       }),
       do: runbook["title"] || "Runbook execution"

  defp request_title(%{context: context, id: id}),
    do: context["action_id"] || String.slice(id, 0, 8)

  defp execution_risk(%{"stages" => stages}) when is_list(stages) do
    stages
    |> Enum.flat_map(&Map.get(&1, "items", []))
    |> Enum.map(& &1["risk"])
    |> Enum.max_by(&risk_rank/1, fn -> nil end)
  end

  defp execution_risk(_plan), do: nil

  defp risk_rank("critical"), do: 4
  defp risk_rank("high"), do: 3
  defp risk_rank("medium"), do: 2
  defp risk_rank("low"), do: 1
  defp risk_rank(_risk), do: 0

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

  defp grant_duration_options(account_id) do
    allowed = Approvals.allowed_grant_durations(account_id)

    Enum.filter(@grant_duration_options, fn {_label, value} ->
      parse_duration(value) in allowed
    end)
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

    decisions =
      case Approvals.list_decisions_for_request(request, subject) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    approved_count =
      case Approvals.approved_count_for_request(request, subject) do
        {:ok, n} -> n
        {:error, _} -> 0
      end

    actor_id = subject.actor && subject.actor.id

    socket
    |> assign(:decisions, decisions)
    |> assign(:approved_count, approved_count)
    |> assign(:already_decided?, Enum.any?(decisions, &(&1.decider_id == actor_id)))
    |> assign(
      :self_blocked?,
      not request.allow_self_approval and request.requested_by_id == actor_id
    )
  end

  # Resolves a user_id → email for the request/decision labels. Tolerates
  # missing rows (a since-removed user) by returning `nil` so the
  # template can fall back to a placeholder.
  defp lookup_user(nil), do: nil

  defp lookup_user(id) when is_binary(id) do
    case Users.fetch_user_by_id(id) do
      {:ok, user} -> user
      _ -> nil
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

  # Resolve the run's args into the action's command template for display —
  # gated on our compiled pack provably being the runner's (its pinned hash, or
  # the advertised pack version when unpinned), so we only ever render the exact
  # template the runner holds. Returns nil (no command card) for a drift, a
  # script-kind action, or a template we can't fully resolve — the raw Arguments
  # card still carries the detail.
  defp build_command_preview(%Catalog.RunnerAction{} = action, %Runs.ActionRun{} = run) do
    specs = List.wrap(action.args_schema["args"])

    with {:ok, command} <-
           PacksRegistry.resolve_command(
             action.pack_id,
             action.action_id,
             run.expected_pack_hash,
             action.pack_version
           ),
         {:ok, args} <- RawJSON.decode_object(run.args_raw),
         {:ok, line} <- CommandPreview.render(command, args, specs) do
      line
    else
      _ -> nil
    end
  end

  defp build_command_preview(_action, _run), do: nil

  defp visible_action_args(%Runs.ActionRun{} = run) do
    case RawJSON.decode_object(run.args_raw) do
      {:ok, args} -> RawJSON.redact(args, run.sensitive_arg_names)
      {:error, _reason} -> %{}
    end
  end

  defp visible_action_args(_run), do: %{}

  defp request_expired?(%{expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  defp request_expired?(_), do: false

  # Server-rendered fallback for the live countdown (no-JS, and the first paint
  # before the hook mounts). Coarse on purpose — the ExpiryCountdown hook replaces
  # it with the ticking MM:SS within a second.
  defp countdown_fallback(%DateTime{} = expires_at) do
    case DateTime.diff(expires_at, DateTime.utc_now(), :second) do
      seconds when seconds <= 0 -> "Expired"
      seconds when seconds < 3600 -> "Expires in #{div(seconds, 60)}m"
      seconds -> "Expires in #{div(seconds, 3600)}h"
    end
  end

  def handle_info({:approval_request_updated, %{id: id} = updated}, socket)
      when id == socket.assigns.request.id do
    {:noreply,
     socket
     |> assign(:request, updated)
     |> assign(:decided_by, lookup_user(updated.decided_by_id))
     |> assign_decisions(updated)}
  end

  def handle_info(%{event: "presence_diff"} = event, socket) do
    connection =
      RunnerPresence.patch_connection(
        socket.assigns.runner_connection,
        runner_id(socket.assigns.run),
        RunnerPresence.normalize(event)
      )

    {:noreply, assign(socket, :runner_connection, connection)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("grant_form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:grant_duration, params["duration"] || "once")
     |> assign_decision_fields(params)}
  end

  # The live countdown reached zero client-side. Re-fetch so the terminal "Expired"
  # panel replaces the Approve form right away instead of waiting for the expiry
  # job's broadcast. Server-authoritative: the re-fetch + render-time
  # request_expired?/1 decide using the server clock — a skewed client clock can
  # only trigger the re-check, never force the outcome (the decide context also
  # refuses an expired approve, IL-15).
  def handle_event("expiry_lapsed", _params, socket) do
    case Approvals.fetch_approval_request_by_id(
           socket.assigns.request.id,
           socket.assigns.current_subject
         ) do
      {:ok, request} ->
        {:noreply, socket |> assign(:request, request) |> assign_decisions(request)}

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
        opts = [
          duration: parse_duration(params["duration"]),
          scope: parse_scope(params["scope"]),
          max_uses: parse_max_uses(params["max_uses"])
        ]

        reason = blank_or(params["reason"])

        case Approvals.approve_request(
               socket.assigns.request,
               socket.assigns.current_subject,
               reason,
               opts
             ) do
          # Threshold met — finalized + dispatched.
          {:ok, {request, :runbook_execution}} ->
            {:noreply,
             socket
             |> assign(:request, request)
             |> assign_decisions(request)
             |> put_flash(:info, "Runbook approved. Eligible actions are being dispatched.")}

          {:ok, {request, %_{} = _run}} ->
            {:noreply,
             socket
             |> assign(:request, request)
             |> assign_decisions(request)
             |> put_flash(:info, approval_flash(opts))}

          # Recorded but below the distinct-approver threshold — still pending.
          {:ok, {request, :pending}} ->
            socket = assign_decisions(socket, request)

            msg =
              "Recorded — #{socket.assigns.approved_count} of #{request.min_approvals} approvals."

            {:noreply, socket |> assign(:request, request) |> put_flash(:info, msg)}

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
             |> assign(:request, request)
             |> assign_decisions(request)
             |> put_flash(:info, "Denied.")}

          {:error, reason} ->
            decision_failed(socket, reason, params)
        end
      end
    )
  end

  # Carries the decision form's operator-entered values back into the render, so
  # any re-render puts them where the operator left them.
  defp assign_decision_fields(socket, params) do
    socket
    |> assign(:decision_reason, params["reason"] || "")
    |> assign(:grant_scope, params["scope"] || "exact_args")
    |> assign(:grant_max_uses, params["max_uses"] || "")
  end

  # A self-approval refusal isn't a stale-state race — leave the panel as-is
  # (don't re-fetch), just flash the cause. The form stays live so they can still
  # Deny, so the note they wrote has to come back with it.
  defp decision_failed(socket, :self_approval_forbidden, params) do
    {:noreply,
     socket
     |> assign_decision_fields(params)
     |> put_flash(:error, "You can't approve your own request.")}
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
        |> assign(:request, request)
        |> assign(:decided_by, lookup_user(request.decided_by_id))
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

  defp parse_max_uses(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_max_uses(_), do: nil

  defp parse_duration("one_hour"), do: :one_hour
  defp parse_duration("one_day"), do: :one_day
  defp parse_duration("thirty_days"), do: :thirty_days
  defp parse_duration("ninety_days"), do: :ninety_days
  defp parse_duration(_), do: :once

  defp parse_scope("any_args"), do: :any_args
  defp parse_scope(_), do: :exact_args

  # Extract values via Keyword.fetch so the function doesn't depend on
  # the exact pair-count of `opts` — a previous shape mismatched the
  # caller's 3-key opts (`duration`, `scope`, `max_uses`) and crashed
  # the LV on every approve click.
  defp approval_flash(opts) do
    scope = Keyword.fetch!(opts, :scope)
    max_uses = Keyword.get(opts, :max_uses)

    case Keyword.fetch!(opts, :duration) do
      :once -> "Approved for this call only."
      :one_hour -> grant_flash("the next hour", scope, max_uses)
      :one_day -> grant_flash("the next 24 hours", scope, max_uses)
      :thirty_days -> grant_flash("the next 30 days", scope, max_uses) <> revoke_hint()
      :ninety_days -> grant_flash("the next 90 days", scope, max_uses) <> revoke_hint()
    end
  end

  defp grant_flash(window, scope, max_uses) do
    "Approved. Standing grant active for #{window} (#{scope_label(scope)}#{uses_suffix(max_uses)})."
  end

  defp revoke_hint, do: " Revoke from the Approvals page."

  # Echo the reuse cap so the approver sees exactly what they granted — an
  # unlimited grant (nil) reads as the duration window alone.
  defp uses_suffix(nil), do: ""
  defp uses_suffix(n), do: ", up to #{n} #{if n == 1, do: "use", else: "uses"}"

  defp scope_label(:any_args), do: "any arguments"
  defp scope_label(_), do: "same arguments only"

  defp blank_or(""), do: nil
  defp blank_or(value), do: value

  # Rendering helper for "Requested by" / "Decided by". Prefers the
  # user's full name, falls back to email, then to a short UUID slice
  # if the user record is gone (deleted account), then to em-dash.
  defp user_label(%Emisar.Users.User{full_name: name}, _id)
       when is_binary(name) and name != "",
       do: name

  defp user_label(%Emisar.Users.User{email: email}, _id), do: email
  defp user_label(_, id) when is_binary(id), do: String.slice(id, 0, 8) <> "…"
  defp user_label(_, _), do: "—"

  # Hover context for the source qualifier. `:operator` (a human from the
  # console) carries no qualifier at all — the requester name says it; `:mcp`
  # is the one that matters, an autonomous LLM agent reaching the gate.
  defp dispatch_source_title(:mcp), do: "Dispatched by an LLM agent over the MCP API"
  defp dispatch_source_title(:runbook), do: "Dispatched as a step in a runbook run"
  defp dispatch_source_title(:scheduled), do: "Dispatched by a schedule"
  defp dispatch_source_title(_), do: nil

  # The dispatch channel qualifier: name the actual MCP client (its API-key
  # name, e.g. "Claude Code") when we have it, so an agent's request reads as
  # who it was, not a generic "LLM agent" — the attribution house rule. Falls
  # back to the source noun for non-MCP dispatch or an unnamed/absent key.
  defp approval_channel(%{source: :mcp, api_key: %{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp approval_channel(%{source: source}), do: format_source(source)

  # First 12 chars of a runner UUID + "…" trailer when one exists, or
  # an em-dash if the context didn't carry a runner_id at all. Kept as
  # a helper so the template stays single-expression — mixing a slice
  # and a ternary inline tripped the HEEx formatter into an unstable
  # whitespace fixed-point.
  defp truncated_runner_id(nil), do: "—"
  defp truncated_runner_id(id) when is_binary(id), do: String.slice(id, 0, 12) <> "…"

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
    <.dashboard_shell
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
      flash={@flash}
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
          View runbook execution
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
      <div :if={not @loaded?} class="mt-8 flex items-center gap-2 text-sm text-zinc-400">
        <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
        Loading approval…
      </div>
      <%!-- The page owns its rhythm (§3.3): ONE space-y-12 child, mt-4 for air
           under the title; the STATUS block groups the naked meta row with the
           verdict that elaborates it. --%>
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
            <.meta_field label="Status">
              <.status_badge status={verdict_status(@request)} />
            </.meta_field>
            <%!-- Never clip the action on the decision screen — an approver must read
             the full action id before deciding. `wrap` gives it the full row on
             mobile and wraps rather than truncating; the risk pill flows after. --%>
            <.meta_field label={if(@execution_request?, do: "Runbook", else: "Action")} wrap>
              <span class="inline-flex flex-wrap items-center gap-x-2 gap-y-1">
                <span class={[if(not @execution_request?, do: "font-mono"), "text-zinc-200"]}>
                  {request_title(@request)}
                </span>
                <.risk_pill :if={@action_risk} risk={@action_risk} />
              </span>
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
                <span class="truncate font-mono text-xs text-zinc-400">
                  {truncated_runner_id(@request.context["runner_id"])}
                </span>
              <% end %>
            </.meta_field>
            <.meta_field :if={@execution_request?} label="Frozen work">
              <span class="text-zinc-200">{execution_work_label(@execution_plan)}</span>
            </.meta_field>
            <%!-- Who (the accountable human) AND what asked: a request from an
             autonomous LLM agent (MCP) is the reason the gate exists and
             warrants more scrutiny than an operator's own dispatch. --%>
            <.meta_field label="Requested by">
              <span class="block truncate">
                <span class="text-zinc-200">
                  {user_label(@requested_by, @request.requested_by_id)}
                </span>
                <%!-- The source qualifier is quiet TYPE after the name (the
                     run-detail "Dispatched by" grammar), never a filled chip —
                     who asked is metadata, not a status. --%>
                <span
                  :if={@run && @run.source != :operator}
                  class="text-zinc-400"
                  title={dispatch_source_title(@run.source)}
                >
                  · {approval_channel(@run)}
                </span>
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
              <span class="text-zinc-200">{@approved_count} of {@request.min_approvals}</span>
            </.meta_field>
            <%!-- Expiry isn't a meta field: for a held request the live countdown
               owns it in the decide panel (more prominent + ticking); a decided
               request's expiry is moot. --%>
          </div>

          <% verdict = verdict_status(@request) %>

          <%!-- Lead with the verdict — anchored to the status it elaborates
               (the run-detail correction), as an EVENT BLOCK, not a wash box:
               brand = approved, rose = denied/expired/cancelled. Decider +
               time + note ride the body. --%>
          <.event_block
            :if={verdict != :pending}
            icon={verdict_icon(verdict)}
            tone={verdict_tone(verdict)}
            title={verdict_title(verdict)}
            class="mt-8 max-w-4xl"
          >
            <:body>
              <%= case verdict do %>
                <% :expired -> %>
                  This request expired before anyone decided, so it was auto-denied — the {target_noun(
                    @execution_request?
                  )} will not run. The requester can re-issue it if
                  it's still needed.
                <% :cancelled -> %>
                  This request was withdrawn before a decision, so the {target_noun(
                    @execution_request?
                  )} did not run.
                <% _ -> %>
                  <span :if={@request.decided_at}>
                    by {user_label(@decided_by, @request.decided_by_id)} ·
                    <.local_time value={@request.decided_at} mode={:forensic} class="tabular-nums" />
                  </span>
                  <span
                    :if={@request.decision_reason && @request.decision_reason != ""}
                    class="mt-1.5 block"
                  >
                    “{@request.decision_reason}”
                  </span>
              <% end %>
            </:body>
          </.event_block>
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
              <div class="space-y-6">
                <section :for={stage <- @execution_plan["stages"] || []}>
                  <div class="flex flex-wrap items-center justify-between gap-3">
                    <h3 class="text-sm font-semibold text-zinc-100">{stage["title"]}</h3>
                    <span class="text-xs text-zinc-400">
                      {if stage["mode"] == "parallel",
                        do: "Parallel · up to #{stage["max_parallel"]}",
                        else: "Sequential"}
                    </span>
                  </div>
                  <ul class="mt-2 divide-y divide-zinc-800/70 border-y border-zinc-800/70">
                    <li
                      :for={item <- stage["items"] || []}
                      class="py-4"
                    >
                      <div class="min-w-0">
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="font-mono text-sm text-zinc-100">{item["action"]}</span>
                          <.risk_pill :if={item["risk"]} risk={item["risk"]} />
                        </div>
                        <p class="mt-1 text-xs text-zinc-400">
                          On
                          <span class="font-medium text-zinc-300">
                            {RunbookWorkflowComponents.runner_name(item["runner_ref"])}
                          </span>
                        </p>
                      </div>
                      <RunbookWorkflowComponents.argument_list
                        arguments={item["args"] || %{}}
                        class="mt-3"
                      />
                    </li>
                  </ul>
                </section>
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
                  <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                    Reason
                  </dt>
                  <dd class="mt-1 text-sm leading-relaxed text-zinc-200">{@request.reason}</dd>
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

            <%!-- Who has voted so far — surfaced for any multi-approver gate so
               an approver sees who's already signed off (and that a deny
               finalized). A single-approver request shows it only once decided
               (the decision-history panel covers the lone vote). --%>
            <%!-- The vote trail ON THE CANVAS — hairline rows under a section
               header (the approvals-list grammar), not a boxed split panel. --%>
            <section :if={@decisions != [] and @request.min_approvals > 1}>
              <.section_header title="Decisions">
                <:subtitle>{@approved_count} of {@request.min_approvals} approvals</:subtitle>
              </.section_header>
              <ul class="divide-y divide-zinc-800/70">
                <li :for={decision <- @decisions} class="flex items-center gap-3 py-2.5 text-sm">
                  <.icon
                    name={decision_icon(decision.decision)}
                    class={"h-4 w-4 flex-none " <> decision_icon_class(decision.decision)}
                  />
                  <span class="min-w-0 flex-1 truncate text-zinc-200">
                    {user_label(decision.decider, decision.decider_id)}
                  </span>
                  <span class="text-xs text-zinc-400">{decision_verb(decision.decision)}</span>
                  <.local_time
                    id={"decision-when-#{decision.id}"}
                    value={decision.decided_at}
                    mode={:forensic}
                    class="text-xs tabular-nums text-zinc-400"
                  />
                </li>
              </ul>
            </section>
          </div>

          <%!-- Right: the decision panel, only while the request is genuinely live
             (sticky on desktop so it stays in reach past a long args/reason). A
             decided or lapsed request has no rail — its outcome leads the page in
             the verdict callout above, so the column goes full-width. --%>
          <aside :if={verdict == :pending} class="xl:sticky xl:top-6 xl:self-start">
            <.decision_panel
              can_decide?={Approvals.subject_can_decide_approval?(@current_subject)}
              decision_reason={@decision_reason}
              grant_duration={@grant_duration}
              grant_scope={@grant_scope}
              grant_max_uses={@grant_max_uses}
              grant_duration_options={@grant_duration_options}
              runner_state={@runner_connection}
              execution_request?={@execution_request?}
              self_blocked?={@self_blocked?}
              already_decided?={@already_decided?}
              approved_count={@approved_count}
              min_approvals={@request.min_approvals}
              expires_at={@request.expires_at}
              request_id={@request.id}
              current_account={@current_account}
            />
          </aside>
        </div>
      </div>
    </.dashboard_shell>
    """
  end

  attr :can_decide?, :boolean, required: true
  # The operator's in-progress decision input, tracked server-side so a
  # re-render restores it rather than clearing it.
  attr :decision_reason, :string, default: ""
  attr :grant_scope, :string, default: "exact_args"
  attr :grant_max_uses, :string, default: ""
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
  attr :execution_request?, :boolean, default: false
  # Server-computed UI gates. self_blocked? hides Approve when this user is the
  # requester and self-approval is forbidden; already_decided? hides both forms
  # once they've voted. The CONTEXT re-checks both (IL-15) — these are cosmetic.
  attr :self_blocked?, :boolean, default: false
  attr :already_decided?, :boolean, default: false
  attr :approved_count, :integer, default: 0
  attr :min_approvals, :integer, default: 1
  attr :expires_at, :any, default: nil
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
        <span data-countdown-text>{countdown_fallback(@expires_at)}</span>
      </div>

      <p :if={@min_approvals > 1} class="text-xs leading-relaxed text-zinc-400">
        This {target_noun(@execution_request?)} needs
        <strong class="text-zinc-100">{@min_approvals} distinct approvals</strong>
        — {@approved_count} so far.
      </p>

      <.event_block
        :if={not @execution_request? and @runner_state == :offline}
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
          <%!-- Approve form. Hidden when this user is the requester and the
               policy forbids self-approval — the context refuses it anyway
               (IL-15), this just removes the dead button. They can still Deny
               their own request. --%>
          <p :if={@self_blocked?} class="mt-4 text-xs leading-relaxed text-zinc-400">
            You can't approve your own request — a different operator must approve it.
          </p>
          <p class="mt-4 text-xs leading-relaxed text-zinc-400">
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
              aria-label="Decision note"
              placeholder="Note — logged with your decision (optional)"
              class="min-h-0 resize-none"
            />

            <%!-- Standing grants disabled (account cap 0) → the reuse menu
                 would be a dead one-option select; a quiet line says why the
                 affordance is gone. --%>
            <p
              :if={
                not @execution_request? and not @self_blocked? and
                  length(@grant_duration_options) <= 1
              }
              class="text-[11px] leading-relaxed text-zinc-400"
            >
              Standing grants are disabled for this account — every approval is single-use.
            </p>
            <.disclosure :if={
              not @execution_request? and not @self_blocked? and
                length(@grant_duration_options) > 1
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
                    >
                    approvals page
                  </.link>.
                  </p>
                </div>
              </div>
            </.disclosure>

            <%!-- Approve stays gated for the self-blocked requester; deny is
                 always available (denying your own request is fine). --%>
            <.button
              :if={not @self_blocked?}
              name="decision"
              value="approve"
              class="w-full"
              icon="hero-check"
              phx-disable-with="Approving…"
            >
              {if(@execution_request?, do: "Approve runbook", else: "Approve and send")}
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

  defp decision_intro(true, _self_blocked?, _options) do
    "Approve once to release every action shown here. This execution will not ask for another " <>
      "approval. If policy changes to deny the work, runner access is removed, or a trusted " <>
      "pack is no longer available before dispatch, Emisar stops the execution."
  end

  defp decision_intro(false, self_blocked?, options) do
    "Approve runs this action once#{reuse_clause(self_blocked?, options)} decision is logged."
  end

  # The middle clause of the decide-form lead line. The reuse-window offer
  # appears only when the standing-grant menu itself does — the account allows a
  # duration past "once" (`grant_duration_options` has more than one entry) and
  # the operator isn't self-blocked — so the copy never names an affordance the
  # form doesn't show.
  defp reuse_clause(false, [_, _ | _]) do
    " — or pick a reuse window to issue a standing grant. Either"
  end

  defp reuse_clause(_self_blocked?, _options), do: ". Your"

  # The overall verdict the page leads with. A still-pending request that has
  # lapsed past its expiry reads as :expired — the sweeper just hasn't
  # auto-denied it yet, so a live Approve would fail and the outcome is settled.
  defp verdict_status(%{status: :pending} = request) do
    if request_expired?(request), do: :expired, else: :pending
  end

  defp verdict_status(%{status: status}), do: status

  # Verdict presentation, keyed on the normalized status (never :pending — the
  # callout only renders once verdict_status != :pending).
  defp verdict_tone(:approved), do: :brand
  defp verdict_tone(:denied), do: :rose
  defp verdict_tone(:expired), do: :rose
  defp verdict_tone(:cancelled), do: :neutral

  defp verdict_title(:approved), do: "Approved"
  defp verdict_title(:denied), do: "Denied"
  defp verdict_title(:expired), do: "Expired — auto-denied"
  defp verdict_title(:cancelled), do: "Cancelled"

  defp verdict_icon(:approved), do: "hero-check-circle"
  defp verdict_icon(:denied), do: "hero-x-circle"
  defp verdict_icon(:expired), do: "hero-clock"
  defp verdict_icon(:cancelled), do: "hero-no-symbol"

  # Decision-list rendering helpers (the enum loads as an atom).
  defp decision_icon(:approve), do: "hero-check-circle"
  defp decision_icon(:deny), do: "hero-x-circle"

  defp decision_icon_class(:approve), do: "text-brand-400"
  defp decision_icon_class(:deny), do: "text-rose-400"

  defp decision_verb(:approve), do: "approved"
  defp decision_verb(:deny), do: "denied"
end
