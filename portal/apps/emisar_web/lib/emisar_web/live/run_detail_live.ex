defmodule EmisarWeb.RunDetailLive do
  use EmisarWeb, :live_view
  alias Emisar.{Approvals, Audit, Runners, Runs, Users}
  alias EmisarWeb.Permissions
  alias EmisarWeb.RunStatuses

  # The output terminal shows the most-recent N chunks — the live stream caps at
  # it (stream_insert :limit) AND the initial mount load fetches exactly it — so
  # a >N-chunk run reads identically whether watched live or reloaded, instead of
  # live showing the newest N and a reload showing the oldest N. A note flags the
  # trim so partial output never reads as complete.
  @event_window 500
  defp event_window, do: @event_window

  defp output_pre_classes do
    "max-h-[60vh] overflow-auto whitespace-pre-wrap break-all bg-black/60 p-4 font-mono text-xs leading-normal text-zinc-300"
  end

  defp events_truncated?(%{progress_event_count: count}), do: count > @event_window
  defp events_truncated?(_), do: false

  # "Load earlier output" is offered only for terminal runs: a running run's
  # stream evicts to the most-recent window, so paging earlier chunks in would
  # fight that eviction. A terminal run streams nothing more, so backfill is safe.
  defp can_load_earlier?(%{status: status}, more_earlier?),
    do: Runs.terminal_status?(status) and more_earlier?

  defp event_seq(nil), do: nil
  defp event_seq(%{seq: seq}), do: seq

  def mount(%{"id" => id}, _session, socket) do
    subject = socket.assigns.current_subject

    case Runs.fetch_run_by_id(id, subject, preload: [:runner, :attribution]) do
      # A denied role and a missing run are indistinguishable — never leak
      # existence, never crash on {:error, :unauthorized}.
      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runs")}

      {:ok, run} ->
        if connected?(socket) do
          Runs.subscribe_run(run.account_id, run.id)
        end

        # Load the SAME window the live stream converges to — the most-recent
        # @event_window chunks, chronological — so a >window run reads identically
        # live or reloaded. Deferred behind connected?/1 so the dead render doesn't
        # run the heavy read a second time (same pattern as run_new_live).
        #
        # Three states, never conflated: the dead render hasn't read yet
        # (:loading), a transient read failure must not raise inside mount and
        # must not claim the run produced nothing (:error), and :loaded is the
        # only state in which an empty window means "no output captured".
        {events, output_state} =
          if connected?(socket) do
            case Runs.list_recent_events_for_run(run, event_window(), subject) do
              {:ok, evts} -> {evts, :loaded}
              {:error, _} -> {[], :error}
            end
          else
            {[], :loading}
          end

        approval_request = lookup_approval(subject, run)
        approval_decider = if connected?(socket), do: approval_decider(approval_request)

        approval_event_id =
          if connected?(socket), do: approval_event_id(approval_request, subject)

        {:ok,
         socket
         |> assign(:page_title, "Run #{run.action_id}")
         |> assign(:run, run)
         |> assign(:action_args, visible_action_args(run, subject))
         |> assign(:approval_request, approval_request)
         |> assign(:approval_decider, approval_decider)
         |> assign(:approval_event_id, approval_event_id)
         |> assign(:runner_connection, runner_connection(run))
         # Whether any output was persisted — gates the output panel for an
         # errored run so "result never arrived" doesn't render an empty terminal.
         |> assign(:output_present?, events != [])
         |> assign(:output_state, output_state)
         |> assign(:oldest_seq, event_seq(List.first(events)))
         |> assign(:more_earlier?, events_truncated?(run))
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

  # The decider behind an approved run's "Approval" row — the human the record
  # answers "who let this run" with.
  defp approval_decider(%Approvals.Request{decided_by_id: id}) when is_binary(id) do
    case Users.fetch_user_by_id(id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp approval_decider(_), do: nil

  defp approval_event_id(%Approvals.Request{id: id}, subject) do
    case Audit.approval_event_refs([id], subject) do
      {:ok, %{^id => %{final: event_id}}} -> event_id
      _ -> nil
    end
  end

  defp approval_event_id(_, _subject), do: nil

  defp decider_label(%Users.User{full_name: name}, _id) when is_binary(name) and name != "",
    do: name

  defp decider_label(%Users.User{email: email}, _id), do: email
  # The deciding user's row is gone — an honest label beats an id fragment
  # (the approvals surfaces render the same deleted-user state as "Former
  # member"); the full decider id stays on the audit trail.
  defp decider_label(_, id) when is_binary(id), do: "a former member"
  defp decider_label(_, _), do: "—"

  def handle_info({:run_updated, run}, socket) when run.id == socket.assigns.run.id do
    # The broadcast carries a preload-less run; keep the associations loaded at
    # mount (:runner, :api_key, :requested_by) so "Dispatched by" and the runner
    # label don't degrade to "—"/"AI agent" on the first live status flip. The
    # run's own columns (status, policy, timing, progress counts) come from the
    # fresh struct — only the immutable dispatch-time associations are carried.
    old = socket.assigns.run
    run = %{run | runner: old.runner, api_key: old.api_key, requested_by: old.requested_by}

    # If status flips to/from pending_approval, refresh the linked
    # approval row so the banner updates without a page reload.
    approval_request = lookup_approval(socket.assigns.current_subject, run)

    {:noreply,
     socket
     |> assign(:run, run)
     |> assign(:action_args, visible_action_args(run, socket.assigns.current_subject))
     |> assign(:approval_request, approval_request)
     |> assign(:approval_decider, approval_decider(approval_request))
     |> assign(
       :approval_event_id,
       approval_event_id(approval_request, socket.assigns.current_subject)
     )}
  end

  # A live-appending stream never evicts on its own, so a chatty run streaming
  # thousands of progress chunks would grow the viewer's DOM without bound. Cap
  # the client at the most-recent 500 events — stream/4's :limit does not carry
  # to stream_insert/4, so it must be passed on every insert. Server socket
  # memory is unaffected (streams are write-only to the client).
  def handle_info({:run_event, event}, socket) do
    {:noreply,
     socket
     |> stream_insert(:events, event, limit: -@event_window)
     |> assign(:output_present?, true)}
  end

  def handle_info(%{event: "presence_diff"} = event, socket) do
    connection =
      Runners.project_connection(
        socket.assigns.runner_connection,
        socket.assigns.run.runner_id,
        Runners.normalize_connection_change(event)
      )

    {:noreply, assign(socket, :runner_connection, connection)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # Runs owns the decode + sensitivity replacement; an unauthorized or
  # undecodable projection renders no Arguments panel at all.
  defp visible_action_args(run, subject) do
    case Runs.project_action_args(run, subject) do
      {:ok, args} -> args
      {:error, _reason} -> %{}
    end
  end

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
            {:noreply, socket |> assign(:run, run) |> put_flash(:info, "Cancellation accepted.")}

          _ ->
            {:noreply, put_flash(socket, :error, "Unable to cancel.")}
        end
      end
    )
  end

  # Page the next-older window of trimmed output into a terminal run's viewer.
  # The subject-gated read is the authorization gate; a vanished run or the start
  # of output is a quiet no-op rather than a crash.
  def handle_event("load_earlier", _params, socket) do
    %{run: run, oldest_seq: oldest_seq, current_subject: subject} = socket.assigns

    with true <- can_load_earlier?(run, socket.assigns.more_earlier?) and is_integer(oldest_seq),
         {:ok, page} <-
           Runs.list_events_for_run_before(run.id, oldest_seq, event_window() + 1, subject) do
      # Reading one row past the window is what tells us anything older remains,
      # so an exactly-full final page doesn't leave the control offering a no-op.
      {earlier, more_earlier?} =
        if length(page) > event_window(), do: {tl(page), true}, else: {page, false}

      socket =
        earlier
        |> Enum.reverse()
        |> Enum.reduce(socket, &stream_insert(&2, :events, &1, at: 0))
        |> assign(:oldest_seq, event_seq(List.first(earlier)) || oldest_seq)
        |> assign(:more_earlier?, more_earlier?)

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  # Both views are already present as escaped text. These commands only switch
  # the local presentation and its matching Copy target, so reviewing or copying
  # JSON never needs a LiveView round trip or a second authorization/data path.
  defp show_raw_output do
    JS.hide(to: "#run-output-json-view")
    |> JS.hide(to: "#run-output-copy-json")
    |> JS.show(to: "#run-output-raw-view")
    |> JS.show(to: "#run-output-raw-legend", display: "inline")
    |> JS.show(to: "#run-output-raw-tools", display: "flex")
    |> JS.show(to: "#run-output-copy-raw", display: "inline-flex")
    |> JS.set_attribute({"aria-pressed", "true"}, to: "#run-output-raw-toggle")
    |> JS.set_attribute({"aria-pressed", "false"}, to: "#run-output-json-toggle")
  end

  defp show_json_output do
    JS.hide(to: "#run-output-raw-view")
    |> JS.hide(to: "#run-output-raw-legend")
    |> JS.hide(to: "#run-output-raw-tools")
    |> JS.hide(to: "#run-output-copy-raw")
    |> JS.show(to: "#run-output-json-view")
    |> JS.show(to: "#run-output-copy-json", display: "inline-flex")
    |> JS.set_attribute({"aria-pressed", "false"}, to: "#run-output-raw-toggle")
    |> JS.set_attribute({"aria-pressed", "true"}, to: "#run-output-json-toggle")
  end

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
      section={:runs}
      width={:table}
    >
      <:title>
        <%!-- On a phone the long mono action id already fills the header, so the
             secondary runner line hides below sm — the Runner fact in the grid
             below still names it. --%>
        <.detail_header
          back="Runs"
          navigate={~p"/app/#{@current_account}/runs"}
          title={@run.action_id}
          mono
        >
          <:meta :if={@run.runner}>
            <span class="hidden sm:inline">on {runner_label(@run.runner)}</span>
          </:meta>
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
          <.icon name="action.copy" class="-ml-0.5 h-3.5 w-3.5" /> Copy id
        </.button>
        <%!-- Close the loop: the dispatch's slice of the audit trail. request_id
             groups the run's transitions, its grant use, and its cancel request
             (run events target the RUNNER, so a target filter would miss them).
             Subject-scoped by the audit page itself, so the link just
             pre-filters — it can't widen access. --%>
        <%!-- A BUTTON like its neighbors — a bare text link sandwiched between
             the Copy-id and Cancel buttons read as a third grammar in one row. --%>
        <.button
          navigate={~p"/app/#{@current_account}/audit?#{run_trail_query(@run)}"}
          variant={:secondary}
          size={:md}
        >
          View activity
        </.button>
        <.confirm_button
          :if={
            @run.status in [:sent, :running, :pending] and
              Runs.subject_can_cancel_run?(@current_subject)
          }
          id="cancel-run"
          title="Cancel this run?"
          confirm_label="Cancel run"
          on_confirm={JS.push("cancel")}
        >
          <:body>
            <%= if @run.status == :pending do %>
              This queued run has not reached the runner and will be cancelled immediately.
            <% else %>
              The runner is signalled SIGTERM, then SIGKILL if it doesn't stop.
            <% end %>
          </:body>
          Cancel run
        </.confirm_button>
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
            <%!-- wrap: the status meaning rides a <.tooltip>, and scalar truncation
             is `overflow: hidden` — it would clip the bubble away entirely. --%>
            <.meta_field label="Status" wrap>
              <.tooltip text={RunStatuses.meaning(@run.status)} align={:left}>
                <.status_badge status={@run.status} />
              </.tooltip>
            </.meta_field>
            <.meta_field label="Runner">
              <.link
                :if={@run.runner}
                navigate={~p"/app/#{@current_account}/runners/#{@run.runner_id}"}
                class="truncate text-zinc-200 hover:text-brand-300"
              >
                {runner_label(@run.runner)}
              </.link>
              <.removed_runner
                :if={is_nil(@run.runner)}
                runner_id={@run.runner_id}
                class="text-zinc-400"
              />
            </.meta_field>
            <.meta_field label="Dispatched by">
              <% {who, via} = Runs.run_who_via(@run) %>
              <span class="block truncate">
                <span :if={who} class="text-zinc-200">{who}</span>
                <span :if={via} class={if who, do: "text-zinc-400", else: "text-zinc-200"}>
                  {if who, do: "via #{via}", else: via}
                </span>
                <span :if={!who && !via} class="text-zinc-500">—</span>
                <span :if={version = Runs.client_version(@run)} class="text-zinc-400">
                  {version}
                </span>
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
            <%!-- The code is a fact the operator READS, so it stays neutral like
                 every peer value in this row (§7.42). STATUS above owns the
                 verdict; tinting 0 brand and 1 rose told it a second time, in a
                 second vocabulary, right beside the badge that already said it. --%>
            <.meta_field label="Exit code">
              <span :if={is_integer(@run.exit_code)} class="font-mono text-zinc-200">
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
              icon="state.awaiting_human"
              title="Waiting on approval"
            >
              <:body>This run is held until an approver decides.</:body>
              <div class="mt-4">
                <.button
                  tone={:amber}
                  size={:md}
                  class="group"
                  navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
                >
                  View approval <.cta_arrow />
                </.button>
              </div>
            </.event_block>

            <%!-- Cancelled-with-reason — an approver's denial cancels the run and
               writes "approval denied: …" into reason_text; a bare grey badge
               would drop that reason. Driven by the run (not the approval row,
               which a prune may have removed). --%>
            <.event_block
              :if={@run.status == :cancelled and @run.reason_text not in [nil, ""]}
              icon="state.cancelled"
              tone={:rose}
              title="Cancelled"
            >
              <:body><span class="whitespace-pre-wrap">{@run.reason_text}</span></:body>
              <div :if={@approval_request} class="mt-4">
                <.button
                  variant={:secondary}
                  tone={:rose}
                  size={:md}
                  class="group"
                  navigate={~p"/app/#{@current_account}/approvals/#{@approval_request.id}"}
                >
                  View approval <.cta_arrow />
                </.button>
              </div>
            </.event_block>

            <.event_block
              :if={@run.status == :cancelling}
              icon="action.cancel"
              tone={:amber}
              title="Cancellation requested"
            >
              <:body>
                Waiting for the runner to stop and report the final outcome.
              </:body>
            </.event_block>

            <%!-- Terminal cause — only when we got a message back. Titled and
               toned by the status so a failed command never reads as a system
               "Error". --%>
            <.event_block
              :if={@run.error_message}
              icon="state.warning"
              tone={error_block_tone(@run.status)}
              title={RunStatuses.label(@run.status)}
            >
              <:body><span class="whitespace-pre-wrap">{@run.error_message}</span></:body>
            </.event_block>

            <.event_block
              :if={@run.local_audit_failed}
              icon="state.not_dispatched"
              tone={:rose}
              title="Runner audit record incomplete"
            >
              <:body>
                The runner could not persist its terminal event to its local audit journal.
                This run's cloud audit trail and result remain available; inspect the runner's
                audit storage before relying on its local journal.
              </:body>
            </.event_block>

            <%!-- Runner-dropped warning — in flight but its runner's socket is
               gone. Don't fake a terminal status; flag that output may be
               incomplete until it reconnects (or the timeout sweep errors it). --%>
            <.event_block
              :if={@run.status in [:sent, :running, :cancelling] and @runner_connection == :offline}
              icon="state.not_dispatched"
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
              icon="state.not_dispatched"
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
        <section :if={
          @run.reason not in [nil, ""] or @run.evidence not in [nil, ""] or
            @run.expected not in [nil, ""] or show_policy?(@run)
        }>
          <.section_header title="Why" />
          <dl class="space-y-5">
            <div :if={@run.reason && @run.reason != ""}>
              <dt
                :if={not lone_reason?(@run)}
                class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400"
              >
                Reason
              </dt>
              <dd class={[
                "text-sm leading-relaxed text-zinc-200",
                not lone_reason?(@run) && "mt-1"
              ]}>
                {@run.reason}
              </dd>
            </div>
            <%!-- The optional justification chain the agent gave alongside the
                 reason — what it observed, then the outcome it expected. Rendered
                 only when populated (operator runs carry neither). --%>
            <div :if={@run.evidence && @run.evidence != ""}>
              <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                Evidence
              </dt>
              <dd class="mt-1 text-sm leading-relaxed text-zinc-200">
                <span class="whitespace-pre-wrap">{@run.evidence}</span>
              </dd>
            </div>
            <div :if={@run.expected && @run.expected != ""}>
              <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                Expected
              </dt>
              <dd class="mt-1 text-sm leading-relaxed text-zinc-200">
                <span class="whitespace-pre-wrap">{@run.expected}</span>
              </dd>
            </div>
            <div :if={show_policy?(@run)}>
              <%!-- Plain field-key like REASON above — one icon on one label
                   made the pair read as two different kinds of fact. --%>
              <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                Policy
              </dt>
              <%!-- The version rides the policy line itself — a lone "Policy v1"
                   row below read as a second, unexplained fact. --%>
              <dd
                :if={@run.policy_reason && @run.policy_reason != ""}
                class="mt-1 text-sm leading-relaxed text-zinc-200"
              >
                {@run.policy_reason}
                <span :if={is_integer(@run.policy_version)} class="text-xs text-zinc-400">·
                v{@run.policy_version}</span>
              </dd>
              <dd
                :if={matched_rules_label(@run.matched_rules) != "—"}
                class="mt-1.5 text-xs text-zinc-400"
              >
                Matched
                <span class="font-mono text-zinc-400">
                  {matched_rules_label(@run.matched_rules)}
                </span>
              </dd>
            </div>
            <%!-- The human release behind an approved run — who, when, and the
                 note they logged. The record's answer to "who let this run". --%>
            <div :if={@approval_request && @approval_request.status == :approved}>
              <dt class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                Approval
              </dt>
              <dd class="mt-1 text-sm leading-relaxed text-zinc-200">
                Approved by {decider_label(@approval_decider, @approval_request.decided_by_id)}
                <span :if={@approval_request.decided_at} class="text-zinc-400">·
                <.local_time
                  value={@approval_request.decided_at}
                  mode={:forensic}
                  class="tabular-nums"
                /></span>
              </dd>
              <dd
                :if={@approval_request.decision_reason && @approval_request.decision_reason != ""}
                class="mt-1 text-sm leading-relaxed text-zinc-300"
              >
                “{@approval_request.decision_reason}”
              </dd>
              <dd :if={@approval_event_id} class="mt-2">
                <.link
                  navigate={~p"/app/#{@current_account}/audit/#{@approval_event_id}"}
                  class="group inline-flex min-h-10 items-center gap-1 text-xs font-medium text-brand-400 hover:text-brand-300"
                >
                  View audit record <.cta_arrow />
                </.link>
              </dd>
            </div>
          </dl>
        </section>

        <%!-- Self-reported MCP client metadata (correlation with the operator's
             own MDM/EDR/inventory) — labeled as self-reported, never verified
             posture. Renders nothing for non-MCP runs. --%>
        <.mcp_client_metadata metadata={@run.mcp_client_metadata} />

        <%!-- Arguments before output. Operators read the page top→down:
             "what was called → what came back" — all input context above the
             result. The code panels ARE the earned artifact boxes. --%>
        <.code_panel
          :if={@action_args != %{}}
          label="Arguments"
          annotation={@run.args_sha256 && "sha256:#{@run.args_sha256}"}
          max_h="max-h-64"
          code={format_json(@action_args)}
        />

        <%!-- The exact shell command the runner ran. Sensitive arg values are
             redacted runner-side — the audit-grade record of what executed. --%>
        <.code_panel
          :if={@run.executed_command && @run.executed_command != ""}
          label="Executed command"
          annotation={
            if @run.executed_command_truncated,
              do: "truncated · secrets redacted",
              else: "secrets redacted"
          }
          code={@run.executed_command}
        />

        <%!-- Output stream — the main event, in the code_panel ARTIFACT frame
             (island fill + solid zinc-800 edge + 16px title) but hand-rolled:
             it streams chunk spans into the <pre>, which code_panel's static
             `code` attr can't (the one sanctioned hand-roll, design-console-ux §1).
             Hidden for statuses where the panel would just be blank. --%>
        <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — earned: the run terminal frame (the sanctioned hand-rolled code_panel) --%>
        <div
          :if={show_output?(@run, @output_present?, @output_state)}
          data-shot="run-output"
          class="overflow-hidden rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-zinc-800"
        >
          <header class="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-800/70 px-4 py-2">
            <div class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
              <h3 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
                Output
              </h3>
              <%!-- Streaming affordance — a pulsing pill while the run is still
                   in flight, so an idle terminal reads as "more is coming",
                   not "this is the final output". Gone once terminal. --%>
              <span
                :if={@run.status in [:sent, :running, :cancelling]}
                class="inline-flex items-center gap-1 rounded-full bg-brand-500/10 px-2 py-0.5 text-[10px] font-medium text-brand-300 ring-1 ring-brand-500/30"
              >
                <span class="h-1.5 w-1.5 animate-pulse rounded-full bg-brand-400"></span> streaming…
              </span>
              <span
                :if={@output_present?}
                id="run-output-raw-legend"
                class="font-mono text-[11px] text-zinc-400"
              >stderr in rose</span>
            </div>
            <div class="ml-auto flex flex-wrap items-center justify-end gap-2">
              <div
                :if={
                  (@run.status in [:sent, :running, :cancelling] and events_truncated?(@run)) or
                    can_load_earlier?(@run, @more_earlier?)
                }
                id="run-output-raw-tools"
                class="flex items-center gap-3 font-mono text-[11px] text-zinc-400"
              >
                <%!-- Trimmed head: a running run can only show the live window, so it
                     says so; a terminal run offers to page the earlier output back
                     in (gated so backfill never fights the live stream's eviction). --%>
                <span
                  :if={@run.status in [:sent, :running, :cancelling] and events_truncated?(@run)}
                  class="text-amber-400/80"
                >
                  latest {event_window()} chunks · earlier output trimmed
                </span>
                <.button
                  :if={can_load_earlier?(@run, @more_earlier?)}
                  variant={:secondary}
                  size={:sm}
                  phx-click="load_earlier"
                >
                  Load earlier output
                </.button>
              </div>
              <div class="flex shrink-0 items-center gap-2">
                <.segmented_filter_group
                  :if={is_map(@run.structured_output)}
                  label="Output view"
                >
                  <.segmented_filter
                    id="run-output-raw-toggle"
                    active?={true}
                    aria-controls="run-output-raw-view"
                    phx-click={show_raw_output()}
                  >
                    Raw
                  </.segmented_filter>
                  <.segmented_filter
                    id="run-output-json-toggle"
                    active?={false}
                    aria-controls="run-output-json-view"
                    phx-click={show_json_output()}
                  >
                    JSON
                  </.segmented_filter>
                </.segmented_filter_group>
                <.copy_button
                  :if={@output_present?}
                  id="run-output-copy-raw"
                  target="#run-output"
                  aria-live="polite"
                  class="shrink-0 bg-zinc-800 px-2 text-zinc-200 hover:bg-zinc-700"
                >
                  Copy
                </.copy_button>
                <.copy_button
                  :if={is_map(@run.structured_output)}
                  id="run-output-copy-json"
                  target="#run-output-json-view"
                  aria-live="polite"
                  class="hidden shrink-0 bg-zinc-800 px-2 text-zinc-200 hover:bg-zinc-700"
                >
                  Copy
                </.copy_button>
              </div>
            </div>
          </header>
          <%!-- Each chunk already carries its trailing newline (the runner
               streams line-by-line via ReadBytes('\n')), so output is one
               pre-formatted block with chunks as inline spans — they
               concatenate and only the real newlines break lines. Block
               elements or template indentation here would double the
               spacing, since <pre> makes all whitespace significant. --%>
          <div id="run-output-raw-view">
            <%!-- The window hasn't been read yet (dead render) — never flash
                 "No output captured." at a run that may have plenty. --%>
            <.loading_state :if={@output_state == :loading} />

            <%!-- The read failed. "No output captured." here would state a fact
                 about the run from a query that never answered. --%>
            <.callout
              :if={@output_state == :error}
              tone={:rose}
              icon="state.warning"
              title="Couldn't load this run's output"
              class="m-4"
            >
              This is a read error, not an empty result — the run may well have produced output.
              Refresh the page to try again.
            </.callout>

            <%!-- A terminal run that streamed nothing gets one quiet line instead
                 of a 24rem black void (the in-flight min-height stays — more may
                 be coming). --%>
            <p
              :if={
                @output_state == :loaded and not @output_present? and
                  @run.status not in [:sent, :running, :cancelling]
              }
              class="bg-black/60 p-4 font-mono text-xs text-zinc-400"
            >
              No output captured.
            </p>
            <%!-- min-height only while IN FLIGHT (room for chunks to stream into);
                 a terminal run's panel hugs its real output instead of padding a
                 two-line result with a 24rem void. "Load earlier output" prepends
                 into this scroll container; nothing sets `overflow-anchor`, so the
                 browser default (auto) keeps the operator's visible line put while
                 the earlier window is inserted above it. --%>
            <pre
              :if={
                @output_state != :loading and
                  (@output_present? or @run.status in [:sent, :running, :cancelling])
              }
              id="run-output"
              phx-update="stream"
              tabindex="0"
              aria-label="Raw run output"
              class={[
                output_pre_classes(),
                @run.status in [:sent, :running, :cancelling] && "min-h-[24rem]"
              ]}
            ><span
                :for={{id, event} <- @streams.events}
                id={id}
                class={event.stream == "stderr" && "text-rose-300"}
              >{event_chunk(event)}</span></pre>
          </div>
          <pre
            :if={is_map(@run.structured_output)}
            id="run-output-json-view"
            tabindex="0"
            aria-label="Formatted JSON output"
            class={["hidden", output_pre_classes()]}
          >{format_json(@run.structured_output)}</pre>
        </div>
      </div>
    </.console_shell>
    """
  end

  # Whether any attention banner renders — the stack's wrapper must vanish with
  # them, or its empty div would double the wrapper's 48px gap.
  defp attention?(run, approval_request, runner_connection) do
    (run.status == :pending_approval and approval_request != nil) or
      (run.status == :cancelled and run.reason_text not in [nil, ""]) or
      run.status == :cancelling or
      run.error_message != nil or
      run.local_audit_failed or
      (run.status in [:sent, :running, :cancelling, :pending] and runner_connection == :offline)
  end

  # Every message-bearing terminal status is a rose did-not-happen outcome,
  # matching its status badge.
  defp error_block_tone(_status), do: :rose

  defp runner_label(%Emisar.Runners.Runner{name: name}) when is_binary(name) and name != "",
    do: name

  defp runner_label(%Emisar.Runners.Runner{hostname: host}) when is_binary(host) and host != "",
    do: host

  # Only reachable from running-sentence copy (the offline event block) — the
  # Runner meta field renders `<.removed_runner>` for a nil association instead.
  defp runner_label(_), do: "a removed runner"

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

  # The section header already says "Why", so a lone REASON key stacked under it
  # prints one thing twice (§7.43). The keys earn their place the moment a second
  # fact — evidence, the expected outcome, the policy that gated it — joins them.
  defp lone_reason?(run) do
    run.evidence in [nil, ""] and run.expected in [nil, ""] and not show_policy?(run)
  end

  # No point staring at a black terminal for a run that never made it to the
  # runner. Cancelled / denied / awaiting-approval / refused runs never produce
  # output; surfacing the panel just signals "broken".
  #
  # An errored run is the special case: it may have produced output before
  # failing (show it) or none at all — "runner disconnected, result never
  # arrived" — so gate it on whether any output was actually persisted.
  # Everything else (sent / running while streaming, success, failed) gets the
  # panel — an empty one is fine because chunks stream in via PubSub.
  defp show_output?(%{status: status}, _output_present?, _output_state)
       when status in [:cancelled, :denied, :pending_approval, :pending, :refused],
       do: false

  # Until the window is read, "did this run capture anything?" has no answer —
  # the panel renders so the loading and read-failure states have somewhere to
  # live instead of the whole section silently disappearing.
  defp show_output?(_run, _output_present?, output_state) when output_state != :loaded, do: true

  defp show_output?(%{status: :error}, output_present?, :loaded), do: output_present?

  defp show_output?(_run, _output_present?, :loaded), do: true

  defp matched_rules_label(nil), do: "—"
  defp matched_rules_label([]), do: "—"
  defp matched_rules_label(rules) when is_list(rules), do: Enum.join(rules, ", ")

  defp run_trail_query(%Runs.ActionRun{request_id: request_id}),
    do: [request_id: request_id]
end
