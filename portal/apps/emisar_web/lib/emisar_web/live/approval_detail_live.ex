defmodule EmisarWeb.ApprovalDetailLive do
  use EmisarWeb, :live_view
  alias Emisar.{Approvals, Catalog, Runners, Runs, Users}
  alias EmisarWeb.{CommandPreview, PacksRegistry, Permissions}

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

        # Risk + the plain-English "what this does" are the approver's headline
        # signals but aren't on the request — look the action up from the catalog
        # (display-only, connected pass; nil if it's no longer advertised).
        action =
          if connected?(socket),
            do: fetch_action_for(request.context, socket.assigns.current_subject)

        {:ok,
         socket
         |> assign(:page_title, title)
         |> assign(:request, request)
         |> assign(:run, run)
         |> assign(:action_risk, action && action.risk)
         |> assign(:action_description, action && action.description)
         # The exact command the runner will execute, arguments resolved into
         # the action's template — shown only when our compiled pack is provably
         # the runner's (its pinned hash, or advertised version when unpinned).
         |> assign(:executed_command, build_command_preview(action, run))
         |> assign(:runner_connection, runner_connection(run))
         |> assign(:requested_by, requested_by)
         |> assign(:decided_by, decided_by)
         |> assign(:decision_reason, "")
         |> assign_decisions(request)
         # Tracks the duration the operator picked in the grant-reuse
         # disclosure. "once" (the default) means "no grant" — in that
         # mode the Match / Limit-to fields are irrelevant and hidden.
         |> assign(:grant_duration, "once")
         # Only offer durations the account's lifetime cap allows, so an
         # approver can't pick one the server would reject (the cap is account
         # config, fixed for this session — compute it once at mount).
         |> assign(:grant_duration_options, grant_duration_options(account_id))}
    end
  end

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
         {:ok, line} <- CommandPreview.render(command, run.args, specs) do
      line
    else
      _ -> nil
    end
  end

  defp build_command_preview(_action, _run), do: nil

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

  # The live countdown reached zero client-side. Re-fetch so the terminal "Expired"
  # panel replaces the Approve form right away instead of waiting for the Oban
  # sweeper's broadcast. Server-authoritative: the re-fetch + render-time
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

  defp decision_error_message(reason) when reason in [:run_cancelled, :run_not_pending_approval],
    do: "The run was cancelled before approval, so there's nothing left to approve."

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

  # How the held run was dispatched. `:operator` (a human from the console)
  # carries no tag — the requester name says it. The rest qualify "who asked":
  # `:mcp` is the one that matters, an autonomous LLM agent reaching the gate.
  defp dispatch_source_label(:mcp), do: "LLM agent"
  defp dispatch_source_label(:runbook), do: "Runbook"
  defp dispatch_source_label(:scheduled), do: "Scheduled"
  defp dispatch_source_label(_), do: nil

  defp dispatch_source_icon(:mcp), do: "hero-bolt"
  defp dispatch_source_icon(:runbook), do: "hero-book-open"
  defp dispatch_source_icon(:scheduled), do: "hero-clock"
  defp dispatch_source_icon(_), do: "hero-cpu-chip"

  defp dispatch_source_title(:mcp), do: "Dispatched by an LLM agent over the MCP API"
  defp dispatch_source_title(:runbook), do: "Dispatched as a step in a runbook run"
  defp dispatch_source_title(:scheduled), do: "Dispatched by a schedule"
  defp dispatch_source_title(_), do: nil

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
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:approvals}
      width={:detail}
    >
      <:title>
        <%!-- No "Approval ·" prefix — the breadcrumb already says where you are;
             the action id IS the entity. --%>
        <.detail_header
          back="Approvals"
          navigate={~p"/app/#{@current_account}/approvals"}
          title={@request.context["action_id"] || "—"}
          mono
        />
      </:title>
      <:actions>
        <%!-- The decision trail for this request (requested / approved / denied /
             expired), beyond the votes shown below. Subject-scoped by the audit
             page, so the link only pre-filters. --%>
        <.link
          navigate={
            ~p"/app/#{@current_account}/audit?#{[subject_kind: "approval_request", subject_id: @request.id]}"
          }
          class="group inline-flex items-center gap-1 text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View activity <.cta_arrow class="h-3 w-3" />
        </.link>
      </:actions>
      <%!-- Meta strip: at-a-glance facts. Status leads — same pattern
           as RunDetail / RunnerDetail — then action, runner,
           requester, when. --%>
      <.meta_strip cols={5}>
        <.meta_field label="Status">
          <.status_badge status={@request.status} />
        </.meta_field>
        <%!-- Never clip the action on the decision screen — an approver must read
             the full action id before deciding. `wrap` gives it the full row on
             mobile and wraps rather than truncating; the risk pill flows after. --%>
        <.meta_field label="Action" wrap>
          <span class="inline-flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class="font-mono text-zinc-200">{@request.context["action_id"] || "—"}</span>
            <.risk_pill :if={@action_risk} risk={@action_risk} />
          </span>
        </.meta_field>
        <.meta_field label="Runner">
          <%= if @run && @run.runner do %>
            <span class="inline-flex min-w-0 items-center gap-1.5">
              <.status_dot
                tone={if(@runner_connection == :online, do: :brand, else: :neutral)}
                title={if(@runner_connection == :online, do: "Online", else: "Offline")}
              />
              <.link
                navigate={~p"/app/#{@current_account}/runners/#{@run.runner.id}"}
                class="truncate text-zinc-200 hover:text-brand-300"
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
        <%!-- Who (the accountable human) AND what asked: a request from an
             autonomous LLM agent (MCP) is the reason the gate exists and
             warrants more scrutiny than an operator's own dispatch. --%>
        <.meta_field label="Requested by">
          <span class="inline-flex min-w-0 items-center gap-1.5">
            <span class="truncate text-zinc-200">
              {user_label(@requested_by, @request.requested_by_id)}
            </span>
            <.chip
              :if={@run && @run.source != :operator}
              icon={dispatch_source_icon(@run.source)}
              title={dispatch_source_title(@run.source)}
              class="flex-none"
            >
              {dispatch_source_label(@run.source)}
            </.chip>
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
        <%!-- Expiry isn't a meta field: for a held request the live countdown owns
             it in the decide panel (more prominent + ticking); a decided request's
             expiry is moot. --%>
      </.meta_strip>

      <% verdict = verdict_status(@request) %>

      <%!-- Lead with the verdict. A decided request buried its outcome in a
           right-rail panel below the fold on mobile; now the outcome — colored
           to the decision, with decider + time + note — is the first thing under
           the meta strip. Rendered for every non-pending state (a lapsed-but-not-
           yet-swept request reads as expired). --%>
      <.callout
        :if={verdict != :pending}
        tone={verdict_tone(verdict)}
        icon={verdict_icon(verdict)}
        title={verdict_title(verdict)}
        class="mt-4"
      >
        <%= case verdict do %>
          <% :expired -> %>
            <p class="leading-relaxed">
              This request expired before anyone decided, so it was auto-denied — the action will
              not run. The requester can re-issue it if it's still needed.
            </p>
          <% :cancelled -> %>
            <p class="leading-relaxed">
              This request was withdrawn before a decision, so the action did not run.
            </p>
          <% _ -> %>
            <p :if={@request.decided_at} class="leading-relaxed">
              by {user_label(@decided_by, @request.decided_by_id)} ·
              <.local_time value={@request.decided_at} mode={:forensic} class="tabular-nums" />
            </p>
            <p
              :if={@request.decision_reason && @request.decision_reason != ""}
              class="mt-1.5 text-sm leading-relaxed opacity-90"
            >
              “{@request.decision_reason}”
            </p>
        <% end %>
      </.callout>

      <div class={[
        "mt-6 grid grid-cols-1 gap-6",
        verdict == :pending && "lg:grid-cols-[1fr_320px]"
      ]}>
        <%!-- Left: the decision record — the artifact (what will run), the raw
             args one click away, ONE why-cluster, then the vote trail. --%>
        <div class="space-y-4">
          <%!-- THE ARTIFACT — the single most decision-relevant fact on the page,
               one altitude above every supporting panel (surface step + white
               ring, not another identical hairline box): the plain-English effect
               from the pack manifest as its caption, then the exact command the
               runner will execute — the run's arguments resolved into the
               action's template. The command shows only when our compiled pack is
               provably the runner's (pinned hash, or advertised version);
               otherwise the raw arguments ARE the artifact and render in its
               place. Sensitive args are masked. --%>
          <section
            :if={@executed_command || @action_description || (@run && @run.args != %{})}
            class="overflow-hidden rounded-xl bg-zinc-900/[0.85] shadow-[inset_0_1px_0_0_rgba(255,255,255,0.08)] ring-1 ring-white/[0.12]"
          >
            <header class="flex items-center justify-between gap-3 border-b border-white/5 px-5 py-3">
              <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
                {if @executed_command, do: "Command", else: "Arguments"}
              </h2>
              <span class="text-xs text-zinc-500">
                {if @executed_command,
                  do: "what the runner will execute",
                  else: "what the runner will receive"}
              </span>
            </header>
            <%!-- Caption one step of gray BELOW the command — the brightest thing
                 in the artifact must be the thing the runner will execute. --%>
            <p
              :if={@action_description}
              class="border-b border-white/5 px-5 py-3 text-sm leading-relaxed text-zinc-400"
            >
              {@action_description}
            </p>
            <pre
              :if={@executed_command}
              class="overflow-x-auto bg-black/50 px-5 py-4 font-mono text-sm leading-relaxed text-zinc-50 [font-variant-ligatures:none]"
            ><span class="select-none text-zinc-600">$ </span>{@executed_command}</pre>
            <pre
              :if={is_nil(@executed_command) && @run && @run.args != %{}}
              class="max-h-64 overflow-auto bg-black/50 px-5 py-4 font-mono text-xs leading-relaxed text-zinc-300"
            >{format_json(@run.args)}</pre>
          </section>

          <%!-- The raw args stay one click away once the command carries the
               detail — redundant with the resolved template, but the approver
               verifying the exact payload (against its logged sha) needs them. --%>
          <.disclosure
            :if={@executed_command && @run && @run.args != %{}}
            id={"approval-args-#{@request.id}"}
          >
            <:summary>
              Raw arguments
              <span :if={@request.context["args_sha256"]} class="ml-1 font-mono text-zinc-500">
                sha256:{String.slice(@request.context["args_sha256"], 0, 16)}…
              </span>
            </:summary>
            <pre class="max-h-64 overflow-auto rounded-b-lg bg-black/40 px-4 py-3 font-mono text-xs leading-relaxed text-zinc-300">{format_json(@run.args)}</pre>
          </.disclosure>

          <%!-- ONE why-cluster: who asked for it and what gated it, together —
               not a Reason card and a policy callout competing at equal weight.
               The policy key wears amber only while the decision is live; once
               decided the same fact is history and goes quiet. --%>
          <.panel
            :if={(@request.reason && @request.reason != "") || (@run && @run.policy_reason)}
            title="Why"
            padding="p-5"
          >
            <dl class="space-y-4">
              <div :if={@request.reason && @request.reason != ""}>
                <dt class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                  Requester
                </dt>
                <dd class="mt-1 text-sm leading-relaxed text-zinc-200">“{@request.reason}”</dd>
              </div>
              <div :if={@run && @run.policy_reason}>
                <dt class={[
                  "flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider",
                  if(verdict == :pending, do: "text-amber-300", else: "text-zinc-500")
                ]}>
                  <.icon name="hero-shield-exclamation" class="h-3.5 w-3.5" /> Policy
                </dt>
                <dd class="mt-1 text-sm leading-relaxed text-zinc-200">{@run.policy_reason}</dd>
                <dd
                  :if={@run.matched_rules && @run.matched_rules != []}
                  class="mt-1.5 text-xs text-zinc-500"
                >
                  Matched rules: <span class="font-mono">{Enum.join(@run.matched_rules, ", ")}</span>
                </dd>
              </div>
            </dl>
          </.panel>

          <%!-- Who has voted so far — surfaced for any multi-approver gate so
               an approver sees who's already signed off (and that a deny
               finalized). A single-approver request shows it only once decided
               (the decision-history panel covers the lone vote). --%>
          <.panel
            :if={@decisions != [] and @request.min_approvals > 1}
            variant={:split}
            title="Decisions"
          >
            <:annotation>{@approved_count} of {@request.min_approvals} approvals</:annotation>
            <ul class="divide-y divide-zinc-800/70">
              <li :for={decision <- @decisions} class="flex items-center gap-3 px-4 py-2 text-sm">
                <.icon
                  name={decision_icon(decision.decision)}
                  class={"h-4 w-4 flex-none " <> decision_icon_class(decision.decision)}
                />
                <span class="min-w-0 flex-1 truncate text-zinc-200">
                  {user_label(decision.decider, decision.decider_id)}
                </span>
                <span class="text-xs text-zinc-500">{decision_verb(decision.decision)}</span>
                <.local_time
                  value={decision.decided_at}
                  mode={:forensic}
                  class="text-xs tabular-nums text-zinc-500"
                />
              </li>
            </ul>
          </.panel>

          <div :if={@run}>
            <.link
              navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
              class="group inline-flex items-center gap-1 text-sm text-brand-400 hover:text-brand-300"
            >
              View run details <.cta_arrow />
            </.link>
          </div>
        </div>

        <%!-- Right: the decision panel, only while the request is genuinely live
             (sticky on desktop so it stays in reach past a long args/reason). A
             decided or lapsed request has no rail — its outcome leads the page in
             the verdict callout above, so the column goes full-width. --%>
        <aside :if={verdict == :pending} class="lg:sticky lg:top-6 lg:self-start">
          <.decision_panel
            can_decide?={Approvals.subject_can_decide_approval?(@current_subject)}
            grant_duration={@grant_duration}
            grant_duration_options={@grant_duration_options}
            runner_state={@runner_connection}
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
    </.dashboard_shell>
    """
  end

  attr :can_decide?, :boolean, required: true
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
    <.panel title="Decide">
      <:subtitle>Logged to the audit trail.</:subtitle>

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

      <p
        :if={@min_approvals > 1}
        class="rounded-lg bg-black/30 px-3 py-2 text-xs text-zinc-300 ring-1 ring-white/[0.08]"
      >
        This action needs <strong class="text-zinc-100">{@min_approvals} distinct approvals</strong>
        — {@approved_count} so far.
      </p>

      <.offline_notice :if={@runner_state == :offline} severity={:info} title="Runner offline">
        You can still approve — the action queues and runs once the runner reconnects, or
        expires if it doesn't.
      </.offline_notice>

      <%= cond do %>
        <% not @can_decide? -> %>
          <p class="mt-4 rounded-lg bg-black/30 p-4 text-xs text-zinc-400 ring-1 ring-white/[0.08]">
            Viewers can't decide approvals.
          </p>
        <% @already_decided? -> %>
          <p class="mt-4 rounded-lg bg-black/30 p-4 text-xs text-zinc-400 ring-1 ring-white/[0.08]">
            You've already recorded your decision on this request. Waiting on the remaining approvers.
          </p>
        <% true -> %>
          <%!-- Approve form. Hidden when this user is the requester and the
               policy forbids self-approval — the context refuses it anyway
               (IL-15), this just removes the dead button. They can still Deny
               their own request. --%>
          <div
            :if={@self_blocked?}
            class="mt-4 flex items-start gap-2 rounded-lg bg-black/30 p-3 text-xs text-zinc-300 ring-1 ring-white/[0.08]"
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

            <.disclosure>
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
                      class="text-brand-400 hover:text-brand-300"
                    >
                    approvals page
                  </.link>.
                  </p>
                </div>
              </div>
            </.disclosure>

            <.button
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
            <%!-- `tone={:rose}` tints the focus ring rose — this is the
                 destructive decision. `aria-label` names it for AT. --%>
            <.input
              type="textarea"
              name="reason"
              value={nil}
              tone={:rose}
              rows="2"
              aria-label="Reason for denial"
              placeholder="Why are you denying this? (optional, logged in the decision history)"
              class="min-h-0 resize-none"
            />
            <.button
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
    </.panel>
    """
  end

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
