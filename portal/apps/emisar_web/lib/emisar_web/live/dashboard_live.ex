defmodule EmisarWeb.DashboardLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys, Approvals, Billing, Catalog, Runners, Runs}

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
      list_or_empty(Runs.list_recent_runs(subject, limit: 8, preload: [:runner, :api_key]))
    )
    |> assign(:run_stats, unwrap_ok(Runs.fetch_run_stats(subject, hours: 24)))
    |> assign(:pending_approvals, pending)
    |> assign(:agents, agents_summary(api_keys))
    |> assign(:billing, unwrap_ok(Billing.billing_summary(account, subject)))
    |> assign(:team_mfa, team_mfa(account, subject))
    |> assign(:pending_packs_count, Catalog.count_pending_pack_versions(subject))
    |> assign(:can_view_runners?, Runners.subject_can_view_runners?(subject))
    |> assign(:can_view_runs?, Runs.subject_can_view_runs?(subject))
    |> assign(:can_view_agents?, ApiKeys.subject_can_view_api_keys?(subject))
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
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:dashboard}
      width={:full}
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
        pending_packs_count={@pending_packs_count}
        current_account={@current_account}
        can_view_runners?={@can_view_runners?}
        can_view_runs?={@can_view_runs?}
        can_view_agents?={@can_view_agents?}
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
  attr :pending_packs_count, :integer, default: 0
  attr :current_account, :map, required: true
  attr :can_view_runners?, :boolean, default: true
  attr :can_view_runs?, :boolean, default: true
  attr :can_view_agents?, :boolean, default: true

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
    <.runners_offline_banner
      :if={@runners_total > 0 and @runners_connected == 0}
      current_account={@current_account}
    />
    <.packs_pending_banner
      :if={@pending_packs_count > 0}
      count={@pending_packs_count}
      current_account={@current_account}
    />

    <%!-- The three pillars. Grid order = the onboarding order (host → agent →
         people); a pillar the role can't act on is dropped rather than rendered
         as a dead CTA. --%>
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <.runners_pillar
        :if={@can_view_runners?}
        connected={@runners_connected}
        total={@runners_total}
        current_account={@current_account}
      />
      <.agents_pillar :if={@can_view_agents?} agents={@agents} current_account={@current_account} />
      <.team_pillar team_mfa={@team_mfa} current_account={@current_account} />
    </div>

    <%!-- The escape hatch, only when it's live: a run held on a human decision
         is an agent blocked right now. Zero pending renders nothing — silence
         is the confirmation. --%>
    <div :if={@pending_approvals != []} class="mt-6">
      <.attention_panel
        icon="hero-hand-raised"
        title="Awaiting your approval"
        count={@pending_approvals_count}
        href={~p"/app/#{@current_account}/approvals"}
        cta="Review all"
      >
        <ul class="divide-y divide-amber-500/10">
          <li :for={request <- Enum.take(@pending_approvals, 5)}>
            <.link
              navigate={~p"/app/#{@current_account}/approvals/#{request.id}"}
              class="flex items-center justify-between gap-3 py-2.5 text-sm hover:opacity-90"
            >
              <div class="min-w-0">
                <div class="break-all font-mono text-amber-100 sm:truncate">
                  {request.context["action_id"] || "—"}
                </div>
                <div class="truncate text-xs text-amber-200/60">
                  <.local_time value={request.requested_at} mode={:relative} />
                  <span :if={request.reason && request.reason != ""}>· {request.reason}</span>
                </div>
              </div>
              <.icon name="hero-arrow-right" class="h-4 w-4 shrink-0 text-amber-300/70" />
            </.link>
          </li>
        </ul>
      </.attention_panel>
    </div>

    <%!-- Recent runs — the activity proof, full width, with the 24h digest as
         the header's quiet annotation (a zero window is a non-event, not a
         hero number). No parallel "activity" mirror; that's the audit page. --%>
    <.panel :if={@can_view_runs?} variant={:split} title="Recent runs" class="mt-8">
      <:annotation :if={@run_stats && @run_stats.total > 0}>
        <span class="tabular-nums">{@run_stats.total} in the last {@run_stats.window_hours}h</span>
        <span :if={@run_stats.success_rate} class="tabular-nums">
          · {@run_stats.success_rate}% success
        </span>
        <span :if={@run_stats.failed > 0} class="tabular-nums text-amber-300">
          · {@run_stats.failed} failed
        </span>
      </:annotation>
      <:actions>
        <.link
          navigate={~p"/app/#{@current_account}/runs"}
          class="text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View all <.icon name="hero-arrow-right" class="ml-0.5 h-3 w-3" />
        </.link>
      </:actions>

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
              navigate={~p"/app/#{@current_account}/settings/agents"}
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
        <ul class="divide-y divide-zinc-900">
          <li :for={run <- @recent_runs}>
            <.run_row run={run} show_runner show_source current_account={@current_account} />
          </li>
        </ul>
      <% end %>
    </.panel>
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
  # One card shape, two states. LIVE: an icon tile wearing the pillar's
  # semantic posture, the big tabular fact, a one-line status, and the
  # pillar's create action quiet in the corner. ZERO: the same card becomes
  # the guided CTA (brand-tinted, whole card is the link) — so onboarding is
  # the dashboard's natural empty state, not a separate wizard that goes
  # stale. Posture tone lives on the TILE; status text speaks up only for
  # amber/rose (healthy stays quiet — silence is the confirmation).

  attr :connected, :integer, required: true
  attr :total, :integer, required: true
  attr :current_account, :map, required: true

  defp runners_pillar(%{total: 0} = assigns) do
    ~H"""
    <.pillar_cta
      icon="hero-cpu-chip"
      label="Runners"
      title="Install your first runner"
      body="One curl one-liner on any Linux or macOS host — it dials out, registers, and shows up here."
      cta="Open the install wizard"
      navigate={~p"/app/#{@current_account}/runners/install"}
    />
    """
  end

  defp runners_pillar(assigns) do
    ~H"""
    <.pillar
      icon="hero-cpu-chip"
      label="Runners"
      tone={runners_tone(@connected, @total)}
      status_tone={runners_status_tone(@connected, @total)}
      navigate={~p"/app/#{@current_account}/runners"}
      action_label="Add runner"
      action_navigate={~p"/app/#{@current_account}/runners/install"}
    >
      <:value>
        {@connected}<span class="text-xl text-zinc-500"> / {@total} online</span>
      </:value>
      <:status>{runners_status(@connected, @total)}</:status>
    </.pillar>
    """
  end

  # connected/total are :integer attrs, but Elixir 1.20's type checker won't
  # carry that into the template and flags `<`/`>` there as a struct
  # comparison. Guard clauses use term ordering (no such warning) and read
  # more clearly. Offline wears amber everywhere — one fact, one tone (the
  # loud all-offline BANNER carries the escalation, not this pillar).
  defp runners_status(0, _total), do: "All runners offline →"

  defp runners_status(connected, total) when connected < total,
    do: "#{total - connected} offline →"

  defp runners_status(_connected, _total), do: "All connected"

  # Tiles wear brand (healthy) or neutral — never amber: two amber tiles at
  # once read as an alarm wall and spend amber's attention value. The STATUS
  # LINE carries the amber; a rose tile is reserved for a hard lockout (Team).
  defp runners_tone(connected, total) when connected < total, do: :neutral
  defp runners_tone(_connected, _total), do: :brand

  defp runners_status_tone(connected, total) when connected < total, do: :amber
  defp runners_status_tone(_connected, _total), do: :neutral

  attr :agents, :map, required: true
  attr :current_account, :map, required: true

  defp agents_pillar(%{agents: %{total: 0}} = assigns) do
    ~H"""
    <.pillar_cta
      icon="hero-sparkles"
      label="LLM agents"
      title="Connect an LLM agent"
      body="Pick Claude Code, Cursor, or any MCP client — we mint a scoped key and a paste-ready snippet."
      cta="Connect an agent"
      navigate={~p"/app/#{@current_account}/settings/agents"}
    />
    """
  end

  defp agents_pillar(assigns) do
    ~H"""
    <.pillar
      icon="hero-sparkles"
      label="LLM agents"
      tone={if @agents.active_today > 0, do: :brand, else: :neutral}
      navigate={~p"/app/#{@current_account}/settings/agents"}
      action_label="Connect"
      action_navigate={~p"/app/#{@current_account}/settings/agents"}
    >
      <:value>
        {@agents.total}<span class="text-xl text-zinc-500">
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

  # -- Attention panel ------------------------------------------------

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :href, :string, required: true
  attr :cta, :string, required: true
  slot :inner_block, required: true

  # Amber "needs a decision" panel (pending approvals — the only attention panel
  # on the dashboard). The slot content carries its own matching amber tone.
  defp attention_panel(assigns) do
    ~H"""
    <section class="rounded-xl bg-amber-500/[0.06] p-5 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.04)] ring-1 ring-amber-500/30">
      <header class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name={@icon} class="h-4 w-4 text-amber-300" />
          <h3 class="text-sm font-semibold text-amber-100">
            {@title}
            <.count_badge count={@count} tone={:amber} class="ml-1" />
          </h3>
        </div>
        <.link navigate={@href} class="text-xs font-medium text-amber-200 hover:text-amber-100">
          {@cta} →
        </.link>
      </header>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :current_account, :map, required: true

  defp runners_offline_banner(assigns) do
    ~H"""
    <.offline_notice severity={:critical} title="All runners offline" class="mb-4">
      No actions can be dispatched until a runner reconnects. Check the runner
      host's logs or the systemd/launchd unit.
      <:action>
        <.button
          variant={:secondary}
          tone={:rose}
          size={:sm}
          navigate={~p"/app/#{@current_account}/runners"}
        >
          View runners →
        </.button>
      </:action>
    </.offline_notice>
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

  # The Team pillar reports "who's in, and is the people-attack surface
  # tight?" — member count as the fact, 2FA posture as the status:
  #
  #   * rose  — account enforces MFA AND someone hasn't enrolled.
  #             They literally can't sign in until they fix it.
  #   * amber — MFA is optional but at least one teammate hasn't
  #             enrolled. Soft nudge.
  #   * brand — every member is enrolled. Quiet "you're good".
  #
  # A solo account (just you) renders the invite CTA instead — onboarding
  # the team IS this pillar's zero state.

  attr :team_mfa, :any, required: true
  attr :current_account, :map, required: true

  defp team_pillar(%{team_mfa: :unavailable} = assigns) do
    ~H"""
    <.pillar
      icon="hero-user-group"
      label="Team"
      tone={:neutral}
      navigate={~p"/app/#{@current_account}/settings/team"}
    >
      <:value>—</:value>
      <:status>Couldn't load team data</:status>
    </.pillar>
    """
  end

  defp team_pillar(%{team_mfa: %{total: total}} = assigns) when total <= 1 do
    ~H"""
    <.pillar_cta
      icon="hero-user-group"
      label="Team"
      title="Invite your team"
      body="Teammates get their own sign-in, role, and audit trail — no shared credentials."
      cta="Invite a teammate"
      navigate={~p"/app/#{@current_account}/settings/team/invite"}
    />
    """
  end

  defp team_pillar(assigns) do
    posture =
      cond do
        assigns.team_mfa.missing == 0 -> :enrolled
        assigns.team_mfa.required? -> :lockout
        true -> :nudge
      end

    assigns = assign(assigns, :posture, posture)

    ~H"""
    <.pillar
      icon="hero-user-group"
      label="Team"
      tone={team_tile_tone(@posture)}
      status_tone={team_status_tone(@posture)}
      navigate={~p"/app/#{@current_account}/settings/team"}
      action_label="Invite"
      action_navigate={~p"/app/#{@current_account}/settings/team/invite"}
    >
      <:value>
        {@team_mfa.total}<span class="text-xl text-zinc-500"> members</span>
      </:value>
      <:status>{team_status(@posture, @team_mfa)}</:status>
    </.pillar>
    """
  end

  # Enrolled = quiet brand; a hard lockout (MFA required and someone can't sign
  # in) earns the rose alarm on tile AND line; the optional-MFA nudge keeps the
  # tile neutral and lets the status line alone carry the amber.
  defp team_tile_tone(:enrolled), do: :brand
  defp team_tile_tone(:lockout), do: :rose
  defp team_tile_tone(:nudge), do: :neutral

  defp team_status_tone(:enrolled), do: :neutral
  defp team_status_tone(:lockout), do: :rose
  defp team_status_tone(:nudge), do: :amber

  defp team_status(:enrolled, m), do: "All #{m.total} have 2FA"
  defp team_status(:lockout, m), do: "#{m.missing} can't sign in until enrolled →"
  defp team_status(:nudge, m), do: "#{m.missing} without 2FA →"

  # -- The pillar card shape --------------------------------------------

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, required: true, values: [:brand, :rose, :neutral]
  attr :status_tone, :atom, default: :neutral, values: [:amber, :rose, :neutral]
  attr :navigate, :string, required: true
  attr :action_label, :string, default: nil
  attr :action_navigate, :string, default: nil
  slot :value, required: true
  slot :status, required: true

  defp pillar(assigns) do
    ~H"""
    <div class="flex flex-col rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07] p-5">
      <div class="flex items-center justify-between gap-3">
        <div class="flex min-w-0 items-center gap-2.5">
          <span class={[
            "grid h-8 w-8 shrink-0 place-items-center rounded-lg ring-1",
            pillar_tile(@tone)
          ]}>
            <.icon name={@icon} class="h-4 w-4" />
          </span>
          <span class="truncate text-sm font-medium text-zinc-300">{@label}</span>
        </div>
        <%!-- -m/p padding extends the hit area to ~40px without growing the
             visible text — these are the product's three main actions and on a
             phone a bare 12px text link is an unhittable target. --%>
        <.link
          :if={@action_label}
          navigate={@action_navigate}
          class="-m-2.5 shrink-0 p-2.5 text-xs font-medium text-zinc-500 transition-colors hover:text-brand-300"
        >
          {@action_label}
        </.link>
      </div>
      <.link navigate={@navigate} class="group mt-5 block">
        <div class="font-display text-3xl font-semibold leading-none tracking-[-0.02em] text-zinc-50 tabular-nums transition-colors group-hover:text-brand-200">
          {render_slot(@value)}
        </div>
        <div class={["mt-2 flex items-center gap-1.5 text-xs", pillar_status_class(@status_tone)]}>
          {render_slot(@status)}
        </div>
      </.link>
    </div>
    """
  end

  # The tile wears the pillar's overall posture (brand healthy / rose lockout /
  # neutral otherwise); the STATUS LINE alone carries amber, so attention tint
  # never stacks into an alarm wall — a healthy pillar stays quiet (no green
  # shout).
  defp pillar_tile(:brand), do: "bg-brand-500/10 text-brand-400 ring-brand-500/30"
  defp pillar_tile(:rose), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"
  defp pillar_tile(:neutral), do: "bg-zinc-800/80 text-zinc-400 ring-white/10"

  defp pillar_status_class(:amber), do: "text-amber-300"
  defp pillar_status_class(:rose), do: "text-rose-300"
  defp pillar_status_class(:neutral), do: "text-zinc-500"

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :cta, :string, required: true
  attr :navigate, :string, required: true

  # The pillar's ZERO state — the same card silhouette, brand-tinted, the
  # whole card one link to the create/onboard flow. Three of these on a fresh
  # account ARE the onboarding checklist; they graduate to live pillars one by
  # one as the steps complete.
  defp pillar_cta(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group flex flex-col rounded-xl bg-brand-950/30 p-5 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-brand-500/25 transition-colors hover:bg-brand-950/40 hover:ring-brand-500/40"
    >
      <div class="flex items-center gap-2.5">
        <span class="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-brand-500/10 text-brand-400 ring-1 ring-brand-500/30">
          <.icon name={@icon} class="h-4 w-4" />
        </span>
        <span class="text-sm font-medium text-zinc-300">{@label}</span>
      </div>
      <div class="mt-4 text-sm font-semibold text-zinc-50">{@title}</div>
      <p class="mt-1 text-xs leading-relaxed text-zinc-400">{@body}</p>
      <div class="mt-auto flex items-center gap-1 pt-3 text-xs font-medium text-brand-400 transition-colors group-hover:text-brand-300">
        {@cta}
        <.icon
          name="hero-arrow-right"
          class="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5"
        />
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
