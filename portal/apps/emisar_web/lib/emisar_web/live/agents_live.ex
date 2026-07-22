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

  A live key whose emisar-mcp bridge is below the minimum supported
  version reads rose "unsupported" in place of that liveness word — a
  version-blocked client isn't merely quiet (see `pill_status/1`).

  We re-render every #{5} s via a self-scheduled `:tick` so "Last call"
  + the status badge stay fresh without a full PubSub subscription on
  every MCP request.
  """
  use EmisarWeb, :live_view
  alias Emisar.{ApiKeys, Compat}
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions, UrlHelpers}
  alias Phoenix.LiveView.JS

  @active_threshold_secs 5 * 60
  @idle_threshold_secs 24 * 60 * 60
  @refresh_ms 5_000
  @remote_client_ids ~w(claude_web chatgpt)

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @refresh_ms)

      # Live API-key list — another operator's create / revoke (or an
      # LLM's first call that flips api_key.bound) reflows this page
      # without the viewer refreshing.
      ApiKeys.subscribe_account_api_keys(socket.assigns.current_account.id)
    end

    # The operator first picks which LLM client they're connecting. For local
    # clients the INSTALLER does the setup (device-grant approval mints the
    # keys); the manual snippet's key is minted lazily, only when its
    # disclosure is opened. Cloud clients use OAuth, so their backing key is
    # minted only after the user consents in the OAuth flow.
    {:ok,
     socket
     |> assign(:page_title, "LLM agents")
     |> assign(:quick_secret, nil)
     # The snippet/custom paths watch their just-minted key for its first
     # call; the installer path (key ids minted at grant approval, unknown
     # here) watches for ANY key minted after this page opened connecting.
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)
     |> assign(:watch_since, DateTime.utc_now())
     |> assign(:snippet_open?, false)
     |> assign(:selected_client, nil)
     |> assign(:base_url, UrlHelpers.derive_base_url(socket))
     |> ConfirmDialog.init()
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
       ~p"/app/#{socket.assigns.current_account}/agents",
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
     |> assign(:quick_secret, nil)
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)}
  end

  def handle_event("select_client", %{"client" => id}, socket) when id in @remote_client_ids do
    {:noreply,
     socket
     |> assign(:selected_client, id)
     |> assign(:quick_secret, nil)
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)}
  end

  def handle_event("select_client", %{"client" => id}, socket) do
    # Picking a local client mints NOTHING — the installer's device-grant
    # approval mints the keys, and the manual snippet mints its own lazily on
    # reveal. Switching clients resets the lazy snippet state.
    {:noreply,
     socket
     |> assign(:selected_client, id)
     |> assign(:quick_secret, nil)
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)
     |> assign(:snippet_open?, false)}
  end

  def handle_event("reveal_snippet", _params, socket) do
    # Quick-mint is the ISSUE tier (operators and above) — gating it on
    # manage broke the flow for the very role the picker rendered for.
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket ->
        socket = assign(socket, :snippet_open?, not socket.assigns.snippet_open?)

        if socket.assigns.snippet_open? and is_nil(socket.assigns.quick_secret) and
             local_client?(socket.assigns.selected_client) do
          mint_snippet_key(socket)
        else
          {:noreply, socket}
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

  # Every api_key change (including `api_key.first_used`) reloads the list;
  # `quick_key_connected?/2` derives the waiting→connected flip from the
  # reloaded keys, so the broadcast and the tick fallback share one judgment.
  def handle_info({:list_changed, :api_key, _event_type, _id}, socket),
    do: {:noreply, reload(socket)}

  # The badge hooks (UserAuth) forward account-topic broadcasts to every
  # authenticated LV — ignore the ones this page doesn't render.
  def handle_info(_, socket), do: {:noreply, socket}

  # -- Internals -------------------------------------------------------

  # The manual snippet's lazy mint (reveal_snippet): named after the client so
  # it lands on the agents list and audit rows as e.g. "Claude Desktop".
  defp mint_snippet_key(socket) do
    name = client_label(socket.assigns.selected_client)

    case ApiKeys.mint_quick_key(socket.assigns.current_subject, name: name) do
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign(:quick_key_id, key.id)
         |> assign(:quick_connected?, false)
         |> reload()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:snippet_open?, false)
         |> put_flash(:error, "Could not mint a key for the snippet.")}
    end
  end

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
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign(:quick_key_id, key.id)
         |> assign(:quick_connected?, false)
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

  # Derives the connect flow's waiting→connected flip from the loaded keys —
  # sticky once true. Two watch modes: the snippet/custom paths watch their
  # just-minted key's id; the installer path — whose key ids are minted by the
  # device-grant approval and unknown to this page — watches for any key
  # minted AFTER this page opened making its first call (a pre-existing
  # agent's activity can never flip it; scoped-advance discipline).
  defp quick_key_connected?(%{assigns: %{quick_connected?: true}}, _keys), do: true

  defp quick_key_connected?(%{assigns: %{quick_key_id: id}}, keys) when is_binary(id),
    do: Enum.any?(keys, &(&1.id == id and &1.last_used_at))

  defp quick_key_connected?(%{assigns: assigns}, keys) do
    local_client?(assigns.selected_client) and
      Enum.any?(keys, fn key ->
        key.last_used_at && DateTime.compare(key.inserted_at, assigns.watch_since) == :gt
      end)
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
        |> assign(:quick_connected?, quick_key_connected?(socket, keys))
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
  defp owner_label(%{created_by: %{} = user}), do: user_display_name(user)
  defp owner_label(_), do: "Auto-minted"

  # Pre-sort by owner so each `group_by={&owner_label/1}` cluster is one
  # contiguous run under a single header; within a cluster the context's
  # recent-first order holds.
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
      true -> "text-zinc-400"
    end
  end

  defp expiry_class(%ApiKeys.ApiKey{}), do: "text-zinc-400"

  # Rotation lineage. The swap is PENDING while the replaced key is still usable
  # — this key's first authenticated use retires it. The lineage seg renders only
  # while pending, so the replaced row is always the preloaded, still-usable
  # ancestor; successors inherit the name, so it's named by its distinguishing
  # prefix.
  defp swap_pending?(%ApiKeys.ApiKey{replaces: %ApiKeys.ApiKey{} = replaced}),
    do: ApiKeys.ApiKey.usable?(replaced)

  defp swap_pending?(%ApiKeys.ApiKey{}), do: false

  defp replaced_key_label(%ApiKeys.ApiKey{replaces: %ApiKeys.ApiKey{} = replaced}),
    do: replaced.key_prefix <> "…"

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

  # The status the row LEADS with. A bridge below the minimum emisar-mcp
  # version is blocked by version policy, so its recency is moot — the pill
  # reads rose "unsupported" in place of "idle"/"active", the way the packs
  # page reads "retired" instead of "trusted". A revoked key stays "revoked"
  # (operator intent wins, as "rejected" wins over "retired" there); an
  # outdated-but-usable bridge keeps its real liveness with the amber version
  # chip beside it.
  defp pill_status(%ApiKeys.ApiKey{} = key) do
    status = client_status(key)
    bridge_status = Compat.mcp_status(mcp_bridge_version(key))

    if status != :revoked and bridge_status == :unsupported do
      :unsupported
    else
      status
    end
  end

  # The MCP client a key reported at `initialize` (clientInfo): the human-readable
  # "title", else the machine "name". Name only — the client's own version is
  # detail material, not row meta. nil until a client has connected.
  defp reported_client(%ApiKeys.ApiKey{last_client_info: %{} = info}) do
    label = info["title"] || info["name"]
    if is_binary(label) and label != "", do: label
  end

  defp reported_client(_), do: nil

  # The connecting client only earns a meta seg when it ADDS to the row. A
  # quick-mint names the key after the client it was minted for ("Claude Code"),
  # so the client that then connects ("claude-code") just echoes the title and is
  # dropped; a custom-named key ("prod-mcp") keeps it — the client is new info.
  defp distinct_client(%ApiKeys.ApiKey{name: name} = key) do
    case reported_client(key) do
      nil -> nil
      client -> if normalize_client(client) == normalize_client(name), do: nil, else: client
    end
  end

  # Fold case + separators so "Claude Code" and "claude-code" compare equal.
  defp normalize_client(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  # The emisar-mcp bridge version this key last connected with (captured from
  # the UA at `initialize`), for the stale-version chip. nil for a remote
  # connector, which reports no bridge UA.
  defp mcp_bridge_version(%ApiKeys.ApiKey{last_client_info: %{"bridge_version" => version}})
       when is_binary(version),
       do: version

  defp mcp_bridge_version(_), do: nil

  defp usable_mcp_bridge_versions(keys) do
    keys
    |> Enum.filter(&ApiKeys.ApiKey.usable?/1)
    |> Enum.map(&mcp_bridge_version/1)
  end

  defp status_label(:active), do: "active"
  defp status_label(:idle), do: "idle"
  defp status_label(:dormant), do: "dormant"
  defp status_label(:never_used), do: "never used"
  defp status_label(:revoked), do: "revoked"
  defp status_label(:unsupported), do: "unsupported"

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
  @client_ids ~w(claude_web chatgpt claude_code claude_desktop cursor windsurf zed openclaw opencode pi copilot gemini codex goose hermes grok custom)
  @client_labels %{
    "claude_web" => "Claude.ai",
    "chatgpt" => "ChatGPT",
    "claude_code" => "Claude Code",
    "claude_desktop" => "Claude Desktop",
    "cursor" => "Cursor",
    "windsurf" => "Windsurf",
    "zed" => "Zed",
    "openclaw" => "OpenClaw",
    "opencode" => "OpenCode",
    "pi" => "Pi",
    "copilot" => "Copilot CLI",
    "gemini" => "Gemini CLI",
    "codex" => "Codex CLI",
    "goose" => "Goose",
    "hermes" => "Hermes",
    "grok" => "Grok CLI",
    "custom" => "Custom"
  }

  # Two transports under the hood — local stdio bridge (`emisar-mcp`)
  # and remote MCP over HTTP at `/api/mcp/rpc`. Remote-MCP clients
  # don't need the bridge binary installed; they just need a URL and
  # OAuth. We surface that as a different tab variant rather
  # than a global toggle because the operator's question is "which
  # client am I connecting" first; transport falls out of the answer.
  defp remote_client?(id), do: id in @remote_client_ids

  defp local_client?(id),
    do: is_binary(id) and id != "custom" and not remote_client?(id)

  defp client_label(id), do: Map.get(@client_labels, id, "MCP client")

  defp remote_client_ids, do: Enum.filter(@client_ids, &remote_client?/1)

  defp local_client_ids,
    do: Enum.reject(@client_ids, &(remote_client?(&1) or &1 == "custom"))

  # A local client either RUNS its snippet as a command (Claude Code) or pastes
  # it INTO a config file (Claude Desktop, Cursor, Gemini, Codex). The file
  # clients' `location` is a real path (starts with "~"); the command client has
  # none — so the setup header can name the right action instead of always
  # saying "paste".
  defp config_target_is_file?(%{location: location}),
    do: is_binary(location) and String.starts_with?(location, "~")

  defp client_config("claude_web", url, _key) do
    %{
      kind: :remote,
      connector_name: "Emisar",
      connector_name_label: "Connector name",
      rpc_url: "#{url}/api/mcp/rpc",
      rpc_url_label: "Remote MCP server URL",
      oauth_note: %{
        title: "Leave OAuth credentials empty",
        body:
          "OAuth Client ID and OAuth Client Secret are optional. Claude.ai discovers Emisar's OAuth metadata and registers itself."
      },
      steps: [
        "Open Settings → Connectors → Add custom connector in claude.ai.",
        "Paste the connector name and Remote MCP server URL below.",
        "Select Add, then complete the emisar sign-in and consent screen."
      ],
      # The copy fields render inside this step (paste the values), so the guide
      # reads paste → values → next step without scrolling back up.
      form_at_step: 2,
      auto_permit: %{
        pointer:
          "After connecting, open Settings → Connectors → Emisar, then set Read-only tools and Write/delete tools to Always allow.",
        doc_url: nil
      }
    }
  end

  defp client_config("chatgpt", url, _key) do
    %{
      kind: :remote,
      connector_name: "Emisar",
      connector_name_label: "Name",
      rpc_url: "#{url}/api/mcp/rpc",
      rpc_url_label: "MCP Server URL",
      oauth_note: %{
        title: "Use OAuth",
        body:
          "No API key is required. ChatGPT discovers Emisar's OAuth metadata from the server URL."
      },
      steps: [
        "Turn on Developer mode once: Settings → Security and login (also linked at the bottom of Settings → Plugins).",
        "Open Settings → Plugins and click Create.",
        "Set Connection to Server URL, paste the Name and MCP Server URL below, then choose OAuth.",
        "Check \"I understand and want to continue\", click Create, then complete the emisar sign-in and consent screen.",
        "Use it from a new chat: + → More → Emisar. To skip the per-call prompts, open Emisar → Permissions and choose Allow all actions."
      ],
      # The copy fields render inside this step (paste the values), so the guide
      # reads paste → values → next step without scrolling back up.
      form_at_step: 3
    }
  end

  defp client_config("claude_code", url, key) do
    %{
      kind: :local,
      # No `location`: the snippet is a command to RUN, not a file to edit.
      location: nil,
      # Leading space (note the extra indent on the first line): a shell with
      # `ignorespace`/`ignoreboth` keeps this key-bearing command out of history.
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
      auto_permit: %{
        pointer:
          "Add default_tools_approval_mode = \"approve\" below [mcp_servers.emisar] in ~/.codex/config.toml. This trusts only the emisar MCP server; emisar still applies its own policies and approvals.",
        doc_url: "https://developers.openai.com/codex/mcp"
      }
    }
  end

  defp client_config("windsurf", url, key) do
    %{
      kind: :local,
      location: "~/.codeium/windsurf/mcp_config.json",
      body: mcp_json_snippet(url, key, "/usr/local/bin/emisar-mcp", "windsurf")
    }
  end

  # Pi reads the Claude-Code-shaped mcpServers file from its own agent dir.
  defp client_config("pi", url, key) do
    %{
      kind: :local,
      location: "~/.pi/agent/mcp.json",
      body: mcp_json_snippet(url, key, "/usr/local/bin/emisar-mcp", "pi")
    }
  end

  # OpenClaw nests stdio servers under mcp.servers (NOT top-level mcpServers).
  defp client_config("openclaw", url, key) do
    %{
      kind: :local,
      location: "~/.openclaw/openclaw.json",
      body: """
      {
        "mcp": {
          "servers": {
            "emisar": {
              "command": "/usr/local/bin/emisar-mcp",
              "env": {
                "EMISAR_URL": "#{url}",
                "EMISAR_API_KEY": "#{key}",
                "EMISAR_CLIENT": "openclaw"
              }
            }
          }
        }
      }\
      """
    }
  end

  # OpenCode: top-level `mcp`, command as an ARRAY, `environment` (not env).
  defp client_config("opencode", url, key) do
    %{
      kind: :local,
      location: "~/.config/opencode/opencode.json",
      body: """
      {
        "mcp": {
          "emisar": {
            "type": "local",
            "command": ["/usr/local/bin/emisar-mcp"],
            "enabled": true,
            "environment": {
              "EMISAR_URL": "#{url}",
              "EMISAR_API_KEY": "#{key}",
              "EMISAR_CLIENT": "opencode"
            }
          }
        }
      }\
      """
    }
  end

  defp client_config("copilot", url, key) do
    %{
      kind: :local,
      location: "~/.copilot/mcp-config.json",
      body: """
      {
        "mcpServers": {
          "emisar": {
            "type": "local",
            "command": "/usr/local/bin/emisar-mcp",
            "args": [],
            "env": {
              "EMISAR_URL": "#{url}",
              "EMISAR_API_KEY": "#{key}",
              "EMISAR_CLIENT": "copilot-cli"
            },
            "tools": ["*"]
          }
        }
      }\
      """
    }
  end

  # Zed calls them context_servers; `source: "custom"` is required or the
  # entry is silently skipped.
  defp client_config("zed", url, key) do
    %{
      kind: :local,
      location: "~/.config/zed/settings.json",
      body: """
      {
        "context_servers": {
          "emisar": {
            "source": "custom",
            "command": "/usr/local/bin/emisar-mcp",
            "args": [],
            "env": {
              "EMISAR_URL": "#{url}",
              "EMISAR_API_KEY": "#{key}",
              "EMISAR_CLIENT": "zed"
            }
          }
        }
      }\
      """
    }
  end

  defp client_config("hermes", url, key) do
    %{
      kind: :local,
      location: "~/.hermes/config.yaml",
      body: """
      mcp_servers:
        emisar:
          command: /usr/local/bin/emisar-mcp
          env:
            EMISAR_URL: "#{url}"
            EMISAR_API_KEY: "#{key}"
            EMISAR_CLIENT: hermes\
      """
    }
  end

  # Goose's stdio extension grammar: `cmd`/`envs` (not command/env).
  defp client_config("goose", url, key) do
    %{
      kind: :local,
      location: "~/.config/goose/config.yaml",
      body: """
      extensions:
        emisar:
          name: emisar
          cmd: /usr/local/bin/emisar-mcp
          args: []
          enabled: true
          envs:
            EMISAR_URL: "#{url}"
            EMISAR_API_KEY: "#{key}"
            EMISAR_CLIENT: goose
          type: stdio
          timeout: 300\
      """
    }
  end

  defp client_config("grok", url, key) do
    %{
      kind: :local,
      location: nil,
      # Leading space (extra indent on the first line): a shell with
      # `ignorespace`/`ignoreboth` keeps this key-bearing command out of history.
      body: """
       grok mcp add emisar \\
          -e EMISAR_URL=#{url} \\
          -e EMISAR_API_KEY=#{key} \\
          -e EMISAR_CLIENT=grok \\
          -- /usr/local/bin/emisar-mcp\
      """,
      # Grok's native permission rules accept a server-scoped MCPTool wildcard.
      # This drops only Grok's prompt; emisar policy and approvals still apply.
      auto_permit: %{
        location: "~/.grok/config.toml — add to the existing [permission] section",
        body: """
        allow = ["MCPTool(emisar__*)"]\
        """
      }
    }
  end

  # `client` is baked into EMISAR_CLIENT so the bridge can stamp it on
  # every local MCP request's User-Agent — the audit page shows it as
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
      onboarding_incomplete?={@onboarding_incomplete?}
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
          <.back_link navigate={~p"/app/#{@current_account}/agents"}>LLM agents</.back_link>
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
          navigate={~p"/app/#{@current_account}/agents/connect"}
          size={:md}
          icon="hero-plus"
        >
          Connect an agent
        </.button>
      </:actions>

      <.page_intro :if={@live_action == :index}>
        The agents connected to this workspace, and the key behind each — connect a new one, or
        revoke access in one click.
      </.page_intro>

      <.page_intro :if={@live_action == :connect}>
        Pick how your agent connects. Cloud clients use OAuth and mint their backing key only
        after consent; local clients get a one-time key with setup pre-filled.
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
        base_url={@base_url}
        quick_secret={@quick_secret}
        quick_key_id={@quick_key_id}
        quick_connected?={@quick_connected?}
        snippet_open?={@snippet_open?}
        current_account={@current_account}
        form={@form}
      />

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
          class="max-w-prose text-sm leading-relaxed text-zinc-400"
        >
          Connecting an agent needs an operator role or above — ask an operator,
          admin, or owner to mint the key.
        </p>
        <div :if={ApiKeys.subject_can_issue_quick_key?(@current_subject)}>
          <.connect_panel
            configs_for={&client_config(&1, @base_url, @quick_secret || "emk-…")}
            selected_client={@selected_client}
            base_url={@base_url}
            quick_secret={@quick_secret}
            quick_key_id={@quick_key_id}
            quick_connected?={@quick_connected?}
            snippet_open?={@snippet_open?}
            current_account={@current_account}
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
      <section
        :if={
          @live_action == :index and
            not (@show_connect_inline? and @api_keys == [] and
                   not LiveTable.has_active_filters?(@filter_params, @filters))
        }
        class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start"
      >
        <%!-- :table leaves the agents list narrow-of-content and wide-of-page;
             pair it with a docs rail (main+aside) — the list leads, a plain-terms
             "what's an LLM agent" teaches beside it. The rail is a FIXED 22rem
             track that only splits off at xl (its prose never squeezes); below
             xl it stacks full-width. --%>
        <div class="min-w-0">
          <.version_upgrade_notice
            id="mcp-upgrade"
            kind={:mcp}
            versions={usable_mcp_bridge_versions(@api_keys)}
            base_url={@base_url}
            class="mb-10"
          />
          <%!-- NAKED posture line (the runners grammar): page-level notices
               come first, then activity, then filters/data on every list page. --%>
          <div
            :if={@issued_count > 0}
            class="flex flex-wrap items-center gap-x-5 gap-y-1 pb-4 text-xs"
          >
            <span
              class="flex items-center gap-1.5"
              title="called an action in the last 5 minutes"
            >
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
              <span class="tabular-nums text-zinc-400">{@idle_count} idle</span>
            </span>
            <span
              :if={@dormant_count > 0}
              class="flex items-center gap-1.5"
              title="no call for over 24 hours"
            >
              <.status_dot tone={:neutral} size={:sm} />
              <span class="tabular-nums text-zinc-400">{@dormant_count} dormant</span>
            </span>
            <span :if={@never_used_count > 0} class="flex items-center gap-1.5">
              <.status_dot tone={:neutral} size={:sm} />
              <span class="tabular-nums text-zinc-400">{@never_used_count} never used</span>
            </span>
          </div>
          <LiveTable.live_table
            layout={:cards}
            id="agents"
            path={~p"/app/#{@current_account}/agents"}
            rows={sort_by_owner(@api_keys)}
            metadata={@metadata}
            filter_params={@filter_params}
            filters={@filters}
            wrapper_class="divide-y divide-zinc-800/70"
            group_by={&owner_label/1}
          >
            <%!-- The issuing human heads their run of keys ONCE (the runners
                 group-by-group grammar), so the per-row meta stops repeating
                 "owner Andrew Dryga" down the whole list. Rows are pre-sorted by
                 owner so each header opens one contiguous cluster. --%>
            <:group_header :let={owner}>
              <.list_group_header label={owner} />
            </:group_header>
            <:item :let={key}>
              <.list_row padding="py-4">
                <:title>
                  <span class="truncate font-medium text-zinc-100">{key.name}</span>
                  <%!-- The emisar-mcp bridge version this key last connected through —
                     mono + muted in the identity line so bridges are comparable at a
                     glance across agents, the same v{version} grammar the runners list
                     uses. A remote connector reports no bridge → nothing here. --%>
                  <span
                    :if={mcp_bridge_version(key)}
                    class="font-mono text-[11px] text-zinc-400"
                  >
                    v{mcp_bridge_version(key)}
                  </span>
                  <.client_status_pill key={key} />
                  <%!-- The pill already leads with rose "unsupported" when the
                       bridge is below the minimum (a blocked client isn't
                       "idle"), so the chip here only surfaces the softer amber
                       "outdated" — never a second, redundant red label. --%>
                  <.version_chip
                    :if={pill_status(key) != :unsupported}
                    kind={:mcp}
                    version={mcp_bridge_version(key)}
                    id={"mcp-version-#{key.id}"}
                  />
                </:title>
                <:meta>
                  <%!-- Liveness + lifecycle only. The owner heads the group above,
                     so it's off the row; the scopes are a fixed MCP shape nobody
                     manages here, so they earn no chips. No key prefix: truncated
                     it rendered the SAME shared literal on every row. --%>
                  <.meta_line class="text-[11px]">
                    <%!-- The client only earns a seg when it ADDS to the name —
                       a quick-mint names the key after its client, so the seg
                       would just echo the title; a custom-named key keeps it. --%>
                    <:seg :if={distinct_client(key)}>
                      client <span class="text-zinc-300">{distinct_client(key)}</span>
                    </:seg>
                    <%!-- Rotation lineage shows ONLY while the swap is unproven:
                       the replaced key keeps working until this one's first use
                       auto-revokes it, so "swap pending" is the actionable state.
                       Once settled the lineage is forensic — the audit trail keeps
                       it — not a per-row fact on every rotated key forever. --%>
                    <:seg :if={swap_pending?(key)}>
                      <span
                        class="text-amber-300/90"
                        title="Replaces a rotated key — the old key is revoked automatically the first time this key is used"
                      >
                        replaces <span class="font-mono">{replaced_key_label(key)}</span>
                        · swap pending
                      </span>
                    </:seg>
                    <:seg>
                      last call{" "}<.local_time
                        id={"agent-key-used-#{key.id}"}
                        value={key.last_used_at}
                        mode={:relative}
                        placeholder="never"
                      />
                    </:seg>
                    <:seg :if={key.expires_at}>
                      <span class={expiry_class(key)}>
                        {if expired?(key), do: "expired", else: "expires"}
                        <.local_time
                          id={"agent-key-expires-#{key.id}"}
                          value={key.expires_at}
                          mode={:relative}
                        />
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
                    navigate={
                      ~p"/app/#{@current_account}/runs?#{[source: "mcp", api_key_id: key.id]}"
                    }
                    variant={:ghost}
                    size={:sm}
                  >
                    View activity
                  </.button>
                  <.confirm_button
                    :if={
                      is_nil(key.revoked_at) and
                        ApiKeys.subject_can_manage_api_keys?(@current_subject)
                    }
                    id={"rotate-#{key.id}"}
                    title="Rotate this key?"
                    confirm_label="Rotate key"
                    variant={:ghost}
                    tone={:neutral}
                    size={:sm}
                    on_confirm={JS.push("rotate", value: %{id: key.id})}
                  >
                    <:body>
                      A new key with the same scope is minted; this one keeps working until the new
                      key's first use, then it's revoked automatically.
                    </:body>
                    Rotate
                  </.confirm_button>
                  <%!-- IRREVERSIBLE credential kill — typed confirm, same tier
                     as enrollment keys (one ladder for one action class). --%>
                  <.button
                    :if={
                      is_nil(key.revoked_at) and
                        ApiKeys.subject_can_manage_api_keys?(@current_subject)
                    }
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    phx-click={show_confirm_dialog("revoke-agent-key-#{key.id}")}
                  >
                    Revoke
                  </.button>
                  <%!-- Per-row typed dialog with the key's name baked in at render,
                     so it opens already-populated. A single page-level dialog
                     filled by an "open_revoke" round-trip flashed a blank
                     name/token for one round-trip before the server filled it. --%>
                  <.confirm_dialog
                    :if={is_nil(key.revoked_at)}
                    id={"revoke-agent-key-#{key.id}"}
                    title="Revoke this agent key"
                    confirm_label="Revoke key"
                    confirm_token={key.name}
                    typed={@typed}
                    on_confirm={
                      JS.push("revoke", value: %{id: key.id})
                      |> hide_confirm_dialog("revoke-agent-key-#{key.id}")
                    }
                  >
                    <:body>
                      Permanently revokes
                      <span class="font-mono font-medium text-zinc-200">{key.name}</span>
                      — the connected client gets 401s on its next call. This can't be undone;
                      connect the client again to mint a fresh key.
                    </:body>
                  </.confirm_dialog>
                </:actions>
              </.list_row>
            </:item>
            <:empty>
              <.empty_state
                :if={@load_error?}
                tone={:danger}
                icon="hero-exclamation-triangle"
                title="Couldn't load your agents"
              >
                This is a load error, not an empty list — your connected agents may well be here.
                Refresh the page; if it persists, your access to this account may have changed.
              </.empty_state>
              <.empty_state
                :if={not @load_error?}
                icon="hero-cpu-chip"
                title="No agents connected yet."
              >
                Pick a client above. Cloud clients use OAuth; local clients get a key +
                pre-filled snippet. The agent shows up here on its first MCP call.
              </.empty_state>
            </:empty>
          </LiveTable.live_table>
        </div>

        <.agent_docs_rail />
      </section>
    </.dashboard_shell>
    """
  end

  # The "what's an agent + how its key behaves" explainer, shared by the agents
  # list (below the table) and the connect page (right rail): one copy, one place.
  # Kept concise — one section, three paragraphs — so the rail never overshoots a
  # short local-client install panel on the connect page.
  defp agent_docs_rail(assigns) do
    ~H"""
    <.docs_rail
      title="What's an LLM agent?"
      doc_href="/docs/connect-an-llm"
      doc_label="Connect an agent docs"
    >
      <p>
        An agent is any LLM client — <span class="text-zinc-200">Claude, ChatGPT, Cursor,
        Codex</span>
        — connected to emisar over <span class="text-zinc-200">MCP</span>, the Model Context
        Protocol.
      </p>
      <p>
        emisar exposes your runners and their action catalog as an MCP server, so an agent can
        only request actions that are <span class="text-zinc-200">in the catalog</span>
        — never a raw shell. Every call is gated by policy, may need an approval, and lands in
        the audit trail.
      </p>
      <p>
        Each connection gets its own key, revocable in one click. A key reaches only the runners
        the operator who created it can reach — it never outgrows the person behind it, and
        narrowing that operator's scope shrinks every key they've issued. Cloud LLMs like
        Claude.ai and ChatGPT connect from the server URL over OAuth — no token to manage.
      </p>
    </.docs_rail>
    """
  end

  attr :key, :map, required: true

  # Sanctioned page-local status (composes the shared `<.status_dot>` + a toned
  # word — the status_badge grammar): the words are the agents-specific activity
  # ladder overridden by a blocked bridge (see `pill_status/1`), and :active
  # carries the live ping status_badge can't express.
  defp client_status_pill(assigns) do
    status = pill_status(assigns.key)
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
  defp status_dot_tone(:unsupported), do: :rose
  defp status_dot_tone(_), do: :neutral

  defp status_word_class(:active), do: "text-brand-300"
  defp status_word_class(:revoked), do: "text-rose-300"
  defp status_word_class(:unsupported), do: "text-rose-300"
  defp status_word_class(_), do: "text-zinc-400"

  attr :configs_for, :any, required: true
  attr :selected_client, :any, required: true
  attr :base_url, :string, required: true
  attr :quick_secret, :string, default: nil
  attr :quick_key_id, :string, default: nil
  attr :quick_connected?, :boolean, default: false
  attr :snippet_open?, :boolean, default: false
  attr :current_account, :any, required: true
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
    <div class="xl:grid xl:grid-cols-[minmax(0,1fr)_22rem] xl:gap-x-16">
      <div>
        <%!-- Client picker on the canvas — grouped into two transport families.
           Cloud first (the no-install path most new users want); Local below
           for IDE / desktop clients that go through the stdio bridge. Small
           group labels organize the tabs; the pick step is framed by the page
           intro / section header above, so the picker carries no header. --%>
        <div>
          <p class="text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Cloud
            <span class="ml-1 normal-case tracking-normal text-zinc-400">
              — hosted LLMs: no install, OAuth
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
            <span class="ml-1 normal-case tracking-normal text-zinc-400">
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
           "paste URL + choose OAuth". Scope picker only appears AFTER a
           local client is chosen too; it's part of the per-client setup,
           not a standalone step. --%>
        <%= cond do %>
          <% is_nil(@selected_client) -> %>
            <%!-- Nothing picked → nothing rendered: the picker is the prompt;
               480px of reserved dead space buried the agents list. --%>
            <span></span>
          <% @selected_client == "custom" -> %>
            <div class="mt-10 space-y-6">
              <%= if @quick_secret do %>
                <%!-- NEUTRAL, not amber — the copy-now caution is a permanent
                     property of a fresh mint, not an exceptional state (the
                     install-wizard grammar); amber stays reserved for a state
                     that needs the operator's attention. --%>
                <.event_block icon="hero-key" tone={:neutral} title="New key minted — it's live now">
                  <:body>
                    Copy the bearer token below before you leave this page; we won't show it
                    again. If you lose it, create another key.
                  </:body>
                </.event_block>

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
              <.remote_mcp_panel
                client_id={@selected_client}
                client_label={client_label(@selected_client)}
                connector_name={@config.connector_name}
                connector_name_label={@config.connector_name_label}
                rpc_url={@config.rpc_url}
                rpc_url_label={@config.rpc_url_label}
                oauth_note={@config.oauth_note}
                steps={@config.steps}
                form_at_step={@config.form_at_step}
                auto_permit={Map.get(@config, :auto_permit)}
              />
            </div>
          <% @config -> %>
            <div class="mt-10 space-y-8">
              <.local_install_block base_url={@base_url} />

              <%!-- Manual setup is the fallback — the installer writes the
                   config itself, so this stays collapsed and mints its key
                   LAZILY on reveal (no key exists until someone actually
                   wants the snippet). `open` is server-owned: the summary
                   click round-trips, mints once, and re-renders the details
                   in its true state. Two body shapes, and the lead-in must
                   not lie about which: a config-file client (Claude Desktop,
                   Cursor, …) pastes the snippet INTO a file — the path is the
                   load-bearing step — while a command client (Claude Code)
                   RUNS the snippet in a terminal. --%>
              <.disclosure
                id="manual-setup"
                size={:md}
                open={@snippet_open?}
                summary_click="reveal_snippet"
              >
                <:summary>
                  <span class="font-medium">
                    Set up {client_label(@selected_client)} manually instead
                    <span class="text-zinc-400">(shows a config snippet with a fresh key)</span>
                  </span>
                </:summary>
                <%= if @quick_secret do %>
                  <%= if config_target_is_file?(@config) do %>
                    <p class="text-sm text-zinc-400">
                      Open
                      <code class="rounded bg-zinc-900 px-1.5 py-0.5 font-mono text-[13px] text-zinc-200 ring-1 ring-white/10">
                        {@config.location}
                      </code>
                      and add:
                    </p>
                  <% else %>
                    <p class="text-sm text-zinc-400">Run this in your terminal:</p>
                  <% end %>
                  <.code_panel
                    id={"snippet-#{@selected_client}"}
                    label="Snippet"
                    annotation="contains your API key"
                    copy
                    copy_label="Copy snippet"
                    code={@config.body}
                    class="mt-3"
                  />
                  <%!-- Mechanical next step sits right under the snippet: paste
                       or run it, then restart. --%>
                  <p class="mt-3 text-xs text-zinc-400">
                    {if config_target_is_file?(@config),
                      do: "Restart #{client_label(@selected_client)} after saving.",
                      else: "Start a fresh #{client_label(@selected_client)} session to use it."} Shown once — pick the client again for a fresh key if you lose it.
                    <.doc_link href={~p"/docs/connect-an-llm"}>Troubleshooting</.doc_link>
                  </p>
                <% else %>
                  <p class="text-sm text-zinc-400">One moment — minting this client's key…</p>
                <% end %>
              </.disclosure>
            </div>
        <% end %>

        <%!-- Step 2 — Connect your agent: the live connection status (the
             agents analog of the runner-install "waiting → connected"
             watchdog). The snippet/custom paths watch their minted key's id;
             the installer path watches for any key minted after this page
             opened making its first call (quick_key_connected?/2 — a
             pre-existing agent can't flip it). Waiting is the NORMAL state —
             the quiet dot-led wait line (wait-room grammar) — and the brand
             connected block takes over on the first call (instant via the
             broadcast, tick as the fallback). --%>
        <section :if={@quick_key_id || local_client?(@selected_client)} class="mt-8">
          <.step_header step={2} title="Connect your agent">
            <:subtitle>
              start {client_label(@selected_client)} — its first call lands it here
            </:subtitle>
          </.step_header>
          <%= if @quick_connected? do %>
            <.event_block
              icon="hero-check-circle"
              tone={:brand}
              title="Connected — your agent is live"
            >
              <:body>
                Its first call just landed. Every request now shows under its name in
                <.link
                  navigate={~p"/app/#{@current_account}/agents"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  agents
                </.link>
                and <.link
                  navigate={~p"/app/#{@current_account}/runs"}
                  class="text-brand-400 hover:text-brand-300"
                >Runs</.link>.
              </:body>
            </.event_block>
          <% else %>
            <div class="flex items-start gap-3">
              <%!-- mt-[6px]: optically centers the 10px dot on the first
                   text line (text-sm/relaxed ≈ 23px line box). --%>
              <.status_dot tone={:brand} ping size={:lg} class="mt-[6px]" />
              <p class="text-sm leading-relaxed text-zinc-400">
                <span class="font-medium text-zinc-300">Waiting for your agent's first call</span>
                — this updates on its own; you can leave, and the agent will show in the
                agents list either way.
              </p>
            </div>
          <% end %>
        </section>

        <%!-- Optional, off the act→wait timeline — reads after the live
             status for local clients (remote keeps its copy inside
             remote_mcp_panel, which has no wait status). --%>
        <div :if={@config && @config.kind != :remote && Map.get(@config, :auto_permit)} class="mt-8">
          <.auto_permit_block
            client_id={@selected_client}
            client_label={client_label(@selected_client)}
            auto_permit={Map.get(@config, :auto_permit)}
          />
        </div>
      </div>

      <%!-- The reading rail — the shared what's-an-agent + how-its-key-behaves
           explainer (the same one the agents list shows below its table). Hidden
           below xl (where the grid collapses to one column) so the connect steps
           lead; condensed to one section, it no longer overshoots a short
           local-client install panel. --%>
      <div class="hidden xl:block">
        <.agent_docs_rail />
      </div>
    </div>
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

  attr :step, :integer, required: true
  attr :title, :string, required: true
  slot :subtitle
  slot :actions

  # A numbered section header for the local-client connect flow — a quiet step
  # number + the `section_header` title/subtitle/actions shape — so the flow
  # reads as an explicit sequence: 1 Install the bridge (it configures the
  # client and asks for browser approval), 2 Connect your agent. (Cloud
  # clients get numbered `<.steps>` in the remote panel; local clients are
  # richer sections, so they number the headers.)
  defp step_header(assigns) do
    ~H"""
    <header class="mb-4 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
      <div class="flex min-w-0 items-baseline gap-3">
        <%!-- A quiet typographic numeral, not a badge — same size as the title,
             muted and tabular so the three step numbers align down the column and
             the eye reads a sequence without chrome. --%>
        <span class="shrink-0 font-display text-base font-medium tabular-nums text-zinc-400">
          {@step}
        </span>
        <div class="min-w-0">
          <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
            {@title}
          </h2>
          <p :if={@subtitle != []} class="mt-0.5 text-xs text-zinc-400">{render_slot(@subtitle)}</p>
        </div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  # Renders only AFTER a local client is picked. The install line is the
  # same for every local client — extracting it keeps the per-client
  # snippet focused on just the config the operator needs to paste, and
  # cloud-LLM users never see it at all. The command comes from
  # UrlHelpers.mcp_install_command/1, so a dev or self-hosted portal's
  # base URL rides along as EMISAR_URL.
  attr :base_url, :string, required: true

  defp local_install_block(assigns) do
    ~H"""
    <div>
      <%!-- Inspect-first links (manual install · verify the release) sit on the
           RIGHT as header actions — they open the docs/trust pages in a new tab
           (doc_link's ↗), so a security-conscious operator can vet the curl|bash
           without losing this flow. --%>
      <.step_header step={1} title="Install the bridge">
        <:subtitle>one-time, per machine</:subtitle>
        <:actions>
          <%!-- text-xs so these header-action links stay subordinate to the
               16px heading — doc_link inherits ambient size, and step_header's
               actions slot sets none. --%>
          <div class="flex items-center gap-3 text-xs">
            <.doc_link href={~p"/docs/connect-an-llm"}>Manual install</.doc_link>
            <.doc_link href={~p"/trust" <> "#release-integrity"}>Verify the release</.doc_link>
          </div>
        </:actions>
      </.step_header>
      <.code_panel
        id="install-mcp-cmd"
        label="macOS / Linux"
        copy
        code={UrlHelpers.mcp_install_command(@base_url)}
      />
      <p class="mt-2 text-xs leading-5 text-zinc-400">
        The installer offers to add emisar to the LLM clients it finds on the machine —
        approve the connection in your browser when it asks. No key to copy.
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
          Skip the per-tool prompts <span class="text-zinc-400">(optional)</span>
        </span>
      </:summary>
      <.auto_permit_why client_label={@client_label} />
      <p class="mt-3 text-[11px] text-zinc-400 font-mono">{@auto_permit.location}</p>
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
          Skip the per-tool prompts <span class="text-zinc-400">(optional)</span>
        </span>
      </:summary>
      <.auto_permit_why client_label={@client_label} />
      <p class="mt-3 text-xs text-zinc-400">{@auto_permit.pointer}</p>
      <p :if={@auto_permit.doc_url} class="mt-2 text-[11px] text-zinc-400">
        <.link
          href={@auto_permit.doc_url}
          target="_blank"
          rel="noopener noreferrer"
          class="group text-brand-400 hover:text-brand-300"
        >
          {@client_label} MCP docs <.icon name="hero-arrow-up-right" class="ml-0.5 h-3 w-3" />
        </.link>
      </p>
    </.disclosure>
    """
  end

  # One direct safety sentence; the client-specific instruction follows it.
  attr :client_label, :string, required: true

  defp auto_permit_why(assigns) do
    ~H"""
    <p class="text-xs text-zinc-400">
      Emisar still enforces policy and asks for approval before risky actions, so it is safe to
      turn off {@client_label}'s extra prompts.
    </p>
    """
  end

  attr :client_id, :string, required: true
  attr :client_label, :string, required: true
  attr :connector_name, :string, required: true
  attr :connector_name_label, :string, required: true
  attr :rpc_url, :string, required: true
  attr :rpc_url_label, :string, required: true
  attr :oauth_note, :map, required: true
  attr :steps, :list, required: true
  attr :form_at_step, :integer, required: true
  attr :auto_permit, :any, required: true

  defp remote_mcp_panel(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <%!-- One top-to-bottom guide. The copy-paste values render INSIDE the
             step that uses them (form_at_step) rather than in a separate block
             above the steps, so the operator reads "paste these" → the fields →
             the next step without scrolling back up. Each client stores its own
             step list + paste index because the menu paths and paste point differ
             (Claude.ai pastes at step 2, ChatGPT at step 3). --%>
        <.section_header title={"Steps for #{@client_label}"} />
        <.steps class="mt-5">
          <:step :for={{step, idx} <- Enum.with_index(@steps)}>
            {step}
            <div :if={idx == @form_at_step - 1} class="mt-4 space-y-4">
              <.code_line
                id={"connector-name-#{@client_id}"}
                label={@connector_name_label}
                value={@connector_name}
                copy_label="Copy name"
              />
              <.code_line
                id={"rpc-url-#{@client_id}"}
                label={@rpc_url_label}
                value={@rpc_url}
                copy_label="Copy URL"
              />
              <.status_note icon="hero-information-circle" tone={:neutral} title={@oauth_note.title}>
                {@oauth_note.body}
              </.status_note>
            </div>
          </:step>
        </.steps>
      </div>

      <.auto_permit_block
        client_id={@client_id}
        client_label={@client_label}
        auto_permit={@auto_permit}
      />

      <p class="text-xs text-zinc-400">
        Cloud LLM connectors need {@client_label} to be on a plan that
        supports custom OAuth MCP servers. Connection refused or 401?
        <.doc_link href={~p"/docs/connect-an-llm"}>Troubleshooting</.doc_link>
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
        <p class="mt-1 text-xs text-zinc-400">
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
