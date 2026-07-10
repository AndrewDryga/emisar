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

    # Runners derives the current membership's scope from the subject, so the
    # URL cannot select a broader member's scope. The groups and fleet summary
    # remain account-wide by product decision; only individual rows are scoped.

    # Whole-account fleet health for the summary strip — counted from the
    # presence-decorated runners (the group_summary DB aggregate can't know
    # online?), like the dashboard. Account-wide (not scope-filtered), matching
    # the group sidebar so the strip reflects the whole fleet, not just a page.
    fleet = load_fleet_health(socket.assigns.current_subject)

    # Whole-account dispatch posture: when every active runner enforces signatures
    # the portal can't dispatch to ANY of them, so surface it once for the fleet
    # rather than leaving the operator to read it off each runner's chip.
    fleet_signed? = Runners.fleet_all_signed?(socket.assigns.current_subject)

    case Runners.list_runners_for_account(socket.assigns.current_subject, opts) do
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
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runners}
      width={:table}
    >
      <:title>Runners</:title>
      <%!-- The wizard IS the add flow, so the button (→ the same wizard) is
           redundant while an empty fleet shows it inline. --%>
      <:actions :if={not @show_wizard?}>
        <%!-- Enrollment keys are the fleet's OWN sub-feature (the audit "Stream to
             SIEM" pattern) — a quiet secondary door on the owning page, not a
             nav item of their own. --%>
        <.button
          :if={Runners.subject_can_manage_enrollment_keys?(@current_subject)}
          navigate={~p"/app/#{@current_account}/runners/keys"}
          variant={:secondary}
          size={:md}
        >
          Enrollment keys
        </.button>
        <%!-- "Connect a runner" — the destination page's own title, the
             dashboard onboarding step, and the parallel of "Connect an agent".
             One verb for getting a host online, not a stray "Add". --%>
        <.button
          :if={Runners.subject_can_install_runners?(@current_subject)}
          navigate={~p"/app/#{@current_account}/runners/install"}
          size={:md}
          icon="hero-plus"
        >
          Connect a runner
        </.button>
      </:actions>

      <.page_intro :if={not @show_wizard?}>
        Live connection state for every host in your fleet — a runner must be connected before you
        can dispatch an action to it.
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
        <% @show_wizard? and not Runners.subject_can_install_runners?(@current_subject) -> %>
          <%!-- Zero fleet, no install permission: the pitch without a wizard
               whose mint can only fail. --%>
          <.empty_state icon="hero-server-stack" title="No runners yet.">
            A runner is the emisar binary on one of your hosts — ask an operator,
            admin, or owner to connect the first one; its live state will appear
            here.
          </.empty_state>
        <% @show_wizard? -> %>
          <%!-- No runners yet → the empty state IS the installer. A runner is the
               emisar binary on one of your hosts; paste the one-liner to connect
               the first. --%>
          <.install_wizard
            install_command={@install_command}
            base_url={@base_url}
            show_troubleshooting={@show_troubleshooting?}
            keys_path={~p"/app/#{@current_account}/runners/keys"}
            show_keys_link={Runners.subject_can_manage_enrollment_keys?(@current_subject)}
          />
        <% @runners == [] && @metadata.count == 0 -> %>
          <%!-- Dead/pre-connect render — defer the onboarding pitch until the
               live socket confirms there really are no runners. --%>
          <.loading_state />
        <% true -> %>
          <%!-- :table width leaves the fleet list too narrow-of-content and wide
               of page — pair it with a docs rail (the main+aside grammar): the
               fleet leads, a plain-terms "what's a runner" teaches beside it. The
               rail is a FIXED 22rem track that only splits off at xl (so its prose
               never squeezes to 3 words a line); below xl it stacks full-width. --%>
          <div class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
            <div class="min-w-0">
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
             scanning every dot. Whole-account (like the group headers below),
             counted from presence. NAKED posture line, not a boxed band — the
             dashboard pillar grammar: healthy counts stay quiet, offline wears
             amber (needs attention, not failed — the ONE tone the fact wears
             everywhere). --%>
              <div class="flex flex-wrap items-center gap-x-5 gap-y-1 pb-4 text-xs">
                <span class="flex items-center gap-1.5">
                  <.status_dot tone={:brand} size={:sm} />
                  <span class="tabular-nums text-zinc-400">{@fleet.online} connected</span>
                </span>
                <span :if={@fleet.offline > 0} class="flex items-center gap-1.5">
                  <.status_dot tone={:amber} size={:sm} />
                  <span class="tabular-nums text-amber-300">{@fleet.offline} offline</span>
                </span>
                <span :if={@fleet.pending > 0} class="flex items-center gap-1.5">
                  <.status_dot tone={:amber} size={:sm} />
                  <span class="tabular-nums text-amber-300">{@fleet.pending} pending</span>
                </span>
                <span :if={@fleet.disabled > 0} class="flex items-center gap-1.5">
                  <.status_dot tone={:neutral} size={:sm} />
                  <span class="tabular-nums text-zinc-500">{@fleet.disabled} disabled</span>
                </span>
              </div>

              <%!-- Group sidebar shows whole-account totals; the runners
             list below is paginated and may show fewer rows per
             group than the count next to the header. That's
             intentional — operators expect group counts to be
             source-of-truth, not "what fits on this page". --%>
              <%!-- CONTENT ON CANVAS (the audit/runs language): rows under hairlines,
               group labels as naked uppercase text — no island, no banded fills. --%>
              <LiveTable.live_table
                layout={:cards}
                id="runners"
                path={~p"/app/#{@current_account}/runners"}
                rows={sort_by_group(@runners)}
                metadata={@metadata}
                filter_params={@filter_params}
                wrapper_class="divide-y divide-zinc-800/70"
                group_by={fn runner -> runner.group || "(no group)" end}
              >
                <:group_header :let={group_label}>
                  <.list_group_header label={group_label}>
                    {group_total(@groups, group_label)} {if group_total(@groups, group_label) == 1,
                      do: "runner",
                      else: "runners"} total
                  </.list_group_header>
                </:group_header>

                <:item :let={runner}>
                  <% state = connection_status(Runners.connection_state(runner)) %>
                  <li>
                    <.link
                      navigate={~p"/app/#{@current_account}/runners/#{runner.id}"}
                      class="-mx-2 flex items-center gap-4 rounded-md px-2 py-3 transition hover:bg-white/[0.04]"
                    >
                      <div class="min-w-0 flex-1">
                        <%!-- flex-wrap: the runner's name is its identity (often name
                         == hostname, so it's the only copy of it) — on a phone the
                         version + signed-only chip wrap below instead of crushing
                         it to "signed…". --%>
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="truncate font-medium text-zinc-100">{runner.name}</span>
                          <span
                            :if={runner.runner_version}
                            class="font-mono text-[11px] text-zinc-500"
                          >
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
                            signed-only
                          </.chip>
                        </div>
                        <.meta_line class="mt-0.5 text-xs text-zinc-500">
                          <%!-- When name == hostname the title already says it —
                           don't restate the identifier one line down. --%>
                          <:seg :if={
                            (runner.hostname || runner.external_id || "no host") != runner.name
                          }>
                            {runner.hostname || runner.external_id || "no host"}
                          </:seg>
                          <:seg><.heartbeat_status runner={runner} status={state} /></:seg>
                        </.meta_line>
                      </div>

                      <div class="flex items-center gap-4 text-right">
                        <%!-- Zero is the default, not a signal — muted em-dash;
                         "N active runs" only when something is running. --%>
                        <div class="hidden w-20 text-xs tabular-nums text-zinc-400 sm:block">
                          <%!-- Blank at zero, not an em-dash: with every runner idle this column
                           rendered a stack of dashes that read as a BUG, not data (the
                           muted-dash rule is for an occasionally-empty cell, not a
                           usually-empty column). The w-20 slot keeps pills aligned. --%>
                          <span :if={runner.action_load > 0} class="tabular-nums">
                            {runner.action_load} active runs
                          </span>
                        </div>
                        <.status_badge status={state} class="shrink-0" />
                      </div>
                    </.link>
                  </li>
                </:item>
              </LiveTable.live_table>
            </div>

            <.docs_rail title="What's a runner?" doc_href="/docs/runners" doc_label="Runner docs">
              <p>
                A runner is the small <span class="text-zinc-200">emisar agent</span>
                installed on one of your hosts — a server, VM, or container.
              </p>
              <p>
                It's what actually runs an action. The cloud never touches your hosts directly: it
                dispatches to a runner, which executes only the vetted actions in its trusted packs
                and reports the result back.
              </p>
              <p>
                A host needs a connected runner before you can dispatch to it. Give runners a
                <span class="font-mono text-[13px] text-zinc-300">group</span>
                (like <span class="font-mono text-[13px] text-zinc-300">web</span>
                or <span class="font-mono text-[13px] text-zinc-300">cassandra-prod</span>) so
                policies, runbooks, and an LLM's fan-out can target a whole tier at once.
              </p>
            </.docs_rail>
          </div>
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
    last heartbeat{" "}<.local_time
      id={"runner-heartbeat-#{@runner.id}"}
      value={@heartbeat_at}
      mode={:relative}
    />
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
    last seen{" "}<.local_time id={"runner-seen-#{@runner.id}"} value={@seen_at} mode={:relative} />
    """
  end

  defp heartbeat_status(assigns), do: ~H"never connected"
end
