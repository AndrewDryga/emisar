defmodule EmisarWeb.DashboardLive do
  use EmisarWeb, :live_view

  alias Emisar.{ApiKeys, Runners, Approvals, Billing, Catalog, PubSub, Runs}
  alias EmisarWeb.UrlHelpers

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket) do
      PubSub.subscribe_account_runs(account_id)
      PubSub.subscribe_account_runners(account_id)
      PubSub.subscribe_account_approvals(account_id)
    end

    # Mint ONLY on the connected (live) mount, not the dead HTTP
    # render. mount/3 runs twice per page load (Plug pass + WebSocket
    # pass); minting in both would double the DB writes for no UX win.
    # Dead render briefly shows "Generating your install command…";
    # the live mount sub-second later replaces it with the real one.
    #
    # Mint runs in mount/3 (not load/1) so PubSub-triggered re-renders
    # — a runner connecting, a run completing — don't churn extra
    # install keys. Ring eviction in Runners.mint_install_key/3 caps
    # unused autos at 42 per account regardless.
    install_command =
      if connected?(socket) do
        maybe_mint_install_command(socket)
      end

    {:ok,
     socket
     |> assign(:install_command, install_command)
     |> load()}
  end

  # Only mints when the account has zero runners — that's the only path
  # that surfaces the install command in the UI. Accounts with active
  # runners never auto-mint; operators wanting an extra key go via
  # Settings → Auth keys (explicit, audit-logged).
  defp maybe_mint_install_command(socket) do
    subject = socket.assigns.current_subject

    case Runners.list_runners_for_account(subject) do
      {:ok, [], _} ->
        base = UrlHelpers.derive_base_url(socket)

        case Runners.mint_install_key(subject) do
          {:ok, raw, _key} ->
            # Leading space keeps the line out of shell history when
            # HISTCONTROL=ignorespace (bash) or HIST_IGNORE_SPACE (zsh).
            " curl -sSL #{base}/install.sh | sudo EMISAR_AUTH_KEY=#{raw} EMISAR_URL=#{base} bash"

          {:error, _} ->
            :mint_failed
        end

      _ ->
        nil
    end
  end

  def handle_info({_event, _struct}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    account = socket.assigns.current_account
    subject = socket.assigns.current_subject
    {:ok, runners, _} = Runners.list_runners_for_account(subject)
    {:ok, actions, _} = Catalog.list_actions_for_account(subject)
    {:ok, pending, _} = Approvals.list_pending_approval_requests(subject)
    {:ok, api_keys, _} = ApiKeys.list_api_keys_for_account(subject)

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:runners_total, length(runners))
    |> assign(:runners_connected, Enum.count(runners, &(&1.status == "connected")))
    |> assign(:actions_count, length(actions))
    |> assign(:recent_runs, list_or_empty(Runs.list_recent_runs(subject, limit: 6)))
    |> assign(:recent_failures, list_or_empty(Runs.list_recent_failures(subject, hours: 24, limit: 4)))
    |> assign(:run_stats, unwrap_ok(Runs.fetch_run_stats(subject, hours: 24)))
    |> assign(:pending_approvals, pending)
    |> assign(:has_llm_connected?, api_keys != [])
    |> assign(:billing, unwrap_ok(Billing.billing_summary(account, subject)))
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(_), do: nil

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:dashboard}
    >
      <:title>Dashboard</:title>

      <%= if @runners_total == 0 do %>
        <.empty_state_first_runner install_command={@install_command} />
      <% else %>
        <.live_dashboard
          runners_connected={@runners_connected}
          runners_total={@runners_total}
          actions_count={@actions_count}
          pending_approvals={@pending_approvals}
          recent_runs={@recent_runs}
          recent_failures={@recent_failures}
          run_stats={@run_stats}
          has_llm_connected?={@has_llm_connected?}
          billing={@billing}
        />
      <% end %>
    </.dashboard_shell>
    """
  end

  # First-time experience. The install command is pre-rendered on mount
  # (via Runners.mint_install_key) so there's no "generate" click step —
  # operator copies and runs. While runners is empty, the LV is
  # subscribed to account-level runner events; the moment the first
  # runner registers and connects, the page flips to the populated
  # dashboard automatically.
  # Reuses the shared `<.install_wizard>` so the empty-state dashboard
  # and `/app/runners/install` show the exact same widget.
  attr :install_command, :any, required: true

  defp empty_state_first_runner(assigns) do
    ~H"""
    <.install_wizard install_command={@install_command} />
    """
  end

  # The "active" dashboard once at least one runner exists.
  #
  # Layout follows triage hierarchy:
  #   1. Banners (plan-at-limit, runners-all-offline) — only when bad
  #   2. Stats row — three numbers, never four
  #   3. "Needs attention" — pending approvals + recent failures, side-
  #      by-side. Hidden entirely when both are empty.
  #   4. "Connect an LLM" CTA — only when no API keys exist
  #   5. Recent runs — last 6, single column, full width
  attr :runners_connected, :integer, required: true
  attr :runners_total, :integer, required: true
  attr :actions_count, :integer, required: true
  attr :pending_approvals, :list, required: true
  attr :recent_runs, :list, required: true
  attr :recent_failures, :list, required: true
  attr :run_stats, :map, required: true
  attr :has_llm_connected?, :boolean, required: true
  attr :billing, :map, required: true

  defp live_dashboard(assigns) do
    ~H"""
    <.plan_limit_banner :if={runner_headroom_warn?(@billing)} billing={@billing} />
    <.runners_offline_banner
      :if={@runners_total > 0 and @runners_connected == 0}
      runners_total={@runners_total}
    />

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <.runners_stat connected={@runners_connected} total={@runners_total} />
      <.runs_stat stats={@run_stats} />
      <.plan_usage_stat billing={@billing} />
    </div>

    <%!-- Attention rail. Two columns. Collapses to a single muted line
         when both are empty — never silent, always status-aware. --%>
    <div :if={needs_attention?(assigns)} class="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-2">
      <.attention_panel
        :if={@pending_approvals != []}
        tone={:amber}
        icon="hero-hand-raised"
        title="Awaiting your approval"
        count={length(@pending_approvals)}
        href={~p"/app/approvals"}
        cta="Review all"
      >
        <ul class="divide-y divide-amber-500/10">
          <li :for={req <- Enum.take(@pending_approvals, 4)}>
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

      <.attention_panel
        :if={@recent_failures != []}
        tone={:rose}
        icon="hero-exclamation-triangle"
        title="Recent failures (24h)"
        count={length(@recent_failures)}
        href={~p"/app/runs?filter[status][]=failed&filter[status][]=error&filter[status][]=timed_out"}
        cta="See all"
      >
        <ul class="divide-y divide-rose-500/10">
          <li :for={run <- @recent_failures}>
            <.link
              navigate={~p"/app/runs/#{run.id}"}
              class="flex items-center justify-between gap-3 py-2.5 text-sm hover:opacity-90"
            >
              <div class="min-w-0">
                <div class="truncate font-mono text-rose-100">{run.action_id}</div>
                <div class="truncate text-xs text-rose-200/60">
                  <span :if={run.runner}>on {run.runner.name} · </span>
                  {relative_time(run.inserted_at)}
                </div>
              </div>
              <.status_badge status={run.status} class="shrink-0" />
            </.link>
          </li>
        </ul>
      </.attention_panel>
    </div>

    <%!-- Connect-an-LLM CTA. Only when the operator hasn't yet — once
         they have an API key, this nag goes away forever. --%>
    <.link
      :if={not @has_llm_connected?}
      navigate={~p"/app/agents"}
      class="mt-6 flex items-center gap-3 rounded-xl border border-indigo-900/40 bg-indigo-950/20 p-4 transition hover:border-indigo-700/60 hover:bg-indigo-950/40"
    >
      <.icon name="hero-bolt" class="h-5 w-5 flex-none text-indigo-400" />
      <div class="flex-1">
        <div class="text-sm font-semibold text-zinc-100">Connect an LLM</div>
        <p class="mt-0.5 text-xs text-zinc-400">
          Pick a client (Claude Code, Cursor, Gemini, Codex) and we'll mint the API key and
          drop a prefilled snippet you can paste straight in.
        </p>
      </div>
      <.icon name="hero-arrow-right" class="h-4 w-4 flex-none text-indigo-400" />
    </.link>

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
        <div class="px-5 py-10 text-center text-sm text-zinc-500">
          No runs yet. Browse the
          <.link navigate={~p"/app/runners"} class="text-indigo-400 hover:text-indigo-300">runner catalog</.link>
          to try one.
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
                  <span :if={run.runner}>on {run.runner.name} · </span>
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

  defp needs_attention?(assigns),
    do: assigns.pending_approvals != [] or assigns.recent_failures != []

  # Dashboard tiles want a plain list, not a paginator tuple — they
  # don't show Prev/Next. Treat any unauthorized / unexpected reply as
  # empty so the tile still renders cleanly.
  defp list_or_empty({:ok, list, _meta}), do: list
  defp list_or_empty(_), do: []

  defp tone_icon_class(:amber), do: "text-amber-300"
  defp tone_icon_class(:rose), do: "text-rose-300"

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
            @stats.total == 0 -> "Nothing dispatched yet"
            @stats.success_rate == 100 -> "All succeeded"
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
            @stats.failed > 0 -> "ring-1 ring-amber-500/20"
            true -> ""
          end
        }
      />
    </.link>
    """
  end

  # -- Attention panel ------------------------------------------------

  attr :tone, :atom, required: true, values: [:amber, :rose]
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :href, :string, required: true
  attr :cta, :string, required: true
  slot :inner_block, required: true

  defp attention_panel(assigns) do
    ~H"""
    <section class={[
      "rounded-xl border p-5",
      @tone == :amber && "border-amber-500/30 bg-amber-500/[0.04]",
      @tone == :rose && "border-rose-500/30 bg-rose-500/[0.04]"
    ]}>
      <header class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name={@icon} class={"h-4 w-4 #{tone_icon_class(@tone)}"} />
          <h3 class={[
            "text-sm font-semibold",
            @tone == :amber && "text-amber-100",
            @tone == :rose && "text-rose-100"
          ]}>
            {@title}
            <span class={[
              "ml-1 rounded px-1.5 py-0.5 text-xs font-medium",
              @tone == :amber && "bg-amber-500/20 text-amber-200",
              @tone == :rose && "bg-rose-500/20 text-rose-200"
            ]}>
              {@count}
            </span>
          </h3>
        </div>
        <.link
          navigate={@href}
          class={[
            "text-xs font-medium",
            @tone == :amber && "text-amber-200 hover:text-amber-100",
            @tone == :rose && "text-rose-200 hover:text-rose-100"
          ]}
        >
          {@cta} →
        </.link>
      </header>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :runners_total, :integer, required: true

  defp runners_offline_banner(assigns) do
    ~H"""
    <div class="mb-4 flex items-start gap-3 rounded-xl border border-rose-500/40 bg-rose-500/10 p-4">
      <.icon name="hero-signal-slash" class="mt-0.5 h-5 w-5 flex-none text-rose-300" />
      <div class="flex-1 text-sm">
        <p class="font-semibold text-rose-100">
          {@runners_total} {if @runners_total == 1, do: "runner", else: "runners"} offline
        </p>
        <p class="mt-1 text-xs text-rose-200/90">
          No actions can be dispatched until at least one runner reconnects. Check the
          runner host's logs or the systemd/launchd unit.
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

  # -- Plan-usage stat + warning banner -------------------------------

  attr :billing, :map, required: true

  defp plan_usage_stat(assigns) do
    headroom = Emisar.Billing.headroom(assigns.billing, :runners)
    assigns = assign(assigns, :headroom, headroom)

    ~H"""
    <%= cond do %>
      <% @headroom == :unlimited -> %>
        <.stat
          label="Plan"
          value={String.capitalize(@billing.plan)}
          hint={"Unlimited runners · #{@billing.audit_retention_days}d audit"}
        />
      <% @headroom == :at_limit -> %>
        <.link navigate={~p"/app/settings/billing"} class="block">
          <.stat
            label="Plan — at limit"
            value={"#{@billing.runner_count} / #{@billing.runner_limit}"}
            hint="Runners used. Upgrade to add more →"
            class="ring-1 ring-rose-500/40"
          />
        </.link>
      <% @headroom == :warning -> %>
        <.link navigate={~p"/app/settings/billing"} class="block">
          <.stat
            label="Plan — near limit"
            value={"#{@billing.runner_count} / #{@billing.runner_limit}"}
            hint="Runners used. Upgrade for more →"
            class="ring-1 ring-amber-500/40"
          />
        </.link>
      <% true -> %>
        <.stat
          label="Plan"
          value={String.capitalize(@billing.plan)}
          hint={"#{@billing.runner_count} of #{@billing.runner_limit} runners · #{@billing.audit_retention_days}d audit"}
        />
    <% end %>
    """
  end

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
