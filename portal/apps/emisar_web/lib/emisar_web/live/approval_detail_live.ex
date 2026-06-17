defmodule EmisarWeb.ApprovalDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Approvals, Catalog, Runners, Runs, Users}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id
    subject = socket.assigns.current_subject

    case Approvals.fetch_approval_request_by_id(id, subject) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Approval not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/approvals")}

      {:ok, request} ->
        if connected?(socket) do
          Approvals.subscribe_account_approvals(account_id)
          Runners.subscribe_connections(account_id)
        end

        run =
          case Runs.fetch_run_by_id(request.run_id, socket.assigns.current_subject,
                 preload: [:runner]
               ) do
            {:ok, r} -> r
            {:error, _} -> nil
          end

        title = "Approval · " <> ((run && run.action_id) || String.slice(request.id, 0, 8))

        # Display-only label lookups (requester / decider emails) — defer
        # behind connected?/1 so they don't run on the dead render; they
        # fall back to a placeholder until the socket connects.
        requested_by = if connected?(socket), do: lookup_user(request.requested_by_id), else: nil
        decided_by = if connected?(socket), do: lookup_user(request.decided_by_id), else: nil

        # Risk is the approver's headline signal but isn't on the request — look
        # it up from the catalog (display-only, connected pass; nil if the action
        # is no longer advertised).
        action_risk =
          if connected?(socket),
            do: action_risk_for(request.context, socket.assigns.current_subject)

        {:ok,
         socket
         |> assign(:page_title, title)
         |> assign(:request, request)
         |> assign(:run, run)
         |> assign(:action_risk, action_risk)
         |> assign(:runner_connection, runner_connection(run))
         |> assign(:requested_by, requested_by)
         |> assign(:decided_by, decided_by)
         |> assign(:decision_reason, "")
         |> assign_decisions(request)
         # Tracks the duration the operator picked in the grant-reuse
         # disclosure. "once" (the default) means "no grant" — in that
         # mode the Match / Limit-to fields are irrelevant and hidden.
         |> assign(:grant_duration, "once")}
    end
  end

  # Loads the recorded votes + the distinct-approve tally and derives the two
  # server-side flags the decision panel reads — whether THIS user already
  # decided, and whether self-approval is forbidden for them. The context still
  # re-checks both on the decision event (IL-15); these only drive the UI.
  # Deferred behind connected?/1 (like the requester/decider/risk lookups) so the
  # dead render does no DB work — the connected pass and the {:approval_updated, …}
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

  defp action_risk_for(%{"action_id" => action_id, "runner_id" => runner_id}, subject)
       when is_binary(action_id) and is_binary(runner_id) do
    case Catalog.fetch_action_by_id(action_id, runner_id, subject) do
      {:ok, action} -> action.risk
      {:error, _} -> nil
    end
  end

  defp action_risk_for(_context, _subject), do: nil

  def handle_info({:approval_updated, %{id: id} = updated}, socket)
      when id == socket.assigns.request.id do
    {:noreply,
     socket
     |> assign(:request, updated)
     |> assign(:decided_by, lookup_user(updated.decided_by_id))
     |> assign_decisions(updated)}
  end

  # A runner connected/disconnected in the account — refresh the target
  # runner's online dot so the operator knows whether approving executes
  # now or queues.
  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :runner_connection, runner_connection(socket.assigns.run))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("grant_form_changed", params, socket) do
    {:noreply, assign(socket, :grant_duration, params["duration"] || "once")}
  end

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
            decision_failed(socket, reason)
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
            decision_failed(socket, reason)
        end
      end
    )
  end

  # A self-approval refusal isn't a stale-state race — leave the panel as-is
  # (don't re-fetch), just flash the cause.
  defp decision_failed(socket, :self_approval_forbidden) do
    {:noreply, put_flash(socket, :error, "You can't approve your own request.")}
  end

  # An approve/deny that didn't take: the request expired or was decided
  # between render and this click (the live `:approval_updated` broadcast can
  # race a fast click). Re-fetch so the panel flips to decision-history, then
  # flash the real cause instead of leaving the form interactive.
  defp decision_failed(socket, reason) do
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

  defp grant_flash(window, scope, max_uses),
    do:
      "Approved. Standing grant active for #{window} (#{scope_label(scope)}#{uses_suffix(max_uses)})."

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

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:approvals}
      width={:detail}
    >
      <:title>
        <.detail_header back="Approvals" navigate={~p"/app/#{@current_account}/approvals"}>
          Approval · <span class="font-mono text-base">{@request.context["action_id"] || "—"}</span>
        </.detail_header>
      </:title>
      <:actions>
        <%!-- The decision trail for this request (requested / approved / denied /
             expired), beyond the votes shown below. Subject-scoped by the audit
             page, so the link only pre-filters. --%>
        <.link
          navigate={
            ~p"/app/#{@current_account}/audit?#{[subject_kind: "approval_request", subject_id: @request.id]}"
          }
          class="text-xs font-medium text-indigo-400 hover:text-indigo-300"
        >
          View activity →
        </.link>
      </:actions>
      <%!-- Meta strip: at-a-glance facts. Status leads — same pattern
           as RunDetail / RunnerDetail — then action, runner,
           requester, when. --%>
      <.meta_strip cols={5}>
        <.meta_field label="Status">
          <.status_badge status={@request.status} />
        </.meta_field>
        <.meta_field label="Action">
          <span class="inline-flex min-w-0 items-center gap-2">
            <span class="truncate font-mono text-zinc-200">
              {@request.context["action_id"] || "—"}
            </span>
            <.risk_pill :if={@action_risk} risk={@action_risk} class="flex-none" />
          </span>
        </.meta_field>
        <.meta_field label="Runner">
          <%= if @run && @run.runner do %>
            <span class="inline-flex min-w-0 items-center gap-1.5">
              <span
                class={[
                  "h-1.5 w-1.5 flex-none rounded-full",
                  if(@runner_connection == :online, do: "bg-emerald-400", else: "bg-zinc-600")
                ]}
                title={if(@runner_connection == :online, do: "Online", else: "Offline")}
              />
              <.link
                navigate={~p"/app/#{@current_account}/runners/#{@run.runner.id}"}
                class="truncate text-zinc-200 hover:text-indigo-300"
              >
                {@run.runner.name}
              </.link>
            </span>
          <% else %>
            <span class="truncate font-mono text-xs text-zinc-400">
              {truncated_runner_id(@request.context["runner_id"])}
            </span>
          <% end %>
        </.meta_field>
        <.meta_field label="Requested by">
          <span class="truncate text-zinc-200">
            {user_label(@requested_by, @request.requested_by_id)}
          </span>
        </.meta_field>
        <.meta_field label="When">
          <.local_time value={@request.requested_at} class="text-zinc-200" />
        </.meta_field>
        <%!-- Only surface the tally for a multi-approver gate; a 1-of-1
             request reads no differently than the single-approver flow. --%>
        <.meta_field :if={@request.min_approvals > 1} label="Approvals">
          <span class="text-zinc-200">{@approved_count} of {@request.min_approvals}</span>
        </.meta_field>
        <%!-- Only while held: a pending request auto-cancels at expiry, so the
             approver sees how long they have; a decided one's expiry is moot. --%>
        <.meta_field :if={@request.status == :pending} label="Expires">
          <.approval_expiry expires_at={@request.expires_at} />
        </.meta_field>
      </.meta_strip>

      <div class="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <%!-- Left: context — reason, policy, args, link to run --%>
        <div class="space-y-4">
          <.card :if={@request.reason && @request.reason != ""} padding="p-4">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
              Operator's reason
            </h3>
            <p class="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-zinc-200">
              {@request.reason}
            </p>
          </.card>

          <.notice
            :if={@run && @run.policy_reason}
            variant={:warning}
            icon="hero-shield-exclamation"
            title="Why approval is required"
          >
            <p class="leading-relaxed">{@run.policy_reason}</p>
            <div :if={@run.matched_rules && @run.matched_rules != []} class="mt-2 text-xs opacity-80">
              Matched rules: <span class="font-mono">{Enum.join(@run.matched_rules, ", ")}</span>
            </div>
          </.notice>

          <.card :if={@run && @run.args && @run.args != %{}} class="overflow-hidden" padding="">
            <header class="flex items-center justify-between border-b border-zinc-900 px-4 py-2">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                Arguments
              </h3>
              <span :if={@request.context["args_sha256"]} class="font-mono text-[11px] text-zinc-500">
                sha256:{String.slice(@request.context["args_sha256"], 0, 16)}…
              </span>
            </header>
            <pre class="max-h-64 overflow-auto bg-black/40 p-4 font-mono text-xs text-zinc-300">{format_json(@run.args)}</pre>
          </.card>

          <%!-- Who has voted so far — surfaced for any multi-approver gate so
               an approver sees who's already signed off (and that a deny
               finalized). A single-approver request shows it only once decided
               (the decision-history panel covers the lone vote). --%>
          <.card
            :if={@decisions != [] and @request.min_approvals > 1}
            class="overflow-hidden"
            padding=""
          >
            <header class="flex items-center justify-between border-b border-zinc-900 px-4 py-2">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                Decisions
              </h3>
              <span class="text-[11px] text-zinc-500">
                {@approved_count} of {@request.min_approvals} approvals
              </span>
            </header>
            <ul class="divide-y divide-zinc-900">
              <li :for={decision <- @decisions} class="flex items-center gap-3 px-4 py-2 text-sm">
                <.icon
                  name={decision_icon(decision.decision)}
                  class={"h-4 w-4 flex-none " <> decision_icon_class(decision.decision)}
                />
                <span class="min-w-0 flex-1 truncate text-zinc-200">
                  {user_label(decision.decider, decision.decider_id)}
                </span>
                <span class="text-xs text-zinc-500">{decision_verb(decision.decision)}</span>
                <.local_time value={decision.decided_at} class="text-xs text-zinc-500" />
              </li>
            </ul>
          </.card>

          <div :if={@run}>
            <.link
              navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
              class="inline-flex items-center gap-1 text-sm text-indigo-400 hover:text-indigo-300"
            >
              View run details <.icon name="hero-arrow-right" class="h-3.5 w-3.5" />
            </.link>
          </div>
        </div>

        <%!-- Right: decision panel — sticky on desktop so it stays in
             reach when scanning a long args/reason. --%>
        <aside class="lg:sticky lg:top-6 lg:self-start">
          <%= if @request.status == :pending do %>
            <.decision_panel
              can_decide?={Approvals.subject_can_decide_approval?(@current_subject)}
              grant_duration={@grant_duration}
              runner_state={@runner_connection}
              self_blocked?={@self_blocked?}
              already_decided?={@already_decided?}
              approved_count={@approved_count}
              min_approvals={@request.min_approvals}
              current_account={@current_account}
            />
          <% else %>
            <.panel title="Decision history">
              <dl class="space-y-2 text-sm">
                <.kv label="Status"><.status_badge status={@request.status} /></.kv>
                <.kv label="Decided"><.local_time value={@request.decided_at} /></.kv>
                <.kv label="By">{user_label(@decided_by, @request.decided_by_id)}</.kv>
                <.kv :if={@request.decision_reason && @request.decision_reason != ""} label="Reason">
                  <span class="text-xs text-zinc-300">{@request.decision_reason}</span>
                </.kv>
              </dl>
            </.panel>
          <% end %>
        </aside>
      </div>
    </.dashboard_shell>
    """
  end

  attr :can_decide?, :boolean, required: true
  # Drives the reuse-window UI: the Match / Limit-to fields only show
  # once a real grant is being minted (duration != "once"). Defaulted so
  # a caller that forgets to thread it through can't crash the panel.
  attr :grant_duration, :string, default: "once"
  # Connection state of the target runner (:online | :offline | :unknown)
  # so the operator knows whether an approval will actually dispatch.
  attr :runner_state, :atom, default: :unknown
  # Server-computed UI gates. self_blocked? hides Approve when this user is the
  # requester and self-approval is forbidden; already_decided? hides both forms
  # once they've voted. The CONTEXT re-checks both (IL-15) — these are cosmetic.
  attr :self_blocked?, :boolean, default: false
  attr :already_decided?, :boolean, default: false
  attr :approved_count, :integer, default: 0
  attr :min_approvals, :integer, default: 1
  attr :current_account, :map, required: true

  defp decision_panel(assigns) do
    ~H"""
    <.panel title="Decide">
      <:subtitle>Logged to the audit trail.</:subtitle>

      <p
        :if={@min_approvals > 1}
        class="rounded-lg border border-zinc-800 bg-zinc-900/50 px-3 py-2 text-xs text-zinc-300"
      >
        This action needs <strong class="text-zinc-100">{@min_approvals} distinct approvals</strong>
        — {@approved_count} so far.
      </p>

      <div
        :if={@runner_state == :offline}
        class="flex items-start gap-2 rounded-lg border border-amber-500/30 bg-amber-500/[0.06] p-3 text-xs text-amber-200"
      >
        <.icon name="hero-signal-slash" class="mt-0.5 h-4 w-4 flex-none text-amber-300" />
        <span>
          This runner is offline. You can still approve — the action queues and runs once the
          runner reconnects, or expires if it doesn't.
        </span>
      </div>

      <%= cond do %>
        <% not @can_decide? -> %>
          <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
            Viewers can't decide approvals.
          </p>
        <% @already_decided? -> %>
          <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
            You've already recorded your decision on this request. Waiting on the remaining approvers.
          </p>
        <% true -> %>
          <%!-- Approve form. Hidden when this user is the requester and the
               policy forbids self-approval — the context refuses it anyway
               (IL-15), this just removes the dead button. They can still Deny
               their own request. --%>
          <div
            :if={@self_blocked?}
            class="mt-4 flex items-start gap-2 rounded-lg border border-zinc-800 bg-zinc-900/50 p-3 text-xs text-zinc-300"
          >
            <.icon name="hero-information-circle" class="mt-0.5 h-4 w-4 flex-none text-zinc-400" />
            <span>You can't approve your own request — a different operator must approve it.</span>
          </div>
          <%!-- Approve form. Default state = one-shot ("just this
               call") which doesn't create a grant. Reuse-window UI
               is collapsed behind a checkbox so the common path
               is one click of the green button. --%>
          <form
            :if={not @self_blocked?}
            phx-submit="approve"
            phx-change="grant_form_changed"
            class="mt-4 space-y-4"
          >
            <%!-- Bare name (uncontrolled): the LV doesn't track this note, the
                 approve handler reads whatever's posted. `aria-label` names it
                 for AT (the placeholder is not an accessible name); `min-h-0`
                 undoes the component's default min-height for a compact 2-row box. --%>
            <.input
              type="textarea"
              name="reason"
              value={nil}
              rows="2"
              aria-label="Approval note"
              placeholder="Note (optional)"
              class="min-h-0 resize-none"
            />

            <details class="group rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
              <summary class="flex cursor-pointer items-center justify-between text-xs text-zinc-300 hover:text-zinc-100">
                <span class="flex items-center gap-2">
                  <.icon name="hero-clock" class="h-3.5 w-3.5 text-zinc-400" />
                  Allow the LLM to reuse this approval
                </span>
                <.icon
                  name="hero-chevron-down"
                  class="h-4 w-4 text-zinc-500 transition group-open:rotate-180"
                />
              </summary>
              <div class="mt-3 space-y-3">
                <div>
                  <.input
                    name="duration"
                    type="select"
                    label="For"
                    label_variant={:eyebrow}
                    value={@grant_duration}
                    options={[
                      {"Just this call (no grant)", "once"},
                      {"Next 1 hour", "one_hour"},
                      {"Next 24 hours", "one_day"},
                      {"Next 30 days", "thirty_days"},
                      {"Next 90 days", "ninety_days"}
                    ]}
                  />
                </div>
                <%!-- Match / Limit-to only matter when an actual grant is
                   being minted. With duration="once" no grant is created,
                   so showing these fields was asking the operator to
                   configure parameters that get discarded. The form's
                   phx-change handler tracks duration → re-renders this
                   block. --%>
                <div :if={@grant_duration != "once"}>
                  <%!-- Not value-bound: the LV doesn't track scope, so it
                       defaults to "Same arguments only" each render — the
                       parse on approve reads whatever's posted. --%>
                  <.input
                    name="scope"
                    type="select"
                    label="Match"
                    label_variant={:eyebrow}
                    value={nil}
                    options={[
                      {"Same arguments only", "exact_args"},
                      {"Any arguments for this action", "any_args"}
                    ]}
                  />
                </div>
                <div :if={@grant_duration != "once"}>
                  <%!-- Explicit `id` so the eyebrow label's `for` associates;
                       bare name (uncontrolled), the approve handler reads the
                       posted value. --%>
                  <.input
                    type="number"
                    id="grant_max_uses"
                    name="max_uses"
                    value={nil}
                    label="Limit to (optional)"
                    label_variant={:eyebrow}
                    min="1"
                    placeholder="unlimited"
                  />
                  <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
                    Cap how many times this grant can be used within the window. Leave blank for unlimited.
                    Grants are reviewable + revocable on the <.link
                      navigate={~p"/app/#{@current_account}/approvals"}
                      class="text-indigo-400 hover:text-indigo-300"
                    >
                    approvals page
                  </.link>.
                  </p>
                </div>
              </div>
            </details>

            <.button
              variant="success"
              class="w-full"
              icon="hero-check"
              phx-disable-with="Approving…"
            >
              Approve and send
            </.button>
          </form>

          <%!-- Deny carries its own reason — the higher-stakes decision was
               the one with nowhere to record *why*, leaving a blank reason in
               the decision history. The handler already accepts it. --%>
          <form phx-submit="deny" class="mt-3 space-y-3">
            <%!-- `tone="danger"` tints the focus ring rose — this is the
                 destructive decision. `aria-label` names it for AT. --%>
            <.input
              type="textarea"
              name="reason"
              value={nil}
              tone="danger"
              rows="2"
              aria-label="Reason for denial"
              placeholder="Why are you denying this? (optional, logged in the decision history)"
              class="min-h-0 resize-none"
            />
            <.button variant="danger" class="w-full" icon="hero-x-mark" phx-disable-with="Denying…">
              Deny
            </.button>
          </form>
      <% end %>
    </.panel>
    """
  end

  # Decision-list rendering helpers (the enum loads as an atom).
  defp decision_icon(:approve), do: "hero-check-circle"
  defp decision_icon(:deny), do: "hero-x-circle"

  defp decision_icon_class(:approve), do: "text-emerald-400"
  defp decision_icon_class(:deny), do: "text-rose-400"

  defp decision_verb(:approve), do: "approved"
  defp decision_verb(:deny), do: "denied"
end
