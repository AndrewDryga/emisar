defmodule EmisarWeb.RunDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Approvals, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    subject = socket.assigns.current_subject

    case Runs.fetch_run_by_id(id, subject, preload: [:runner, :api_key]) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runs")}

      {:ok, run} ->
        if connected?(socket) do
          Runs.subscribe_run(run.account_id, run.id)
          # Watch the runner's live connection so a socket dropping mid-run
          # surfaces as a banner — without it, an in-flight run whose runner
          # vanished just looks slow until the timeout sweep errors it.
          Runners.subscribe_connections(run.account_id)
        end

        # The event list (up to 500 rows) is secondary to the run itself and
        # streamed — defer it behind connected?/1 so the dead render doesn't
        # run the heavy read a second time (same pattern as run_new_live).
        events =
          if connected?(socket) do
            {:ok, evts, _meta} = Runs.list_events_for_run(run.id, subject, page: [limit: 500])
            evts
          else
            []
          end

        approval_request = lookup_approval(subject, run)

        {:ok,
         socket
         |> assign(:page_title, "Run #{run.action_id}")
         |> assign(:run, run)
         |> assign(:approval_request, approval_request)
         |> assign(:runner_connection, runner_connection(run))
         # Whether any output was persisted — gates the output panel for an
         # errored run so "result never arrived" doesn't render an empty terminal.
         |> assign(:output_present?, events != [])
         |> stream(:events, events)}
    end
  end

  defp lookup_approval(_subject, %{requires_approval: false}), do: nil

  defp lookup_approval(subject, run) do
    case Approvals.fetch_approval_request_by_run_id(run.id, subject) do
      {:ok, req} -> req
      {:error, :not_found} -> nil
    end
  end

  def handle_info({:run_updated, run}, socket) when run.id == socket.assigns.run.id do
    # If status flips to/from pending_approval, refresh the linked
    # approval row so the banner updates without a page reload.
    approval_request = lookup_approval(socket.assigns.current_subject, run)

    {:noreply,
     socket
     |> assign(:run, run)
     |> assign(:approval_request, approval_request)}
  end

  def handle_info({:run_event, event}, socket),
    do: {:noreply, socket |> stream_insert(:events, event) |> assign(:output_present?, true)}

  # The runner's live connection changed — re-derive its state so an
  # in-flight run reflects a runner that just dropped (or reconnected).
  def handle_info(%{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, :runner_connection, runner_connection(socket.assigns.run))}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    Permissions.gated(
      socket,
      Runs.subject_can_cancel_run?(socket.assigns.current_subject),
      fn socket ->
        case Runs.cancel_run(
               socket.assigns.run,
               socket.assigns.current_subject,
               "operator cancelled"
             ) do
          {:ok, run} ->
            {:noreply, socket |> assign(:run, run) |> put_flash(:info, "Cancel sent to runner.")}

          _ ->
            {:noreply, put_flash(socket, :error, "Unable to cancel.")}
        end
      end
    )
  end

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
      section={:runs}
      width={:detail}
    >
      <:title>
        <.detail_header back="Runs" navigate={~p"/app/#{@current_account}/runs"}>
          <span class="font-mono text-base">{@run.action_id}</span>
          <span :if={@run.runner} class="ml-2 text-sm font-normal text-zinc-400">
            on {runner_label(@run.runner)}
          </span>
        </.detail_header>
      </:title>
      <:actions>
        <%!-- Close the loop: this run's slice of the audit trail (every event
             whose subject is this run). Subject-scoped by the audit page itself,
             so the link just pre-filters — it can't widen access. --%>
        <.link
          navigate={
            ~p"/app/#{@current_account}/audit?#{[subject_kind: "action_run", subject_id: @run.id]}"
          }
          class="text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View activity →
        </.link>
        <.button
          :if={
            @run.status in [:sent, :running, :pending] and
              Runs.subject_can_cancel_run?(@current_subject)
          }
          variant="danger"
          size="md"
          phx-click="cancel"
          data-confirm="Cancel this run? The runner will SIGTERM then SIGKILL."
        >
          Cancel run
        </.button>
      </:actions>

      <%!-- Single horizontal meta strip — status leads (so a glance
           tells you the run state without hunting the top-right
           corner), then runner, source, duration, exit, when. Request
           ID used to live in the last cell — it was low-signal debug
           trace; status earns the slot. --%>
      <.meta_strip cols={6}>
        <.meta_field label="Status">
          <.status_badge status={@run.status} />
        </.meta_field>
        <.meta_field label="Runner">
          <.link
            navigate={~p"/app/#{@current_account}/runners/#{@run.runner_id}"}
            class="truncate text-zinc-200 hover:text-brand-300"
          >
            {runner_label(@run.runner)}
          </.link>
        </.meta_field>
        <.meta_field label="Source">
          <span class="block truncate">
            <span class="text-zinc-200">{run_actor(@run)}</span>
            <span :if={client_version(@run)} class="text-zinc-400">{client_version(@run)}</span>
            <span :if={@run.api_key} class="text-zinc-500">· {format_source(@run.source)}</span>
          </span>
          <span
            :if={@run.mcp_session_id}
            class="mt-0.5 block truncate font-mono text-[11px] text-zinc-500"
            title={@run.mcp_session_id}
          >
            session {String.slice(@run.mcp_session_id, 0, 8)}
          </span>
        </.meta_field>
        <.meta_field label="Duration">
          <span class="text-zinc-200">{format_duration(@run.duration_ms)}</span>
        </.meta_field>
        <.meta_field label="Exit code">
          <span class={[
            "font-mono",
            exit_code_class(@run.exit_code)
          ]}>
            {@run.exit_code || "—"}
          </span>
        </.meta_field>
        <.meta_field label="Started">
          <.local_time value={@run.inserted_at} class="text-zinc-200" />
        </.meta_field>
      </.meta_strip>

      <%!-- Approval banner — the run is held on a human decision. Loud amber
           + a one-click jump to the approval page. --%>
      <.notice
        :if={@run.status == :pending_approval and @approval_request}
        variant={:warning}
        icon="hero-hand-raised"
        title="Waiting on approval"
        class="mt-4"
      >
        This run is held until an approver decides.
        <:action>
          <.button
            variant="caution"
            size="md"
            navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
          >
            Review approval →
          </.button>
        </:action>
      </.notice>

      <%!-- Cancelled-with-reason banner — an approver's denial cancels the run
           and writes "approval denied: …" into reason_text; a bare grey badge
           would drop that reason, leaving the requester with no "why didn't it
           run". Driven by the run (not the approval row, which a prune may have
           removed), with a best-effort jump to the decision. --%>
      <.notice
        :if={@run.status == :cancelled and @run.reason_text not in [nil, ""]}
        variant={:danger}
        icon="hero-no-symbol"
        title="Cancelled"
        class="mt-4"
      >
        <span class="whitespace-pre-wrap">{@run.reason_text}</span>
        <:action :if={@approval_request}>
          <.button
            variant="danger"
            size="md"
            navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
          >
            Review approval →
          </.button>
        </:action>
      </.notice>

      <%!-- Error banner — only when terminal-failed and we got a message back. --%>
      <.notice :if={@run.error_message} variant={:danger} title="Error" class="mt-4">
        <span class="whitespace-pre-wrap">{@run.error_message}</span>
      </.notice>

      <%!-- Runner-dropped warning — the run is in flight but its runner's
           socket is gone. Don't fake a terminal status; just flag that the
           output may be incomplete until it reconnects (or the dispatch
           timeout sweep errors the run). --%>
      <.offline_notice
        :if={@run.status in [:sent, :running] and @runner_connection == :offline}
        severity={:caution}
        title="Runner disconnected"
        class="mt-4"
      >
        Its socket dropped while this run was in flight — output may be incomplete.
        The run is marked errored if the runner doesn't reconnect shortly.
      </.offline_notice>

      <%!-- Queued but its target runner is offline — the run can't dispatch
           until the runner reconnects (or the timeout sweep errors it). The
           in-flight banner above ("output may be incomplete") is wrong here:
           nothing's running yet, so say what's actually blocking it. --%>
      <.offline_notice
        :if={@run.status == :pending and @runner_connection == :offline}
        severity={:caution}
        title="Queued — runner offline"
        class="mt-4"
      >
        Waiting for {runner_label(@run.runner)} to reconnect before this run can dispatch.
        It's marked errored if the runner doesn't return before the dispatch timeout.
      </.offline_notice>

      <%!-- Operator's reason, full width. The policy decision renders
           as an inline strip below (only when it carries signal), not a
           side panel that would just echo the status chip. --%>
      <.card :if={@run.reason && @run.reason != ""} class="mt-4" padding="p-4">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
          Operator's reason
        </h3>
        <p class="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-zinc-200">
          {@run.reason}
        </p>
      </.card>

      <%!-- Policy decision strip — single horizontal line. Hidden for
           `allow` (the boring default the run wouldn't exist without).
           For `require_approval`/`deny`, shows the chip + reason +
           matched rules inline so there's no duplicated decision and
           no whole-section visual weight for what's effectively one
           data point. --%>
      <.card
        :if={show_policy?(@run)}
        class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm"
        padding="px-4 py-2.5"
      >
        <span class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
          Policy
        </span>
        <.chip tone={policy_decision_tone(@run.policy_decision)}>
          {policy_label(@run.policy_decision)}
        </.chip>
        <span
          :if={@run.policy_reason && @run.policy_reason != ""}
          class="text-zinc-300"
        >
          {@run.policy_reason}
        </span>
        <span :if={matched_rules_label(@run.matched_rules) != "—"} class="text-xs text-zinc-500">
          · Matched
          <span class="font-mono text-zinc-400">{matched_rules_label(@run.matched_rules)}</span>
        </span>
        <span :if={is_integer(@run.policy_version)} class="text-xs text-zinc-500">
          · Policy <span class="font-mono text-zinc-400">v{@run.policy_version}</span>
        </span>
      </.card>

      <%!-- Arguments before output. Operators read the page top→down:
           "what was called → what came back". Putting args first
           groups all the input context (reason, policy, args) above
           the result, so the operator doesn't have to scroll past a
           tall output panel to recall what was actually invoked. --%>
      <.card :if={@run.args && @run.args != %{}} class="mt-6 overflow-hidden" padding="">
        <header class="flex items-center justify-between border-b border-zinc-900 px-4 py-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Arguments</h3>
          <span :if={@run.args_sha256} class="font-mono text-[11px] text-zinc-500">
            sha256:{String.slice(@run.args_sha256, 0, 16)}…
          </span>
        </header>
        <pre class="max-h-64 overflow-auto bg-black/40 p-4 font-mono text-xs text-zinc-300">{format_json(@run.args)}</pre>
      </.card>

      <%!-- The exact shell command the runner ran. Sensitive arg values
           are redacted runner-side (shown as [REDACTED]) — this is the
           audit-grade record of what actually executed. --%>
      <.card
        :if={@run.executed_command && @run.executed_command != ""}
        class="mt-6 overflow-hidden"
        padding=""
      >
        <header class="flex items-center justify-between border-b border-zinc-900 px-4 py-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
            Executed command
          </h3>
          <span class="text-[11px] text-zinc-600">secrets redacted</span>
        </header>
        <pre class="overflow-auto bg-black/40 p-4 font-mono text-xs text-zinc-200">{@run.executed_command}</pre>
      </.card>

      <%!-- Output stream — the main event. Full width, large, dark
           terminal-style background. Stderr lines render in rose so
           a failure jumps out. Hidden entirely for statuses where
           the panel would just be blank (cancelled, denied, anything
           still awaiting approval) — saves the operator from staring
           at an empty terminal. --%>
      <.card
        :if={show_output?(@run, @output_present?)}
        class="mt-6 overflow-hidden"
        padding=""
      >
        <header class="flex items-center justify-between border-b border-zinc-900 bg-zinc-950/60 px-4 py-2">
          <div class="flex items-center gap-2">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
              Output
            </h3>
            <%!-- Streaming affordance — a pulsing pill while the run is still
                 in flight, so an idle terminal reads as "more is coming",
                 not "this is the final output". Gone once terminal. --%>
            <span
              :if={@run.status in [:sent, :running]}
              class="inline-flex items-center gap-1 rounded-full bg-brand-500/10 px-2 py-0.5 text-[10px] font-medium text-brand-300 ring-1 ring-brand-500/30"
            >
              <span class="h-1.5 w-1.5 animate-pulse rounded-full bg-brand-400"></span> streaming…
            </span>
          </div>
          <span class="text-[11px] text-zinc-500">stderr in rose</span>
        </header>
        <%!-- Each chunk already carries its trailing newline (the runner
             streams line-by-line via ReadBytes('\n')), so output is one
             pre-formatted block with chunks as inline spans — they
             concatenate and only the real newlines break lines. Block
             elements or template indentation here would double the
             spacing, since <pre> makes all whitespace significant. --%>
        <pre
          id="run-output"
          phx-update="stream"
          class="max-h-[60vh] min-h-[24rem] overflow-auto whitespace-pre-wrap break-all bg-black p-4 font-mono text-xs leading-normal text-zinc-300"
        ><span
            :for={{id, event} <- @streams.events}
            id={id}
            class={event.stream == "stderr" && "text-rose-300"}
          >{event_chunk(event)}</span></pre>
      </.card>
    </.dashboard_shell>
    """
  end

  defp exit_code_class(0), do: "text-brand-300"
  defp exit_code_class(code) when is_integer(code), do: "text-rose-300"
  defp exit_code_class(_), do: "text-zinc-500"

  defp policy_label("allow"), do: "Allowed"
  defp policy_label("require_approval"), do: "Requires approval"
  defp policy_label("deny"), do: "Denied"
  defp policy_label(other), do: other

  defp runner_label(%Emisar.Runners.Runner{name: name}) when is_binary(name) and name != "",
    do: name

  defp runner_label(%Emisar.Runners.Runner{hostname: host}) when is_binary(host) and host != "",
    do: host

  defp runner_label(_), do: "Unknown runner"

  # Live connection state of the run's runner (:online | :offline). Keyed
  # on runner_id/account_id — both columns, always loaded — so it survives
  # a non-preloaded {:run_updated, run} broadcast replacing the assign.
  defp runner_connection(%{runner_id: id, account_id: account_id}) when is_binary(id),
    do: if(Runners.online?(account_id, id), do: :online, else: :offline)

  defp runner_connection(_), do: :unknown

  # `allow` is the implicit happy path — if the run dispatched at all
  # we already know policy let it through. Showing the strip just
  # adds visual noise to every list-of-runs detail page. Surface it
  # only when policy actually intervened (held for approval, denied)
  # or when policy somehow recorded a non-allow without a status flip.
  defp show_policy?(%{policy_decision: nil}), do: false
  defp show_policy?(%{policy_decision: "allow"}), do: false
  defp show_policy?(%{policy_decision: _}), do: true

  # No point staring at a black terminal for a run that never made it to the
  # runner. Cancelled / denied / awaiting-approval / refused runs never produce
  # output; surfacing the panel just signals "broken".
  #
  # An errored run is the special case: it may have produced output before
  # failing (show it) or none at all — "runner disconnected, result never
  # arrived" — so gate it on whether any output was actually persisted.
  # Everything else (sent / running while streaming, success, failed) gets the
  # panel — an empty one is fine because chunks stream in via PubSub.
  defp show_output?(%{status: :error}, output_present?), do: output_present?

  defp show_output?(%{status: status}, _output_present?)
       when status in [:cancelled, :denied, :pending_approval, :pending, :refused],
       do: false

  defp show_output?(_run, _output_present?), do: true

  defp policy_decision_tone("allow"), do: :brand
  defp policy_decision_tone("require_approval"), do: :amber
  defp policy_decision_tone("deny"), do: :rose
  defp policy_decision_tone(_), do: :neutral

  defp matched_rules_label(nil), do: "—"
  defp matched_rules_label([]), do: "—"
  defp matched_rules_label(rules) when is_list(rules), do: Enum.join(rules, ", ")
end
