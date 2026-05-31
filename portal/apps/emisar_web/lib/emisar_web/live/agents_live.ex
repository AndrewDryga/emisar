defmodule EmisarWeb.AgentsLive do
  @moduledoc """
  "Agents" — the operator-facing view of API keys.

  Each API key represents one LLM client (Claude Code, Cursor, etc.)
  that can call the MCP tools API. The page mirrors the Runners page in
  layout: a status grid at top, a list of "connections" with live
  status badges, and a persistent "connect a new client" guide so the
  copy-paste config snippets are always one click away — not buried
  behind a "Generate key" button.

  Status derivation is based on `last_used_at`:

    * `:active`    — call within last 5 min (green pulse)
    * `:idle`      — call within last 24 h
    * `:dormant`   — call > 24 h ago
    * `:never_used`— issued but no MCP call has ever landed

  We re-render every #{5} s via a self-scheduled `:tick` so "Last call"
  + the status badge stay fresh without a full PubSub subscription on
  every MCP request.
  """
  use EmisarWeb, :live_view

  alias Emisar.{Runners, ApiKeys}
  alias Emisar.ApiKeys.ApiKey
  alias EmisarWeb.{LiveTable, Permissions, UrlHelpers}

  @all_scopes Emisar.ApiKeys.ApiKey.Changeset.valid_scopes()
  @active_threshold_secs 5 * 60
  @idle_threshold_secs 24 * 60 * 60
  @refresh_ms 5_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @refresh_ms)
    end

    # The page no longer auto-mints on load — instead the operator
    # first picks which LLM client they're connecting (Claude Desktop,
    # Cursor, Codex, …). When they pick, we mint a quick key whose
    # `name` reflects the choice so the audit trail and the agents
    # list both say "Claude Desktop" instead of "Quick connect (auto)".
    # The client id also flows into the snippet's EMISAR_CLIENT env
    # var so the bridge stamps it onto every User-Agent.
    #
    # Ring eviction in `ApiKeys.mint_quick_key/3` still caps unused
    # autos at 42 per account regardless of how many tabs the operator
    # opens.

    {:ok, runners, _} = Runners.list_runners_for_account(socket.assigns.current_subject)

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:all_scopes, @all_scopes)
     |> assign(:runners, runners)
     |> assign(:quick_secret, nil)
     |> assign(:selected_client, nil)
     |> assign(:show_advanced, false)
     |> assign(:base_url, UrlHelpers.derive_base_url(socket))
     |> assign_form(default_params())}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  # -- Events ----------------------------------------------------------

  def handle_event("select_client", %{"client" => id}, socket) do
    # First-pick mints a quick key whose name matches the client
    # (so it shows up as e.g. "Claude Desktop" on the agents list and
    # in audit rows). Switching clients re-mints — the previous
    # un-bound auto-key gets ring-evicted naturally.
    Permissions.gated(socket, :manage_api_keys, fn s ->
      name = client_label(id)

      case ApiKeys.mint_quick_key(s.assigns.current_subject, name: name) do
        {:ok, raw, _key} ->
          {:noreply,
           s
           |> assign(:selected_client, id)
           |> assign(:quick_secret, raw)
           |> reload()}

        {:error, _} ->
          {:noreply,
           s
           |> assign(:selected_client, id)
           |> put_flash(:error, "Could not mint a quick key.")}
      end
    end)
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, not socket.assigns.show_advanced)}
  end

  def handle_event("validate", %{"api_key" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    Permissions.gated(socket, :manage_api_keys, fn s -> do_create(s, params) end)
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(socket, :manage_api_keys, fn s -> do_revoke(s, id) end)
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, reload(socket)}
  end

  # -- Internals -------------------------------------------------------

  defp do_create(socket, params) do
    attrs = %{
      name: params["name"] || "",
      scopes: selected_scopes(params),
      runner_filter: selected_runner_ids(params, socket.assigns.runners),
      runner_group_filter: selected_runner_groups(params, socket.assigns.runners)
    }

    case ApiKeys.create_key(attrs, socket.assigns.current_subject) do
      {:ok, raw, _key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign(:show_advanced, false)
         |> assign_form(default_params())
         |> reload()}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create key: #{humanize_errors(changeset)}")}
    end
  end

  defp do_revoke(socket, id) do
    case ApiKeys.fetch_api_key_by_id(id, socket.assigns.current_subject) do
      {:error, :not_found} ->
        {:noreply, socket}

      {:ok, key} ->
        {:ok, _} = ApiKeys.revoke_api_key(key, socket.assigns.current_subject)
        {:noreply, socket |> put_flash(:info, "API key revoked.") |> reload()}
    end
  end

  # Refresh-in-place (tick / mutation): re-runs with current URL params
  # so the operator doesn't jump back to page 1 on revoke or every 5 s.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  defp load(socket, params) do
    opts = LiveTable.params_to_opts(params)

    case ApiKeys.list_api_keys_for_account(socket.assigns.current_subject, opts) do
      {:ok, keys, meta} ->
        socket
        |> assign(:api_keys, keys)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:active_count, count_status(keys, :active))
        |> assign(:idle_count, count_status(keys, :idle))
        |> assign(:never_used_count, count_status(keys, :never_used))
        |> assign(:issued_count, length(active_keys(keys)))

      {:error, _} ->
        load(socket, %{})
    end
  end

  defp active_keys(keys), do: Enum.reject(keys, & &1.revoked_at)

  defp count_status(keys, status),
    do: Enum.count(active_keys(keys), &(client_status(&1) == status))

  defp default_params do
    %{
      "name" => "",
      "scopes" => ["actions:read", "actions:execute"],
      "runner_filter" => [],
      "runner_group_filter" => []
    }
  end

  # Allowlist submitted runner IDs against the account's real runners
  # so a malicious POST can't sneak in IDs from another account.
  defp selected_runner_ids(%{"runner_filter" => ids}, runners) when is_list(ids) do
    allowed = MapSet.new(Enum.map(runners, & &1.id))
    Enum.filter(ids, &MapSet.member?(allowed, &1))
  end

  defp selected_runner_ids(%{"runner_filter" => ids}, runners) when is_map(ids) do
    allowed = MapSet.new(Enum.map(runners, & &1.id))

    ids
    |> Enum.filter(fn {_k, v} -> v in ["true", "on", true] end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.filter(&MapSet.member?(allowed, &1))
  end

  defp selected_runner_ids(_, _), do: []

  # Same allowlist treatment for groups: only accept group names that
  # actually exist on at least one of the account's runners. Prevents
  # a hand-rolled POST from sneaking in an arbitrary group string.
  defp selected_runner_groups(%{"runner_group_filter" => groups}, runners) when is_list(groups) do
    allowed = MapSet.new(Enum.map(runners, & &1.group))
    Enum.filter(groups, &MapSet.member?(allowed, &1))
  end

  defp selected_runner_groups(%{"runner_group_filter" => groups}, runners) when is_map(groups) do
    allowed = MapSet.new(Enum.map(runners, & &1.group))

    groups
    |> Enum.filter(fn {_k, v} -> v in ["true", "on", true] end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.filter(&MapSet.member?(allowed, &1))
  end

  defp selected_runner_groups(_, _), do: []

  defp selected_scopes(%{"scopes" => scopes}) when is_list(scopes),
    do: Enum.filter(scopes, &(&1 in @all_scopes))

  defp selected_scopes(%{"scopes" => scopes}) when is_map(scopes) do
    scopes
    |> Enum.filter(fn {_k, v} -> v in ["true", "on", true] end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.filter(&(&1 in @all_scopes))
  end

  defp selected_scopes(_), do: []

  defp assign_form(socket, params) do
    runners = socket.assigns[:runners] || []

    socket
    |> assign(:form, to_form(params, as: "api_key"))
    |> assign(:selected_scopes, selected_scopes(params))
    |> assign(:selected_runner_ids, selected_runner_ids(params, runners))
    |> assign(:selected_runner_groups, selected_runner_groups(params, runners))
  end

  defp format_runner_filter([], _runners), do: "All runners"

  defp format_runner_filter(ids, runners) do
    names =
      runners
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map(& &1.name)

    case names do
      [] -> "—"
      [one] -> one
      [a, b] -> "#{a}, #{b}"
      list -> "#{Enum.at(list, 0)} +#{length(list) - 1}"
    end
  end

  # Combined-scope label for an API key row: surfaces whichever
  # filter is active, or "All runners" when both are empty.
  defp format_key_scope(key, runners) do
    runner_ids = key.runner_filter || []
    groups = key.runner_group_filter || []

    cond do
      runner_ids == [] and groups == [] ->
        "all runners"

      groups != [] and runner_ids == [] ->
        "groups: #{Enum.join(groups, ", ")}"

      groups == [] and runner_ids != [] ->
        format_runner_filter(runner_ids, runners)

      true ->
        "groups: #{Enum.join(groups, ", ")} + #{length(runner_ids)} explicit"
    end
  end

  # -- Status derivation ----------------------------------------------

  defp client_status(%ApiKey{revoked_at: ts}) when not is_nil(ts), do: :revoked
  defp client_status(%ApiKey{last_used_at: nil}), do: :never_used

  defp client_status(%ApiKey{last_used_at: ts}) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff <= @active_threshold_secs -> :active
      diff <= @idle_threshold_secs -> :idle
      true -> :dormant
    end
  end

  defp status_label(:active), do: "Active"
  defp status_label(:idle), do: "Idle"
  defp status_label(:dormant), do: "Dormant"
  defp status_label(:never_used), do: "Never used"
  defp status_label(:revoked), do: "Revoked"

  # Maps to the colour palette `core_components.status_badge/1` uses
  # elsewhere — green for active, amber for idle/never, zinc for dormant.
  defp status_class(:active), do: "bg-emerald-500/10 text-emerald-300 ring-emerald-500/30"
  defp status_class(:idle), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp status_class(:dormant), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"
  defp status_class(:never_used), do: "bg-amber-500/10 text-amber-200 ring-amber-500/30"
  defp status_class(:revoked), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"

  # -- Client configs --------------------------------------------------
  #
  # Single source of truth for the "Connect a client" panel. Each entry
  # describes one MCP client: label, where its config lives, and a
  # body templated with this operator's URL + key.

  # `@client_ids` ordering drives the tab strip in `connect_panel/1` so
  # claude-code stays first. Map iteration order isn't guaranteed —
  # keep ids as a list and pair labels separately.
  @client_ids ~w(claude_code claude_desktop cursor gemini codex)
  @client_labels %{
    "claude_code" => "Claude Code",
    "claude_desktop" => "Claude Desktop",
    "cursor" => "Cursor",
    "gemini" => "Gemini CLI",
    "codex" => "Codex CLI"
  }

  defp client_label(id), do: Map.get(@client_labels, id, "MCP client")
  defp client_ids, do: @client_ids

  defp client_config(client_id, url, key) do
    case client_id do
      "claude_code" ->
        %{
          location: "One command — registers the bridge globally",
          body: """
          claude mcp add emisar /usr/local/bin/emisar-mcp \\
              --scope user \\
              -e EMISAR_URL=#{url} \\
              -e EMISAR_API_KEY=#{key} \\
              -e EMISAR_CLIENT=claude-code\
          """
        }

      "claude_desktop" ->
        %{
          location: "~/Library/Application Support/Claude/claude_desktop_config.json",
          body: mcp_json_snippet(url, key, "/usr/local/bin/emisar-mcp", "claude-desktop")
        }

      "cursor" ->
        %{
          location: "~/.cursor/mcp.json",
          body: mcp_json_snippet(url, key, "emisar-mcp", "cursor")
        }

      "gemini" ->
        %{
          location: "~/.gemini/settings.json",
          body: mcp_json_snippet(url, key, "/usr/local/bin/emisar-mcp", "gemini")
        }

      "codex" ->
        %{
          location: "~/.codex/config.toml",
          body: """
          [mcp_servers.emisar]
          command = "/usr/local/bin/emisar-mcp"
          env = { EMISAR_URL = "#{url}", EMISAR_API_KEY = "#{key}", EMISAR_CLIENT = "codex" }\
          """
        }
    end
  end

  # `client` is baked into EMISAR_CLIENT so the bridge can stamp it on
  # every cloud request's User-Agent — the audit page shows it as
  # "Client: claude-desktop" etc., so operators see which LLM client
  # produced each event without having to parse the IP.
  defp mcp_json_snippet(url, key, command, client) do
    """
    {
      "mcpServers": {
        "emisar": {
          "command": "#{command}",
          "env": {
            "EMISAR_URL": "#{url}",
            "EMISAR_API_KEY": "#{key}",
            "EMISAR_CLIENT": "#{client}"
          }
        }
      }
    }\
    """
  end

  # -- Render ----------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:agents}
    >
      <:title>Agents</:title>

      <%!-- Header summary strip — 4 stats in a single horizontal
           band instead of 4 separate tiles. Lower visual weight so
           the connect-a-client panel can lead. --%>
      <div class="mb-6 flex flex-wrap items-center gap-x-6 gap-y-2 rounded-xl border border-zinc-900 bg-zinc-950/40 px-5 py-3 text-sm">
        <.summary_stat tone={:emerald} value={@active_count} label="Active" hint="last 5 min" />
        <.summary_stat tone={:amber} value={@idle_count} label="Idle" hint="last 24 h" />
        <.summary_stat tone={:zinc} value={@never_used_count} label="Never used" />
        <div class="ml-auto text-xs text-zinc-500">
          {@metadata.count || @issued_count} {if (@metadata.count || @issued_count) == 1, do: "key", else: "keys"} total
        </div>
      </div>

      <%!-- Connect-a-client guide (always visible, pre-filled key) --%>
      <.connect_panel
        configs_for={fn id -> client_config(id, @base_url, @quick_secret || "emk-…") end}
        selected_client={@selected_client}
        quick_secret={@quick_secret}
      />

      <%!-- Connected agents list — single-column rows matching the
           AuthKeys / Grants visual language. --%>
      <section class="mt-8 overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40">
        <header class="border-b border-zinc-900 px-5 py-3">
          <h2 class="text-sm font-semibold text-zinc-100">Connected agents</h2>
        </header>

        <%= if @api_keys == [] do %>
          <div class="px-5 py-10 text-center text-sm text-zinc-500">
            No LLMs connected yet. Pick a client above and we'll mint a key + prefilled snippet.
          </div>
        <% else %>
          <ul class="divide-y divide-zinc-900">
            <li :for={key <- @api_keys} class="flex items-start gap-4 px-5 py-4">
              <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                <.icon name={agent_icon(key.name)} class="h-4 w-4" />
              </span>

              <div class="min-w-0 flex-1">
                <%!-- Row 1: name + status pill + scope chips --%>
                <div class="flex flex-wrap items-center gap-2">
                  <span class="truncate font-medium text-zinc-100">{key.name}</span>
                  <.client_status_pill key={key} />
                  <.chip :for={scope <- key.scopes || []} tone={:indigo} mono>{scope}</.chip>
                </div>

                <%!-- Row 2: prefix + scope (runners + groups) + last call --%>
                <div class="mt-1 truncate font-mono text-[11px] text-zinc-500">
                  {key.key_prefix}…
                  · {format_key_scope(key, @runners)}
                  · last call {format_last_used(key.last_used_at)}
                  <span :if={key.created_by}>· by {key.created_by.email}</span>
                </div>
              </div>

              <%= cond do %>
                <% key.revoked_at -> %>
                  <span></span>
                <% Permissions.can?(assigns, :manage_api_keys) -> %>
                  <button
                    phx-click="revoke"
                    phx-value-id={key.id}
                    data-confirm="Revoke this API key? The connected client will get 401s on its next call."
                    class="shrink-0 rounded-lg border border-rose-500/40 px-2.5 py-1 text-xs font-medium text-rose-200 hover:bg-rose-500/10"
                  >
                    Revoke
                  </button>
                <% true -> %>
                  <span></span>
              <% end %>
            </li>
          </ul>

          <div class="border-t border-zinc-900 px-5 py-3">
            <LiveTable.paginator
              id="agents"
              path={~p"/app/agents"}
              metadata={@metadata}
              filter_params={@filter_params}
            />
          </div>
        <% end %>
      </section>

      <%!-- Advanced: custom-shape key (scopes + runner allowlist) --%>
      <details
        :if={Permissions.can?(assigns, :manage_api_keys)}
        class="group mt-6 rounded-xl border border-zinc-900 bg-zinc-950/40"
      >
        <summary class="flex cursor-pointer items-center justify-between gap-3 px-5 py-3 text-sm text-zinc-300 hover:text-zinc-100">
          <span class="flex items-center gap-2">
            <.icon name="hero-adjustments-horizontal" class="h-4 w-4 text-zinc-500" />
            Need a custom key? Restrict scopes or runners.
          </span>
          <.icon name="hero-chevron-down" class="h-4 w-4 text-zinc-500 transition group-open:rotate-180" />
        </summary>

        <div class="border-t border-zinc-900 px-5 py-5">
          <.advanced_create_panel
            form={@form}
            all_scopes={@all_scopes}
            selected_scopes={@selected_scopes}
            runners={@runners}
            selected_runner_ids={@selected_runner_ids}
            selected_runner_groups={@selected_runner_groups}
          />
        </div>
      </details>
    </.dashboard_shell>
    """
  end

  attr :tone, :atom, required: true, values: [:emerald, :amber, :zinc]
  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  defp summary_stat(assigns) do
    ~H"""
    <div class="flex items-baseline gap-1.5">
      <span class={["text-base font-semibold", summary_value_class(@tone)]}>{@value}</span>
      <span class="text-zinc-400">{@label}</span>
      <span :if={@hint} class="text-xs text-zinc-600">({@hint})</span>
    </div>
    """
  end

  defp summary_value_class(:emerald), do: "text-emerald-300"
  defp summary_value_class(:amber), do: "text-amber-300"
  defp summary_value_class(:zinc), do: "text-zinc-300"

  attr :key, :map, required: true

  defp client_status_pill(assigns) do
    status = client_status(assigns.key)
    assigns = assign(assigns, status: status)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-1.5 py-0.5 text-[10px] font-medium ring-1 ring-inset",
      status_class(@status)
    ]}>
      <span :if={@status == :active} class="relative inline-flex h-1.5 w-1.5">
        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75"></span>
        <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-emerald-400"></span>
      </span>
      {status_label(@status)}
    </span>
    """
  end

  # Picks a hero icon that vaguely matches the client family — purely
  # for visual differentiation in the list, doesn't carry meaning.
  defp agent_icon(name) when is_binary(name) do
    n = String.downcase(name)

    cond do
      String.contains?(n, "claude") -> "hero-sparkles"
      String.contains?(n, "cursor") -> "hero-cursor-arrow-rays"
      String.contains?(n, "gemini") -> "hero-star"
      String.contains?(n, "codex") -> "hero-code-bracket"
      true -> "hero-cpu-chip"
    end
  end

  defp agent_icon(_), do: "hero-cpu-chip"

  defp format_last_used(nil), do: "never"
  defp format_last_used(ts), do: relative_time(ts)

  attr :configs_for, :any, required: true
  attr :selected_client, :any, required: true
  attr :quick_secret, :string, default: nil

  defp connect_panel(assigns) do
    config =
      if assigns.selected_client,
        do: assigns.configs_for.(assigns.selected_client),
        else: nil

    assigns = assign(assigns, :config, config)

    ~H"""
    <div class="overflow-hidden rounded-2xl border border-zinc-900 bg-zinc-950/60">
      <div class="border-b border-zinc-900 px-6 py-4">
        <h2 class="text-base font-semibold text-zinc-50">Connect a client</h2>
        <p class="mt-0.5 text-xs text-zinc-500">
          Pick the LLM client you're connecting. We mint a fresh API key named after the
          client (so audit rows say "Claude Desktop" instead of "Quick connect"), pre-fill
          its install snippet, and stamp every call with a User-Agent that names the host
          and client.
        </p>
      </div>

      <%!-- Step 1: install the MCP binary. Same one-liner regardless of
           client, so render once at the top instead of buried in each
           per-client snippet's footer link. --%>
      <div class="border-b border-zinc-900 px-6 py-4">
        <div class="flex items-center gap-2">
          <span class="grid h-5 w-5 place-items-center rounded-full bg-indigo-500/20 text-[10px] font-bold text-indigo-300">
            1
          </span>
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-300">
            Install emisar-mcp
          </h3>
        </div>
        <p class="mt-1 ml-7 text-xs text-zinc-500">
          One-time install on the machine running your LLM client.
        </p>
        <div class="mt-2 ml-7 overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
          <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-3 py-2">
            <p class="font-mono text-[10px] text-zinc-500">macOS / Linux</p>
            <button
              type="button"
              id="copy-install-mcp"
              class="rounded bg-zinc-800/80 px-2 py-0.5 text-[11px] font-medium text-zinc-200 hover:bg-zinc-700"
              onclick="const el = document.getElementById('install-mcp-cmd'); navigator.clipboard.writeText(el.textContent.trim()); const orig = this.innerText; this.innerText = 'Copied'; setTimeout(() => { this.innerText = orig; }, 1500);"
            >
              Copy
            </button>
          </div>
          <pre
            id="install-mcp-cmd"
            class="overflow-x-auto p-3 font-mono text-xs leading-5 text-zinc-200"
          >curl -sSL https://emisar.dev/install-mcp.sh | sudo bash</pre>
        </div>
        <p class="mt-2 ml-7 text-[11px] text-zinc-500">
          Inspects the bridge first?
          <.link href={~p"/docs/connect-an-llm"} class="text-indigo-400 hover:text-indigo-300">
            Manual install →
          </.link>
        </p>
      </div>

      <%!-- Step 2: client snippet. --%>
      <div class="border-b border-zinc-900 px-6 py-3">
        <div class="flex items-center gap-2">
          <span class="grid h-5 w-5 place-items-center rounded-full bg-indigo-500/20 text-[10px] font-bold text-indigo-300">
            2
          </span>
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-300">
            Pick your client
          </h3>
        </div>
      </div>

      <%!-- Tab strip --%>
      <div class="flex flex-wrap gap-1.5 border-b border-zinc-900 px-6 py-3">
        <button
          :for={id <- client_ids()}
          type="button"
          phx-click="select_client"
          phx-value-client={id}
          class={[
            "rounded-lg px-3 py-1.5 text-sm font-medium transition",
            if(id == @selected_client,
              do: "bg-zinc-100 text-zinc-950",
              else: "bg-zinc-900 text-zinc-300 hover:bg-zinc-800"
            )
          ]}
        >
          {client_label(id)}
        </button>
      </div>

      <%!-- Body: snippet only once a client has been picked --%>
      <div class="space-y-5 px-6 py-5">
        <%= cond do %>
          <% is_nil(@selected_client) -> %>
            <div class="rounded-lg border border-dashed border-zinc-800 p-8 text-center">
              <p class="text-sm text-zinc-300">Pick a client above to get started.</p>
              <p class="mt-1 text-xs text-zinc-500">
                We won't mint a key until you do — keeps the audit trail and the agents list clean.
              </p>
            </div>

          <% @config -> %>
            <%= if @quick_secret do %>
              <div class="flex items-start gap-3 rounded-lg bg-amber-500/10 p-3 ring-1 ring-amber-500/30">
                <.icon name="hero-information-circle" class="mt-0.5 h-4 w-4 flex-none text-amber-300" />
                <div class="text-xs text-amber-100/90">
                  The snippet below contains a freshly-minted API key — copy the full snippet,
                  not just part of it. We won't be able to show this key again after you leave
                  the page. If you lose it, pick the client again to mint a new one.
                </div>
              </div>
            <% end %>

            <div class="overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
              <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
                <p class="font-mono text-[11px] text-zinc-500">{@config.location}</p>
                <button
                  type="button"
                  id={"copy-#{@selected_client}"}
                  class="rounded bg-zinc-800/80 px-2.5 py-1 text-xs font-medium text-zinc-200 hover:bg-zinc-700"
                  onclick={"const el = document.getElementById('snippet-#{@selected_client}'); navigator.clipboard.writeText(el.textContent.trim()); const orig = this.innerText; this.innerText = 'Copied'; setTimeout(() => { this.innerText = orig; }, 1500);"}
                >
                  Copy snippet
                </button>
              </div>
              <pre
                id={"snippet-#{@selected_client}"}
                class="overflow-x-auto p-4 font-mono text-xs leading-6 text-zinc-200"
              ><%= @config.body %></pre>
            </div>

            <p class="text-xs text-zinc-500">
              Paste the snippet into the file path above and restart {client_label(@selected_client)}.
              <.link href={~p"/docs/connect-an-llm"} class="text-indigo-400 hover:text-indigo-300">
                Troubleshooting →
              </.link>
            </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :all_scopes, :list, required: true
  attr :selected_scopes, :list, required: true
  attr :runners, :list, required: true
  attr :selected_runner_ids, :list, required: true
  attr :selected_runner_groups, :list, required: true

  defp advanced_create_panel(assigns) do
    # Distinct group names — drives the "Allowed groups" picker. Empty
    # when the account has only `default`-group runners, in which case
    # we hide the group fieldset entirely to avoid noise.
    groups =
      assigns.runners
      |> Enum.map(& &1.group)
      |> Enum.uniq()
      |> Enum.sort()

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div>
      <h3 class="text-sm font-semibold text-zinc-100">Custom key</h3>
      <p class="mt-1 text-xs text-zinc-500">
        Pick exactly which scopes and runners this key can target.
      </p>

      <.simple_form for={@form} id="api_key_form" phx-change="validate" phx-submit="create">
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          placeholder="e.g. Claude Desktop on laptop"
          required
        />

        <fieldset>
          <legend class="text-sm font-medium text-zinc-200">Scopes</legend>
          <div class="mt-2 space-y-1.5">
            <label
              :for={scope <- @all_scopes}
              class="flex items-center gap-2.5 rounded px-1 py-1 text-sm text-zinc-300 hover:bg-zinc-900/40"
            >
              <input
                type="checkbox"
                name="api_key[scopes][]"
                value={scope}
                checked={scope in @selected_scopes}
                class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40"
              />
              <span class="font-mono text-xs">{scope}</span>
            </label>
          </div>
        </fieldset>

        <%!-- Allowed groups — picked first because they scale better
             than per-runner ticks. Skipped when every runner is in
             the same default group (nothing meaningful to scope to). --%>
        <fieldset :if={length(@groups) > 1}>
          <legend class="text-sm font-medium text-zinc-200">Allowed runner groups</legend>
          <p class="mt-1 text-xs text-zinc-500">
            Tick groups this key may target. Auto-includes runners later added to the same group.
          </p>
          <div class="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
            <label
              :for={group <- @groups}
              class="flex items-center gap-2.5 rounded border border-zinc-800 bg-zinc-950/40 px-2 py-1.5 text-sm text-zinc-300 hover:border-indigo-500/40"
            >
              <input
                type="checkbox"
                name="api_key[runner_group_filter][]"
                value={group}
                checked={group in @selected_runner_groups}
                class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40"
              />
              <span class="truncate">{group}</span>
            </label>
          </div>
        </fieldset>

        <fieldset>
          <legend class="text-sm font-medium text-zinc-200">Allowed individual runners</legend>
          <p class="mt-1 text-xs text-zinc-500">
            Empty groups AND empty individual list = all runners. Tick to add specific runners on
            top of any group selection above.
          </p>
          <%= if @runners == [] do %>
            <p class="mt-2 rounded-lg bg-zinc-900/60 p-3 text-xs text-zinc-400">
              No runners registered yet.
            </p>
          <% else %>
            <div class="mt-2 max-h-40 space-y-1 overflow-y-auto rounded-lg border border-zinc-800 bg-zinc-950/40 p-2">
              <label
                :for={runner <- @runners}
                class="flex items-center gap-2.5 rounded px-1.5 py-1 text-sm text-zinc-300 hover:bg-zinc-900/60"
              >
                <input
                  type="checkbox"
                  name="api_key[runner_filter][]"
                  value={runner.id}
                  checked={runner.id in @selected_runner_ids}
                  class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40"
                />
                <span class="flex-1 truncate">{runner.name}</span>
                <span class="text-xs text-zinc-500">{runner.group}</span>
              </label>
            </div>
          <% end %>
        </fieldset>

        <:actions>
          <.button phx-disable-with="Creating...">Create key</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
