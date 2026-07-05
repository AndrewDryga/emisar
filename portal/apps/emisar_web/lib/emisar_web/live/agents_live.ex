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
  alias Emisar.ApiKeys
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions, UrlHelpers}
  alias Phoenix.LiveView.JS

  @active_threshold_secs 5 * 60
  @idle_threshold_secs 24 * 60 * 60
  @refresh_ms 5_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @refresh_ms)

      # Live API-key list — another operator's create / revoke (or an
      # LLM's first call that flips api_key.bound) reflows this page
      # without the viewer refreshing.
      ApiKeys.subscribe_account_api_keys(socket.assigns.current_account.id)
    end

    # The operator first picks which LLM client they're connecting
    # (Claude Desktop, Cursor, Codex, …). On pick we mint a quick key
    # whose `name` reflects the choice, so the audit trail and the
    # agents list both read "Claude Desktop" rather than a generic
    # "Quick connect". The client id also flows into the snippet's
    # EMISAR_CLIENT env var so the bridge stamps it onto every
    # User-Agent.
    #
    # `ApiKeys.mint_quick_key/2` ring-evicts unused autos at 42 per
    # account, so opening many tabs can't accumulate dangling keys.
    {:ok,
     socket
     |> assign(:page_title, "LLM agents")
     |> assign(:quick_secret, nil)
     |> assign(:selected_client, nil)
     |> assign(:base_url, UrlHelpers.derive_base_url(socket))
     |> ConfirmDialog.init()
     |> assign(:revoke_target, nil)
     |> assign(:rotated, nil)
     |> assign_form(ApiKeys.change_key(default_params()))}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/settings/agents",
       params
     )}
  end

  # -- Events ----------------------------------------------------------

  def handle_event("select_client", %{"client" => "custom"}, socket) do
    # The custom tab swaps the snippet for a key-builder form — no
    # quick mint, the operator fills in the form and submits.
    {:noreply,
     socket
     |> assign(:selected_client, "custom")
     |> assign(:quick_secret, nil)}
  end

  def handle_event("select_client", %{"client" => id}, socket) do
    # First-pick mints a quick key whose name matches the client
    # (so it shows up as e.g. "Claude Desktop" on the agents list and
    # in audit rows). Switching clients re-mints — the previous
    # un-bound auto-key gets ring-evicted naturally. Any restrictions
    # picked in the shared scope panel propagate to the mint so
    # quick-mints can be scoped too, not only Custom-tab keys.
    Permissions.gated(
      socket,
      # Quick-mint is the ISSUE tier (operators and above) — gating it on
      # manage broke the flow for the very role the picker rendered for.
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket ->
        name = client_label(id)

        case ApiKeys.mint_quick_key(socket.assigns.current_subject, name: name) do
          {:ok, raw, _key} ->
            {:noreply,
             socket
             |> assign(:selected_client, id)
             |> assign(:quick_secret, raw)
             |> reload()}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:selected_client, id)
             |> put_flash(:error, "Could not mint a quick key.")}
        end
      end
    )
  end

  def handle_event("validate", %{"api_key" => params}, socket) do
    changeset = ApiKeys.change_key(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      &do_create(&1, params)
    )
  end

  # Sets the typed-confirm target; the dialog's Confirm fires "revoke",
  # which stays the server-authz gate (IL-15).
  def handle_event("open_revoke", %{"id" => id}, socket) do
    target = Enum.find(socket.assigns.api_keys, &(&1.id == id))
    {:noreply, socket |> ConfirmDialog.reset() |> assign(:revoke_target, target)}
  end

  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("dismiss_rotated", _params, socket),
    do: {:noreply, assign(socket, :rotated, nil)}

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      &do_revoke(&1, id)
    )
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      &do_rotate(&1, id)
    )
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, reload(socket)}
  end

  def handle_info({:list_changed, :api_key, _event_type, _id}, socket),
    do: {:noreply, reload(socket)}

  # The badge hooks (UserAuth) forward account-topic broadcasts to every
  # authenticated LV — ignore the ones this page doesn't render.
  def handle_info(_, socket), do: {:noreply, socket}

  # -- Internals -------------------------------------------------------

  defp do_create(socket, params) do
    # A Custom key is a plain `:mcp` key — identity + expiry only. It carries no
    # per-key scope: account Policy + the operator's own runner scope decide
    # what it may do, same as a quick-mint.
    attrs = %{
      name: params["name"] || "",
      description: nil_if_blank(params["description"]),
      expires_at: parse_expires_at(params["expires_at"])
    }

    case ApiKeys.create_key(attrs, socket.assigns.current_subject) do
      {:ok, raw, _key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign_form(ApiKeys.change_key(default_params()))
         |> reload()}

      # Field errors (required name, length, or a DB constraint) render inline
      # on the form via <.input>/<.error> — no flash dump.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
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

  defp do_rotate(socket, id) do
    with {:ok, key} <- ApiKeys.fetch_api_key_by_id(id, socket.assigns.current_subject),
         {:ok, raw, _new_key} <- ApiKeys.rotate_api_key(key, socket.assigns.current_subject) do
      # The successor's one-time secret shows in a compact reveal banner right
      # here on the index — never by dumping the whole connect panel + custom
      # key form onto the list page. No flash: the banner IS the confirmation,
      # and it stays until dismissed (a flash would auto-close over the only
      # copy of the secret's instructions).
      {:noreply, socket |> assign(:rotated, %{name: key.name, secret: raw}) |> reload()}
    else
      {:error, :not_found} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not rotate the key.")}
    end
  end

  # Refresh-in-place (tick / mutation): re-runs with current URL params
  # so the operator doesn't jump back to page 1 on revoke or every 5 s.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  # The connect panel embeds INLINE only while connecting IS the page's job:
  # a fleet with no live agent keys (onboarding — the runners-wizard pattern),
  # or a one-time secret on screen (a quick mint / rotation reveal must not
  # vanish when the reload lands). Otherwise the flow lives on its own
  # /connect page behind the title CTA.
  defp assign_connect_inline(socket, keys) do
    inline? = active_keys(keys) == [] or socket.assigns.quick_secret != nil
    assign(socket, :show_connect_inline?, inline?)
  end

  # Fill the static Owner filter's options with the account's real key creators
  # (the filter's SQL still comes from the Query module's `fun`).
  defp with_owner_options(subject) do
    owners =
      case ApiKeys.list_key_owner_options(subject) do
        {:ok, options} -> options
        _ -> []
      end

    Enum.map(ApiKeys.ApiKey.Query.filters(), fn
      %{name: :owner} = filter -> %{filter | values: owners}
      filter -> filter
    end)
  end

  defp load(socket, params) do
    # The status filter defaults to "live" (declared on the filter itself, so
    # LiveTable applies it AND renders it un-highlighted) — no need to inject it
    # into the params here.
    filters = with_owner_options(socket.assigns.current_subject)
    opts = LiveTable.params_to_opts(params, filters)

    case ApiKeys.list_api_keys_for_account(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:created_by, :replaces])
         ) do
      {:ok, keys, meta} ->
        socket
        |> assign(:api_keys, keys)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:active_count, count_status(keys, :active))
        |> assign(:idle_count, count_status(keys, :idle))
        |> assign(:dormant_count, count_status(keys, :dormant))
        |> assign(:never_used_count, count_status(keys, :never_used))
        |> assign(:issued_count, length(active_keys(keys)))
        |> assign_connect_inline(keys)
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — flag it
      # so the list says "couldn't load" instead of a silent empty list (which
      # would read "no keys" when really the read failed).
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:api_keys, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:active_count, 0)
        |> assign(:idle_count, 0)
        |> assign(:dormant_count, 0)
        |> assign(:never_used_count, 0)
        |> assign(:issued_count, 0)
        # A failed read must NOT flip the page into onboarding — the account
        # may well have agents; only a secret on screen keeps the panel.
        |> assign(:show_connect_inline?, socket.assigns.quick_secret != nil)
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  defp active_keys(keys), do: Enum.reject(keys, & &1.revoked_at)

  # The issuing human — the grouping key for the list. Falls back to "Auto"
  # for system-minted keys with no creator.
  defp owner_label(%{created_by: %{} = user}), do: user.full_name || user.email
  defp owner_label(_), do: "Auto-minted"

  # Rows sorted by owner so one person's keys cluster together (the row meta
  # names the owner; within a cluster the context's recent-first order holds).
  defp sort_by_owner(keys), do: Enum.sort_by(keys, &owner_label/1)

  defp count_status(keys, status),
    do: Enum.count(active_keys(keys), &(client_status(&1) == status))

  defp default_params do
    %{"name" => "", "description" => "", "expires_at" => ""}
  end

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil

  defp nil_if_blank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  # The `<input type="datetime-local">` posts `"YYYY-MM-DDTHH:MM"` (no
  # seconds, no timezone). Treat as local time relative to the cloud's
  # UTC wallclock — operators typing "expires Dec 25 at 10am" expect
  # something close to "Dec 25 at 10am UTC" rather than guessing the
  # browser's timezone server-side. Returning nil for blank lets the
  # cast skip the field entirely.
  defp parse_expires_at(nil), do: nil
  defp parse_expires_at(""), do: nil

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "api_key"))

  defp expired?(%ApiKeys.ApiKey{expires_at: %DateTime{} = exp}),
    do: DateTime.compare(exp, DateTime.utc_now()) == :lt

  defp expired?(%ApiKeys.ApiKey{}), do: false

  # Past expiry reads rose (the key is dead); inside a week, amber (rotate
  # soon); otherwise muted like the rest of the meta line.
  defp expiry_class(%ApiKeys.ApiKey{expires_at: %DateTime{} = exp}) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(exp, now) == :lt -> "text-rose-400"
      DateTime.diff(exp, now, :day) < 7 -> "text-amber-400"
      true -> "text-zinc-500"
    end
  end

  defp expiry_class(%ApiKeys.ApiKey{}), do: "text-zinc-500"

  # Rotation lineage. The swap is PENDING while the replaced key is still
  # usable — this key's first authenticated use retires it. Successors inherit
  # the name, so the replaced key is named by its distinguishing prefix; the
  # id-slice fallback covers a hard-deleted (quick-ring-evicted) ancestor.
  defp swap_pending?(%ApiKeys.ApiKey{replaces: %ApiKeys.ApiKey{} = replaced}),
    do: ApiKeys.ApiKey.usable?(replaced)

  defp swap_pending?(%ApiKeys.ApiKey{}), do: false

  defp replaced_key_label(%ApiKeys.ApiKey{replaces: %ApiKeys.ApiKey{} = replaced}),
    do: replaced.key_prefix <> "…"

  defp replaced_key_label(%ApiKeys.ApiKey{replaces_id: id}) when is_binary(id),
    do: String.slice(id, 0, 8) <> "…"

  # -- Status derivation ----------------------------------------------

  defp client_status(%ApiKeys.ApiKey{revoked_at: ts}) when not is_nil(ts), do: :revoked
  defp client_status(%ApiKeys.ApiKey{last_used_at: nil}), do: :never_used

  defp client_status(%ApiKeys.ApiKey{last_used_at: ts}) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff <= @active_threshold_secs -> :active
      diff <= @idle_threshold_secs -> :idle
      true -> :dormant
    end
  end

  # The MCP client a key reported at `initialize` (clientInfo): prefer the
  # human-readable "title" over the machine "name", with "version" appended
  # when present. nil until a client has connected.
  # Name only — the client VERSION is detail material, not row meta.
  defp reported_client(%ApiKeys.ApiKey{last_client_info: %{} = info}) do
    label = info["title"] || info["name"]
    if is_binary(label) and label != "", do: label
  end

  defp reported_client(_), do: nil

  defp status_label(:active), do: "active"
  defp status_label(:idle), do: "idle"
  defp status_label(:dormant), do: "dormant"
  defp status_label(:never_used), do: "never used"
  defp status_label(:revoked), do: "revoked"

  # Maps to the colour palette `core_components.status_badge/1` uses
  # elsewhere — green for active, amber for idle/never, zinc for dormant.

  # -- Client configs --------------------------------------------------
  #
  # Single source of truth for the "Connect a client" panel. Each entry
  # describes one MCP client: label, where its config lives, and a
  # body templated with this operator's URL + key.

  # `@client_ids` ordering drives the tab strip in `connect_panel/1` so
  # claude-code stays first. Map iteration order isn't guaranteed —
  # keep ids as a list and pair labels separately.
  #
  # `"custom"` is the trailing pseudo-client: picking it doesn't mint a
  # quick key + snippet, it surfaces a key-builder form instead. Keeps
  # the "I need a tighter scope" affordance discoverable next to the
  # client tabs, not hidden in a collapsed details further down.
  @client_ids ~w(claude_web chatgpt claude_code claude_desktop cursor gemini codex custom)
  @client_labels %{
    "claude_web" => "Claude.ai",
    "chatgpt" => "ChatGPT",
    "claude_code" => "Claude Code",
    "claude_desktop" => "Claude Desktop",
    "cursor" => "Cursor",
    "gemini" => "Gemini CLI",
    "codex" => "Codex CLI",
    "custom" => "Custom"
  }

  # Two transports under the hood — local stdio bridge (`emisar-mcp`)
  # and remote MCP over HTTP at `/api/mcp/rpc`. Remote-MCP clients
  # don't need the bridge binary installed; they just need a URL +
  # bearer token. We surface that as a different tab variant rather
  # than a global toggle because the operator's question is "which
  # client am I connecting" first; transport falls out of the answer.
  @remote_client_ids ~w(claude_web chatgpt)
  defp remote_client?(id), do: id in @remote_client_ids

  defp client_label(id), do: Map.get(@client_labels, id, "MCP client")

  defp remote_client_ids, do: Enum.filter(@client_ids, &remote_client?/1)

  defp local_client_ids,
    do: Enum.reject(@client_ids, &(remote_client?(&1) or &1 == "custom"))

  defp client_config("claude_web", url, key) do
    %{
      kind: :remote,
      rpc_url: "#{url}/api/mcp/rpc",
      auth_header: "Authorization: Bearer #{key}",
      steps: [
        "Open Settings → Connectors → Add custom connector in claude.ai.",
        "Name it \"Emisar\" and paste the URL below into Remote MCP server URL.",
        "Under Authentication, add a header named Authorization with value Bearer <key>.",
        "Save. Claude tests the connection and lists every Emisar action as a tool."
      ]
    }
  end

  defp client_config("chatgpt", url, key) do
    %{
      kind: :remote,
      rpc_url: "#{url}/api/mcp/rpc",
      auth_header: "Authorization: Bearer #{key}",
      steps: [
        "Open Settings → Connectors in ChatGPT (Pro / Team / Enterprise — custom connectors are gated).",
        "Click Add custom connector and paste the URL below as the MCP server URL.",
        "Set the bearer token to the API key (no header name needed — ChatGPT prepends \"Authorization: Bearer\").",
        "Save. Tools become available in the next chat turn."
      ]
    }
  end

  defp client_config("claude_code", url, key) do
    %{
      kind: :local,
      location: "One command — registers the bridge globally",
      body: """
      claude mcp add emisar /usr/local/bin/emisar-mcp \\
          --scope user \\
          -e EMISAR_URL=#{url} \\
          -e EMISAR_API_KEY=#{key} \\
          -e EMISAR_CLIENT=claude-code\
      """,
      # Verified against Anthropic's docs: a `permissions.allow` entry of
      # `mcp__<server>__*` auto-approves every tool from that MCP server
      # (server name `emisar` matches the `claude mcp add emisar` above).
      auto_permit: %{
        location: "~/.claude/settings.json (Claude Code's settings — not an emisar file)",
        body: """
        {
          "permissions": {
            "allow": ["mcp__emisar__*"]
          }
        }\
        """
      }
    }
  end

  defp client_config("claude_desktop", url, key) do
    %{
      kind: :local,
      location: "~/Library/Application Support/Claude/claude_desktop_config.json",
      body: mcp_json_snippet(url, key, "/usr/local/bin/emisar-mcp", "claude-desktop")
    }
  end

  defp client_config("cursor", url, key) do
    %{
      kind: :local,
      location: "~/.cursor/mcp.json",
      body: mcp_json_snippet(url, key, "emisar-mcp", "cursor"),
      # Cursor has no per-server allowlist in mcp.json — auto-run is a global
      # agent toggle (Settings → set tool approval to auto-run / "Yolo").
      # Honest pointer rather than an invented config key.
      auto_permit: %{
        pointer:
          "Cursor controls this globally, not per-server: in Settings, set the agent's tool-approval to auto-run (\"Yolo\" mode). There's no per-server allowlist in mcp.json.",
        doc_url: "https://docs.cursor.com/context/mcp"
      }
    }
  end

  defp client_config("gemini", url, key) do
    %{
      kind: :local,
      location: "~/.gemini/settings.json",
      body: mcp_json_snippet(url, key, "/usr/local/bin/emisar-mcp", "gemini"),
      # Verified against Gemini CLI's docs: `"trust": true` on an MCP server
      # bypasses all tool-call confirmations for that server. Same file as
      # the snippet above — add the one key to the existing `emisar` block.
      auto_permit: %{
        location: "~/.gemini/settings.json — add to the \"emisar\" server block above",
        body: """
        "emisar": {
          "trust": true
        }\
        """
      }
    }
  end

  defp client_config("codex", url, key) do
    %{
      kind: :local,
      location: "~/.codex/config.toml",
      body: """
      [mcp_servers.emisar]
      command = "/usr/local/bin/emisar-mcp"
      env = { EMISAR_URL = "#{url}", EMISAR_API_KEY = "#{key}", EMISAR_CLIENT = "codex" }\
      """,
      # Codex CLI has no per-server tool auto-approve key — approvals are a
      # global `approval_policy` in config.toml (openai/codex#24135). Honest
      # pointer rather than an invented per-server setting.
      auto_permit: %{
        pointer:
          "Codex controls this globally, not per-server: set approval_policy in ~/.codex/config.toml (e.g. \"on-request\"/\"never\"). There's no per-MCP-server allowlist key.",
        doc_url: "https://developers.openai.com/codex/config-basic"
      }
    }
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
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:agents}
      width={:table}
    >
      <:title>
        <%!-- The connect flow is a title-row CTA (the Runners "Connect a runner" /
             audit "Stream to SIEM" pattern) — except while the inline panel IS
             the page (onboarding / a secret reveal), where a second CTA to the
             same flow would just duplicate it. --%>
        <%= if @live_action == :connect do %>
          <.back_link navigate={~p"/app/#{@current_account}/settings/agents"}>LLM agents</.back_link>
          Connect an agent
        <% else %>
          LLM agents
        <% end %>
      </:title>
      <:actions :if={
        @live_action == :index and not @show_connect_inline? and
          ApiKeys.subject_can_issue_quick_key?(@current_subject)
      }>
        <.button
          navigate={~p"/app/#{@current_account}/settings/agents/connect"}
          size={:md}
          icon="hero-plus"
        >
          Connect an agent
        </.button>
      </:actions>

      <.page_intro :if={@live_action == :index}>
        Connect Claude, ChatGPT, Cursor, Codex — any MCP agent — to dispatch gated, audited
        actions. Each key is scoped to runners and capabilities, and revocable in one click.
        <.doc_link href="/docs/connect-an-llm">Connect an agent docs</.doc_link>
      </.page_intro>

      <.page_intro :if={@live_action == :connect}>
        Pick how your agent connects — we only mint a key once you choose, named after the
        client, setup pre-filled. Keeps the audit trail and the agents list clean.
        <.doc_link href="/docs/connect-an-llm">Connect an agent docs</.doc_link>
      </.page_intro>

      <.empty_state
        :if={
          @live_action == :connect and
            not ApiKeys.subject_can_issue_quick_key?(@current_subject)
        }
        variant={:bare}
        icon="hero-cpu-chip"
        title="Connecting an agent needs an operator role or above."
      >
        Ask an operator, admin, or owner to mint the key — you'll see the
        agent and its activity here once it's connected.
      </.empty_state>

      <.connect_panel
        :if={@live_action == :connect and ApiKeys.subject_can_issue_quick_key?(@current_subject)}
        configs_for={&client_config(&1, @base_url, @quick_secret || "emk-…")}
        selected_client={@selected_client}
        quick_secret={@quick_secret}
        form={@form}
      />

      <%!-- NAKED posture line (the runners grammar): activity now leads, the
           quiet states render only when they exist, and the key total lives in
           the list's own pager — not repeated here. Thresholds ride the title
           tooltips. --%>
      <%!-- Activity posture — only once agents exist. In onboarding (no keys)
           "0 active now" is a fact about nothing; the connect flow below is the
           whole story until the first agent lands. --%>
      <%!-- No hand-rolled pb here: the shell's space-y owns the gap on BOTH
           sides, so the bar sits evenly between the intro and the list. --%>
      <div
        :if={@live_action == :index and @issued_count > 0}
        class="flex flex-wrap items-center gap-x-5 gap-y-1 text-xs"
      >
        <span class="flex items-center gap-1.5" title="called an action in the last 5 minutes">
          <%!-- The dot signals only when something IS active — a green dot
               beside a zero count signaled nothing. Idle is a fact, not a
               caution — neutral, like dormant. --%>
          <.status_dot
            tone={if @active_count > 0, do: :brand, else: :neutral}
            size={:sm}
            ping={@active_count > 0}
          />
          <span class="tabular-nums text-zinc-400">{@active_count} active now</span>
        </span>
        <span
          :if={@idle_count > 0}
          class="flex items-center gap-1.5"
          title="last call within 24 hours"
        >
          <.status_dot tone={:neutral} size={:sm} />
          <span class="tabular-nums text-zinc-500">{@idle_count} idle</span>
        </span>
        <span
          :if={@dormant_count > 0}
          class="flex items-center gap-1.5"
          title="no call for over 24 hours"
        >
          <.status_dot tone={:neutral} size={:sm} />
          <span class="tabular-nums text-zinc-500">{@dormant_count} dormant</span>
        </span>
        <span :if={@never_used_count > 0} class="flex items-center gap-1.5">
          <.status_dot tone={:neutral} size={:sm} />
          <span class="tabular-nums text-zinc-500">{@never_used_count} never used</span>
        </span>
      </div>

      <%!-- Rotation success — the SAME "here's your key" grammar as the connect
           flow (naked amber status line + the secret in a recessed code
           artifact), right above the list where the old key still shows for
           the final revoke step. Not the boxed secret_reveal banner: that
           variant is keys-new's form-replacing success step, and two grammars
           for one event on one surface read as two designs. The amber SPINE
           (LiveTable's card_spine pending tone) binds note + artifact + Done
           into one transient block — without it the three pieces blended into
           the page around them. --%>
      <.event_block
        :if={@live_action == :index and @rotated}
        icon="hero-key"
        title="Key rotated — copy the new key now; it won't be shown again"
      >
        <:body>
          Update <span class="font-medium text-zinc-200">{@rotated.name}</span>'s client config
          with this key. The old key keeps working until this one's first use — the moment the
          client authenticates with it, the old key is revoked automatically.
        </:body>
        <.code_panel
          id="rotated-key"
          label="API key (bearer token)"
          copy
          copy_label="Copy key"
          code={@rotated.secret}
          class="mt-4"
        />
        <div class="mt-4">
          <.button variant={:secondary} size={:sm} phx-click="dismiss_rotated">Done</.button>
        </div>
      </.event_block>

      <%!-- The empty state IS the connect flow (the runners install-wizard
           pattern): no agents → the panel renders right here, no detour. It
           also pins open while a quick-mint secret is on screen, so the
           reload can't hide the only copy. --%>
      <section :if={@live_action == :index and @show_connect_inline?}>
        <.section_header title="Connect an agent" />
        <%!-- A role that can't mint gets the honest note, not a picker whose
             every chip dies in a denial flash. --%>
        <p
          :if={not ApiKeys.subject_can_issue_quick_key?(@current_subject)}
          class="max-w-prose text-sm leading-relaxed text-zinc-500"
        >
          Connecting an agent needs an operator role or above — ask an operator,
          admin, or owner to mint the key.
        </p>
        <div :if={ApiKeys.subject_can_issue_quick_key?(@current_subject)}>
          <.connect_panel
            configs_for={&client_config(&1, @base_url, @quick_secret || "emk-…")}
            selected_client={@selected_client}
            quick_secret={@quick_secret}
            form={@form}
          />
        </div>
      </section>

      <%!-- Connected agents list — single-column rows matching the
           EnrollmentKeys / Grants visual language. --%>
      <%!-- Plain heading above a standalone live_table (self-framed cards
           panel), matching the Pending / Members sections — not a bordered
           section wrapping it, which boxed the filter against a second
           border. --%>
      <%!-- Hidden while the embedded picker IS the zero state — a second
           "No agents connected yet" hairline under it was pure noise. An
           ACTIVE filter keeps the section: filter-empty needs its live bar
           (and the clear link) to escape back to the full set. --%>
      <section :if={
        @live_action == :index and
          not (@show_connect_inline? and @api_keys == [] and
                 not LiveTable.has_active_filters?(@filter_params, @filters))
      }>
        <LiveTable.live_table
          layout={:cards}
          id="agents"
          path={~p"/app/#{@current_account}/settings/agents"}
          rows={sort_by_owner(@api_keys)}
          metadata={@metadata}
          filter_params={@filter_params}
          filters={@filters}
          wrapper_class="divide-y divide-zinc-800/70"
        >
          <:item :let={key}>
            <.list_row padding="py-4">
              <:title>
                <span class="truncate font-medium text-zinc-100">{key.name}</span>
                <.client_status_pill key={key} />
              </:title>
              <:meta>
                <%!-- Identity + liveness only. The OWNER leads — whose
                     credential this is, the fact an operator audits by (the
                     scopes are a fixed MCP shape nobody manages here, so they
                     earned no chips). No key prefix: truncated it rendered the
                     SAME shared literal on every row. --%>
                <.meta_line class="text-[11px]">
                  <:seg>
                    owner <span class="text-zinc-300">{owner_label(key)}</span>
                  </:seg>
                  <:seg :if={reported_client(key)}>
                    client <span class="text-zinc-300">{reported_client(key)}</span>
                  </:seg>
                  <%!-- Rotation lineage — the successor names the key it
                       replaces by prefix (successors inherit the NAME, so the
                       prefix is the distinguisher). Amber while the old key is
                       still live: the swap isn't proven until this key's first
                       use auto-revokes it. --%>
                  <:seg :if={key.replaces_id}>
                    <span
                      :if={swap_pending?(key)}
                      class="text-amber-300/90"
                      title="Replaces a rotated key — the old key is revoked automatically the first time this key is used"
                    >
                      replaces <span class="font-mono">{replaced_key_label(key)}</span> · swap pending
                    </span>
                    <span
                      :if={not swap_pending?(key)}
                      title="Minted by rotation — the key it replaced has been revoked"
                    >
                      replaced <span class="font-mono">{replaced_key_label(key)}</span>
                    </span>
                  </:seg>
                  <:seg>
                    last call{" "}<.local_time
                      value={key.last_used_at}
                      mode={:relative}
                      placeholder="never"
                    />
                  </:seg>
                  <:seg :if={key.expires_at}>
                    <span class={expiry_class(key)}>
                      {if expired?(key), do: "expired", else: "expires"}
                      <.local_time value={key.expires_at} mode={:relative} />
                    </span>
                  </:seg>
                </.meta_line>
              </:meta>
              <:actions>
                <%!-- What this agent actually did — deep-link the audit log
                     filtered to this key's actor. Shown for revoked keys too:
                     that's exactly when "what did it do" matters. Every role
                     that can see this page also holds view_audit. --%>
                <%!-- An agent's activity is its RUNS (scoped by api_key_id); the
                     audit actor filter is empty for an api_key (terminal run events
                     are engine-attributed), so this pivots to the runs feed. Both
                     params: source picks the Dispatched-by kind, api_key_id the
                     agent — the bar lands with the pair visibly active. --%>
                <.button
                  navigate={~p"/app/#{@current_account}/runs?#{[source: "mcp", api_key_id: key.id]}"}
                  variant={:ghost}
                  size={:sm}
                >
                  View activity
                </.button>
                <.button
                  :if={
                    is_nil(key.revoked_at) and ApiKeys.subject_can_manage_api_keys?(@current_subject)
                  }
                  variant={:ghost}
                  size={:sm}
                  phx-click="rotate"
                  phx-value-id={key.id}
                  data-confirm="Rotate this key? A new key with the same scope is minted; this one keeps working until the new key's first use, then it's revoked automatically."
                >
                  Rotate
                </.button>
                <%!-- IRREVERSIBLE credential kill — typed confirm, same tier
                     as enrollment keys (one ladder for one action class). --%>
                <.button
                  :if={
                    is_nil(key.revoked_at) and ApiKeys.subject_can_manage_api_keys?(@current_subject)
                  }
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  phx-click={
                    JS.push("open_revoke", value: %{id: key.id})
                    |> show_confirm_dialog("revoke-agent-key")
                  }
                >
                  Revoke
                </.button>
              </:actions>
            </.list_row>
          </:item>
          <:empty>
            <.empty_state
              :if={@load_error?}
              variant={:bare}
              tone={:danger}
              icon="hero-exclamation-triangle"
              title="Couldn't load your agents"
            >
              This is a load error, not an empty list — your connected agents may well be here.
              Refresh the page; if it persists, your access to this account may have changed.
            </.empty_state>
            <.empty_state
              :if={not @load_error?}
              variant={:bare}
              icon="hero-cpu-chip"
              title="No agents connected yet."
            >
              Pick a client above — we mint a key + pre-fill the snippet (local) or
              URL + token (cloud). The agent shows up here on its first MCP call.
            </.empty_state>
          </:empty>
        </LiveTable.live_table>
      </section>

      <%!-- One page-level typed-confirm dialog; open_revoke fills
           @revoke_target. With no target the token is blank, so Confirm
           stays disabled; "revoke" stays the server gate (IL-15). --%>
      <.confirm_dialog
        id="revoke-agent-key"
        title="Revoke this agent key"
        confirm_label="Revoke key"
        confirm_token={(@revoke_target && @revoke_target.name) || ""}
        typed={@typed}
        on_confirm={
          JS.push("revoke", value: %{id: @revoke_target && @revoke_target.id})
          |> hide_confirm_dialog("revoke-agent-key")
        }
      >
        <:body>
          Permanently revokes
          <span class="font-mono font-medium text-zinc-200">
            {(@revoke_target && @revoke_target.name) || ""}
          </span>
          — the connected client gets 401s on its next call. This can't be undone;
          connect the client again to mint a fresh key.
        </:body>
      </.confirm_dialog>
    </.dashboard_shell>
    """
  end

  attr :key, :map, required: true

  # Sanctioned page-local status (composes the shared `<.status_dot>` + a toned
  # word — the status_badge grammar): the words are the agents-specific activity
  # ladder, and :active carries the live ping status_badge can't express.
  defp client_status_pill(assigns) do
    status = client_status(assigns.key)
    assigns = assign(assigns, status: status)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap text-[11px] font-medium",
      status_word_class(@status)
    ]}>
      <.status_dot tone={status_dot_tone(@status)} size={:sm} ping={@status == :active} />
      {status_label(@status)}
    </span>
    """
  end

  defp status_dot_tone(:active), do: :brand
  defp status_dot_tone(_), do: :neutral

  defp status_word_class(:active), do: "text-brand-300"
  defp status_word_class(:revoked), do: "text-rose-300"
  defp status_word_class(_), do: "text-zinc-500"

  attr :configs_for, :any, required: true
  attr :selected_client, :any, required: true
  attr :quick_secret, :string, default: nil
  attr :form, :any, default: nil

  defp connect_panel(assigns) do
    config =
      cond do
        assigns.selected_client == nil -> nil
        assigns.selected_client == "custom" -> nil
        true -> assigns.configs_for.(assigns.selected_client)
      end

    assigns = assign(assigns, :config, config)

    ~H"""
    <%!-- CONTENT ON CANVAS, task + rail (the install-wizard / keys-new
         grammar) at the same 7xl column as the list it's reached from, so the
         header never jumps: the picker + per-client setup are the task on the
         left; the "how keys work" explainer fills the rail on the right. --%>
    <div class="lg:grid lg:grid-cols-[minmax(0,1fr)_22rem] lg:gap-x-16">
      <div>
        <%!-- Client picker on the canvas — grouped into two transport families.
           Cloud first (the no-install path most new users want); Local below
           for IDE / desktop clients that go through the stdio bridge. Small
           group labels organize the tabs; the pick step is framed by the page
           intro / section header above, so the picker carries no header. --%>
        <div>
          <p class="text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Cloud
            <span class="ml-1 normal-case tracking-normal text-zinc-600">
              — hosted LLMs: no install, URL + token
            </span>
          </p>
          <div class="mt-2.5 flex flex-wrap gap-1.5">
            <.client_tab
              :for={id <- remote_client_ids()}
              id={id}
              label={client_label(id)}
              selected={id == @selected_client}
            />
          </div>

          <p class="mt-6 text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Local / IDE clients
            <span class="ml-1 normal-case tracking-normal text-zinc-600">
              — uses the stdio bridge
            </span>
          </p>
          <div class="mt-2.5 flex flex-wrap gap-1.5">
            <.client_tab
              :for={id <- local_client_ids()}
              id={id}
              label={client_label(id)}
              selected={id == @selected_client}
            />
          </div>

          <p class="mt-6 text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Roll your own
          </p>
          <div class="mt-2.5 flex flex-wrap gap-1.5">
            <.client_tab
              id="custom"
              label="Custom key (advanced)"
              selected={"custom" == @selected_client}
            />
          </div>
        </div>

        <%!-- Body. Empty state until the operator picks. Once picked we
           render the per-transport setup section — for local clients
           that's "install + paste snippet", for remote it's
           "URL + bearer header + per-host steps". Scope picker only
           appears AFTER a client is chosen too; it's part of the
           per-client setup, not a standalone step. --%>
        <%= cond do %>
          <% is_nil(@selected_client) -> %>
            <%!-- Nothing picked → nothing rendered: the picker is the prompt;
               480px of reserved dead space buried the agents list. --%>
            <span></span>
          <% @selected_client == "custom" -> %>
            <div class="mt-10 space-y-6">
              <%= if @quick_secret do %>
                <.minted_note>
                  Copy the bearer token below before you leave this page; we won't show it
                  again. If you lose it, create another key.
                </.minted_note>

                <.code_panel
                  id="custom-secret"
                  label="API key (bearer token)"
                  copy
                  copy_label="Copy key"
                  code={@quick_secret}
                />
              <% end %>

              <.custom_key_panel form={@form} />
            </div>
          <% @config && @config.kind == :remote -> %>
            <div class="mt-10 space-y-8">
              <%= if @quick_secret do %>
                <.minted_note>
                  Copy the bearer token below before you leave this page; we won't show it
                  again. If you lose it, pick the client again to mint a new one.
                </.minted_note>
              <% end %>

              <.remote_mcp_panel
                client_id={@selected_client}
                client_label={client_label(@selected_client)}
                rpc_url={@config.rpc_url}
                auth_header={@config.auth_header}
                steps={@config.steps}
              />
            </div>
          <% @config -> %>
            <div class="mt-10 space-y-8">
              <.local_install_block />

              <div>
                <.section_header title={"Paste this into #{client_label(@selected_client)}"}>
                  <:subtitle><span class="font-mono">{@config.location}</span></:subtitle>
                </.section_header>
                <%!-- The fresh-mint note sits WITH the snippet that holds the key,
                     not up by the install step — "the snippet below" now points
                     right at it. --%>
                <.minted_note :if={@quick_secret} class="mb-4">
                  The snippet below contains it — copy the whole snippet, not just part. We
                  won't show this key again after you leave the page; pick the client again to
                  mint a new one.
                </.minted_note>
                <.code_panel
                  id={"snippet-#{@selected_client}"}
                  label="Snippet"
                  annotation="contains your API key"
                  copy
                  copy_label="Copy snippet"
                  code={@config.body}
                />
                <p class="mt-2 text-xs text-zinc-500">
                  Restart {client_label(@selected_client)} after pasting.
                  <.link
                    href={~p"/docs/connect-an-llm"}
                    class="group text-brand-400 hover:text-brand-300"
                  >
                    Troubleshooting <.cta_arrow class="ml-0.5 h-3 w-3" />
                  </.link>
                </p>
              </div>

              <.auto_permit_block
                client_id={@selected_client}
                client_label={client_label(@selected_client)}
                auto_permit={Map.get(@config, :auto_permit)}
              />
            </div>
        <% end %>
      </div>

      <%!-- The reading rail — how agent keys work, so the operator minting a
           credential understands its reach and lifecycle before handing it to
           an LLM (the keys-new explainer pattern). --%>
      <aside class="mt-12 lg:mt-0">
        <.section_header title="How agent keys work" />
        <div class="space-y-4 text-sm leading-relaxed text-zinc-400">
          <p>
            Each key is a bearer credential for
            <span class="font-medium text-zinc-300">one MCP client</span>
            — the agent presents it on every call, and its activity lands in Runs and
            the audit trail under the key's name.
          </p>
          <p>
            A key never widens what's allowed. What it may DO is your
            <span class="font-medium text-zinc-300">policy</span>
            — risky actions pause for human approval, out-of-policy ones are denied.
            Which runners it can reach is
            <span class="font-medium text-zinc-300">your own runner scope</span>
            (set per member on the Team page): a key inherits the reach of whoever
            minted it, and shrinks the moment that scope does.
          </p>
          <p>
            The key itself carries no extra permission to lock down — that's why there
            are no per-key scope knobs here. To narrow one agent, mint it under a member
            whose runner scope is already narrow.
          </p>
          <p>
            Quick-connect keys don't expire; revoke one from the agents list when its
            client no longer needs access. Custom keys default to a 30-day expiry.
            Rotating mints a successor — the old key keeps working until the new one's
            first use, then it's revoked automatically.
          </p>
        </div>
      </aside>
    </div>
    """
  end

  # Thin wrapper over the shared <.status_note> so the "New key minted"
  # phrase + its key/amber identity live in ONE place for the three quick-mint
  # branches.
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp minted_note(assigns) do
    ~H"""
    <.status_note
      icon="hero-key"
      tone={:amber}
      title="New key minted — it's live now"
      class={@class}
    >
      {render_slot(@inner_block)}
    </.status_note>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :selected, :boolean, default: false

  defp client_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_client"
      phx-value-client={@id}
      class={[
        "rounded-lg px-3 py-1.5 text-sm font-medium transition",
        if(@selected,
          do: "bg-zinc-100 text-zinc-950",
          else: "bg-zinc-900 text-zinc-300 hover:bg-zinc-800"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  # Renders only AFTER a local client is picked. The install line is the
  # same for every local client — extracting it keeps the per-client
  # snippet focused on just the config the operator needs to paste, and
  # cloud-LLM users never see it at all.
  defp local_install_block(assigns) do
    ~H"""
    <div>
      <.section_header title="Install the bridge">
        <:subtitle>one-time, per machine</:subtitle>
      </.section_header>
      <.code_panel
        id="install-mcp-cmd"
        label="macOS / Linux"
        copy
        code="curl -sSL https://emisar.dev/install-mcp.sh | sudo bash"
      />
      <p class="mt-2 text-[11px] text-zinc-500">
        Inspects the bridge first?
        <.link
          href={~p"/docs/connect-an-llm"}
          class="group text-brand-400 hover:text-brand-300"
        >
          Manual install <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
        ·
        <.link
          href={~p"/trust" <> "#release-integrity"}
          class="group text-brand-400 hover:text-brand-300"
        >
          Verify the release <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
      </p>
    </div>
    """
  end

  # Optional "stop the per-tool prompts" step. emisar already gates every
  # action SERVER-SIDE (per-account policy + human approval on risky ones),
  # so the client's own "allow this tool?" prompt is redundant for emisar's
  # MCP tools — auto-permitting them in the CLIENT only drops that prompt, it
  # never bypasses emisar's policy/approval gate. Collapsed by default: it's
  # secondary to the connect steps. Dispatches on the auto-permit shape — a
  # verified config snippet, or an honest pointer for clients with no
  # per-server allowlist — so we never show an invented setting.
  attr :client_id, :string, required: true
  attr :client_label, :string, required: true
  attr :auto_permit, :any, required: true

  defp auto_permit_block(%{auto_permit: nil} = assigns), do: ~H""

  defp auto_permit_block(%{auto_permit: %{body: _}} = assigns) do
    ~H"""
    <.disclosure size={:md}>
      <:summary>
        <span class="font-medium">
          Skip the per-tool prompts <span class="text-zinc-500">(optional)</span>
        </span>
      </:summary>
      <.auto_permit_why client_label={@client_label} />
      <p class="mt-3 text-[11px] text-zinc-500 font-mono">{@auto_permit.location}</p>
      <.code_panel
        id={"permit-#{@client_id}"}
        label={"#{@client_label}'s setting"}
        annotation="not an emisar config"
        copy
        code={@auto_permit.body}
        class="mt-2"
      />
    </.disclosure>
    """
  end

  defp auto_permit_block(%{auto_permit: %{pointer: _}} = assigns) do
    ~H"""
    <.disclosure size={:md}>
      <:summary>
        <span class="font-medium">
          Skip the per-tool prompts <span class="text-zinc-500">(optional)</span>
        </span>
      </:summary>
      <.auto_permit_why client_label={@client_label} />
      <p class="mt-3 text-xs text-zinc-400">{@auto_permit.pointer}</p>
      <p class="mt-2 text-[11px] text-zinc-500">
        <.link
          href={@auto_permit.doc_url}
          target="_blank"
          rel="noopener noreferrer"
          class="group text-brand-400 hover:text-brand-300"
        >
          {@client_label} MCP docs <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
      </p>
    </.disclosure>
    """
  end

  # The shared WHY — stated the same way for the snippet and pointer variants:
  # safe BECAUSE emisar gates server-side; the client toggle only removes its
  # own prompt.
  attr :client_label, :string, required: true

  defp auto_permit_why(assigns) do
    ~H"""
    <p class="text-xs text-zinc-400">
      emisar gates every action <strong class="text-zinc-200">server-side</strong>
      — per-account policy, and human approval on risky ones — so {@client_label}'s
      per-tool "allow this?" prompt is redundant for emisar's tools. Safe to silence:
      this only drops {@client_label}'s prompt. A risky action still pauses for approval
      at emisar, and an out-of-policy one is still denied. What counts as "risky" is your <strong class="text-zinc-200">Policy</strong>. Keep the tiers you don't want run
      unattended on require-approval or deny.
    </p>
    """
  end

  attr :client_id, :string, required: true
  attr :client_label, :string, required: true
  attr :rpc_url, :string, required: true
  attr :auth_header, :string, required: true
  attr :steps, :list, required: true

  defp remote_mcp_panel(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.section_header title="Add the connector">
          <:subtitle>Paste both values into {@client_label}'s custom-connector setup.</:subtitle>
        </.section_header>
        <%!-- The two values cloud LLMs need. Bearer header is rendered
             in full (operator just minted it) so they can copy the whole
             "Authorization: Bearer emk-..." string verbatim. --%>
        <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — earned artifact frame (credential values), pending code_panel migration --%>
        <div class="overflow-hidden rounded-lg bg-black/80 ring-1 ring-white/[0.08]">
          <div class="flex items-center justify-between gap-3 border-b border-zinc-800/70 px-4 py-2.5">
            <p class="font-mono text-[11px] text-zinc-500">connector settings</p>
            <.copy_button
              id={"copy-#{@client_id}-conn"}
              text={"URL: #{@rpc_url}\nHeader: #{@auth_header}"}
            >
              Copy URL + header
            </.copy_button>
          </div>
          <div class="grid grid-cols-[max-content,1fr] gap-x-3 gap-y-1 p-4 font-mono text-xs leading-6 text-zinc-200">
            <span class="text-zinc-500">URL:</span>
            <span id={"rpc-url-#{@client_id}"} class="break-all text-zinc-200">{@rpc_url}</span>
            <span class="text-zinc-500">Header:</span>
            <span id={"auth-hdr-#{@client_id}"} class="break-all text-zinc-200">{@auth_header}</span>
          </div>
        </div>
      </div>

      <div>
        <%!-- Per-host step list on the canvas — content, not an artifact. Each
             client config stores its own list because the menu paths differ
             (Claude.ai uses "Custom connectors", ChatGPT "Connectors"). --%>
        <.section_header title={"Steps for #{@client_label}"} />
        <.steps>
          <:step :for={step <- @steps}>{step}</:step>
        </.steps>
      </div>

      <p class="text-xs text-zinc-500">
        Cloud LLM connectors need {@client_label} to be on a plan that
        supports custom MCP servers. Connection refused or 401?
        <.link
          href={~p"/docs/connect-an-llm"}
          class="group text-brand-400 hover:text-brand-300"
        >
          Troubleshooting <.cta_arrow class="ml-0.5 h-3 w-3" />
        </.link>
      </p>
    </div>
    """
  end

  attr :form, :any, required: true

  defp custom_key_panel(assigns) do
    ~H"""
    <div class="space-y-5">
      <p class="text-sm leading-relaxed text-zinc-400">
        Create a key by hand — for an agent that isn't one of the presets above, or when
        you want to give it your own name and expiry date.
      </p>

      <.simple_form for={@form} id="api_key_form" phx-change="validate" phx-submit="create">
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          placeholder="e.g. Claude Desktop on laptop"
          required
        />

        <.input
          field={@form[:description]}
          type="textarea"
          label="Description"
          placeholder="Optional — what is this key for? Who uses it?"
          rows="2"
        />

        <%!-- `datetime-local` posts as "YYYY-MM-DDTHH:MM" with no
             timezone; the LV parses it as UTC. Operators typing
             "expires Dec 25 at 10am" get a key that expires at
             10:00 UTC on that date, which is close enough for an
             audit-friendly default without dragging browser-tz
             guessing into the server. --%>
        <.input
          field={@form[:expires_at]}
          type="datetime-local"
          label="Expires (UTC)"
        />
        <p class="mt-1 text-xs text-zinc-500">
          Leave blank for the default 30-day expiry — a short-lived key limits the
          blast radius if it leaks. Pick a date to override.
        </p>

        <:actions>
          <.button phx-disable-with="Creating...">Create key</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
