defmodule EmisarWeb.RunnersLive do
  use EmisarWeb, :live_view
  alias Emisar.Compat
  alias Emisar.Runners
  alias EmisarWeb.FleetStates
  alias EmisarWeb.LiveTable
  alias EmisarWeb.RunnerInstall
  alias EmisarWeb.UrlHelpers

  @reload_debounce_ms 500

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runners")
     |> assign(:install_command, nil)
     |> assign(:base_url, UrlHelpers.derive_base_url(socket))
     |> assign(:show_troubleshooting?, false)
     |> assign(:reload_scheduled?, false)
     |> assign_retention_hours(socket.assigns.current_account)}
  end

  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      {:noreply, load(socket, params)}
    else
      {:noreply, prepare_disconnected(socket, params)}
    end
  end

  def handle_info(%{event: "presence_diff"} = event, socket) do
    change = Runners.normalize_connection_change(event)

    if Runners.connection_topology_changed?(change) do
      {:noreply, schedule_reload(socket)}
    else
      runners = Enum.map(socket.assigns.runners, &Runners.project_runner_connection(&1, change))
      {:noreply, assign(socket, :runners, runners)}
    end
  end

  def handle_info(:reload_runners, socket),
    do: {:noreply, socket |> assign(:reload_scheduled?, false) |> reload()}

  # The empty-state wizard's grace period elapsed with no runner — reveal its
  # troubleshooting checklist (a runner joining first re-runs load/2, which drops
  # show_wizard? and shows the list, pre-empting this).
  def handle_info(:reveal_troubleshooting, socket),
    do: {:noreply, assign(socket, :show_troubleshooting?, true)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(socket, ~p"/app/#{socket.assigns.current_account}/runners", params)}
  end

  # Runners owns the cleanup contract — it re-checks manage_runners and the
  # unrestricted runner access the account-wide schedule needs (IL-15), and
  # validates the raw window, so a crafted event from a viewer or a
  # runner-scoped admin denies and a malformed one is a changeset error rather
  # than a stored setting.
  def handle_event("set_runner_retention", %{"hours" => _raw} = attrs, socket) do
    case Runners.update_inactive_retention_settings(
           socket.assigns.current_account,
           attrs,
           socket.assigns.current_subject
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:current_account, account)
         |> assign_retention_hours(account)
         |> put_flash(:info, retention_set_flash(retention_hours(account)))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Pick a valid cleanup period.")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only owners and admins with full runner access can change this setting."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update automatic cleanup.")}
    end
  end

  def handle_event("cleanup_inactive_now", _params, socket) do
    case Runners.sweep_inactive_runners(socket.assigns.current_subject) do
      {:ok, 0} ->
        {:noreply,
         put_flash(socket, :info, "Nothing to remove — no runner has been inactive that long.")}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, cleanup_flash(count))
         |> reload()}

      {:error, :retention_disabled} ->
        {:noreply, put_flash(socket, :error, "Turn on automatic cleanup first.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to clean up runners.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not clean up — try again.")}
    end
  end

  defp assign_retention_hours(socket, account),
    do: assign(socket, :retention_hours, retention_hours(account))

  # The stored window is data, not a promise: an unusable value reads as off —
  # the same verdict the sweep takes — instead of reaching the phrase helpers.
  defp retention_hours(account) do
    case Runners.inactive_retention_hours(account) do
      {:ok, hours} -> hours
      {:error, :retention_disabled} -> nil
    end
  end

  defp retention_set_flash(nil), do: "Automatic cleanup turned off — inactive runners are kept."

  defp retention_set_flash(hours) do
    period = retention_period_phrase(hours)
    "Automatic cleanup on — runners inactive for #{period} are removed by the hourly sweep."
  end

  defp cleanup_flash(1), do: "Removed 1 inactive runner."
  defp cleanup_flash(count), do: "Removed #{count} inactive runners."

  # What a member who can't change the schedule reads in its place. Worded like
  # the select's own options, so both audiences read the setting the same way.
  defp retention_value_label(nil), do: "Off"
  defp retention_value_label(hours), do: "After #{retention_period_phrase(hours)} inactive"

  defp retention_period_phrase(1), do: "1 hour"
  defp retention_period_phrase(24), do: "1 day"

  defp retention_period_phrase(hours) when rem(hours, 24) == 0,
    do: "#{div(hours, 24)} days"

  defp retention_period_phrase(hours), do: "#{hours} hours"

  defp runner_retention_options(current_hours) do
    [
      %{
        value: "",
        label: "Off — keep inactive runners",
        selected: is_nil(current_hours),
        disabled: false
      },
      retention_option(1, "After 1 hour inactive", current_hours),
      retention_option(6, "After 6 hours inactive", current_hours),
      retention_option(24, "After 1 day inactive", current_hours),
      retention_option(168, "After 7 days inactive", current_hours),
      retention_option(336, "After 14 days inactive", current_hours),
      retention_option(720, "After 30 days inactive", current_hours),
      retention_option(1_440, "After 60 days inactive", current_hours),
      retention_option(2_160, "After 90 days inactive", current_hours)
    ]
  end

  defp retention_option(hours, label, current_hours) do
    %{
      value: Integer.to_string(hours),
      label: label,
      selected: current_hours == hours,
      disabled: false
    }
  end

  # PubSub-driven refresh — re-run the current page/filter.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  defp schedule_reload(%{assigns: %{reload_scheduled?: true}} = socket), do: socket

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload_runners, @reload_debounce_ms)
    assign(socket, :reload_scheduled?, true)
  end

  defp prepare_disconnected(socket, params) do
    socket
    |> assign(:runners, [])
    |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
    |> assign(:show_wizard?, false)
    |> assign(:has_runner_access?, false)
    |> assign(:has_full_runner_access?, false)
    |> assign(:filter_params, params)
    |> assign(:filters, Runners.runner_filters())
    |> assign(:groups, [])
    |> assign(:fleet, Runners.fleet_status([]))
    |> assign(:loaded?, false)
    |> assign(:load_error?, false)
  end

  defp load(socket, params) do
    filters = Runners.runner_filters()
    opts = LiveTable.params_to_opts(params, filters)
    runner_access = Runners.runner_access_facts_for_subject(socket.assigns.current_subject)

    # Runners derives current access from the subject, so the URL cannot select
    # a broader membership. Rows, group summaries, and fleet posture all use the
    # same scoped fleet; counts must not reveal inaccessible runners.

    # Fleet posture — counts, signature mode, and the reasons behind them — is
    # projected from the complete accessible set, not the current page. That one
    # read also answers the account-wide signed-only question, so a whole-fleet
    # notice never disagrees with the counters beside it.
    fleet = load_fleet_status(socket.assigns.current_subject)

    opts = Keyword.put(opts, :preload, [:online?])

    case Runners.list_runners_for_account(socket.assigns.current_subject, opts) do
      {:ok, runners, meta} ->
        # nil, not [] — a failed summaries read must not print "0 runners total"
        # above the group's own visible rows.
        groups =
          case Runners.list_group_summaries(socket.assigns.current_subject) do
            {:ok, list} -> list
            _ -> nil
          end

        # An empty fleet on the live socket IS the wizard — mint the one-liner and
        # render the installer inline, so a first-time operator connects a host
        # without a detour to /runners/install (the LLM-agents page does the same).
        #
        # `meta.count` is the FILTERED count, so a filter that matches nothing —
        # `?group=` a retired group — otherwise reads as an empty fleet: a
        # 500-runner account gets "connect your first runner" AND a freshly
        # minted root-capable install key on every visit. A filtered miss is an
        # empty RESULT, never an empty fleet.
        show_wizard? =
          runner_access.full_access? and runners == [] and meta.count == 0 and connected?(socket) and
            not LiveTable.has_active_filters?(params, filters)

        socket
        |> maybe_mint_install(
          show_wizard? and Runners.subject_can_install_runners?(socket.assigns.current_subject)
        )
        |> assign(:runners, runners)
        |> assign(:metadata, meta)
        |> assign(:show_wizard?, show_wizard?)
        |> assign(:has_runner_access?, runner_access.has_access?)
        |> assign(:has_full_runner_access?, runner_access.full_access?)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:groups, groups)
        |> assign(:fleet, fleet)
        |> assign(:loaded?, true)
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — show a
      # load-error state, NOT a silent empty fleet (that would read "no runners"
      # when really the read failed and a host may well be connected).
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:runners, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:show_wizard?, false)
        |> assign(:has_runner_access?, runner_access.has_access?)
        |> assign(:has_full_runner_access?, runner_access.full_access?)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:groups, [])
        |> assign(:fleet, fleet)
        |> assign(:loaded?, true)
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

  defp load_fleet_status(subject) do
    case Runners.fetch_fleet_status(subject) do
      {:ok, fleet} -> fleet
      _ -> Runners.fleet_status([])
    end
  end

  def render(assigns) do
    ~H"""
    <.console_shell
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
      section={:runners}
      width={:table}
    >
      <:title>Runners</:title>
      <%!-- The wizard IS the add flow, so the button (→ the same wizard) is
           redundant while an empty fleet shows it inline. --%>
      <:actions :if={not @show_wizard?}>
        <%!-- Enrollment keys are the fleet's OWN sub-feature (the audit "SIEM
             export" pattern) — a quiet secondary door on the owning page, not a
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
          icon="action.add"
        >
          Connect a runner
        </.button>
      </:actions>

      <.page_intro :if={not @show_wizard?}>
        Live connection state for every host you can access — a runner must be connected before
        you can dispatch an action to it.
      </.page_intro>

      <%= cond do %>
        <% @load_error? -> %>
          <.empty_state
            tone={:danger}
            icon="state.warning"
            title="Couldn't load your fleet"
          >
            This is a load error, not an empty fleet — a host may well be connected. Refresh the
            page; if it persists, your access to this account may have changed.
          </.empty_state>
        <% @show_wizard? and not Runners.subject_can_install_runners?(@current_subject) -> %>
          <%!-- Zero fleet, no install permission: the pitch without a wizard
               whose mint can only fail. --%>
          <.empty_state icon="product.runner" title="No runners yet.">
            A runner is the emisar binary on one of your hosts. Connecting one needs
            an operator role or above, with access to all runners — ask a teammate
            who has both, and the new host's live state will appear here.
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
        <% not @loaded? -> %>
          <%!-- Dead/pre-connect render — defer the onboarding pitch until the
               live socket confirms there really are no runners. --%>
          <.loading_state />
        <% not @has_runner_access? -> %>
          <.empty_state icon="product.runner" title="No runner access">
            You don't have access to any runners. An owner or admin can grant it from Team.
          </.empty_state>
        <% not @has_full_runner_access? and @metadata.count == 0 and
             not LiveTable.has_active_filters?(@filter_params, @filters) -> %>
          <.empty_state icon="product.runner" title="No runners in your access">
            No runners match your assigned scope. An owner or admin can update it from Team.
          </.empty_state>
        <% true -> %>
          <%!-- :table width leaves the fleet list too narrow-of-content and wide
               of page — pair it with a docs rail (the main+aside grammar): the
               fleet leads, a plain-terms "what's a runner" teaches beside it. The
               rail is a FIXED 22rem track that only splits off at xl (so its prose
               never squeezes to 3 words a line); below xl it's hidden — the fleet
               leads, and the explainer is supporting context, not something to
               scroll past on a narrow screen. --%>
          <div class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
            <div class="min-w-0">
              <%!-- Alerts keep a tight internal rhythm, then the stack leaves a
                   larger exit gutter before ordinary fleet counters and rows. --%>
              <div
                :if={fleet_notices?(@fleet, @runners)}
                id="fleet-attention"
                class="mb-10 space-y-6"
              >
                <%!-- Fleet-dark escalation: runners exist but none are reachable, so
                     nothing can be dispatched right now. --%>
                <.offline_notice
                  :if={@fleet.counts.online == 0 and @fleet.counts.offline > 0}
                  severity={:critical}
                  title="All runners offline"
                >
                  Every runner in this fleet is disconnected — dispatched actions will queue (or fail)
                  until one reconnects. Check the hosts, or the runner service on them.
                </.offline_notice>
                <%!-- Whole-fleet dispatch posture: every active runner is signed-only, so the
                     portal is locked out account-wide. --%>
                <.callout
                  :if={@fleet.signature_mode == :signed_only}
                  tone={:brand}
                  icon="trust.signed_dispatch"
                  title="Fleet is signed-only"
                >
                  Every runner in this account verifies a client signature and refuses unsigned runs, so
                  the portal can't dispatch to any of them. Runs and runbooks must come from an MCP client
                  configured with each runner's signing key.
                  <.doc_link href={~p"/docs/signed-dispatch"}>Signed dispatch docs</.doc_link>
                </.callout>
                <.version_upgrade_notice
                  id="runner-upgrade"
                  kind={:runner}
                  versions={Enum.map(@runners, & &1.runner_version)}
                  base_url={@base_url}
                />
              </div>
              <%!-- Fleet health at a glance, so "is anything down?" doesn't mean
             scanning every accessible dot. Counted from presence. NAKED posture line, not a boxed band — the
             dashboard pillar grammar: healthy counts stay quiet, offline wears
             amber (needs attention, not failed — the ONE tone the fact wears
             everywhere). --%>
              <div class="flex flex-wrap items-center gap-x-5 gap-y-1 pb-4 text-xs">
                <span class="flex items-center gap-1.5">
                  <%!-- Zero connected is not a healthy state: green is a real
                       pass/healthy fact (design-system §3.1), so the dot only
                       goes brand once a host is actually reachable. --%>
                  <.status_dot
                    tone={if @fleet.counts.online > 0, do: :brand, else: :neutral}
                    size={:sm}
                  />
                  <span class="tabular-nums text-zinc-400">
                    {@fleet.counts.online} {FleetStates.label(:online)}
                  </span>
                </span>
                <span :if={@fleet.counts.offline > 0} class="flex items-center gap-1.5">
                  <.status_dot tone={:amber} size={:sm} />
                  <span class="tabular-nums text-amber-300">
                    {@fleet.counts.offline} {FleetStates.label(:offline)}
                  </span>
                </span>
                <span :if={@fleet.counts.pending > 0} class="flex items-center gap-1.5">
                  <.status_dot tone={:amber} size={:sm} />
                  <span class="tabular-nums text-amber-300">
                    {@fleet.counts.pending} {FleetStates.label(:pending)}
                  </span>
                </span>
                <span :if={@fleet.counts.disabled > 0} class="flex items-center gap-1.5">
                  <.status_dot tone={:neutral} size={:sm} />
                  <span class="tabular-nums text-zinc-400">
                    {@fleet.counts.disabled} {FleetStates.label(:disabled)}
                  </span>
                </span>
              </div>

              <%!-- Group headers show accessible totals; the runners list below
             is paginated and may show fewer rows per
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
                filters={@filters}
                filter_params={@filter_params}
                wrapper_class="divide-y divide-zinc-800/70"
                group_by={fn runner -> runner.group || "(no group)" end}
              >
                <:empty>No runners match this search.</:empty>

                <:group_header :let={group_label}>
                  <.list_group_header label={group_label}>
                    {group_total_label(@groups, group_label)}
                  </.list_group_header>
                </:group_header>

                <:item :let={runner}>
                  <% readiness = Runners.runner_readiness(runner) %>
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
                            class="font-mono text-[11px] text-zinc-400"
                          >
                            {version_label(runner.runner_version)}
                          </span>
                          <.version_chip
                            kind={:runner}
                            version={runner.runner_version}
                            id={"runner-version-#{runner.id}"}
                          />
                          <%!-- Hardened runners are scannable at a glance — the portal
                           can't dispatch to them; only signed MCP calls run. --%>
                          <.chip
                            :if={readiness.signatures.mode == :signed_only}
                            tone={:neutral}
                            icon="trust.signed_dispatch"
                            title="Runs only signed dispatches — the portal can't dispatch to this runner"
                          >
                            signed-only
                          </.chip>
                        </div>
                        <.meta_line class="mt-0.5 text-xs text-zinc-400">
                          <%!-- When name == hostname the title already says it —
                           don't restate the identifier one line down. --%>
                          <:seg :if={
                            (runner.hostname || runner.external_id || "no host") != runner.name
                          }>
                            {runner.hostname || runner.external_id || "no host"}
                          </:seg>
                          <:seg><.heartbeat_status readiness={readiness} /></:seg>
                          <%!-- Zero is the default, not a signal — the count joins the meta
                           line only while something is actually running. --%>
                          <:seg :if={readiness.action_load > 0}>
                            {active_runs_label(readiness.action_load)}
                          </:seg>
                        </.meta_line>
                      </div>

                      <div class="flex items-center gap-4 text-right">
                        <.runner_status_badge
                          state={readiness.connection.state}
                          version={runner.runner_version}
                          class="shrink-0"
                        />
                      </div>
                    </.link>
                  </li>
                </:item>
              </LiveTable.live_table>
            </div>

            <div class="hidden space-y-6 xl:block">
              <.docs_rail
                title="What's a runner?"
                doc_href="/docs/runner-fleet"
                doc_label="Runner docs"
              >
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

              <div>
                <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                  Housekeeping
                </h3>
                <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — self-contained control card, the team-security rail grammar --%>
                <div id="runners-cleanup" class="mt-3 rounded-xl border border-zinc-800/80 p-4">
                  <h4 class="text-sm font-medium text-zinc-100">Automatic cleanup</h4>
                  <p class="mt-1 text-xs leading-relaxed text-zinc-400">
                    Remove runners that have been disconnected for the selected period. An hourly
                    sweep deletes them; a host that comes back online re-enrolls as a fresh
                    runner. Currently-connected and disabled runners are never touched.
                  </p>
                  <.gated_setting
                    id="runner-retention"
                    can_change?={Runners.subject_can_manage_inactive_retention?(@current_subject)}
                    value={retention_value_label(@retention_hours)}
                    who_can_change="Only owners and admins can change this."
                    class="mt-3"
                  >
                    <form id="runner-retention-form" phx-change="set_runner_retention">
                      <.select
                        name="hours"
                        aria-label="Remove runners inactive for"
                        options={runner_retention_options(@retention_hours)}
                      />
                    </form>
                  </.gated_setting>
                  <%!-- A runner-scoped admin can't set the account-wide schedule but can
                       still run the manual sweep — it's narrowed to their own scope. --%>
                  <.confirm_button
                    :if={@retention_hours && Runners.subject_can_manage_runners?(@current_subject)}
                    id="runners-cleanup-now"
                    variant={:secondary}
                    tone={:neutral}
                    size={:lg}
                    class="mt-3 w-full"
                    title="Clean up inactive runners?"
                    confirm_label="Clean up now"
                    on_confirm={JS.push("cleanup_inactive_now")}
                  >
                    <:body>
                      Soft-deletes every runner inactive for more than {retention_period_phrase(
                        @retention_hours
                      )}. A host that comes back online re-enrolls as a fresh runner; its
                      audit history is kept.
                    </:body>
                    Clean up now
                  </.confirm_button>
                </div>
              </div>
            </div>
          </div>
      <% end %>
    </.console_shell>
    """
  end

  # Visible (this-page) runners, grouped + sorted by group name so the
  # Pre-sort the page's runners by group so `<.live_table group_by={…}>`
  # walks them in stable order and emits one `:group_header` per group.
  # Within a group the natural ordering from the context (recently active
  # first) is preserved.
  defp sort_by_group(runners), do: Enum.sort_by(runners, &(&1.group || ""))

  # Whether the notice stack above the fleet has anything to say. Not all of it
  # is attention: a dark fleet and a signed-only posture are, while an available
  # update rides here as a neutral heads-up — the notices carry that difference
  # in their own tone, so this only decides whether the section exists at all.
  defp fleet_notices?(fleet, runners) do
    (fleet.counts.online == 0 and fleet.counts.offline > 0) or
      fleet.signature_mode == :signed_only or
      Enum.any?(runners, &(Compat.runner_status(&1.runner_version) in [:outdated, :unsupported]))
  end

  # The group's whole-fleet total, or nothing at all when the summaries read
  # failed — a count is a fact, and an unread one has no honest placeholder.
  defp group_total_label(nil, _group), do: nil

  defp group_total_label(groups, group) do
    total =
      Enum.find_value(groups, 0, fn
        {^group, n} -> n
        _ -> nil
      end)

    "#{total} #{if total == 1, do: "runner", else: "runners"} total"
  end

  # "last heartbeat 3m ago" / "just connected — waiting for first
  # heartbeat" / "last seen 5m ago" / "never connected". Composes the
  # readiness heartbeat fact into one human line — clearer than a "—" with
  # "(connected X ago)" tacked on the side. The two time-bearing cases
  # render the timestamp through <.local_time> (viewer-local, hoverable,
  # live) like every other timestamp; {" "} keeps the prefix from
  # abutting the <time> tag (HEEx trims the surrounding newline).
  attr :readiness, :map, required: true

  defp heartbeat_status(%{readiness: %{heartbeat: %{at: %DateTime{} = ts}}} = assigns) do
    assigns = assign(assigns, :heartbeat_at, ts)

    ~H"""
    last heartbeat{" "}<.local_time
      id={"runner-heartbeat-#{@readiness.runner_id}"}
      value={@heartbeat_at}
      mode={:relative}
    />
    """
  end

  defp heartbeat_status(%{readiness: %{heartbeat: %{state: :awaiting_first}}} = assigns) do
    ~H"just connected — waiting for first heartbeat"
  end

  defp heartbeat_status(%{readiness: %{heartbeat: %{connected_at: %DateTime{} = ts}}} = assigns) do
    assigns = assign(assigns, :seen_at, ts)

    ~H"""
    last seen{" "}<.local_time
      id={"runner-seen-#{@readiness.runner_id}"}
      value={@seen_at}
      mode={:relative}
    />
    """
  end

  defp heartbeat_status(assigns), do: ~H"never connected"

  defp active_runs_label(1), do: "1 active run"
  defp active_runs_label(count), do: "#{count} active runs"
end
