defmodule EmisarWeb.DashboardLive do
  use EmisarWeb, :live_view

  alias Emisar.{ApiKeys, Runners, Approvals, Billing, Catalog, PubSub, Runs}

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket) do
      PubSub.subscribe_account_runs(account_id)
      Runners.subscribe_connections(account_id)
      PubSub.subscribe_account_approvals(account_id)
      {:ok, load(socket)}
    else
      {:ok, socket |> assign(:page_title, "Dashboard") |> assign(:loading?, true)}
    end
  end

  def handle_info(%{event: "presence_diff"}, socket), do: {:noreply, load(socket)}
  def handle_info({_event, _struct}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    account = socket.assigns.current_account
    subject = socket.assigns.current_subject
    {:ok, runners, _} = Runners.list_runners_for_account(subject)
    {:ok, actions, _} = Catalog.list_actions_for_account(subject)
    {:ok, pending, _} = Approvals.list_pending_approval_requests(subject)
    {:ok, api_keys, _} = ApiKeys.list_api_keys_for_account(subject)
    memberships = list_memberships(subject)

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:loading?, false)
    |> assign(:runners_total, length(runners))
    |> assign(:runners_connected, Enum.count(runners, & &1.online?))
    |> assign(:actions_count, length(actions))
    |> assign(:recent_runs, list_or_empty(Runs.list_recent_runs(subject, limit: 6)))
    |> assign(:run_stats, unwrap_ok(Runs.fetch_run_stats(subject, hours: 24)))
    |> assign(:pending_approvals, pending)
    |> assign(:has_llm_connected?, api_keys != [])
    |> assign(:billing, unwrap_ok(Billing.billing_summary(account, subject)))
    |> assign(:team_mfa, team_mfa_stats(memberships, account))
  end

  defp list_memberships(subject) do
    case Emisar.Accounts.list_memberships_for_account(subject) do
      {:ok, list, _} -> list
      _ -> []
    end
  end

  # Tile data for the team-security stat. Team size + how many have
  # enrolled MFA + whether the account *requires* MFA. The combination
  # decides the tile's tone (rose when required-but-missing, amber
  # when optional-but-missing, emerald when fully enrolled).
  defp team_mfa_stats(memberships, account) do
    enrolled =
      Enum.count(memberships, fn m ->
        m.user && m.user.mfa_enabled_at
      end)

    %{
      total: length(memberships),
      enrolled: enrolled,
      missing: length(memberships) - enrolled,
      required?: account.require_mfa
    }
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(_), do: nil

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:dashboard}
    >
      <:title>Dashboard</:title>

      <.loading_state :if={@loading?} />

      <.live_dashboard
        :if={not @loading?}
        runners_total={@runners_total}
        runners_connected={@runners_connected}
        actions_count={@actions_count}
        pending_approvals={@pending_approvals}
        recent_runs={@recent_runs}
        run_stats={@run_stats}
        has_llm_connected?={@has_llm_connected?}
        billing={@billing}
        team_mfa={@team_mfa}
      />
    </.dashboard_shell>
    """
  end

  # Onboarding checklist. Each card disappears the moment its
  # condition is met — "no runners" goes away when the first runner
  # registers, "no LLM" goes away when the first API key gets minted.
  # When both are done, the whole block hides; the dashboard goes
  # straight to stats. Same single-line-tile shape as the original
  # bottom-of-page LLM nag — just hoisted to the top so a fresh
  # account sees the next step instead of "0 runners, 0 runs".

  attr :runners_total, :integer, required: true
  attr :has_llm_connected?, :boolean, required: true

  defp onboarding_checklist(assigns) do
    ~H"""
    <div
      :if={@runners_total == 0 or not @has_llm_connected?}
      class="mb-6 grid grid-cols-1 gap-3 lg:grid-cols-2"
    >
      <.onboarding_card
        :if={@runners_total == 0}
        href={~p"/app/runners/install"}
        icon="hero-cpu-chip"
        title="Connect a runner"
        body="Install the agent on a server you want to operate — one curl one-liner. The dashboard tracks the rest from heartbeat onwards."
      />
      <.onboarding_card
        :if={not @has_llm_connected?}
        href={~p"/app/agents"}
        icon="hero-bolt"
        title="Connect an LLM"
        body="Pick a client (Claude Code, Cursor, Gemini, Codex) and we'll mint the API key and drop a prefilled snippet you can paste straight in."
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
      class="flex items-center gap-3 rounded-xl border border-indigo-900/40 bg-indigo-950/20 p-4 transition hover:border-indigo-700/60 hover:bg-indigo-950/40"
    >
      <.icon name={@icon} class="h-5 w-5 flex-none text-indigo-400" />
      <div class="flex-1">
        <div class="text-sm font-semibold text-zinc-100">{@title}</div>
        <p class="mt-0.5 text-xs text-zinc-400">{@body}</p>
      </div>
      <.icon name="hero-arrow-right" class="h-4 w-4 flex-none text-indigo-400" />
    </.link>
    """
  end

  # The "active" dashboard once at least one runner exists.
  #
  # Layout follows triage hierarchy:
  #   1. Banners (plan-at-limit, all-runners-offline) — only when bad
  #   2. Stats row — three numbers, never four
  #   3. Pending approvals — full width, only when something is waiting.
  #      (Failures aren't mirrored here: they surface inline in Recent
  #      runs and roll up into the Runs stat tile, so there's no separate
  #      panel left half-empty when there's nothing else beside it.)
  #   4. Recent runs — last 6, single column, full width
  attr :runners_connected, :integer, required: true
  attr :runners_total, :integer, required: true
  attr :actions_count, :integer, required: true
  attr :pending_approvals, :list, required: true
  attr :recent_runs, :list, required: true
  attr :run_stats, :map, required: true
  attr :has_llm_connected?, :boolean, required: true
  attr :billing, :map, required: true
  attr :team_mfa, :map, required: true

  defp live_dashboard(assigns) do
    ~H"""
    <.onboarding_checklist
      runners_total={@runners_total}
      has_llm_connected?={@has_llm_connected?}
    />

    <.plan_limit_banner :if={runner_headroom_warn?(@billing)} billing={@billing} />
    <.runners_offline_banner :if={@runners_total > 0 and @runners_connected == 0} />

    <%!-- Three tiles, never four. Plan info used to live in the third
         slot but billing is rarely operational. Team-MFA posture is —
         it tells the operator at a glance "is the people-attack
         surface tight?" and links straight to the team page where
         they'd fix it. --%>
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <.runners_stat connected={@runners_connected} total={@runners_total} />
      <.runs_stat stats={@run_stats} />
      <.team_security_stat team_mfa={@team_mfa} />
    </div>

    <%!-- Pending approvals — runs held on a human decision, the one
         thing on this page that actively blocks an LLM. Full width;
         shown only when there's something to act on. --%>
    <div :if={@pending_approvals != []} class="mt-6">
      <.attention_panel
        icon="hero-hand-raised"
        title="Awaiting your approval"
        count={length(@pending_approvals)}
        href={~p"/app/approvals"}
        cta="Review all"
      >
        <ul class="divide-y divide-amber-500/10">
          <li :for={req <- Enum.take(@pending_approvals, 5)}>
            <.link
              navigate={~p"/app/approvals/#{req.id}"}
              class="flex items-center justify-between gap-3 py-2.5 text-sm hover:opacity-90"
            >
              <div class="min-w-0">
                <div class="truncate font-mono text-amber-100">
                  {req.context["action_id"] || "—"}
                </div>
                <div class="truncate text-xs text-amber-200/60">
                  {relative_time(req.requested_at)}
                  <span :if={req.reason && req.reason != ""}>· {req.reason}</span>
                </div>
              </div>
              <.icon name="hero-arrow-right" class="h-4 w-4 shrink-0 text-amber-300/70" />
            </.link>
          </li>
        </ul>
      </.attention_panel>
    </div>

    <%!-- Recent runs — full width, no parallel "activity" mirror at
         the bottom (that just duplicated the audit page). --%>
    <div class="mt-8 overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40">
      <header class="flex items-center justify-between border-b border-zinc-900 px-5 py-3">
        <h2 class="text-sm font-semibold text-zinc-100">Recent runs</h2>
        <.link
          navigate={~p"/app/runs"}
          class="text-xs font-medium text-indigo-400 hover:text-indigo-300"
        >
          See all <.icon name="hero-arrow-right" class="ml-0.5 h-3 w-3" />
        </.link>
      </header>

      <%= if @recent_runs == [] do %>
        <%!-- Brand-new-account state. Cover both shapes: no runners
             registered yet (point to install) AND have-runners-but-
             no-runs-yet (point to a runner detail or runbook). --%>
        <div class="mx-auto max-w-md px-5 py-10 text-center">
          <.icon name="hero-bolt" class="mx-auto h-8 w-8 text-zinc-700" />
          <p class="mt-3 text-sm text-zinc-300">No runs yet.</p>
          <p class="mt-1 text-xs leading-relaxed text-zinc-500">
            Register a
            <.link navigate={~p"/app/runners"} class="text-indigo-400 hover:text-indigo-300">
              runner
            </.link>
            and dispatch an action from its detail page, or kick off a <.link
              navigate={~p"/app/runbooks"}
              class="text-indigo-400 hover:text-indigo-300"
            >runbook</.link>.
            LLM-driven runs (via the <.link
              navigate={~p"/app/agents"}
              class="text-indigo-400 hover:text-indigo-300"
            >MCP API</.link>) land here too.
          </p>
        </div>
      <% else %>
        <ul class="divide-y divide-zinc-900">
          <li :for={run <- @recent_runs}>
            <.link
              navigate={~p"/app/runs/#{run.id}"}
              class="flex items-center justify-between gap-3 px-5 py-3 transition hover:bg-zinc-900/40"
            >
              <div class="min-w-0">
                <div class="truncate font-mono text-sm text-zinc-200">{run.action_id}</div>
                <div class="truncate text-xs text-zinc-500">
                  <span :if={run.runner}>{"on #{run.runner.name} · "}</span>
                  {relative_time(run.inserted_at)}
                </div>
              </div>
              <.status_badge status={run.status} class="shrink-0" />
            </.link>
          </li>
        </ul>
      <% end %>
    </div>
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

  defp runners_stat(assigns) do
    ~H"""
    <.link navigate={~p"/app/runners"} class="block">
      <.stat
        label="Runners online"
        value={"#{@connected} / #{@total}"}
        hint={
          cond do
            @total == 0 -> "No runners yet"
            @connected == 0 -> "All runners offline"
            @connected < @total -> "#{@total - @connected} disconnected"
            true -> "All connected"
          end
        }
        class={
          cond do
            @connected == 0 and @total > 0 -> "ring-1 ring-rose-500/30"
            @connected < @total -> "ring-1 ring-amber-500/20"
            true -> ""
          end
        }
      />
    </.link>
    """
  end

  attr :stats, :map, required: true

  defp runs_stat(assigns) do
    ~H"""
    <.link navigate={~p"/app/runs"} class="block">
      <.stat
        label={"Runs (last #{@stats.window_hours}h)"}
        value={@stats.total}
        hint={
          cond do
            @stats.total == 0 ->
              "Nothing dispatched yet"

            @stats.success_rate == 100 ->
              "All succeeded"

            @stats.success_rate != nil ->
              "#{@stats.success_rate}% success · #{@stats.failed} failed"

            true ->
              "#{@stats.total} in progress"
          end
        }
        class={
          cond do
            @stats.failed > 0 and @stats.success_rate != nil and @stats.success_rate < 75 ->
              "ring-1 ring-rose-500/30"

            @stats.failed > 0 ->
              "ring-1 ring-amber-500/20"

            true ->
              ""
          end
        }
      />
    </.link>
    """
  end

  # -- Attention panel ------------------------------------------------

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :href, :string, required: true
  attr :cta, :string, required: true
  slot :inner_block, required: true

  defp attention_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-amber-500/30 bg-amber-500/[0.04] p-5">
      <header class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name={@icon} class="h-4 w-4 text-amber-300" />
          <h3 class="text-sm font-semibold text-amber-100">
            {@title}
            <span class="ml-1 rounded bg-amber-500/20 px-1.5 py-0.5 text-xs font-medium text-amber-200">
              {@count}
            </span>
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

  defp runners_offline_banner(assigns) do
    ~H"""
    <div class="mb-4 flex items-start gap-3 rounded-xl border border-rose-500/40 bg-rose-500/10 p-4">
      <.icon name="hero-signal-slash" class="mt-0.5 h-5 w-5 flex-none text-rose-300" />
      <div class="flex-1 text-sm">
        <p class="font-semibold text-rose-100">All runners offline</p>
        <p class="mt-1 text-xs text-rose-200/90">
          No actions can be dispatched until a runner reconnects. Check the runner
          host's logs or the systemd/launchd unit.
        </p>
      </div>
      <.link
        navigate={~p"/app/runners"}
        class="shrink-0 self-start rounded-lg bg-rose-500/20 px-3 py-1.5 text-xs font-semibold text-rose-100 hover:bg-rose-500/30"
      >
        View runners →
      </.link>
    </div>
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
  #   * emerald — every member is enrolled. Quiet "you're good".
  #
  # Always links to the team page where the operator can chase the
  # missing enrollments.

  attr :team_mfa, :map, required: true

  defp team_security_stat(assigns) do
    tone =
      cond do
        assigns.team_mfa.total == 0 -> :zinc
        assigns.team_mfa.missing == 0 -> :emerald
        assigns.team_mfa.required? -> :rose
        true -> :amber
      end

    assigns = assign(assigns, :tone, tone)

    ~H"""
    <.link navigate={~p"/app/settings/team"} class="block">
      <.stat
        label={stat_label(@tone, @team_mfa)}
        value={"#{@team_mfa.enrolled} / #{@team_mfa.total}"}
        hint={stat_hint(@tone, @team_mfa)}
        class={stat_ring(@tone)}
      />
    </.link>
    """
  end

  defp stat_label(_, _), do: "Team 2FA"

  defp stat_hint(:emerald, m),
    do: "All #{m.total} members enrolled."

  defp stat_hint(:rose, m),
    do: "#{m.missing} can't sign in until enrolled →"

  defp stat_hint(:amber, m),
    do:
      "#{m.missing} #{if m.missing == 1, do: "member hasn't", else: "members haven't"} enrolled →"

  defp stat_hint(:zinc, _),
    do: "No teammates yet."

  defp stat_ring(:rose), do: "ring-1 ring-rose-500/40"
  defp stat_ring(:amber), do: "ring-1 ring-amber-500/30"
  defp stat_ring(_), do: nil

  attr :billing, :map, required: true

  defp plan_limit_banner(assigns) do
    headroom = Emisar.Billing.headroom(assigns.billing, :runners)
    assigns = assign(assigns, :headroom, headroom)

    ~H"""
    <div class={[
      "mt-4 flex items-start gap-3 rounded-xl border p-4",
      if(@headroom == :at_limit,
        do: "border-rose-500/40 bg-rose-500/10",
        else: "border-amber-500/40 bg-amber-500/10"
      )
    ]}>
      <.icon
        name="hero-exclamation-triangle"
        class={"mt-0.5 h-5 w-5 flex-none #{if @headroom == :at_limit, do: "text-rose-300", else: "text-amber-300"}"}
      />
      <div class="flex-1 text-sm">
        <%= if @headroom == :at_limit do %>
          <p class="font-semibold text-rose-100">
            You're at your runner limit ({@billing.runner_count} of {@billing.runner_limit}).
          </p>
          <p class="mt-1 text-xs text-rose-200/90">
            The next runner that tries to register will get a 402 response and fail to come
            online. Upgrade the plan to add more, or remove an unused runner first.
          </p>
        <% else %>
          <p class="font-semibold text-amber-100">
            One runner slot left on the {String.capitalize(@billing.plan)} plan ({@billing.runner_count} of {@billing.runner_limit}).
          </p>
          <p class="mt-1 text-xs text-amber-200/90">
            Heads up — your next install will use the last slot. Upgrade now if you expect to
            add more.
          </p>
        <% end %>
      </div>
      <.link
        navigate={~p"/app/settings/billing"}
        class={[
          "shrink-0 self-start rounded-lg px-3 py-1.5 text-xs font-semibold",
          if(@headroom == :at_limit,
            do: "bg-rose-500/20 text-rose-100 hover:bg-rose-500/30",
            else: "bg-amber-500/20 text-amber-100 hover:bg-amber-500/30"
          )
        ]}
      >
        See plans →
      </.link>
    </div>
    """
  end

  defp runner_headroom_warn?(billing) do
    Emisar.Billing.headroom(billing, :runners) in [:warning, :at_limit]
  end
end
