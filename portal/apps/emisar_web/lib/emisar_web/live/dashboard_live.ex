defmodule EmisarWeb.DashboardLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys, Approvals, Billing, Catalog, Runners, Runs, SSO}

  @reload_debounce_ms 500

  def mount(_params, _session, socket) do
    subject = socket.assigns.current_subject

    # A finance-only member (billing_manager) can't read a single dashboard
    # tile — every operational query returns :unauthorized, so recent_runs is
    # always empty and the first-run checklist ("Get to your first gated run")
    # leads a dead-end tutorial for runner onboarding they can't perform. Send
    # them to their home base instead. Capability-based, not role-name, so a
    # future narrow finance role inherits the right landing.
    if finance_only?(subject) do
      {:ok,
       push_navigate(socket, to: ~p"/app/#{socket.assigns.current_account}/settings/billing")}
    else
      account_id = socket.assigns.current_account.id

      if connected?(socket) do
        Runs.subscribe_account_runs(account_id)
        {:ok, load(socket)}
      else
        {:ok, socket |> assign(:page_title, "Dashboard") |> assign(:loading?, true)}
      end
    end
  end

  # Can manage billing but can't even view the operational surfaces: among the
  # roles only billing_manager (owners/admins can view runs; operators/viewers
  # can't manage billing), but stated as capabilities so it can't drift.
  defp finance_only?(subject) do
    Billing.subject_can_manage_billing?(subject) and not Runs.subject_can_view_runs?(subject)
  end

  # Durable domain events and real runner joins/leaves can arrive in bursts.
  # One debounce queue coalesces them, while the queued domains keep unrelated
  # dashboard sections from re-querying. Heartbeat-only Presence metadata is
  # ignored.
  def handle_info(%{event: "presence_diff"} = event, socket) do
    change = Runners.normalize_connection_change(event)

    if Runners.connection_topology_changed?(change) do
      {:noreply, schedule_refresh(socket, :runners)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:run_updated, _run_id}, socket),
    do: {:noreply, schedule_refresh(socket, :runs)}

  def handle_info({:approval_updated, _request_id}, socket),
    do: {:noreply, schedule_refresh(socket, :approvals)}

  def handle_info(:refresh_dashboard, socket) do
    socket =
      socket.assigns.pending_refreshes
      |> Enum.reduce(socket, &refresh_domain/2)
      |> assign(:refresh_scheduled?, false)
      |> assign(:pending_refreshes, [])
      |> assign_current_setup_state()

    {:noreply, socket}
  end

  # Total catch-all: the badge hooks forward account-topic broadcasts to every
  # authenticated LV, so any other shape must be ignored, not crash.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(socket, domain) do
    pending_refreshes = Enum.uniq([domain | socket.assigns.pending_refreshes])
    socket = assign(socket, :pending_refreshes, pending_refreshes)

    if socket.assigns.refresh_scheduled? do
      socket
    else
      Process.send_after(self(), :refresh_dashboard, @reload_debounce_ms)
      assign(socket, :refresh_scheduled?, true)
    end
  end

  defp load(socket) do
    account = socket.assigns.current_account
    subject = socket.assigns.current_subject
    # Tolerate {:error, :unauthorized} per tile — a billing_manager (or any
    # future narrow role) still gets a rendering dashboard rather than a crashed
    # landing page. The raw read results are kept alongside the collapsed lists:
    # an empty list only means "genuinely empty account" when its read verifiably
    # succeeded, so the first-run checklist refuses to activate on unverified
    # emptiness and every tile renders its own read failure instead of a zero.
    api_keys_read = ApiKeys.list_api_keys_for_account(subject)
    api_keys = list_or_empty(api_keys_read)

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:loading?, false)
    |> assign(:refresh_scheduled?, false)
    |> assign(:pending_refreshes, [])
    |> assign(:setup_reads, %{api_keys: read_ok?(api_keys_read)})
    |> assign(:agents, agents_summary(api_keys))
    |> assign(:billing, unwrap_ok(Billing.billing_summary(account, subject)))
    |> assign(:team_security, team_security(subject))
    |> assign(:sso_enabled?, sso_enabled?(subject))
    |> assign(:can_view_runners?, Runners.subject_can_view_runners?(subject))
    |> assign(:can_view_runs?, Runs.subject_can_view_runs?(subject))
    |> assign(:can_view_agents?, ApiKeys.subject_can_view_api_keys?(subject))
    |> assign(:can_view_approvals?, Approvals.subject_can_view_approvals?(subject))
    |> refresh_runners()
    |> refresh_runs()
    |> refresh_approvals()
    |> assign_current_setup_state()
  end

  defp refresh_domain(:runners, socket), do: refresh_runners(socket)
  defp refresh_domain(:runs, socket), do: refresh_runs(socket)
  defp refresh_domain(:approvals, socket), do: refresh_approvals(socket)

  defp refresh_runners(socket) do
    subject = socket.assigns.current_subject
    runners_read = Runners.list_all_runners_for_account(subject, preload: [:online?])
    runners = list_or_empty(runners_read)

    # Only a currently ONLINE runner's advertised actions are dispatchable —
    # catalog rows left behind by an offline runner can't back the checklist's
    # "ask your agent to run an action" step. The readiness projection owns
    # what "online" means (a disabled runner never counts), so the checklist and
    # the fleet pillar can't drift from the runners page.
    readiness = Enum.map(runners, &Runners.runner_readiness/1)
    online_runner_ids = for %{connection: %{state: :online}} = r <- readiness, do: r.runner_id
    actions_read = Catalog.action_risks_for_runner_ids(online_runner_ids, subject)

    actions_advertised? =
      case actions_read do
        {:ok, action_risks} -> map_size(action_risks) > 0
        _ -> false
      end

    socket
    |> assign(:runners_total, length(runners))
    |> assign(:runners_connected, length(online_runner_ids))
    |> assign(:runners_error?, not read_ok?(runners_read))
    |> assign(:actions_advertised?, actions_advertised?)
    |> put_setup_read(:runners, runners_read)
    |> put_setup_read(:actions, actions_read)
  end

  defp refresh_runs(socket) do
    subject = socket.assigns.current_subject

    # :api_key so the source badge names the actual agent ("Claude Code -
    # on-call"), same as the runs page — not the generic "MCP / LLM".
    recent_runs_read =
      Runs.list_recent_runs(subject,
        limit: 8,
        count: false,
        preload: [:runner, :attribution]
      )

    recent_runs = list_or_empty(recent_runs_read)

    socket
    |> assign(:recent_runs, recent_runs)
    |> assign(:recent_runs_error?, not read_ok?(recent_runs_read))
    # The header digest describes the rows below it, so it is derived from the
    # very list that renders — never a second, wider read (§7.36).
    |> assign(:shown_run_stats, Runs.summarize_runs(recent_runs))
    |> put_setup_read(:recent_runs, recent_runs_read)
  end

  defp refresh_approvals(socket) do
    read =
      Approvals.list_pending_approval_requests(socket.assigns.current_subject,
        page: [limit: 5],
        count: false
      )

    socket
    |> assign(:pending_approvals, list_or_empty(read))
    |> assign(:pending_approvals_error?, not read_ok?(read))
  end

  defp put_setup_read(socket, name, result) do
    setup_reads = Map.put(socket.assigns.setup_reads, name, read_ok?(result))
    assign(socket, :setup_reads, setup_reads)
  end

  defp assign_current_setup_state(socket) do
    show_setup? =
      socket.assigns.recent_runs == [] and
        Enum.all?(socket.assigns.setup_reads, fn {_key, ok?} -> ok? end)

    assign_setup_state(socket, socket.assigns.current_subject, show_setup?)
  end

  # First-run: until the account has actually RUN something, the dashboard's job
  # is onboarding — an ordered checklist that runs all the way to the first run
  # (connect a runner, connect an agent, then ask the agent to run one) — not
  # posture over data that doesn't exist yet. It stays through the "both
  # connected, nothing run" phase, where its third step is the run itself, and
  # hands off to the pillars the moment a run lands.
  # Sequenced, not locked: any step stays clickable in any order.
  defp assign_setup_state(socket, subject, show_setup?) do
    socket
    |> assign(:show_setup?, show_setup?)
    |> assign(:can_install_runners?, Runners.subject_can_install_runners?(subject))
    |> assign(:can_issue_agent_key?, ApiKeys.subject_can_issue_quick_key?(subject))
    |> assign(:can_invite_members?, Accounts.subject_can_manage_team?(subject))
  end

  # A read counts as verified only when it returned its ok shape — anything
  # else (an unauthorized tile) is unavailable data, never an empty account.
  defp read_ok?({:ok, _}), do: true
  defp read_ok?({:ok, _, _}), do: true
  defp read_ok?(_), do: false

  # The LLM-agents pillar's live facts, from the same MCP-key list the agents
  # page shows and the same domain reading of it. The pillar counts the keys an
  # agent can still authenticate with (`live`), so an account left holding only
  # revoked or expired credentials falls back to the connect invitation.
  defp agents_summary(api_keys) do
    now = DateTime.utc_now()

    summary =
      api_keys
      |> Enum.map(&ApiKeys.key_facts(&1, now))
      |> ApiKeys.summarize_key_facts()

    %{
      total: summary.live,
      connected: summary.connected,
      active_today: summary.active_today,
      last_call_at: summary.last_call_at
    }
  end

  # The team tile's facts, or :unavailable when the read fails — so it shows "—"
  # rather than a misleading "0 / 0" that reads as an empty team. Accounts owns
  # the account-wide aggregate and the enforcement state; the dashboard never
  # recombines raw settings with a per-page membership tally, which read falsely
  # reassuring on a team past its first page.
  defp team_security(subject) do
    case Accounts.fetch_team_security_facts(subject) do
      {:ok, facts} -> facts
      {:error, _reason} -> :unavailable
    end
  end

  # SSO owns "is this account federated?" — a denied read reads as not connected,
  # which is what the pillar's enable-vs-manage pitch already assumes.
  defp sso_enabled?(subject) do
    case SSO.fetch_account_connection_facts(subject) do
      {:ok, %{enabled?: enabled?}} -> enabled?
      {:error, _reason} -> false
    end
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(_), do: nil

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
      section={:dashboard}
      width={:table}
    >
      <:title>Dashboard</:title>

      <.loading_state :if={@loading?} />

      <.live_dashboard
        :if={not @loading?}
        runners_total={@runners_total}
        runners_connected={@runners_connected}
        runners_error?={@runners_error?}
        actions_advertised?={@actions_advertised?}
        pending_approvals={@pending_approvals}
        pending_approvals_count={@pending_approvals_count}
        pending_approvals_error?={@pending_approvals_error?}
        recent_runs={@recent_runs}
        recent_runs_error?={@recent_runs_error?}
        shown_run_stats={@shown_run_stats}
        agents={@agents}
        billing={@billing}
        can_manage_billing={Billing.subject_can_manage_billing?(@current_subject)}
        team_security={@team_security}
        sso_enabled?={@sso_enabled?}
        pending_packs_count={@pending_packs_count}
        current_account={@current_account}
        can_view_runners?={@can_view_runners?}
        can_view_runs?={@can_view_runs?}
        can_view_agents?={@can_view_agents?}
        can_view_approvals?={@can_view_approvals?}
        show_setup?={@show_setup?}
        can_install_runners?={@can_install_runners?}
        can_issue_agent_key?={@can_issue_agent_key?}
        can_invite_members?={@can_invite_members?}
      />
    </.dashboard_shell>
    """
  end

  # The dashboard is the product's three pillars — Runners, LLM agents, Team
  # (the three main jobs: connect hosts, connect agents, onboard people) — then
  # the escape hatch when it fires, then activity:
  #
  #   1. Banners (plan-at-limit, all-runners-offline) — only when bad
  #   2. The three pillar cards — ALWAYS. Each carries live state for the
  #      operator who has it set up, and becomes the guided create/onboard CTA
  #      at zero. The onboarding checklist IS the pillars' zero states — a new
  #      account reads its three next steps off the same surface a veteran
  #      reads fleet posture from, and cards graduate one by one as steps land.
  #   3. Pending approvals (amber) — only when a decision actually waits.
  #      Approvals is the escape hatch, not the centerpiece: most actions are
  #      read-only and never gate, so this surface earns space only when live.
  #   4. Recent runs — the activity proof, with the 24h digest in its header.
  attr :runners_connected, :integer, required: true
  attr :runners_total, :integer, required: true
  attr :runners_error?, :boolean, required: true
  attr :actions_advertised?, :boolean, required: true
  attr :pending_approvals, :list, required: true
  attr :pending_approvals_count, :integer, required: true
  attr :pending_approvals_error?, :boolean, required: true
  attr :recent_runs, :list, required: true
  attr :recent_runs_error?, :boolean, required: true
  attr :shown_run_stats, :map, required: true
  attr :agents, :map, required: true
  attr :billing, :map, required: true
  attr :can_manage_billing, :boolean, default: false
  attr :team_security, :any, required: true
  attr :sso_enabled?, :boolean, required: true
  attr :pending_packs_count, :integer, default: 0
  attr :current_account, :map, required: true
  attr :can_view_runners?, :boolean, default: true
  attr :can_view_runs?, :boolean, default: true
  attr :can_view_agents?, :boolean, default: true
  attr :can_view_approvals?, :boolean, default: true
  attr :show_setup?, :boolean, default: false
  attr :can_install_runners?, :boolean, default: false
  attr :can_issue_agent_key?, :boolean, default: false
  attr :can_invite_members?, :boolean, default: false

  defp live_dashboard(assigns) do
    ~H"""
    <.subscription_banner status={@billing.subscription_status}>
      <:cta :if={@can_manage_billing}>
        <.button
          variant={:secondary}
          size={:sm}
          navigate={~p"/app/#{@current_account}/settings/billing"}
        >
          Manage billing
        </.button>
      </:cta>
    </.subscription_banner>
    <.plan_limit_banner
      :if={runner_headroom_warn?(@billing)}
      billing={@billing}
      current_account={@current_account}
    />
    <.packs_pending_banner
      :if={@pending_packs_count > 0}
      count={@pending_packs_count}
      current_account={@current_account}
    />

    <%!-- FIRST-RUN: three equal side-by-side CTAs implied three parallel jobs,
         but the product does nothing until a runner AND an agent are connected
         — team is genuinely optional. The zero state is an ordered checklist
         to the first gated run instead; it self-replaces with the pillars the
         moment anything has run. --%>
    <.setup_checklist
      :if={@show_setup?}
      runners_connected={@runners_connected}
      runners_total={@runners_total}
      actions_advertised?={@actions_advertised?}
      agents_connected={@agents.connected}
      agents_total={@agents.total}
      team_total={if is_map(@team_security), do: @team_security.mfa_total, else: 0}
      current_account={@current_account}
      can_install_runners?={@can_install_runners?}
      can_issue_agent_key?={@can_issue_agent_key?}
      can_invite_members?={@can_invite_members?}
    />

    <%!-- The three pillars. Grid order = the onboarding order (host → agent →
         people); a pillar the role can't act on is dropped rather than rendered
         as a dead CTA. --%>
    <div :if={not @show_setup?} class="grid grid-cols-1 gap-8 pt-2 sm:grid-cols-3 sm:gap-10">
      <.runners_pillar
        :if={@can_view_runners?}
        connected={@runners_connected}
        total={@runners_total}
        read_failed?={@runners_error?}
        current_account={@current_account}
      />
      <.agents_pillar :if={@can_view_agents?} agents={@agents} current_account={@current_account} />
      <.team_pillar
        team_security={@team_security}
        sso_enabled?={@sso_enabled?}
        current_account={@current_account}
      />
    </div>

    <%!-- A failed approvals read would otherwise be indistinguishable from the
         zero state below, hiding held actions entirely — so it keeps the
         section and says the queue is unknown. --%>
    <section :if={@can_view_approvals? and @pending_approvals_error?} class="pt-6">
      <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
        Awaiting review
      </h2>
      <.empty_state
        variant={:hint}
        tone={:danger}
        icon="hero-exclamation-triangle"
        title="Couldn't load pending approvals"
        class="mt-3"
      >
        This is a load error, not an empty queue — a held action may be waiting. Refresh the page,
        or open Approvals to check.
      </.empty_state>
    </section>

    <%!-- The escape hatch, only when it's live: a run held on a human decision
         is an agent blocked right now. Zero pending renders nothing — silence
         is the confirmation. Same content-on-canvas grammar as Recent runs —
         amber stays on the STATUS (the dot, the waiting count), never a boxed
         wash: approvals earn attention, not the centerpiece. --%>
    <section :if={@pending_approvals != [] and not @pending_approvals_error?} class="pt-6">
      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <div class="flex min-w-0 flex-wrap items-baseline gap-3">
          <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
            Awaiting review
          </h2>
          <span class="text-xs tabular-nums text-amber-300">
            {@pending_approvals_count} {pending_decision_label(@pending_approvals_count)}
          </span>
        </div>
        <.link
          navigate={~p"/app/#{@current_account}/approvals"}
          class="group text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          Review all <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
      </div>
      <ul class="mt-3 divide-y divide-zinc-800/70 border-t border-zinc-800/70">
        <li :for={request <- Enum.take(@pending_approvals, 5)}>
          <.link
            navigate={~p"/app/#{@current_account}/approvals/#{request.id}"}
            class="group -mx-2 flex items-center gap-3 rounded-md px-2 py-3.5 transition hover:bg-white/[0.04]"
          >
            <.status_dot tone={:amber} size={:md} />
            <div class="min-w-0 flex-1">
              <%!-- The same name the approvals queue shows: reading `action_id`
                   straight off the context printed a bare "—" for every runbook
                   execution, which carries a runbook title instead. --%>
              <div class="break-all font-mono text-sm text-zinc-200 sm:truncate">
                {Approvals.request_name(request) || "—"}
              </div>
              <div class="truncate text-xs text-zinc-400">
                <.local_time
                  id={"dash-pending-#{request.id}"}
                  value={request.requested_at}
                  mode={:relative}
                />
                <span :if={request.reason && request.reason != ""}>· {request.reason}</span>
              </div>
            </div>
            <.cta_arrow class="h-3.5 w-3.5 shrink-0 text-zinc-500 group-hover:text-brand-400" />
          </.link>
        </li>
      </ul>
    </section>

    <%!-- Recent runs — the activity proof, full width, with the 24h digest as
         the header's quiet annotation (a zero window is a non-event, not a
         hero number). No parallel "activity" mirror; that's the audit page. --%>
    <%!-- Recent runs sits DIRECTLY on the canvas — a section title, a quiet
         digest, and borderless rows under a single hairline. The activity feed
         is content, not a framed widget. --%>
    <section :if={@can_view_runs? and not @show_setup?} class="pt-6">
      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <div class="flex min-w-0 flex-wrap items-baseline gap-3">
          <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
            Recent runs
          </h2>
          <%!-- The digest quantifies THESE rows, not a 24h window (§7.36). The
               window read said "5 in the last 24h · 100% success" directly above
               a list that also carried older runs and a cancelled one — a summary
               that describes a different set than the collection it annotates is
               worse than none. `summarize_runs/1` applies the domain's own
               outcome split to the rows being rendered, so the two cannot drift. --%>
          <span :if={@shown_run_stats.total > 0} class="text-xs text-zinc-400">
            <span class="tabular-nums">
              {@shown_run_stats.total} {if @shown_run_stats.total == 1,
                do: "run",
                else: "runs"} shown
            </span>
            <span :if={@shown_run_stats.success_rate} class="tabular-nums">
              · {@shown_run_stats.success_rate}% success
            </span>
            <span :if={@shown_run_stats.failed > 0} class="tabular-nums text-amber-300">
              · {@shown_run_stats.failed} failed
            </span>
          </span>
        </div>
        <%!-- The runs section renders only once a run exists (the checklist owns
             the whole path to the first run), so this always resolves. --%>
        <.link
          navigate={~p"/app/#{@current_account}/runs"}
          class="group text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View all <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
      </div>

      <%!-- The runs read failed, so the empty feed below would claim nothing has
           run. Say the read failed instead. --%>
      <.empty_state
        :if={@recent_runs_error?}
        variant={:hint}
        tone={:danger}
        icon="hero-exclamation-triangle"
        title="Couldn't load recent runs"
        class="mt-3"
      >
        This is a load error, not an empty feed — runs may well exist. Refresh the page, or open
        Runs to check.
      </.empty_state>

      <ul
        :if={not @recent_runs_error?}
        class="mt-3 divide-y divide-zinc-800/70 border-t border-zinc-800/70"
      >
        <li :for={run <- @recent_runs}>
          <.run_row
            run={run}
            show_runner
            show_source
            padding="-mx-2 px-2 py-3.5"
            current_account={@current_account}
          />
        </li>
      </ul>
    </section>
    """
  end

  defp pending_decision_label(1), do: "pending decision"
  defp pending_decision_label(_count), do: "pending decisions"

  # Dashboard tiles want a plain list, not a paginator tuple — they don't show
  # Prev/Next. The empty list is only ever the RENDER shape: every caller pairs
  # it with `read_ok?/1` so a failed read renders its own error state instead of
  # the tile's "nothing waiting".
  defp list_or_empty({:ok, list, _meta}), do: list
  defp list_or_empty({:ok, list}) when is_list(list), do: list
  defp list_or_empty(_), do: []

  # -- The three pillars ------------------------------------------------
  #
  # Naked typography on the canvas — ONE language in every state, so a fresh,
  # a half-set-up, and a full account read as the same design (not a card grid
  # grafted onto the naked stats). LIVE: the big tabular fact + a one-line
  # posture (tone rides the status dot; the line speaks up only for amber/rose
  # — healthy stays quiet). ZERO: the SAME naked shape, the fact slot becoming
  # a guided invitation over a brand action line. Onboarding IS the dashboard's
  # empty state, never a separate wizard that goes stale.

  # -- First-run setup checklist ---------------------------------------

  # The zero state's onboarding: an ORDERED path to the first gated run.
  # Two required connections + one optional invite — sequenced by emphasis
  # (the current step carries the page's one brand fill), never locked.
  # Completion is capability-based, not row-based: a step reads done only when
  # the thing it promises actually works right now — a runner that is online
  # (not a stored row for an offline host), a key an agent has authenticated
  # with (not one merely issued) — so the first-action step never points at a
  # run that cannot succeed.
  attr :runners_connected, :integer, required: true
  attr :runners_total, :integer, required: true
  attr :actions_advertised?, :boolean, required: true
  attr :agents_connected, :integer, required: true
  attr :agents_total, :integer, required: true
  attr :team_total, :integer, required: true
  attr :current_account, :map, required: true
  attr :can_install_runners?, :boolean, default: false
  attr :can_issue_agent_key?, :boolean, default: false
  attr :can_invite_members?, :boolean, default: false

  defp setup_checklist(assigns) do
    runner_done? = assigns.runners_connected > 0
    agent_done? = assigns.agents_connected > 0

    both_connected? = runner_done? and agent_done?

    assigns =
      assigns
      |> assign(:runner_done?, runner_done?)
      |> assign(:agent_done?, agent_done?)
      |> assign(:runner_offline?, not runner_done? and assigns.runners_total > 0)
      |> assign(:agent_unused?, not agent_done? and assigns.agents_total > 0)
      |> assign(:both_connected?, both_connected?)
      # of 3: the third step is the first run itself. done_count tracks the two
      # connections (max 2) — a landed run hides the whole checklist, so it never
      # reads "3 of 3"; the count tops out at "2 of 3", i.e. "set up, now run one".
      |> assign(:done_count, Enum.count([runner_done?, agent_done?], & &1))
      |> assign(
        :current_step,
        cond do
          both_connected? -> 3
          runner_done? -> 2
          true -> 1
        end
      )
      # The exact words to send an agent, so a first-timer isn't left guessing.
      # A read-only health check: it maps to real actions (load / memory / disk /
      # failed units) and can't change anything, so it's a safe first run.
      |> assign(
        :example_prompt,
        "Check my production via emisar — load, memory, disk, and any failed services — and flag anything that needs attention."
      )

    ~H"""
    <section class="pt-2">
      <div class="flex flex-wrap items-baseline gap-3">
        <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
          Get to your first gated run
        </h2>
        <span :if={@done_count > 0} class="text-xs tabular-nums text-brand-300">
          {@done_count} of 3 done
        </span>
      </div>
      <p class="mt-1 max-w-prose text-sm leading-relaxed text-zinc-400">
        <%= if @runner_done? and not @actions_advertised? do %>
          Your runner needs at least one action pack before it can do work. Install a pack from the
          catalog, then ask any MCP client — Claude, Cursor, Codex — to run it. Every call is checked
          against policy first.
        <% else %>
          Two connections, then ask any MCP client — Claude, Cursor, Codex — to run an action on
          your own hosts. Every call is checked against policy first.
        <% end %>
      </p>

      <ol class="mt-6 divide-y divide-zinc-800/70 border-t border-zinc-800/70">
        <.setup_step
          number={1}
          done={@runner_done?}
          current={@current_step == 1}
          title="Connect a runner"
          done_text={"#{@runners_connected} #{if @runners_connected == 1, do: "runner", else: "runners"} connected"}
          action_label="Connect a runner"
          navigate={~p"/app/#{@current_account}/runners/install"}
          done_navigate={~p"/app/#{@current_account}/runners"}
          can_act?={@can_install_runners?}
        >
          <%= if @runner_offline? do %>
            {@runners_total} {if @runners_total == 1, do: "runner is", else: "runners are"} installed
            but offline right now. Bring one back online, or connect another host.
            <.link
              navigate={~p"/app/#{@current_account}/runners"}
              class="font-medium text-brand-400 hover:text-brand-300"
            >See runner status</.link>
          <% else %>
            The emisar agent on one of your hosts — one curl command, connected in
            about two minutes.
          <% end %>
        </.setup_step>
        <.setup_step
          number={2}
          done={@agent_done?}
          current={@current_step == 2}
          title="Connect an LLM agent"
          done_text={"#{@agents_connected} #{if @agents_connected == 1, do: "agent", else: "agents"} connected"}
          action_label="Connect an agent"
          navigate={~p"/app/#{@current_account}/agents/connect"}
          done_navigate={~p"/app/#{@current_account}/agents"}
          can_act?={@can_issue_agent_key?}
        >
          <%= if @agent_unused? do %>
            {@agents_total} {if @agents_total == 1, do: "key is", else: "keys are"} issued, but no
            agent has made an authenticated call yet. Finish the setup in your MCP client — this
            step completes on its first call.
          <% else %>
            Give Claude, Cursor, or any MCP client a scoped, revocable key.
          <% end %>
        </.setup_step>
        <%!-- Step 3 — make the first run possible, then spell out the exact
             words to send. A connected runner with no advertised actions needs
             a pack before the example prompt can work. --%>
        <li class="flex flex-col gap-3 py-5 sm:flex-row sm:items-start sm:gap-5">
          <span class={[
            "grid h-7 w-7 shrink-0 place-items-center rounded-full text-xs font-semibold ring-1",
            if(@both_connected?,
              do: "bg-zinc-800 text-zinc-100 ring-zinc-600",
              else: "text-zinc-400 ring-zinc-800"
            )
          ]}>
            3
          </span>
          <div class="min-w-0 flex-1">
            <%= if @runner_done? and not @actions_advertised? do %>
              <span class={[
                "font-medium",
                if(@both_connected?, do: "text-zinc-100", else: "text-zinc-300")
              ]}>
                Install a pack from the catalog
              </span>
              <p class="mt-0.5 max-w-prose text-sm leading-relaxed text-zinc-400">
                Your runner is connected, but it is not advertising any actions yet. Find the packs
                that match this host, then install one before asking your agent to run an action.
              </p>
              <.code_line
                id="onboarding-suggest-packs"
                label="On the runner"
                value="emisar pack suggest"
                prompt
                class="mt-3 sm:max-w-prose"
              />
              <p class="mt-2 max-w-prose text-sm leading-relaxed text-zinc-400">
                Run one of the
                <code class="font-mono text-xs text-zinc-300">emisar pack install</code>
                commands it prints. <.doc_link href={~p"/packs"}>Browse the pack catalog</.doc_link>
              </p>
            <% else %>
              <span class={[
                "font-medium",
                if(@both_connected?, do: "text-zinc-100", else: "text-zinc-300")
              ]}>
                Ask your agent to run an action
              </span>
              <p class="mt-0.5 max-w-prose text-sm leading-relaxed text-zinc-400">
                Ask in plain English — your agent picks the matching action from the catalog and
                runs it on the host. A read-only health check is a safe first run:
              </p>
              <.code_panel
                id="onboarding-example-prompt"
                label="Example prompt"
                copy
                wrap
                class="mt-3 sm:max-w-prose"
                code={@example_prompt}
              />
            <% end %>
          </div>
        </li>
        <.setup_step
          number={4}
          optional
          done={@team_total > 1}
          done_text={"#{@team_total} members"}
          title="Invite your team"
          action_label="Send an invite"
          navigate={~p"/app/#{@current_account}/settings/team/invite"}
          done_navigate={~p"/app/#{@current_account}/settings/team"}
          can_act?={@can_invite_members?}
        >
          Teammates dispatch and approve under their own audited identity.
        </.setup_step>
      </ol>

      <p
        :if={not (@can_install_runners? or @can_issue_agent_key? or @can_invite_members?)}
        class="mt-4 text-xs text-zinc-400"
      >
        Setup needs an operator role or above — ask an owner or admin to connect the
        first runner and agent.
      </p>
    </section>
    """
  end

  attr :number, :integer, required: true
  attr :done, :boolean, required: true
  attr :current, :boolean, default: false
  attr :optional, :boolean, default: false
  attr :title, :string, required: true
  attr :done_text, :string, required: true
  attr :action_label, :string, required: true
  attr :navigate, :string, required: true
  attr :done_navigate, :string, required: true
  attr :can_act?, :boolean, default: false
  slot :inner_block, required: true

  defp setup_step(assigns) do
    ~H"""
    <li class="flex flex-col gap-3 py-5 sm:flex-row sm:items-center sm:gap-5">
      <%!-- Marker: brand check once done; the current step's number reads
           brightest; later steps recede. --%>
      <span
        :if={@done}
        class="grid h-7 w-7 shrink-0 place-items-center rounded-full bg-brand-500/15 text-brand-300 ring-1 ring-brand-500/30"
      >
        <.icon name="hero-check" class="h-4 w-4" />
      </span>
      <span
        :if={not @done}
        class={[
          "grid h-7 w-7 shrink-0 place-items-center rounded-full text-xs font-semibold ring-1",
          if(@current,
            do: "bg-zinc-800 text-zinc-100 ring-zinc-600",
            else: "text-zinc-400 ring-zinc-800"
          )
        ]}
      >
        {@number}
      </span>

      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline gap-2">
          <span class={[
            "font-medium",
            cond do
              @done -> "text-zinc-400"
              @current -> "text-zinc-100"
              true -> "text-zinc-300"
            end
          ]}>
            {@title}
          </span>
          <span :if={@optional} class="text-[11px] text-zinc-400">optional</span>
        </div>
        <p class="mt-0.5 max-w-prose text-sm leading-relaxed text-zinc-400">
          <%= if @done do %>
            {@done_text}
          <% else %>
            {render_slot(@inner_block)}
          <% end %>
        </p>
      </div>

      <div class="shrink-0 sm:pl-4">
        <.link
          :if={@done}
          navigate={@done_navigate}
          class="group text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
        <%!-- ONE brand fill on the page: the current step's action. Later
             steps stay clickable, quietly (sequenced, not locked). --%>
        <.button :if={not @done and @can_act? and @current} navigate={@navigate} size={:md}>
          {@action_label}
        </.button>
        <.button
          :if={not @done and @can_act? and not @current}
          navigate={@navigate}
          variant={:secondary}
          size={:md}
        >
          {@action_label}
        </.button>
      </div>
    </li>
    """
  end

  attr :connected, :integer, required: true
  attr :total, :integer, required: true
  attr :read_failed?, :boolean, required: true
  attr :current_account, :map, required: true

  # A failed fleet read leaves the counts at 0, which would pitch "Put your
  # first host online" at an account whose hosts are running — say the read
  # failed instead, in the Team pillar's grammar.
  defp runners_pillar(%{read_failed?: true} = assigns) do
    ~H"""
    <.pillar
      label="Runners"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/runners"}
    >
      <:value>—</:value>
      <:status>Couldn't load your fleet</:status>
    </.pillar>
    """
  end

  defp runners_pillar(%{total: 0} = assigns) do
    ~H"""
    <.pillar_cta
      label="Runners"
      title="Put your first host online"
      cta="One curl command"
      navigate={~p"/app/#{@current_account}/runners/install"}
    />
    """
  end

  defp runners_pillar(assigns) do
    ~H"""
    <.pillar
      label="Runners"
      tone={runners_tone(@connected, @total)}
      status_tone={runners_status_tone(@connected, @total)}
      navigate={~p"/app/#{@current_account}/runners"}
    >
      <:value>
        {@connected}<span class="text-2xl text-zinc-500"> / {@total} connected</span>
      </:value>
      <:status>{runners_status(@connected, @total)}</:status>
    </.pillar>
    """
  end

  # connected/total are :integer attrs, but Elixir 1.20's type checker won't
  # carry that into the template and flags `<`/`>` there as a struct
  # comparison. Guard clauses use term ordering (no such warning) and read
  # more clearly. A partial outage is an amber nudge, ALL offline a rose hard
  # stop — the posture line IS the whole offline alarm now (no banner). No " →"
  # in the string: the pillar appends the animated <.cta_arrow> for any attention
  # status.
  defp runners_status(0, _total), do: "All runners offline"

  defp runners_status(connected, total) when connected < total,
    do: "#{total - connected} offline"

  defp runners_status(_connected, _total), do: "All connected"

  # Tiles wear brand (healthy) or neutral — never amber: two amber tiles at
  # once read as an alarm wall and spend amber's attention value. The STATUS
  # LINE carries the amber; a rose tile is reserved for a hard lockout (Team).
  defp runners_tone(connected, total) when connected < total, do: :neutral
  defp runners_tone(_connected, _total), do: :brand

  # ALL offline is a hard stop — nothing can dispatch — so the posture line goes
  # ROSE, not the amber a partial outage (some runners still up) gets. That rose
  # line IS the dashboard's whole offline alarm; no separate banner stacks on it.
  defp runners_status_tone(0, _total), do: :rose
  defp runners_status_tone(connected, total) when connected < total, do: :amber
  defp runners_status_tone(_connected, _total), do: :neutral

  attr :agents, :map, required: true
  attr :current_account, :map, required: true

  defp agents_pillar(%{agents: %{total: 0}} = assigns) do
    ~H"""
    <.pillar_cta
      label="LLM agents"
      title="Connect any MCP client"
      cta="Mint a scoped key"
      navigate={~p"/app/#{@current_account}/agents"}
    />
    """
  end

  defp agents_pillar(assigns) do
    ~H"""
    <.pillar
      label="LLM agents"
      tone={if @agents.active_today > 0, do: :brand, else: :neutral}
      navigate={~p"/app/#{@current_account}/agents"}
    >
      <%!-- The bare agent count is just entities; the operational fact is how
           many acted today, so it leads the metric in the Runners "N / M"
           grammar and the status line carries the non-redundant recency. --%>
      <:value>
        {@agents.active_today}<span class="text-2xl text-zinc-500"> / {@agents.total} active today</span>
      </:value>
      <:status>
        <%= if @agents.last_call_at do %>
          last call{" "}<.local_time value={@agents.last_call_at} mode={:relative} />
        <% else %>
          No calls yet
        <% end %>
      </:status>
    </.pillar>
    """
  end

  attr :count, :integer, required: true
  attr :current_account, :map, required: true

  defp packs_pending_banner(assigns) do
    ~H"""
    <.callout
      tone={:amber}
      icon="hero-shield-exclamation"
      title={"#{@count} pack version#{if @count == 1, do: "", else: "s"} need#{if @count == 1, do: "s", else: ""} a decision"}
      navigate={~p"/app/#{@current_account}/packs"}
      class="mb-10"
    >
      Dispatch is blocked against these until an admin reviews the advertised hash or
      resolves the retired version.
      <%!-- The whole callout is the link — this line is its affordance, in the
           pillar CTA grammar (quiet brand + the house arrow), never a bare
           16px text row. --%>
      <:action>
        <span class="flex items-center gap-1 text-[13px] font-medium text-brand-400 transition-colors group-hover:text-brand-300">
          Review packs <.cta_arrow class="h-3.5 w-3.5" />
        </span>
      </:action>
    </.callout>
    """
  end

  # The Team pillar is the team-onboarding nudge, keyed on member count and SSO
  # state: a solo account (just the owner) reports its honest count and pitches
  # inviting the team; once a team exists, it pitches SSO — federated sign-in
  # for everyone; once SSO is LIVE, the forward action is managing the
  # providers, not enabling what's already on. Per-member 2FA posture lives on
  # the Team settings roster, where it's actionable, not as a dashboard stat.

  attr :team_security, :any, required: true
  attr :sso_enabled?, :boolean, required: true
  attr :current_account, :map, required: true

  defp team_pillar(%{team_security: :unavailable} = assigns) do
    ~H"""
    <.pillar
      label="Team"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/settings/team"}
    >
      <:value>—</:value>
      <:status>Couldn't load team data</:status>
    </.pillar>
    """
  end

  # Solo (just the owner): the honest member count, with inviting the team as the
  # forward action. SSO is premature until there IS a team to federate, so it
  # waits for the next state.
  defp team_pillar(%{team_security: %{mfa_total: total}} = assigns) when total <= 1 do
    ~H"""
    <.pillar
      label="Team"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/settings/team/invite"}
    >
      <:value>1<span class="text-2xl text-zinc-500"> member</span></:value>
      <:action>Invite team members</:action>
    </.pillar>
    """
  end

  # A real team exists — the valuable next step is federated identity: pitch
  # enabling SSO until a connection is live, then managing the providers
  # (nudging "Enable" at an account already on SSO reads as a bug). The
  # settings page owns the plan/permission gate either way.
  defp team_pillar(%{sso_enabled?: false} = assigns) do
    ~H"""
    <.pillar
      label="Team"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/settings/team"}
    >
      <:value>{@team_security.mfa_total}<span class="text-2xl text-zinc-500"> members</span></:value>
      <:action>Enable SSO</:action>
    </.pillar>
    """
  end

  defp team_pillar(assigns) do
    ~H"""
    <.pillar
      label="Team"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/settings/team"}
    >
      <:value>{@team_security.mfa_total}<span class="text-2xl text-zinc-500"> members</span></:value>
      <:action>Manage SSO providers</:action>
    </.pillar>
    """
  end

  # -- The pillar card shape --------------------------------------------

  attr :label, :string, required: true
  attr :tone, :atom, required: true, values: [:brand, :rose, :neutral]
  attr :status_tone, :atom, default: :neutral, values: [:amber, :rose, :neutral]
  attr :navigate, :string, required: true
  slot :value, required: true
  # A live pillar carries EITHER a posture line (`:status` — dot + fact, tinted
  # by status_tone) OR a forward action (`:action` — a quiet brand link with the
  # house arrow). Runners/LLM report posture; Team nudges an action.
  slot :status
  slot :action

  defp pillar(assigns) do
    ~H"""
    <%!-- A LIVE pillar is naked typography on the canvas — no box. The number
         is the design: label row, a big display figure, a one-line posture.
         Containment is reserved for the CTA state (an invitation earns a box);
         a healthy stat doesn't. --%>
    <%!-- The WHOLE group is one link, and its hover is the house wash
         (bg-white/[0.04]) and NOTHING else — identical to a table row. No
         brand tint on the figure: emerald is the SEMANTIC accent (pass /
         healthy), not a hover decoration for a neutral stat, and the table
         never tints content on hover either. -m/p keeps the resting layout
         identical while the wash breathes past the text. No create link up
         here — the band is pure posture; the pillar's page owns the real
         Add/Connect/Invite action. --%>
    <.link
      navigate={@navigate}
      class="group -m-3 flex flex-col rounded-lg p-3 transition hover:bg-white/[0.04]"
    >
      <span class="truncate text-sm font-medium text-zinc-400">
        {@label}
      </span>
      <div class="mt-3 font-display text-4xl font-semibold leading-none tracking-[-0.03em] text-zinc-50 tabular-nums">
        {render_slot(@value)}
      </div>
      <%!-- The pillar's LAST line sits on one baseline across the whole row —
           bottom-pinned in an equal-height (grid-stretched) column, so the
           agents pillar's extra posture line can't push its forward action a
           row below its siblings'. Here that's the posture line only when no
           action follows it; `pt-` preserves the resting 10px gap once the
           auto margin collapses in the tallest pillar. --%>
      <div
        :if={@status != []}
        class={[
          "flex items-center gap-1.5 text-[13px]",
          if(@action == [], do: "mt-auto pt-2.5", else: "mt-2.5"),
          pillar_status_class(@status_tone)
        ]}
      >
        <.status_dot tone={pillar_dot_tone(@tone, @status_tone)} />
        {render_slot(@status)}
        <%!-- An attention status (amber/rose) is a "go look" — the animated
             arrow (inherits the line's tone) nudges on the pillar hover; a
             healthy/neutral line has nowhere urgent to go, so no arrow. --%>
        <.cta_arrow :if={@status_tone != :neutral} class="h-3.5 w-3.5" />
      </div>
      <%!-- The action line reads as the pillar's affordance — quiet brand,
           the house arrow — since the WHOLE pillar is the link to its target.
           A tile action is a LINK, never a button chip: the button chrome
           reads as a form submit, and the whole tile is already the link. --%>
      <div
        :if={@action != []}
        class="mt-auto flex items-center gap-1 pt-2.5 text-[13px] font-medium text-brand-400 transition-colors group-hover:text-brand-300"
      >
        {render_slot(@action)}
        <.cta_arrow />
      </div>
    </.link>
    """
  end

  # The pillar's overall posture drives the quiet brand dot (healthy only);
  # the STATUS LINE alone carries amber/rose text, so attention tint never
  # stacks into an alarm wall — a healthy pillar stays quiet (no green shout).
  defp pillar_status_class(:amber), do: "text-amber-300"
  defp pillar_status_class(:rose), do: "text-rose-300"
  defp pillar_status_class(:neutral), do: "text-zinc-400"

  # Every posture line leads with its tone dot — attention lines wear their
  # amber/rose, a healthy pillar the quiet brand dot, an idle one neutral.
  defp pillar_dot_tone(_tile, status) when status != :neutral, do: status
  defp pillar_dot_tone(:brand, _status), do: :brand
  defp pillar_dot_tone(_tile, _status), do: :neutral

  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :cta, :string, required: true
  attr :navigate, :string, required: true

  # The pillar's ZERO state — the SAME naked shape as a live stat (label ·
  # headline · sub-line, whole group one link, the house hover wash), so a fresh
  # or half-set-up account reads as the same design, not a card grid grafted
  # onto the naked stats. No box, no icon — emerald lives only on the action
  # line, the one bit of energy a to-do step earns.
  #
  # Each line carries a DISTINCT payload — the fix for "LLM agents / Connect an
  # LLM agent / Connect an agent" saying one thing three times:
  #   label    = the noun (what is this?)          — "LLM agents"
  #   headline = the outcome (what do I get?)      — "Connect any MCP client"
  #   action   = verb + mechanism (what's the cost?) — "Mint a scoped key →"
  # The headline never repeats the label's noun; the action names the effort in
  # the destination page's own words, so the promise is fulfilled verbatim.
  defp pillar_cta(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group -m-3 flex flex-col rounded-lg p-3 transition hover:bg-white/[0.04]"
    >
      <span class="truncate text-sm font-medium text-zinc-400">{@label}</span>
      <%!-- The invitation sits in a figure-height (min-h 2.25rem) box, bottom-
           aligned, so its baseline meets the big stat figure's baseline in a
           mixed row; min- (not fixed h-9) lets a wrapped headline grow down on
           narrow columns instead of spilling up into the label. --%>
      <div class="mt-3 flex min-h-[2.25rem] items-end font-display text-xl font-semibold leading-snug tracking-[-0.01em] text-zinc-100">
        {@title}
      </div>
      <%!-- Bottom-pinned like the live pillar's action line, so a mixed row of
           CTA and live pillars still lands every forward action on one baseline. --%>
      <div class="mt-auto flex items-center gap-1 pt-2.5 text-[13px] font-medium text-brand-400 transition-colors group-hover:text-brand-300">
        {@cta}
        <.cta_arrow />
      </div>
    </.link>
    """
  end

  attr :billing, :map, required: true
  attr :current_account, :map, required: true

  defp plan_limit_banner(assigns) do
    headroom = Emisar.Billing.headroom(assigns.billing, :runners)
    assigns = assign(assigns, :headroom, headroom)

    ~H"""
    <%= if @headroom == :at_limit do %>
      <.callout
        tone={:rose}
        icon="hero-exclamation-triangle"
        title={"You're at your runner limit (#{@billing.runner_count} of #{@billing.runner_limit})."}
        class="mb-10"
      >
        The next runner that tries to register will get a 402 response and fail to come
        online. Upgrade the plan to add more, or remove an unused runner first.
        <.doc_link href={~p"/docs/limits"}>Plan limits docs</.doc_link>
        <:action>
          <.button
            variant={:secondary}
            size={:sm}
            navigate={~p"/app/#{@current_account}/settings/billing"}
          >
            See plans
          </.button>
        </:action>
      </.callout>
    <% else %>
      <.callout
        tone={:amber}
        icon="hero-exclamation-triangle"
        title={"One runner slot left on the #{String.capitalize(@billing.plan)} plan (#{@billing.runner_count} of #{@billing.runner_limit})."}
        class="mb-10"
      >
        Heads up — your next install will use the last slot. Upgrade now if you expect to
        add more. <.doc_link href={~p"/docs/limits"}>Plan limits docs</.doc_link>
        <:action>
          <.button
            variant={:secondary}
            size={:sm}
            navigate={~p"/app/#{@current_account}/settings/billing"}
          >
            See plans
          </.button>
        </:action>
      </.callout>
    <% end %>
    """
  end

  defp runner_headroom_warn?(billing) do
    Emisar.Billing.headroom(billing, :runners) in [:warning, :at_limit]
  end
end
