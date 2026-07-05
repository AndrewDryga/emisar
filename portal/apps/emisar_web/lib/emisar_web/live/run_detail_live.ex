defmodule EmisarWeb.RunDetailLive do
  use EmisarWeb, :live_view
  alias Emisar.{Approvals, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    subject = socket.assigns.current_subject

    case Runs.fetch_run_by_id(id, subject, preload: [:runner, :api_key, :requested_by]) do
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
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runs}
      width={:table}
    >
      <:title>
        <.detail_header
          back="Runs"
          navigate={~p"/app/#{@current_account}/runs"}
          title={@run.action_id}
          mono
        >
          <:meta :if={@run.runner}>on {runner_label(@run.runner)}</:meta>
        </.detail_header>
      </:title>
      <:actions>
        <%!-- The run id, copyable for a ticket or a log grep — the full UUID
             without cluttering the meta strip (which deliberately dropped it). --%>
        <%!-- A design-system BUTTON like its row neighbors — the copy behavior
             is just the delegated data-copy attributes copy.js listens for,
             so it needs none of the code-panel copy chip's one-off styling. --%>
        <.button
          variant={:secondary}
          size={:md}
          data-copy-text={@run.id}
          data-copy-label-copied="Copied id"
        >
          <.icon name="hero-clipboard-document" class="-ml-0.5 h-3.5 w-3.5" /> Copy id
        </.button>
        <%!-- Close the loop: the dispatch's slice of the audit trail. request_id
             groups the run's transitions, its grant use, and its cancel request
             (run events target the RUNNER, so the old target filter would only
             find this run's pre-rename rows). Subject-scoped by the audit page
             itself, so the link just pre-filters — it can't widen access. --%>
        <%!-- A BUTTON like its neighbors — a bare text link sandwiched between
             the Copy-id and Cancel buttons read as a third grammar in one row. --%>
        <.button
          navigate={~p"/app/#{@current_account}/audit?#{run_trail_query(@run)}"}
          variant={:secondary}
          size={:md}
        >
          View activity
        </.button>
        <.button
          :if={
            @run.status in [:sent, :running, :pending] and
              Runs.subject_can_cancel_run?(@current_subject)
          }
          variant={:secondary}
          tone={:rose}
          size={:md}
          phx-click="cancel"
          data-confirm="Cancel this run? The runner will SIGTERM then SIGKILL."
        >
          Cancel run
        </.button>
      </:actions>

      <%!-- The page owns its rhythm (design-system §3.3): ONE space-y-12 child
           neutralizes the shell's space-y-6 and sets 48px between the major
           blocks (mt-4 = breathing room under the title); the attention stack
           keeps its own tight inner rhythm. --%>
      <div class="mt-4 space-y-12">
        <%!-- The STATUS block: the naked meta row plus, when the run is held /
             dead / blocked, its attention stack — grouped tight (mt-8) because
             the event blocks ELABORATE the status badge two lines up; floated
             as their own 48px section they read weaker than the section
             headers below while carrying the page's live state. --%>
        <div>
          <%!-- Run facts on the CANVAS — the naked meta row (the runner-detail
               grammar), no island. Status leads; ONE row at sm+ (natural widths
               fit the 7xl column); phones keep the tidy 2-col grid, the forensic
               timestamp spanning both columns via `wrap`. --%>
          <div class="grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-14">
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
            <.meta_field label="Dispatched by">
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
            <%!-- Empty Duration / Exit code render the same muted em-dash placeholder
               (text-zinc-500) — never the value span's brighter/monospace styling,
               or the two "no value" cells look mismatched. --%>
            <.meta_field label="Duration">
              <span :if={@run.duration_ms} class="text-zinc-200">
                {format_duration(@run.duration_ms)}
              </span>
              <span :if={is_nil(@run.duration_ms)} class="text-zinc-500">—</span>
            </.meta_field>
            <.meta_field label="Exit code">
              <span
                :if={is_integer(@run.exit_code)}
                class={["font-mono", exit_code_class(@run.exit_code)]}
              >
                {@run.exit_code}
              </span>
              <span :if={is_nil(@run.exit_code)} class="text-zinc-500">—</span>
            </.meta_field>
            <%!-- Forensic (2026-06-30 21:39:54) to match the approval detail's WHEN —
               sibling detail pages describing the same event in two datetime
               dialects read as two authors. --%>
            <.meta_field label="Started" wrap>
              <.local_time
                value={@run.inserted_at}
                mode={:forensic}
                class="tabular-nums text-zinc-200"
              />
            </.meta_field>
          </div>

          <%!-- The ATTENTION stack — the run's held/failed/offline moment as
               EVENT BLOCKS (the icon-capped-spine grammar, §8.1), not wash
               boxes: amber = pending on someone/something, rose = a dead
               outcome. --%>
          <div :if={attention?(@run, @approval_request, @runner_connection)} class="mt-8 space-y-8">
            <%!-- Approval hold — the run is waiting on a human decision. --%>
            <.event_block
              :if={@run.status == :pending_approval and @approval_request}
              icon="hero-hand-raised"
              title="Waiting on approval"
            >
              <:body>This run is held until an approver decides.</:body>
              <div class="mt-4">
                <.button
                  tone={:amber}
                  size={:md}
                  navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
                >
                  View approval →
                </.button>
              </div>
            </.event_block>

            <%!-- Cancelled-with-reason — an approver's denial cancels the run and
               writes "approval denied: …" into reason_text; a bare grey badge
               would drop that reason. Driven by the run (not the approval row,
               which a prune may have removed). --%>
            <.event_block
              :if={@run.status == :cancelled and @run.reason_text not in [nil, ""]}
              icon="hero-no-symbol"
              tone={:rose}
              title="Cancelled"
            >
              <:body><span class="whitespace-pre-wrap">{@run.reason_text}</span></:body>
              <div :if={@approval_request} class="mt-4">
                <.button
                  variant={:secondary}
                  tone={:rose}
                  size={:md}
                  navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
                >
                  View approval →
                </.button>
              </div>
            </.event_block>

            <%!-- Error — only when terminal-failed and we got a message back. --%>
            <.event_block
              :if={@run.error_message}
              icon="hero-exclamation-triangle"
              tone={:rose}
              title="Error"
            >
              <:body><span class="whitespace-pre-wrap">{@run.error_message}</span></:body>
            </.event_block>

            <%!-- Runner-dropped warning — in flight but its runner's socket is
               gone. Don't fake a terminal status; flag that output may be
               incomplete until it reconnects (or the timeout sweep errors it). --%>
            <.event_block
              :if={@run.status in [:sent, :running] and @runner_connection == :offline}
              icon="hero-bolt-slash"
              title="Runner disconnected"
            >
              <:body>
                Its socket dropped while this run was in flight — output may be incomplete.
                The run is marked errored if the runner doesn't reconnect shortly.
              </:body>
            </.event_block>

            <%!-- Queued but its target runner is offline — nothing's running yet,
               so say what's actually blocking it. --%>
            <.event_block
              :if={@run.status == :pending and @runner_connection == :offline}
              icon="hero-bolt-slash"
              title="Queued — runner offline"
            >
              <:body>
                Waiting for {runner_label(@run.runner)} to reconnect before this run can dispatch.
                It's marked errored if the runner doesn't return before the dispatch timeout.
              </:body>
            </.event_block>
          </div>
        </div>

        <%!-- ONE why-cluster on the canvas — who asked and what policy said,
             together (the decision-record grammar), not a boxed card. The
             verdict is told ONCE by the status badge above; this carries the
             WHY plus the matched-rules/version audit trail. Policy hidden for
             `allow` (the boring default the run wouldn't exist without). --%>
        <section :if={@run.reason not in [nil, ""] or show_policy?(@run)}>
          <.section_header title="Why" />
          <dl class="space-y-5">
            <div :if={@run.reason && @run.reason != ""}>
              <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                Reason
              </dt>
              <dd class="mt-1 text-sm leading-relaxed text-zinc-200">“{@run.reason}”</dd>
            </div>
            <div :if={show_policy?(@run)}>
              <%!-- Plain field-key like REASON above — one icon on one label
                   made the pair read as two different kinds of fact. --%>
              <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                Policy
              </dt>
              <dd
                :if={@run.policy_reason && @run.policy_reason != ""}
                class="mt-1 text-sm leading-relaxed text-zinc-200"
              >
                {@run.policy_reason}
              </dd>
              <dd
                :if={
                  matched_rules_label(@run.matched_rules) != "—" or
                    is_integer(@run.policy_version)
                }
                class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500"
              >
                <span :if={matched_rules_label(@run.matched_rules) != "—"}>
                  Matched
                  <span class="font-mono text-zinc-400">
                    {matched_rules_label(@run.matched_rules)}
                  </span>
                </span>
                <span :if={is_integer(@run.policy_version)}>
                  Policy <span class="font-mono text-zinc-400">v{@run.policy_version}</span>
                </span>
              </dd>
            </div>
          </dl>
        </section>

        <%!-- Arguments before output. Operators read the page top→down:
             "what was called → what came back" — all input context above the
             result. The code panels ARE the earned artifact boxes. --%>
        <.code_panel
          :if={@run.args && @run.args != %{}}
          label="Arguments"
          annotation={@run.args_sha256 && "sha256:#{String.slice(@run.args_sha256, 0, 16)}…"}
          max_h="max-h-64"
          code={format_json(@run.args)}
        />

        <%!-- The exact shell command the runner ran. Sensitive arg values are
             redacted runner-side — the audit-grade record of what executed. --%>
        <.code_panel
          :if={@run.executed_command && @run.executed_command != ""}
          label="Executed command"
          annotation="secrets redacted"
          code={@run.executed_command}
        />

        <%!-- Output stream — the main event, in the code_panel ARTIFACT frame
             (island fill + solid zinc-800 edge + 16px title) but hand-rolled:
             it streams chunk spans into the <pre>, which code_panel's static
             `code` attr can't (the one sanctioned hand-roll, console-ux §1).
             Hidden for statuses where the panel would just be blank. --%>
        <div
          :if={show_output?(@run, @output_present?)}
          class="overflow-hidden rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-zinc-800"
        >
          <header class="flex items-center justify-between gap-3 border-b border-zinc-800/70 px-4 py-2">
            <div class="flex shrink-0 items-center gap-2">
              <h3 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
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
            <span class="font-mono text-[11px] text-zinc-500">stderr in rose</span>
          </header>
          <%!-- Each chunk already carries its trailing newline (the runner
               streams line-by-line via ReadBytes('\n')), so output is one
               pre-formatted block with chunks as inline spans — they
               concatenate and only the real newlines break lines. Block
               elements or template indentation here would double the
               spacing, since <pre> makes all whitespace significant. --%>
          <%!-- A terminal run that streamed nothing gets one quiet line instead
               of a 24rem black void (the in-flight min-height stays — more may
               be coming). --%>
          <p
            :if={not @output_present? and @run.status not in [:sent, :running]}
            class="bg-black/60 p-4 font-mono text-xs text-zinc-600"
          >
            No output captured.
          </p>
          <%!-- min-height only while IN FLIGHT (room for chunks to stream into);
               a terminal run's panel hugs its real output instead of padding a
               two-line result with a 24rem void. --%>
          <pre
            :if={@output_present? or @run.status in [:sent, :running]}
            id="run-output"
            phx-update="stream"
            class={[
              "max-h-[60vh] overflow-auto whitespace-pre-wrap break-all bg-black/60 p-4",
              "font-mono text-xs leading-normal text-zinc-300",
              @run.status in [:sent, :running] && "min-h-[24rem]"
            ]}
          ><span
              :for={{id, event} <- @streams.events}
              id={id}
              class={event.stream == "stderr" && "text-rose-300"}
            >{event_chunk(event)}</span></pre>
        </div>
      </div>
    </.dashboard_shell>
    """
  end

  # Whether any attention banner renders — the stack's wrapper must vanish with
  # them, or its empty div would double the wrapper's 48px gap.
  defp attention?(run, approval_request, runner_connection) do
    (run.status == :pending_approval and approval_request != nil) or
      (run.status == :cancelled and run.reason_text not in [nil, ""]) or
      run.error_message != nil or
      (run.status in [:sent, :running, :pending] and runner_connection == :offline)
  end

  # Only ever called with an integer exit code — the nil case renders `<.blank>`.
  defp exit_code_class(0), do: "text-brand-300"
  defp exit_code_class(code) when is_integer(code), do: "text-rose-300"

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

  defp matched_rules_label(nil), do: "—"
  defp matched_rules_label([]), do: "—"
  defp matched_rules_label(rules) when is_list(rules), do: Enum.join(rules, ", ")
  # Legacy runs written before request_id stamping fall back to the old
  # target-filter shape (which is exactly what their rows carry).
  defp run_trail_query(%{request_id: rid}) when is_binary(rid) and rid != "",
    do: [request_id: rid]

  defp run_trail_query(run), do: [target_kind: "action_run", target_id: run.id]
end
