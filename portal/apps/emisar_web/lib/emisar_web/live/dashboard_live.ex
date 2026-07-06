defmodule EmisarWeb.DashboardLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys, Approvals, Billing, Catalog, Runners, Runs, SSO}

  @reload_debounce_ms 500

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket) do
      Runs.subscribe_account_runs(account_id)
      Runners.subscribe_connections(account_id)
      Approvals.subscribe_account_approvals(account_id)
      {:ok, load(socket)}
    else
      {:ok, socket |> assign(:page_title, "Dashboard") |> assign(:loading?, true)}
    end
  end

  # A busy fleet emits many account-topic broadcasts per second, and load/1 is
  # ~9 queries — far too heavy to run per message. Coalesce a burst into one
  # reload via a short trailing debounce: the first message arms the timer,
  # later ones are absorbed by the already-scheduled flag.
  def handle_info(%{event: "presence_diff"}, socket), do: {:noreply, schedule_reload(socket)}
  def handle_info({_event, _struct}, socket), do: {:noreply, schedule_reload(socket)}

  def handle_info(:reload_dashboard, socket),
    do: {:noreply, socket |> assign(:reload_scheduled?, false) |> load()}

  # Total catch-all: the badge hooks forward account-topic broadcasts to every
  # authenticated LV, so any other shape must be ignored, not crash.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_reload(socket) do
    if socket.assigns[:reload_scheduled?] do
      socket
    else
      Process.send_after(self(), :reload_dashboard, @reload_debounce_ms)
      assign(socket, :reload_scheduled?, true)
    end
  end

  defp load(socket) do
    account = socket.assigns.current_account
    subject = socket.assigns.current_subject
    # Tolerate {:error, :unauthorized} per tile — a billing_manager (or any
    # future narrow role) still gets a rendering dashboard; tiles it can't
    # read show empty rather than crashing the landing page.
    runners = list_or_empty(Runners.list_all_runners_for_account(subject))
    pending = list_or_empty(Approvals.list_pending_approval_requests(subject))
    api_keys = list_or_empty(ApiKeys.list_api_keys_for_account(subject))

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:loading?, false)
    |> assign(:runners_total, length(runners))
    |> assign(:runners_connected, Enum.count(runners, & &1.online?))
    |> assign(:first_runner_id, first_runner_id(runners))
    |> assign(
      :recent_runs,
      # :api_key so the source badge names the actual agent ("Claude Code -
      # on-call"), same as the runs page — not the generic "MCP / LLM".
      list_or_empty(
        Runs.list_recent_runs(subject, limit: 8, preload: [:runner, :api_key, :requested_by])
      )
    )
    |> assign(:run_stats, unwrap_ok(Runs.fetch_run_stats(subject, hours: 24)))
    |> assign(:pending_approvals, pending)
    |> assign(:agents, agents_summary(api_keys))
    |> assign(:billing, unwrap_ok(Billing.billing_summary(account, subject)))
    |> assign(:team_mfa, team_mfa(account, subject))
    |> assign(:sso_enabled?, SSO.account_has_enabled_provider?(account.id))
    |> assign(:pending_packs_count, Catalog.count_pending_pack_versions(subject))
    |> assign(:can_view_runners?, Runners.subject_can_view_runners?(subject))
    |> assign(:can_view_runs?, Runs.subject_can_view_runs?(subject))
    |> assign(:can_view_agents?, ApiKeys.subject_can_view_api_keys?(subject))
    |> assign_setup_state(subject)
  end

  # First-run: until the account has BOTH connections (or has actually run
  # something), the dashboard's job is onboarding — an ordered checklist to
  # the first gated run — not posture over data that doesn't exist yet.
  # Sequenced, not locked: any step stays clickable in any order.
  defp assign_setup_state(socket, subject) do
    %{runners_total: runners_total, agents: agents, recent_runs: recent_runs} = socket.assigns
    show_setup? = recent_runs == [] and (runners_total == 0 or agents.total == 0)

    socket
    |> assign(:show_setup?, show_setup?)
    |> assign(:can_install_runners?, Runners.subject_can_install_runners?(subject))
    |> assign(:can_issue_agent_key?, ApiKeys.subject_can_issue_quick_key?(subject))
    |> assign(:can_invite_members?, Accounts.subject_can_manage_team?(subject))
  end

  # The LLM-agents pillar's live facts, from the same MCP-key list the agents
  # page shows (revoked + auto-unused already excluded). "Active today" is a
  # key whose last call landed inside 24h — the "is an agent actually using
  # this?" signal; the newest call overall carries the idle case.
  defp agents_summary(api_keys) do
    now = DateTime.utc_now()

    last_call_at =
      api_keys
      |> Enum.map(& &1.last_used_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    %{
      total: length(api_keys),
      active_today:
        Enum.count(api_keys, fn key ->
          key.last_used_at && DateTime.diff(now, key.last_used_at, :hour) < 24
        end),
      last_call_at: last_call_at
    }
  end

  # Team-MFA tile data, or :unavailable when the read fails — so the tile shows
  # "—" rather than a misleading "0 / 0" that reads as an empty team. Uses the
  # account-wide aggregate, NOT a per-page membership tally: a team past the
  # first page read falsely reassuring before. `missing`/`required?` (the tile's
  # tone inputs) are derived from the account-wide totals.
  defp team_mfa(account, subject) do
    case Accounts.team_mfa_stats(account, subject) do
      {:ok, %{total: total, enrolled: enrolled}} ->
        %{
          total: total,
          enrolled: enrolled,
          missing: total - enrolled,
          required?: account.settings.require_mfa
        }

      _ ->
        :unavailable
    end
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(_), do: nil

  defp first_runner_id([runner | _]), do: runner.id
  defp first_runner_id([]), do: nil

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
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
        pending_approvals={@pending_approvals}
        pending_approvals_count={@pending_approvals_count}
        recent_runs={@recent_runs}
        first_runner_id={@first_runner_id}
        run_stats={@run_stats}
        agents={@agents}
        billing={@billing}
        can_manage_billing={Billing.subject_can_manage_billing?(@current_subject)}
        team_mfa={@team_mfa}
        sso_enabled?={@sso_enabled?}
        pending_packs_count={@pending_packs_count}
        current_account={@current_account}
        can_view_runners?={@can_view_runners?}
        can_view_runs?={@can_view_runs?}
        can_view_agents?={@can_view_agents?}
        approvals_decider?={Approvals.subject_can_decide_approval?(@current_subject)}
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
  attr :pending_approvals, :list, required: true
  attr :pending_approvals_count, :integer, required: true
  attr :recent_runs, :list, required: true
  attr :first_runner_id, :string, default: nil
  attr :run_stats, :map, required: true
  attr :agents, :map, required: true
  attr :billing, :map, required: true
  attr :can_manage_billing, :boolean, default: false
  attr :team_mfa, :any, required: true
  attr :sso_enabled?, :boolean, required: true
  attr :pending_packs_count, :integer, default: 0
  attr :current_account, :map, required: true
  attr :can_view_runners?, :boolean, default: true
  attr :can_view_runs?, :boolean, default: true
  attr :can_view_agents?, :boolean, default: true
  attr :approvals_decider?, :boolean, default: false
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
         moment both connections exist (or anything has run). --%>
    <.setup_checklist
      :if={@show_setup?}
      runners_total={@runners_total}
      agents_total={@agents.total}
      team_total={if is_map(@team_mfa), do: @team_mfa.total, else: 0}
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
        current_account={@current_account}
      />
      <.agents_pillar :if={@can_view_agents?} agents={@agents} current_account={@current_account} />
      <.team_pillar
        team_mfa={@team_mfa}
        sso_enabled?={@sso_enabled?}
        current_account={@current_account}
      />
    </div>

    <%!-- The escape hatch, only when it's live: a run held on a human decision
         is an agent blocked right now. Zero pending renders nothing — silence
         is the confirmation. Same content-on-canvas grammar as Recent runs —
         amber stays on the STATUS (the dot, the waiting count), never a boxed
         wash: approvals earn attention, not the centerpiece. --%>
    <section :if={@pending_approvals != []} class="pt-6">
      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <div class="flex min-w-0 flex-wrap items-baseline gap-3">
          <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
            {if @approvals_decider?, do: "Awaiting your approval", else: "Pending approvals"}
          </h2>
          <span class="text-xs tabular-nums text-amber-300">
            {@pending_approvals_count} {if @approvals_decider?, do: "waiting on you", else: "pending"}
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
              <div class="break-all font-mono text-sm text-zinc-200 sm:truncate">
                {request.context["action_id"] || "—"}
              </div>
              <div class="truncate text-xs text-zinc-500">
                <.local_time value={request.requested_at} mode={:relative} />
                <span :if={request.reason && request.reason != ""}>· {request.reason}</span>
              </div>
            </div>
            <.cta_arrow class="h-3.5 w-3.5 shrink-0 text-zinc-600 group-hover:text-brand-400" />
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
          <span :if={@run_stats && @run_stats.total > 0} class="text-xs text-zinc-500">
            <span class="tabular-nums">
              {@run_stats.total} in the last {@run_stats.window_hours}h
            </span>
            <span :if={@run_stats.success_rate} class="tabular-nums">
              · {@run_stats.success_rate}% success
            </span>
            <span :if={@run_stats.failed > 0} class="tabular-nums text-amber-300">
              · {@run_stats.failed} failed
            </span>
          </span>
        </div>
        <%!-- Gated on runs existing — at zero it dead-ended into an equally
             empty page. --%>
        <.link
          :if={@recent_runs != []}
          navigate={~p"/app/#{@current_account}/runs"}
          class="group text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View all <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
      </div>

      <%= if @recent_runs == [] do %>
        <%!-- The "dispatch your first action" step lives HERE — it's the runs
             surface's own zero state. Two shapes: a connected fleet points at
             the first runner's catalog; no fleet points back at the pillars. --%>
        <.empty_state variant={:bare} icon="hero-bolt" title="No runs yet." class="px-5 py-10">
          <%= if @first_runner_id do %>
            Open
            <.link
              navigate={~p"/app/#{@current_account}/runners/#{@first_runner_id}"}
              class="text-brand-400 hover:text-brand-300"
            >
              your runner
            </.link>
            and dispatch an action from its catalog — or ask a connected
            <.link
              navigate={~p"/app/#{@current_account}/agents"}
              class="text-brand-400 hover:text-brand-300"
            >
              agent
            </.link>
            to. Every run lands here, gated and audited.
          <% else %>
            Install a
            <.link
              navigate={~p"/app/#{@current_account}/runners/install"}
              class="text-brand-400 hover:text-brand-300"
            >
              runner
            </.link>
            first — actions dispatch to your own hosts, and every run lands here,
            gated and audited.
          <% end %>
        </.empty_state>
      <% else %>
        <ul class="mt-3 divide-y divide-zinc-800/70 border-t border-zinc-800/70">
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
      <% end %>
    </section>
    """
  end

  # Dashboard tiles want a plain list, not a paginator tuple — they
  # don't show Prev/Next. Treat any unauthorized / unexpected reply as
  # empty so the tile still renders cleanly.
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
  attr :runners_total, :integer, required: true
  attr :agents_total, :integer, required: true
  attr :team_total, :integer, required: true
  attr :current_account, :map, required: true
  attr :can_install_runners?, :boolean, default: false
  attr :can_issue_agent_key?, :boolean, default: false
  attr :can_invite_members?, :boolean, default: false

  defp setup_checklist(assigns) do
    runner_done? = assigns.runners_total > 0
    agent_done? = assigns.agents_total > 0

    assigns =
      assigns
      |> assign(:runner_done?, runner_done?)
      |> assign(:agent_done?, agent_done?)
      |> assign(:done_count, Enum.count([runner_done?, agent_done?], & &1))
      |> assign(:current_step, if(runner_done?, do: 2, else: 1))
      # A concrete, copy-pasteable prompt so a fresh operator sees exactly what
      # to SAY to their agent — the health check reads as obviously safe and maps
      # to real actions (load / memory / disk / failed units).
      |> assign(
        :example_prompt,
        "Check my production runners with emisar — load, memory, disk, and any failed services — and flag anything that needs attention."
      )

    ~H"""
    <section class="pt-2">
      <div class="flex flex-wrap items-baseline gap-3">
        <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
          Get to your first gated run
        </h2>
        <span :if={@done_count > 0} class="text-xs tabular-nums text-brand-300">
          {@done_count} of 2 done
        </span>
      </div>
      <p class="mt-1 max-w-prose text-sm leading-relaxed text-zinc-500">
        Connect a runner and an agent, and any MCP client can run gated, audited actions
        on your own hosts.
      </p>

      <ol class="mt-6 divide-y divide-zinc-800/70 border-t border-zinc-800/70">
        <.setup_step
          number={1}
          done={@runner_done?}
          current={@current_step == 1}
          title="Connect a runner"
          done_text={"#{@runners_total} #{if @runners_total == 1, do: "runner", else: "runners"} connected"}
          action_label="Connect a runner"
          navigate={~p"/app/#{@current_account}/runners/install"}
          done_navigate={~p"/app/#{@current_account}/runners"}
          can_act?={@can_install_runners?}
        >
          The emisar agent on one of your hosts — one curl command, connected in
          about two minutes.
        </.setup_step>
        <.setup_step
          number={2}
          done={@agent_done?}
          current={@current_step == 2}
          title="Connect an LLM agent"
          done_text={"#{@agents_total} #{if @agents_total == 1, do: "agent", else: "agents"} connected"}
          action_label="Connect an agent"
          navigate={~p"/app/#{@current_account}/agents/connect"}
          done_navigate={~p"/app/#{@current_account}/agents"}
          can_act?={@can_issue_agent_key?}
        >
          Give Claude, Cursor, or any MCP client a scoped, revocable key.
        </.setup_step>
        <%!-- Step 3 — the payoff, and the intuition a fresh operator lacks most:
             WHAT do I actually say? Not a tracked toggle (the checklist hands off
             to the pillars the moment anything runs) — a preview of the "now try
             it" moment, carrying a copy-pasteable example prompt. Custom <li>
             rather than <.setup_step>: its body is a quote block, not one line. --%>
        <li class="flex flex-col gap-3 py-5 sm:flex-row sm:items-start sm:gap-5">
          <span class="grid h-7 w-7 shrink-0 place-items-center rounded-full text-xs font-semibold text-zinc-500 ring-1 ring-zinc-800">
            3
          </span>
          <div class="min-w-0 flex-1">
            <span class="font-medium text-zinc-300">Ask your agent to run an action</span>
            <p class="mt-0.5 max-w-prose text-sm leading-relaxed text-zinc-500">
              The payoff: ask your MCP client in plain language and emisar turns it into a
              gated, audited action on your fleet. Try a health check —
            </p>
            <%!-- The example prompt reads as a QUOTE (left rule + italic), not a
                 boxed artifact that would outshout the checklist steps. Copy
                 hands the exact text to paste into the agent. --%>
            <div class="mt-3 flex items-start gap-3 border-l-2 border-brand-500/40 pl-3 sm:max-w-prose">
              <p class="min-w-0 flex-1 text-sm italic leading-relaxed text-zinc-300">
                {@example_prompt}
              </p>
              <.copy_button text={@example_prompt} class="shrink-0">Copy</.copy_button>
            </div>
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
        class="mt-4 text-xs text-zinc-500"
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
            else: "text-zinc-500 ring-zinc-800"
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
          <span :if={@optional} class="text-[11px] text-zinc-600">optional</span>
        </div>
        <p class="mt-0.5 max-w-prose text-sm leading-relaxed text-zinc-500">
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
  attr :current_account, :map, required: true

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
      <:value>
        {@agents.total}<span class="text-2xl text-zinc-500">
          {if @agents.total == 1, do: " agent", else: " agents"}</span>
      </:value>
      <:status>
        <%= cond do %>
          <% @agents.active_today > 0 -> %>
            {@agents.active_today} active today
          <% @agents.last_call_at -> %>
            last call{" "}<.local_time value={@agents.last_call_at} mode={:relative} />
          <% true -> %>
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
      title={"#{@count} pack version#{if @count == 1, do: "", else: "s"} need#{if @count == 1, do: "s", else: ""} trust review"}
      navigate={~p"/app/#{@current_account}/packs"}
      class="mb-4"
    >
      Dispatch is blocked against these until an admin trusts or rejects the new hash.
      <:action>Review pack trust →</:action>
    </.callout>
    """
  end

  # The Team pillar is the team-onboarding nudge, keyed on member count and SSO
  # state: a solo account (just the owner) reports its honest count and pitches
  # inviting the team; once a team exists, it pitches SSO — federated sign-in
  # for everyone; once SSO is LIVE, the forward action is managing the
  # providers, not enabling what's already on. Per-member 2FA posture lives on
  # the Team settings roster, where it's actionable, not as a dashboard stat.

  attr :team_mfa, :any, required: true
  attr :sso_enabled?, :boolean, required: true
  attr :current_account, :map, required: true

  defp team_pillar(%{team_mfa: :unavailable} = assigns) do
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
  defp team_pillar(%{team_mfa: %{total: total}} = assigns) when total <= 1 do
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
      navigate={~p"/app/#{@current_account}/settings/sso"}
    >
      <:value>{@team_mfa.total}<span class="text-2xl text-zinc-500"> members</span></:value>
      <:action>Enable SSO</:action>
    </.pillar>
    """
  end

  defp team_pillar(assigns) do
    ~H"""
    <.pillar
      label="Team"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/settings/sso"}
    >
      <:value>{@team_mfa.total}<span class="text-2xl text-zinc-500"> members</span></:value>
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
      <div
        :if={@status != []}
        class={[
          "mt-2.5 flex items-center gap-1.5 text-[13px]",
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
        class="mt-2.5 flex items-center gap-1 text-[13px] font-medium text-brand-400 transition-colors group-hover:text-brand-300"
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
  defp pillar_status_class(:neutral), do: "text-zinc-500"

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
      <div class="mt-2.5 flex items-center gap-1 text-[13px] font-medium text-brand-400 transition-colors group-hover:text-brand-300">
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
        class="mb-4"
      >
        The next runner that tries to register will get a 402 response and fail to come
        online. Upgrade the plan to add more, or remove an unused runner first.
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
        class="mb-4"
      >
        Heads up — your next install will use the last slot. Upgrade now if you expect to
        add more.
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
