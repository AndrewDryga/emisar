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
    {:ok, runners} = Runners.list_all_runners_for_account(subject)
    {:ok, pending, _} = Approvals.list_pending_approval_requests(subject)
    {:ok, api_keys, _} = ApiKeys.list_api_keys_for_account(subject)

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:loading?, false)
    |> assign(:runners_total, length(runners))
    |> assign(:runners_connected, Enum.count(runners, & &1.online?))
    |> assign(:first_runner_id, first_runner_id(runners))
    |> assign(
      :recent_runs,
      list_or_empty(Runs.list_recent_runs(subject, limit: 6, preload: [:runner]))
    )
    |> assign(:run_stats, unwrap_ok(Runs.fetch_run_stats(subject, hours: 24)))
    |> assign(:pending_approvals, pending)
    |> assign(:has_llm_connected?, api_keys != [])
    |> assign(:billing, unwrap_ok(Billing.billing_summary(account, subject)))
    |> assign(:team_mfa, team_mfa(account, subject))
    |> assign(:pending_packs_count, Catalog.count_pending_pack_versions(subject))
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
        has_llm_connected?={@has_llm_connected?}
        billing={@billing}
        can_manage_billing={Billing.subject_can_manage_billing?(@current_subject)}
        team_mfa={@team_mfa}
        pending_packs_count={@pending_packs_count}
        current_account={@current_account}
      />
    </.dashboard_shell>
    """
  end

  # Onboarding checklist. Each card disappears the moment its step is
  # done: "connect a runner" once the first registers, "dispatch your
  # first action" once any run exists, "connect an LLM" once the first
  # API key is minted. The block hides only when the account both has a
  # run on the board and an LLM connected — so a fresh account always
  # sees its next step at the top instead of "0 runners, 0 runs". The
  # connect-runner and dispatch cards are mutually exclusive (one needs
  # zero runners, the other needs at least one), so at most two show.

  attr :runners_total, :integer, required: true
  attr :has_llm_connected?, :boolean, required: true
  attr :has_runs?, :boolean, required: true
  attr :first_runner_id, :string, default: nil
  attr :current_account, :map, required: true

  defp onboarding_checklist(assigns) do
    ~H"""
    <div
      :if={not @has_llm_connected? or not @has_runs?}
      class="mb-6 grid grid-cols-1 gap-3 lg:grid-cols-2"
    >
      <.onboarding_card
        :if={@runners_total == 0}
        href={~p"/app/#{@current_account}/runners/install"}
        icon="hero-cpu-chip"
        title="Connect a runner"
        body="Install the agent on a server you want to operate — one curl one-liner. The dashboard tracks the rest from heartbeat onwards."
      />
      <.onboarding_card
        :if={@runners_total > 0 and not @has_runs?}
        href={~p"/app/#{@current_account}/runners/#{@first_runner_id}"}
        icon="hero-rocket-launch"
        title="Dispatch your first action"
        body="Open your runner, pick an action from its catalog, and run it. Policy decides allow, approve, or deny — and every run lands in the audit trail."
      />
      <.onboarding_card
        :if={not @has_llm_connected?}
        href={~p"/app/#{@current_account}/settings/agents"}
        icon="hero-bolt"
        title="Connect an agent"
        body="Pick a client (Claude Code, Cursor, Gemini, Codex) and we'll mint the API key and drop a prefilled snippet you can paste straight in. Optional: each client's setup has a step to stop its per-tool prompts — safe, since emisar still gates every action server-side."
      />
    </div>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  defp onboarding_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="flex items-center gap-3 rounded-xl border border-brand-900/40 bg-brand-950/20 p-4 transition hover:border-brand-700/60 hover:bg-brand-950/40"
    >
      <.icon name={@icon} class="h-5 w-5 flex-none text-brand-400" />
      <div class="flex-1">
        <div class="text-sm font-semibold text-zinc-100">{@title}</div>
        <p class="mt-0.5 text-xs text-zinc-400">{@body}</p>
      </div>
      <.icon name="hero-arrow-right" class="h-4 w-4 flex-none text-brand-400" />
    </.link>
    """
  end

  # The "active" dashboard once at least one runner exists.
  #
  # Layout follows triage hierarchy:
  #   1. Banners (plan-at-limit, all-runners-offline) — only when bad
  #   2. Stats row — three numbers, never four
  #   3. Pending approvals (amber) — full width, only when something waits.
  #   4. Recent runs — last 6, single column, full width
  attr :runners_connected, :integer, required: true
  attr :runners_total, :integer, required: true
  attr :pending_approvals, :list, required: true
  attr :pending_approvals_count, :integer, required: true
  attr :recent_runs, :list, required: true
  attr :first_runner_id, :string, default: nil
  attr :run_stats, :map, required: true
  attr :has_llm_connected?, :boolean, required: true
  attr :billing, :map, required: true
  attr :can_manage_billing, :boolean, default: false
  attr :team_mfa, :any, required: true
  attr :pending_packs_count, :integer, default: 0
  attr :current_account, :map, required: true

  defp live_dashboard(assigns) do
    ~H"""
    <.onboarding_checklist
      runners_total={@runners_total}
      has_llm_connected?={@has_llm_connected?}
      has_runs?={@recent_runs != []}
      first_runner_id={@first_runner_id}
      current_account={@current_account}
    />

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

    <%!-- Pending approvals lead the board — a run held on a human
         decision is an agent blocked right now, the one thing here that
         actively gates an LLM. The gate operator sees what needs them
         before the situational stats. Shown only when there's something
         to act on; otherwise the stats lead as usual. --%>
    <div :if={@pending_approvals != []} class="mb-6">
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
                <div class="truncate font-mono text-amber-100">
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

    <%!-- Three tiles, never four. Plan info used to live in the third
         slot but billing is rarely operational. Team-MFA posture is —
         it tells the operator at a glance "is the people-attack
         surface tight?" and links straight to the team page where
         they'd fix it. --%>
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <.runners_stat
        connected={@runners_connected}
        total={@runners_total}
        current_account={@current_account}
      />
      <.runs_stat stats={@run_stats} current_account={@current_account} />
      <.team_security_stat team_mfa={@team_mfa} current_account={@current_account} />
    </div>

    <%!-- Recent runs — full width, no parallel "activity" mirror at
         the bottom (that just duplicated the audit page). --%>
    <.panel variant={:split} title="Recent runs" class="mt-8">
      <:actions>
        <.link
          navigate={~p"/app/#{@current_account}/runs"}
          class="text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View all <.icon name="hero-arrow-right" class="ml-0.5 h-3 w-3" />
        </.link>
      </:actions>

      <%= if @recent_runs == [] do %>
        <%!-- Brand-new-account state. Cover both shapes: no runners
             registered yet (point to install) AND have-runners-but-
             no-runs-yet (point to a runner detail or runbook). --%>
        <.empty_state variant={:bare} icon="hero-bolt" title="No runs yet." class="px-5 py-10">
          Register a
          <.link
            navigate={~p"/app/#{@current_account}/runners"}
            class="text-brand-400 hover:text-brand-300"
          >
            runner
          </.link>
          and dispatch an action from its detail page, or kick off a <.link
            navigate={~p"/app/#{@current_account}/runbooks"}
            class="text-brand-400 hover:text-brand-300"
          >runbook</.link>.
          LLM-driven runs (via the <.link
            navigate={~p"/app/#{@current_account}/settings/agents"}
            class="text-brand-400 hover:text-brand-300"
          >MCP API</.link>) land here too.
        </.empty_state>
      <% else %>
        <ul class="divide-y divide-zinc-900">
          <li :for={run <- @recent_runs}>
            <.run_row run={run} show_runner current_account={@current_account} />
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
  defp list_or_empty(_), do: []

  # -- Stat tiles ------------------------------------------------------

  attr :connected, :integer, required: true
  attr :total, :integer, required: true
  attr :current_account, :map, required: true

  defp runners_stat(assigns) do
    ~H"""
    <.link navigate={~p"/app/#{@current_account}/runners"} class="block">
      <.stat
        label="Runners online"
        value={"#{@connected} / #{@total}"}
        hint={runners_hint(@connected, @total)}
        hint_tone={runners_tone(@connected, @total)}
      />
    </.link>
    """
  end

  # connected/total are :integer attrs, but Elixir 1.20's type checker won't
  # carry that into the template and flags `<`/`>` there as a struct
  # comparison. Guard clauses use term ordering (no such warning) and read
  # more clearly. Clause order preserves the original cond priority.
  defp runners_hint(_connected, 0), do: "No runners yet"
  defp runners_hint(0, _total), do: "All runners offline"

  defp runners_hint(connected, total) when connected < total,
    do: "#{total - connected} disconnected"

  defp runners_hint(_connected, _total), do: "All connected"

  defp runners_tone(0, total) when total > 0, do: :rose
  defp runners_tone(connected, total) when connected < total, do: :amber
  defp runners_tone(_connected, _total), do: :neutral

  attr :stats, :map, required: true
  attr :current_account, :map, required: true

  defp runs_stat(assigns) do
    ~H"""
    <.link navigate={~p"/app/#{@current_account}/runs"} class="block">
      <.stat
        label={"Runs (last #{@stats.window_hours}h)"}
        value={@stats.total}
        hint={runs_hint(@stats)}
        hint_tone={
          cond do
            @stats.failed > 0 and @stats.success_rate != nil and @stats.success_rate < 75 -> :rose
            @stats.failed > 0 -> :amber
            true -> :neutral
          end
        }
      />
    </.link>
    """
  end

  # Honest one-line outcome summary. "All succeeded" means EVERY run in the
  # window is `:success` (not just a 100% success rate while runs are still
  # pending or ended denied/cancelled); otherwise spell out each non-success
  # bucket so nothing hides.
  defp runs_hint(%{total: 0}), do: "Nothing dispatched yet"
  defp runs_hint(%{success: n, total: n}), do: "All succeeded"

  defp runs_hint(stats) do
    [
      if(stats.success_rate, do: "#{stats.success_rate}% success"),
      if(stats.failed > 0, do: "#{stats.failed} failed"),
      if(stats.in_progress > 0, do: "#{stats.in_progress} running"),
      if(stats.denied > 0, do: "#{stats.denied} denied"),
      if(stats.cancelled > 0, do: "#{stats.cancelled} cancelled")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
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
    <section class="rounded-xl border border-amber-500/30 bg-amber-500/[0.04] p-5">
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

  # -- Team-security stat (replaces the old plan tile) ---------------
  #
  # The third tile reports "how locked-down is your team", not "what
  # plan are you on". Three tones:
  #
  #   * rose  — account enforces MFA AND someone hasn't enrolled.
  #             They literally can't sign in until they fix it.
  #   * amber — MFA is optional but at least one teammate hasn't
  #             enrolled. Soft nudge.
  #   * brand — every member is enrolled. Quiet "you're good".
  #
  # Always links to the team page where the operator can chase the
  # missing enrollments.

  attr :team_mfa, :any, required: true
  attr :current_account, :map, required: true

  defp team_security_stat(%{team_mfa: :unavailable} = assigns) do
    ~H"""
    <.link navigate={~p"/app/#{@current_account}/settings/team"} class="block">
      <.stat label="Team 2FA" value={:unavailable} hint="Couldn't load team data" />
    </.link>
    """
  end

  defp team_security_stat(assigns) do
    tone =
      cond do
        assigns.team_mfa.total == 0 -> :neutral
        assigns.team_mfa.missing == 0 -> :brand
        assigns.team_mfa.required? -> :rose
        true -> :amber
      end

    assigns = assign(assigns, :tone, tone)

    ~H"""
    <.link navigate={~p"/app/#{@current_account}/settings/team"} class="block">
      <.stat
        label={stat_label(@tone, @team_mfa)}
        value={"#{@team_mfa.enrolled} / #{@team_mfa.total}"}
        hint={stat_hint(@tone, @team_mfa)}
        hint_tone={@tone}
      />
    </.link>
    """
  end

  defp stat_label(_, _), do: "Team 2FA"

  defp stat_hint(:brand, m),
    do: "All #{m.total} members enrolled."

  defp stat_hint(:rose, m),
    do: "#{m.missing} can't sign in until enrolled →"

  defp stat_hint(:amber, m) do
    "#{m.missing} #{if m.missing == 1, do: "member hasn't", else: "members haven't"} enrolled →"
  end

  defp stat_hint(:neutral, _),
    do: "No members yet."

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
