defmodule EmisarWeb.RunnersLive do
  use EmisarWeb, :live_view
  alias Emisar.Runners
  alias EmisarWeb.LiveTable
  alias EmisarWeb.RunnerInstall
  alias EmisarWeb.UrlHelpers

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket), do: Runners.subscribe_connections(account_id)

    {:ok,
     socket
     |> assign(:page_title, "Runners")
     |> assign(:install_command, nil)
     |> assign(:base_url, nil)
     |> assign(:show_troubleshooting?, false)}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info(%{event: "presence_diff"}, socket), do: {:noreply, reload(socket)}

  # The empty-state wizard's grace period elapsed with no runner — reveal its
  # troubleshooting checklist (a runner joining first re-runs load/2, which drops
  # show_wizard? and shows the list, pre-empting this).
  def handle_info(:reveal_troubleshooting, socket),
    do: {:noreply, assign(socket, :show_troubleshooting?, true)}

  def handle_info(_, socket), do: {:noreply, socket}

  # PubSub-driven refresh — re-run the current page/filter.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  defp load(socket, params) do
    filters = Runners.Runner.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    # Filter by per-membership runner scopes (#238). Owners/admins
    # rarely have scopes set; operators may. Groups list isn't
    # scope-filtered: the "groups" sidebar header would lie about an
    # empty group when the operator just can't see it, and that's
    # confusing — let the list itself be the source of truth.
    list_opts = Keyword.merge(opts, membership_id: socket.assigns.current_membership.id)

    # Whole-account fleet health for the summary strip — counted from the
    # presence-decorated runners (the group_summary DB aggregate can't know
    # online?), like the dashboard. Account-wide (not scope-filtered), matching
    # the group sidebar so the strip reflects the whole fleet, not just a page.
    fleet = load_fleet_health(socket.assigns.current_subject)

    # Whole-account dispatch posture: when every active runner enforces signatures
    # the portal can't dispatch to ANY of them, so surface it once for the fleet
    # rather than leaving the operator to read it off each runner's chip.
    fleet_signed? = Runners.fleet_all_signed?(socket.assigns.current_subject)

    case Runners.list_runners_for_account(socket.assigns.current_subject, list_opts) do
      {:ok, runners, meta} ->
        groups =
          case Runners.list_group_summaries(socket.assigns.current_subject) do
            {:ok, list} -> list
            _ -> []
          end

        # An empty fleet on the live socket IS the wizard — mint the one-liner and
        # render the installer inline, so a first-time operator connects a host
        # without a detour to /runners/install (the LLM-agents page does the same).
        show_wizard? = runners == [] and meta.count == 0 and connected?(socket)

        socket
        |> maybe_mint_install(show_wizard?)
        |> assign(:runners, runners)
        |> assign(:metadata, meta)
        |> assign(:show_wizard?, show_wizard?)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:groups, groups)
        |> assign(:fleet, fleet)
        |> assign(:fleet_signed?, fleet_signed?)
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — show a
      # load-error state, NOT a silent empty fleet (that would read "no runners"
      # when really the read failed and a host may well be connected).
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:runners, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:show_wizard?, false)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:groups, [])
        |> assign(:fleet, fleet)
        |> assign(:fleet_signed?, fleet_signed?)
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  # Mint the install one-liner the first time an empty fleet renders on the live
  # socket. Mint ONCE — a presence reload re-runs load/2, and re-minting each pass
  # would burn a key per tick; reuse the command already in assigns.
  defp maybe_mint_install(socket, true) do
    if socket.assigns.install_command do
      socket
    else
      base = UrlHelpers.derive_base_url(socket)
      # Only the command + base are used here — unlike the dedicated page, this
      # wizard needs no key id: any runner joining re-runs load/2 and shows the
      # list, so there's no per-key join to match.
      {command, _key_id} = RunnerInstall.mint_command(socket.assigns.current_subject, base)
      Process.send_after(self(), :reveal_troubleshooting, RunnerInstall.troubleshoot_after_ms())
      assign(socket, base_url: base, install_command: command)
    end
  end

  defp maybe_mint_install(socket, false), do: socket

  defp load_fleet_health(subject) do
    case Runners.list_all_runners_for_account(subject) do
      {:ok, runners} -> fleet_health(runners)
      _ -> %{online: 0, offline: 0, pending: 0, disabled: 0}
    end
  end

  defp fleet_health(runners) do
    counts = Enum.frequencies_by(runners, &Runners.connection_state/1)

    %{
      online: Map.get(counts, :online, 0),
      offline: Map.get(counts, :offline, 0),
      pending: Map.get(counts, :pending, 0),
      disabled: Map.get(counts, :disabled, 0)
    }
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
      section={:runners}
      width={if @show_wizard?, do: :form, else: :table}
    >
      <:title>Runners</:title>
      <%!-- The wizard IS the add flow, so the button (→ the same wizard) is
           redundant while an empty fleet shows it inline. --%>
      <:actions :if={not @show_wizard?}>
        <.button navigate={~p"/app/#{@current_account}/runners/install"} size={:md} icon="hero-plus">
          Add a runner
        </.button>
      </:actions>

      <.page_intro :if={not @show_wizard?}>
        Live connection state for every host in your fleet — a runner must be connected before you
        can dispatch an action to it. <.doc_link href="/docs/runners">Runner docs</.doc_link>
      </.page_intro>

      <%= cond do %>
        <% @load_error? -> %>
          <.empty_state
            tone={:danger}
            icon="hero-exclamation-triangle"
            title="Couldn't load your fleet"
          >
            This is a load error, not an empty fleet — a host may well be connected. Refresh the
            page; if it persists, your access to this account may have changed.
          </.empty_state>
        <% @show_wizard? -> %>
          <%!-- No runners yet → the empty state IS the installer. A runner is the
               emisar binary on one of your hosts; paste the one-liner to connect
               the first. --%>
          <.install_wizard
            install_command={@install_command}
            base_url={@base_url}
            show_troubleshooting={@show_troubleshooting?}
            on_failure_path={~p"/app/#{@current_account}/settings/runners/auth-keys"}
          />

          <%!-- Follow-up resources, siblings below the wizard — same as the
               dedicated install page. --%>
          <div class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.link_card href="/docs/quickstart" icon="hero-book-open" title="Installation guide">
              Image-bake, cloud-init, manual install.
            </.link_card>
            <.link_card navigate="/packs" icon="hero-cube-transparent" title="Pack registry">
              Browse linux-core, cassandra, showcase. Install snippets included.
            </.link_card>
          </div>
        <% @runners == [] && @metadata.count == 0 -> %>
          <%!-- Dead/pre-connect render — defer the onboarding pitch until the
               live socket confirms there really are no runners. --%>
          <.loading_state />
        <% true -> %>
          <%!-- Fleet-dark escalation: runners exist but none are reachable, so
               nothing can be dispatched right now. Escalate the quiet band into a
               loud banner (the dashboard's all-offline notice, on the fleet page). --%>
          <.offline_notice
            :if={@fleet.online == 0 and @fleet.offline > 0}
            severity={:critical}
            title="All runners offline"
            class="mb-4"
          >
            Every runner in this fleet is disconnected — dispatched actions will queue (or fail)
            until one reconnects. Check the hosts, or the runner service on them.
          </.offline_notice>
          <%!-- Whole-fleet dispatch posture: every active runner is signed-only, so the
               portal is locked out account-wide. Surface it once here instead of leaving
               the operator to infer it from N per-runner chips + failed dispatches. --%>
          <.callout
            :if={@fleet_signed?}
            tone={:brand}
            icon="hero-shield-check"
            title="Fleet is signed-only"
            class="mb-4"
          >
            Every runner in this account verifies a client signature and refuses unsigned runs, so
            the portal can't dispatch to any of them. Runs and runbooks must come from an MCP client
            configured with each runner's signing key.
          </.callout>
          <%!-- Fleet health at a glance, so "is anything down?" doesn't mean
             scanning every dot. Whole-account (like the group sidebar +
             list below), counted from presence — there's no `:stale` state
             (heartbeat liveness is socket-enforced; see Runners.connection_state). --%>
          <%!-- Health-at-a-glance, small + muted like the per-group totals below.
             The whole-account total is NOT repeated here — it lives in the group
             header(s), so it isn't duplicated above and below the table. --%>
          <.summary_band>
            <.summary_stat tone={:brand} value={@fleet.online} label="Online" />
            <%!-- Amber, not rose: offline = needs attention, not failed —
                 the ONE tone the fact wears everywhere. --%>
            <.summary_stat tone={:amber} value={@fleet.offline} label="Offline" />
            <.summary_stat
              :if={@fleet.pending > 0}
              tone={:amber}
              value={@fleet.pending}
              label="Pending"
            />
            <.summary_stat
              :if={@fleet.disabled > 0}
              tone={:neutral}
              value={@fleet.disabled}
              label="Disabled"
            />
          </.summary_band>

          <%!-- Group sidebar shows whole-account totals; the runners
             list below is paginated and may show fewer rows per
             group than the count next to the header. That's
             intentional — operators expect group counts to be
             source-of-truth, not "what fits on this page". --%>
          <LiveTable.live_table
            layout={:cards}
            id="runners"
            path={~p"/app/#{@current_account}/runners"}
            rows={sort_by_group(@runners)}
            metadata={@metadata}
            filter_params={@filter_params}
            group_by={fn runner -> runner.group || "(no group)" end}
          >
            <:group_header :let={group_label}>
              <li class="border-b border-white/[0.06] bg-black/30 px-5 py-2 flex items-baseline gap-2">
                <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
                  {group_label}
                </h2>
                <span class="text-[11px] text-zinc-500">
                  {group_total(@groups, group_label)} {if group_total(@groups, group_label) == 1,
                    do: "runner",
                    else: "runners"} total
                </span>
              </li>
            </:group_header>

            <:item :let={runner}>
              <% state = connection_status(Runners.connection_state(runner)) %>
              <li class="px-5 py-3">
                <.link
                  navigate={~p"/app/#{@current_account}/runners/#{runner.id}"}
                  class="flex items-center gap-4 transition hover:opacity-90"
                >
                  <div class="min-w-0 flex-1">
                    <%!-- flex-wrap: the runner's name is its identity (often name
                         == hostname, so it's the only copy of it) — on a phone the
                         version + signed-only chip wrap below instead of crushing
                         it to "signed…". --%>
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="truncate font-medium text-zinc-100">{runner.name}</span>
                      <span :if={runner.runner_version} class="font-mono text-[11px] text-zinc-500">
                        v{runner.runner_version}
                      </span>
                      <%!-- Hardened runners are scannable at a glance — the portal
                           can't dispatch to them; only signed MCP calls run. --%>
                      <.chip
                        :if={runner.enforce_signatures}
                        tone={:neutral}
                        icon="hero-shield-check"
                        title="Runs only signed dispatches — the portal can't dispatch to this runner"
                      >
                        Signed-only
                      </.chip>
                    </div>
                    <.meta_line class="mt-0.5 text-xs text-zinc-500">
                      <%!-- When name == hostname the title already says it —
                           don't restate the identifier one line down. --%>
                      <:seg :if={(runner.hostname || runner.external_id || "no host") != runner.name}>
                        {runner.hostname || runner.external_id || "no host"}
                      </:seg>
                      <:seg><.heartbeat_status runner={runner} status={state} /></:seg>
                    </.meta_line>
                  </div>

                  <div class="flex items-center gap-4 text-right">
                    <%!-- Zero is the default, not a signal — muted em-dash;
                         "N active runs" only when something is running. --%>
                    <div class="hidden w-20 text-xs tabular-nums text-zinc-400 sm:block">
                      <span :if={runner.action_load > 0}>{runner.action_load} active runs</span>
                      <span :if={runner.action_load == 0} class="text-zinc-600">—</span>
                    </div>
                    <.status_badge status={state} class="shrink-0" />
                  </div>
                </.link>
              </li>
            </:item>
          </LiveTable.live_table>
      <% end %>
    </.dashboard_shell>
    """
  end

  # Visible (this-page) runners, grouped + sorted by group name so the
  # Pre-sort the page's runners by group so `<.live_table group_by={…}>`
  # walks them in stable order and emits one `:group_header` per group.
  # Within a group the natural ordering from the context (recently active
  # first) is preserved.
  defp sort_by_group(runners), do: Enum.sort_by(runners, &(&1.group || ""))

  defp group_total(groups, group) do
    Enum.find_value(groups, 0, fn
      {^group, n} -> n
      _ -> nil
    end)
  end

  # "last heartbeat 3m ago" / "just connected — waiting for first
  # heartbeat" / "last seen 5m ago" / "never connected". Composes
  # status + timestamps into one human line — clearer than a "—" with
  # "(connected X ago)" tacked on the side. The two time-bearing cases
  # render the timestamp through <.local_time> (viewer-local, hoverable,
  # live) like every other timestamp; {" "} keeps the prefix from
  # abutting the <time> tag (HEEx trims the surrounding newline).
  attr :runner, :map, required: true
  attr :status, :string, required: true

  defp heartbeat_status(%{runner: %{last_heartbeat_at: %DateTime{} = ts}} = assigns) do
    assigns = assign(assigns, :heartbeat_at, ts)

    ~H"""
    last heartbeat{" "}<.local_time value={@heartbeat_at} mode={:relative} />
    """
  end

  defp heartbeat_status(
         %{runner: %{last_connected_at: %DateTime{}}, status: "connected"} = assigns
       ) do
    ~H"just connected — waiting for first heartbeat"
  end

  defp heartbeat_status(%{runner: %{last_connected_at: %DateTime{} = ts}} = assigns) do
    assigns = assign(assigns, :seen_at, ts)

    ~H"""
    last seen{" "}<.local_time value={@seen_at} mode={:relative} />
    """
  end

  defp heartbeat_status(assigns), do: ~H"never connected"
end
