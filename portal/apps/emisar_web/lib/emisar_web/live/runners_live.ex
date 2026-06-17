defmodule EmisarWeb.RunnersLive do
  use EmisarWeb, :live_view

  alias Emisar.Runners
  alias EmisarWeb.LiveTable

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket), do: Runners.subscribe_connections(account_id)

    {:ok, assign(socket, :page_title, "Runners")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info(%{event: "presence_diff"}, socket), do: {:noreply, reload(socket)}
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

    case Runners.list_runners_for_account(socket.assigns.current_subject, list_opts) do
      {:ok, runners, meta} ->
        groups =
          case Runners.list_group_summaries(socket.assigns.current_subject) do
            {:ok, list} -> list
            _ -> []
          end

        socket
        |> assign(:runners, runners)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:groups, groups)
        |> assign(:fleet, fleet)

      # A clean reload can fail too (e.g. a tightened list permission) —
      # degrade to an empty page rather than recursing forever.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:runners, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:groups, [])
        |> assign(:fleet, fleet)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

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
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runners}
      width={:table}
    >
      <:title>Runners</:title>
      <:actions>
        <.button navigate={~p"/app/#{@current_account}/runners/install"} size="md" icon="hero-plus">
          Add a runner
        </.button>
      </:actions>

      <%= if @runners == [] && @metadata.count == 0 do %>
        <%= if connected?(@socket) do %>
          <.empty_state icon="hero-cpu-chip" title="No runners yet">
            A runner is the emisar binary on one of your hosts. The install wizard mints a fresh
            auth key and gives you a one-liner to paste on a Linux or macOS box.
            <:cta navigate={~p"/app/#{@current_account}/runners/install"}>Open install wizard</:cta>
          </.empty_state>
        <% else %>
          <%!-- Dead/pre-connect render — defer the onboarding pitch until the
               live socket confirms there really are no runners. --%>
          <.loading_state />
        <% end %>
      <% else %>
        <%!-- Fleet health at a glance, so "is anything down?" doesn't mean
             scanning every dot. Whole-account (like the group sidebar +
             list below), counted from presence — there's no `:stale` state
             (heartbeat liveness is socket-enforced; see Runners.connection_state). --%>
        <%!-- Health-at-a-glance, small + muted like the per-group totals below.
             The whole-account total is NOT repeated here — it lives in the group
             header(s), so it isn't duplicated above and below the table. --%>
        <.summary_band>
          <.summary_stat tone={:emerald} value={@fleet.online} label="Online" />
          <.summary_stat tone={:rose} value={@fleet.offline} label="Offline" />
          <.summary_stat
            :if={@fleet.pending > 0}
            tone={:amber}
            value={@fleet.pending}
            label="Pending"
          />
          <.summary_stat
            :if={@fleet.disabled > 0}
            tone={:zinc}
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
            <li class="border-b border-zinc-900 bg-zinc-950/60 px-5 py-2 flex items-baseline gap-2">
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-200">
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
                <%!-- Connection dot: green/pulsing when live, amber
                     when known-but-disconnected, zinc when never
                     seen. Clearer than reading a status badge first. --%>
                <.connection_dot status={state} />

                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-2">
                    <span class="truncate font-medium text-zinc-100">{runner.name}</span>
                    <span :if={runner.runner_version} class="font-mono text-[11px] text-zinc-500">
                      v{runner.runner_version}
                    </span>
                  </div>
                  <div class="mt-0.5 truncate text-xs text-zinc-500">
                    <%!-- {" "} guards the space before the component — HEEx trims
                         the newline the formatter inserts between "·" and the tag. --%>
                    {runner.hostname || runner.external_id || "no host"} ·{" "}<.heartbeat_status
                      runner={runner}
                      status={state}
                    />
                  </div>
                </div>

                <div class="flex items-center gap-4 text-right">
                  <div class="hidden text-xs text-zinc-400 sm:block">
                    {runner.action_load} active
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

  attr :status, :string, required: true

  defp connection_dot(%{status: "connected"} = assigns) do
    ~H"""
    <span class="relative grid h-3 w-3 flex-none place-items-center" title="Connected">
      <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-500/40">
      </span>
      <span class="relative h-2 w-2 rounded-full bg-emerald-400"></span>
    </span>
    """
  end

  defp connection_dot(%{status: "disabled"} = assigns) do
    ~H"""
    <span class="h-2.5 w-2.5 flex-none rounded-full bg-zinc-700" title="Disabled"></span>
    """
  end

  defp connection_dot(assigns) do
    ~H"""
    <span class="h-2.5 w-2.5 flex-none rounded-full bg-zinc-600" title="Disconnected"></span>
    """
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
