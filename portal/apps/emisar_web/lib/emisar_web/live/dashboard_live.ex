defmodule EmisarWeb.DashboardLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, Approvals, Audit, Billing, Catalog, PubSub, Runs}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe_account_runs(socket.assigns.current_account.id)
      PubSub.subscribe_account_runners(socket.assigns.current_account.id)
      PubSub.subscribe_account_approvals(socket.assigns.current_account.id)
    end

    {:ok,
     socket
     |> assign(:bootstrap_secret, nil)
     |> load()}
  end

  def handle_event("bootstrap_first_agent", _params, socket) do
    user_id = socket.assigns.current_user.id
    account_id = socket.assigns.current_account.id
    base_url = derive_base_url(socket)

    case Runners.create_auth_key(account_id, user_id, %{
           description: "First runner bootstrap (auto-generated)",
           reusable: true
         }) do
      {:ok, raw, _key} ->
        {:noreply,
         assign(socket, bootstrap_secret: %{key: raw, install_url: base_url})}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Could not generate the auth key.")}
    end
  end

  # Builds the URL the install command should target. In production
  # this is just the request scheme+host; in dev we keep the port so
  # `http://localhost:4000` survives intact.
  defp derive_base_url(socket) do
    case socket.host_uri do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        scheme = scheme || "http"
        port_part = default_port?(scheme, port)
        "#{scheme}://#{host}#{port_part}"

      _ ->
        "https://app.emisar.com"
    end
  end

  defp default_port?(_scheme, nil), do: ""
  defp default_port?("https", 443), do: ""
  defp default_port?("http", 80), do: ""
  defp default_port?(_scheme, port), do: ":#{port}"

  def handle_info({_event, _struct}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    account = socket.assigns.current_account

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:agents_total, length(Runners.list_runners_for_account(account.id)))
    |> assign(:agents_connected, length(Runners.list_runners_for_account(account.id, status: "connected")))
    |> assign(:actions_count, length(Catalog.list_actions_for_account(account.id)))
    |> assign(:recent_runs, Runs.list_runs_for_account(account.id, limit: 8))
    |> assign(:pending_approvals, Approvals.list_pending(account.id))
    |> assign(:recent_audit, Audit.list_events_for_account(account.id, limit: 10))
    |> assign(:billing, Billing.billing_summary(account))
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:dashboard}
    >
      <:title>Dashboard</:title>

      <%= if @agents_total == 0 do %>
        <.empty_state_first_agent bootstrap_secret={@bootstrap_secret} />
      <% else %>
        <.live_dashboard
          agents_connected={@agents_connected}
          agents_total={@agents_total}
          actions_count={@actions_count}
          pending_approvals={@pending_approvals}
          recent_runs={@recent_runs}
          recent_audit={@recent_audit}
          billing={@billing}
        />
      <% end %>
    </.dashboard_shell>
    """
  end

  # First-time experience. Two states:
  #
  #   1. Before bootstrap: a single "Generate install command" button.
  #      Mints a reusable auth key in-place and reveals the real
  #      install one-liner pre-filled with the new secret.
  #   2. After bootstrap: the actual command + "waiting for runner…"
  #      indicator. This LV is subscribed to account-level runner
  #      events, so when the runner connects, the page flips to the
  #      populated dashboard automatically.
  attr :bootstrap_secret, :any, required: true

  defp empty_state_first_agent(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <div class="rounded-2xl border border-zinc-900 bg-gradient-to-b from-indigo-950/40 to-zinc-950/60 p-10">
        <div class="flex items-center gap-3">
          <span class="grid h-10 w-10 place-items-center rounded-xl bg-indigo-500/20 text-indigo-300 ring-1 ring-indigo-500/40">
            <.icon name="hero-rocket-launch" class="h-5 w-5" />
          </span>
          <div>
            <h2 class="text-xl font-semibold text-zinc-50">Connect your first runner</h2>
            <p class="text-sm text-zinc-400">
              Two minutes. Pick a Linux host, paste the one-liner.
            </p>
          </div>
        </div>

        <%= if @bootstrap_secret == nil do %>
          <div class="mt-8 space-y-4">
            <p class="text-sm text-zinc-400">
              We'll mint a reusable bootstrap auth key for this workspace and
              show you the exact install command. The key never leaves this
              browser tab unless you copy it.
            </p>
            <button
              phx-click="bootstrap_first_agent"
              class="inline-flex items-center gap-2 rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
            >
              Generate install command <.icon name="hero-arrow-right" class="h-4 w-4" />
            </button>

            <p class="text-xs text-zinc-500">
              Prefer manual? Generate a key in
              <.link navigate={~p"/app/settings/runners/auth-keys"} class="text-indigo-400 hover:text-indigo-300">
                settings → auth keys
              </.link>
              and follow the
              <.link href={~p"/docs"} class="text-indigo-400 hover:text-indigo-300">install docs</.link>.
            </p>
          </div>
        <% else %>
          <.bootstrap_reveal secret={@bootstrap_secret} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :secret, :map, required: true

  defp bootstrap_reveal(assigns) do
    base = assigns.secret.install_url
    # Leading space keeps the line out of shell history on shells configured
    # with HISTCONTROL=ignorespace/ignoreboth (bash, Debian/Ubuntu default)
    # or HIST_IGNORE_SPACE (zsh) — so the auth key isn't persisted to
    # ~/.bash_history / ~/.zsh_history.
    install =
      " curl -sSL #{base}/install.sh | sudo EMISAR_AUTH_KEY=#{assigns.secret.key} EMISAR_URL=#{base} bash"

    assigns = assign(assigns, :install_command, install)

    ~H"""
    <div class="mt-8 space-y-6">
      <div class="rounded-lg bg-amber-500/10 p-4 ring-1 ring-amber-500/30">
        <p class="text-xs text-amber-200/90">
          Treat this key like a password. Anyone with it can register an
          runner under your workspace. We won't show it again — copy it now.
        </p>
        <div class="mt-3 flex items-center gap-2 rounded-md bg-zinc-950/80 p-2 ring-1 ring-zinc-800">
          <code class="flex-1 break-all font-mono text-xs text-zinc-100">{@secret.key}</code>
          <button
            type="button"
            class="rounded bg-amber-500/20 px-2 py-1 text-xs font-semibold text-amber-100 hover:bg-amber-500/30"
            onclick={"navigator.clipboard.writeText('#{@secret.key}')"}
          >
            Copy
          </button>
        </div>
      </div>

      <div>
        <div class="text-xs uppercase tracking-wider text-zinc-500">Run on any Linux host</div>
        <div class="mt-2 flex items-center gap-2 rounded-lg border border-zinc-800 bg-black/60 p-4 font-mono text-xs">
          <code class="flex-1 whitespace-pre-wrap break-all text-zinc-300">{@install_command}</code>
          <button
            type="button"
            class="self-start rounded bg-indigo-500/20 px-2 py-1 text-xs font-semibold text-indigo-200 hover:bg-indigo-500/30"
            onclick={"navigator.clipboard.writeText('#{@install_command}')"}
          >
            Copy
          </button>
        </div>
        <p class="mt-2 text-xs text-zinc-500">
          Paste as-is — the leading space keeps the key out of your shell history.
        </p>
      </div>

      <div class="flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-950/60 p-4">
        <span class="relative flex h-3 w-3">
          <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-indigo-500/50"></span>
          <span class="relative inline-flex h-3 w-3 rounded-full bg-indigo-400"></span>
        </span>
        <div class="text-sm text-zinc-300">
          Waiting for an runner to connect. This page will refresh automatically.
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.link
          href="https://github.com/andrewdryga/emisar/blob/main/docs/install.md"
          class="rounded-xl border border-zinc-800 bg-zinc-950/60 p-4 transition hover:bg-zinc-900/60"
        >
          <div class="flex items-center gap-2 text-sm font-semibold text-zinc-200">
            <.icon name="hero-book-open" class="h-4 w-4 text-indigo-400" /> Installation guide
          </div>
          <p class="mt-1 text-xs text-zinc-500">
            Image-bake, cloud-init, manual install.
          </p>
        </.link>
        <.link
          href="https://github.com/andrewdryga/emisar/tree/main/runner/examples/packs"
          class="rounded-xl border border-zinc-800 bg-zinc-950/60 p-4 transition hover:bg-zinc-900/60"
        >
          <div class="flex items-center gap-2 text-sm font-semibold text-zinc-200">
            <.icon name="hero-cube-transparent" class="h-4 w-4 text-indigo-400" /> Example packs
          </div>
          <p class="mt-1 text-xs text-zinc-500">
            linux-core, cassandra, showcase. Start here.
          </p>
        </.link>
      </div>
    </div>
    """
  end

  # The "active" dashboard once at least one runner exists.
  attr :agents_connected, :integer, required: true
  attr :agents_total, :integer, required: true
  attr :actions_count, :integer, required: true
  attr :pending_approvals, :list, required: true
  attr :recent_runs, :list, required: true
  attr :recent_audit, :list, required: true
  attr :billing, :map, required: true

  defp live_dashboard(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-4 md:grid-cols-4">
      <.stat label="Runners online" value={@agents_connected} hint={"of #{@agents_total} total"} />
      <.stat label="Actions catalog" value={@actions_count} hint="across all runners" />
      <.stat label="Pending approvals" value={length(@pending_approvals)} hint="awaiting decision" />
      <.stat
        label="Plan"
        value={String.capitalize(@billing.plan)}
        hint={"#{@billing.audit_retention_days}-day audit retention"}
      />
    </div>

    <.link
      navigate={~p"/app/settings/api-keys"}
      class="mt-6 flex items-center gap-3 rounded-xl border border-indigo-900/40 bg-indigo-950/20 p-4 transition hover:border-indigo-700/60 hover:bg-indigo-950/40"
    >
      <.icon name="hero-bolt" class="h-5 w-5 flex-none text-indigo-400" />
      <div class="flex-1">
        <div class="text-sm font-semibold text-zinc-100">Connect an LLM to your actions</div>
        <p class="mt-0.5 text-xs text-zinc-400">
          Issue an API key in Settings → API keys. We'll generate copy-paste config
          for Claude Code, Claude Desktop, Cursor, Gemini CLI, and Codex CLI.
        </p>
      </div>
      <.icon name="hero-arrow-right" class="h-4 w-4 flex-none text-indigo-400" />
    </.link>

    <div class="mt-8 grid grid-cols-1 gap-6 lg:grid-cols-3">
      <.card class="lg:col-span-2">
        <.section_header title="Recent runs" href={~p"/app/runs"} cta="See all" />

        <%= if @recent_runs == [] do %>
          <.empty_state icon="hero-bolt" title="No runs yet" class="mt-4 border-0 bg-transparent p-6">
            Try one from the runner catalog or kick off a runbook.
            <:cta navigate={~p"/app/runners"}>Browse runners</:cta>
          </.empty_state>
        <% else %>
          <ul class="mt-4 divide-y divide-zinc-900">
            <li :for={run <- @recent_runs} class="py-3">
              <.link
                navigate={~p"/app/runs/#{run.id}"}
                class="flex items-center justify-between hover:opacity-80"
              >
                <div>
                  <div class="font-mono text-sm text-zinc-200">{run.action_id}</div>
                  <div class="text-xs text-zinc-500">{relative_time(run.inserted_at)}</div>
                </div>
                <.status_badge status={run.status} />
              </.link>
            </li>
          </ul>
        <% end %>
      </.card>

      <.card>
        <.section_header title="Awaiting approval" href={~p"/app/approvals"} cta="All" />

        <%= if @pending_approvals == [] do %>
          <.empty_state icon="hero-check-circle" title="All clear" class="mt-4 border-0 bg-transparent p-6">
            Nothing is waiting on a decision right now.
          </.empty_state>
        <% else %>
          <ul class="mt-4 divide-y divide-zinc-900">
            <li :for={req <- @pending_approvals} class="py-3">
              <.link navigate={~p"/app/approvals/#{req.id}"} class="text-sm hover:opacity-80">
                <div class="font-medium text-amber-200">
                  Approval #{String.slice(req.id, 0, 8)}
                </div>
                <div class="text-xs text-zinc-500">{relative_time(req.requested_at)}</div>
              </.link>
            </li>
          </ul>
        <% end %>
      </.card>
    </div>

    <.card class="mt-8">
      <.section_header title="Activity" href={~p"/app/audit"} cta="Full audit log" />

      <%= if @recent_audit == [] do %>
        <p class="mt-4 text-sm text-zinc-500">No events yet.</p>
      <% else %>
        <ul class="mt-4 space-y-2 text-sm">
          <li :for={ev <- @recent_audit} class="flex items-center justify-between text-zinc-300">
            <span class="font-mono text-xs">{ev.event_type}</span>
            <span class="text-zinc-500">{relative_time(ev.occurred_at)}</span>
          </li>
        </ul>
      <% end %>
    </.card>
    """
  end

end
