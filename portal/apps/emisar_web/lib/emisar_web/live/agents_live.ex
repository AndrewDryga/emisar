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

  alias Emisar.{ApiKeys, Runners}
  alias EmisarWeb.{LiveTable, Permissions, UrlHelpers}

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
    # `ApiKeys.mint_quick_key/3` ring-evicts unused autos at 42 per
    # account, so opening many tabs can't accumulate dangling keys.

    # IL-18: defer the runner read to the connected mount so the
    # pre-connect render does no query work. The picker briefly shows
    # its empty state, then fills in once the socket connects.
    runners =
      if connected?(socket) do
        {:ok, list, _} = Runners.list_runners_for_account(socket.assigns.current_subject)
        list
      else
        []
      end

    {:ok,
     socket
     |> assign(:page_title, "LLM agents")
     |> assign(:runners, runners)
     |> assign(:quick_secret, nil)
     |> assign(:selected_client, nil)
     |> assign(:base_url, UrlHelpers.derive_base_url(socket))
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
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      fn socket ->
        name = client_label(id)

        opts = [
          name: name,
          runner_filter: socket.assigns.selected_runner_ids,
          runner_group_filter: socket.assigns.selected_runner_groups
        ]

        case ApiKeys.mint_quick_key(socket.assigns.current_subject, opts) do
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

  # Pure scope-picker change (no mint). Keeps the selection alive
  # across tab clicks; the next `select_client` reads these socket
  # assigns and propagates them into `mint_quick_key`.
  def handle_event("update_scope", params, socket) do
    {:noreply,
     socket
     |> assign(
       :selected_runner_ids,
       selected_runner_ids(params, socket.assigns.runners)
     )
     |> assign(
       :selected_runner_groups,
       selected_runner_groups(params, socket.assigns.runners)
     )}
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

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      &do_revoke(&1, id)
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
    # Custom keys minted from the agents page are always MCP-shaped:
    # `actions:read` + `actions:execute`, nothing else. The audit
    # `audit:read` scope lives on the audit page where it belongs;
    # exposing it here just confused operators looking to wire an LLM.
    attrs = %{
      name: params["name"] || "",
      description: nil_if_blank(params["description"]),
      expires_at: parse_expires_at(params["expires_at"]),
      scopes: ["actions:read", "actions:execute"],
      runner_filter: selected_runner_ids(params, socket.assigns.runners),
      runner_group_filter: selected_runner_groups(params, socket.assigns.runners)
    }

    case ApiKeys.create_key(attrs, socket.assigns.current_subject) do
      {:ok, raw, _key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign(:show_advanced, false)
         |> assign_form(ApiKeys.change_key(default_params()))
         |> reload()}

      # Field errors (required name, length, or a DB constraint) render
      # inline on the form via <.input>/<.error> — no flash dump.
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

  # Refresh-in-place (tick / mutation): re-runs with current URL params
  # so the operator doesn't jump back to page 1 on revoke or every 5 s.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

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
    # Default to live keys only — a connected-agents view shouldn't be cluttered
    # with dead credentials; the operator opts into revoked via the Status filter.
    params = Map.put_new(params, "status", "live")

    filters = with_owner_options(socket.assigns.current_subject)
    opts = LiveTable.params_to_opts(params, filters)

    case ApiKeys.list_api_keys_for_account(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:created_by])
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
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
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
      "description" => "",
      "expires_at" => "",
      "runner_filter" => [],
      "runner_group_filter" => []
    }
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

  # Reads the scope selection back out of `changeset.params` — the full
  # string-keyed map handed to `cast`. `runner_filter` /
  # `runner_group_filter` aren't cast fields (they're posted as hidden
  # inputs and applied at create time), but `cast` keeps every submitted
  # string key in `params`, so the scope state still round-trips here.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    runners = socket.assigns[:runners] || []
    params = changeset.params || %{}

    socket
    |> assign(:form, to_form(changeset, as: "api_key"))
    |> assign(:selected_runner_ids, selected_runner_ids(params, runners))
    |> assign(:selected_runner_groups, selected_runner_groups(params, runners))
  end

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
  defp reported_client(%ApiKeys.ApiKey{last_client_info: %{} = info}) do
    label = info["title"] || info["name"]

    cond do
      not (is_binary(label) and label != "") -> nil
      is_binary(info["version"]) and info["version"] != "" -> "#{label} #{info["version"]}"
      true -> label
    end
  end

  defp reported_client(_), do: nil

  defp status_label(:active), do: "Active"
  defp status_label(:idle), do: "Idle"
  defp status_label(:dormant), do: "Dormant"
  defp status_label(:never_used), do: "Never used"
  defp status_label(:revoked), do: "Revoked"

  # Maps to the colour palette `core_components.status_badge/1` uses
  # elsewhere — green for active, amber for idle/never, zinc for dormant.
  defp status_class(:active), do: "bg-brand-500/10 text-brand-300 ring-brand-500/30"
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

  # Plain string instead of inline ternaries to dodge a fixed-point
  # bug in the HEEx formatter where multiple `if x == 1, do:`
  # expressions in one text node grow extra whitespace every time
  # `mix format` runs.
  defp scope_summary(runner_ids, group_ids) do
    "#{length(runner_ids)} runner#{pluralize(runner_ids)}, " <>
      "#{length(group_ids)} group#{pluralize(group_ids)}"
  end

  defp pluralize([_]), do: ""
  defp pluralize(_), do: "s"

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
      <:title>LLM agents</:title>

      <.page_intro>
        Connect an LLM client over MCP to dispatch gated, audited actions — each key is
        scoped to runners and capabilities, and revocable in one click.
        <.doc_link href="/docs/connect-an-llm">Connect an agent docs</.doc_link>
      </.page_intro>

      <%!-- Quiet summary band (shared with Runners) so the connect-a-client
           panel below can lead. --%>
      <.summary_band>
        <.summary_stat tone={:brand} value={@active_count} label="Active" hint="last 5 min" />
        <.summary_stat tone={:amber} value={@idle_count} label="Idle" hint="last 24 h" />
        <.summary_stat tone={:neutral} value={@dormant_count} label="Dormant" hint="24 h+" />
        <.summary_stat tone={:neutral} value={@never_used_count} label="Never used" />
        <:trailing>
          {@metadata.count || @issued_count} {if (@metadata.count || @issued_count) == 1,
            do: "key",
            else: "keys"} total
        </:trailing>
      </.summary_band>

      <%!-- Connect-a-client guide (always visible, pre-filled key) --%>
      <.connect_panel
        configs_for={&client_config(&1, @base_url, @quick_secret || "emk-…")}
        selected_client={@selected_client}
        quick_secret={@quick_secret}
        form={@form}
        runners={@runners}
        selected_runner_ids={@selected_runner_ids}
        selected_runner_groups={@selected_runner_groups}
      />

      <%!-- Connected agents list — single-column rows matching the
           AuthKeys / Grants visual language. --%>
      <%!-- Plain heading above a standalone live_table (self-framed cards
           panel), matching the Pending / Members sections — not a bordered
           section wrapping it, which boxed the filter against a second
           border. --%>
      <section class="mt-8">
        <.section_header title="Connected agents" />

        <LiveTable.live_table
          layout={:cards}
          id="agents"
          path={~p"/app/#{@current_account}/settings/agents"}
          rows={@api_keys}
          metadata={@metadata}
          filter_params={@filter_params}
          filters={@filters}
        >
          <:item :let={key}>
            <.list_row icon={agent_icon(key.name)}>
              <%!-- Row 1: name + status pill --%>
              <:title>
                <span class="truncate font-medium text-zinc-100">{key.name}</span>
                <.client_status_pill key={key} />
              </:title>
              <:chips>
                <.chip :for={scope <- key.scopes || []} tone={:neutral} mono>{scope}</.chip>
              </:chips>
              <:meta>
                <%!-- Row 2: prefix + scope (runners + groups) + last call --%>
                <div class="truncate font-mono text-[11px]">
                  {key.key_prefix}…
                  · {format_key_scope(key, @runners)} · last call{" "}<.local_time
                    value={key.last_used_at}
                    mode={:relative}
                    placeholder="never"
                  />
                  <span :if={key.created_by}>· by {key.created_by.email}</span>
                </div>

                <%!-- Row 3: the MCP client this key reported at `initialize`
                     (clientInfo) — what's actually talking, vs the operator
                     name above. Only shown once a client has connected. --%>
                <div :if={reported_client(key)} class="mt-0.5 truncate text-[11px]">
                  client <span class="text-zinc-300">{reported_client(key)}</span>
                </div>
              </:meta>
              <:actions>
                <%!-- What this agent actually did — deep-link the audit log
                     filtered to this key's actor. Shown for revoked keys too:
                     that's exactly when "what did it do" matters. Every role
                     that can see this page also holds view_audit. --%>
                <%!-- An agent's activity is its RUNS (scoped by api_key_id); the
                     audit actor filter is empty for an api_key (terminal run events
                     are engine-attributed), so this pivots to the runs feed. --%>
                <.button
                  navigate={~p"/app/#{@current_account}/runs?#{[api_key_id: key.id]}"}
                  variant="ghost"
                  size="sm"
                >
                  View activity
                </.button>
                <.button
                  :if={
                    is_nil(key.revoked_at) and ApiKeys.subject_can_manage_api_keys?(@current_subject)
                  }
                  variant="danger"
                  size="sm"
                  phx-click="revoke"
                  phx-value-id={key.id}
                  data-confirm="Revoke this API key? The connected client will get 401s on its next call."
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
    </.dashboard_shell>
    """
  end

  attr :key, :map, required: true

  # A sanctioned hand-rolled pill (not `<.chip>`): the :active state shows a live
  # animate-ping dot the shared chip can't express. Colors mirror `status_class/1`
  # so it still reads as part of the status palette.
  defp client_status_pill(assigns) do
    status = client_status(assigns.key)
    assigns = assign(assigns, status: status)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-1.5 py-0.5 text-[10px] font-medium ring-1 ring-inset",
      status_class(@status)
    ]}>
      <span :if={@status == :active} class="relative inline-flex h-1.5 w-1.5">
        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-brand-400 opacity-75">
        </span>
        <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-brand-400"></span>
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
      String.contains?(n, "chatgpt") -> "hero-chat-bubble-left-ellipsis"
      String.contains?(n, "claude") -> "hero-sparkles"
      String.contains?(n, "cursor") -> "hero-cursor-arrow-rays"
      String.contains?(n, "gemini") -> "hero-star"
      String.contains?(n, "codex") -> "hero-code-bracket"
      true -> "hero-cpu-chip"
    end
  end

  defp agent_icon(_), do: "hero-cpu-chip"

  attr :configs_for, :any, required: true
  attr :selected_client, :any, required: true
  attr :quick_secret, :string, default: nil
  attr :form, :any, default: nil
  attr :runners, :list, default: []
  attr :selected_runner_ids, :list, default: []
  attr :selected_runner_groups, :list, default: []

  defp connect_panel(assigns) do
    config =
      cond do
        assigns.selected_client == nil -> nil
        assigns.selected_client == "custom" -> nil
        true -> assigns.configs_for.(assigns.selected_client)
      end

    assigns = assign(assigns, :config, config)

    ~H"""
    <div class="overflow-hidden rounded-2xl border border-zinc-900 bg-zinc-950/60">
      <%!-- Header. The whole rest of the panel responds to which client
           the operator picks, so put the picker FIRST. Anything that
           depends on the choice (install / snippet / URL+token / scope
           note) renders below, only after a client is chosen. --%>
      <div class="border-b border-zinc-900 px-6 py-4">
        <h2 class="text-base font-semibold text-zinc-50">Connect an agent</h2>
        <p class="mt-0.5 text-xs text-zinc-500">
          Pick how your agent connects. We mint a fresh API key named after the
          client and pre-fill the exact setup it needs.
        </p>
      </div>

      <%!-- Client picker, grouped into two transport families.
           Cloud row first because that's the no-install path most
           new users want; Local row below for IDE / desktop clients
           that go through the stdio bridge. --%>
      <div class="border-b border-zinc-900 px-6 py-4">
        <p class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
          Cloud LLMs
          <span class="ml-1 normal-case tracking-normal text-zinc-600">
            — no install, URL + token
          </span>
        </p>
        <div class="mt-2 flex flex-wrap gap-1.5">
          <.client_tab
            :for={id <- remote_client_ids()}
            id={id}
            label={client_label(id)}
            selected={id == @selected_client}
          />
        </div>

        <p class="mt-5 text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
          Local / IDE clients
          <span class="ml-1 normal-case tracking-normal text-zinc-600">— uses the stdio bridge</span>
        </p>
        <div class="mt-2 flex flex-wrap gap-1.5">
          <.client_tab
            :for={id <- local_client_ids()}
            id={id}
            label={client_label(id)}
            selected={id == @selected_client}
          />
        </div>

        <p class="mt-5 text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
          Roll your own
        </p>
        <div class="mt-2 flex flex-wrap gap-1.5">
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
          <div class="px-6 py-10">
            <div class="rounded-lg border border-dashed border-zinc-800 p-8 text-center">
              <p class="text-sm text-zinc-300">Pick a client above to get started.</p>
              <p class="mt-1 text-xs text-zinc-500">
                We won't mint a key until you do — keeps the audit trail and the agents list clean.
              </p>
            </div>
          </div>
        <% @selected_client == "custom" -> %>
          <div class="space-y-5 px-6 py-5">
            <%= if @quick_secret do %>
              <.notice variant={:warning}>
                <span class="font-semibold">New key minted — it's live now.</span>
                Copy the bearer token below before you leave this page; we won't show it
                again. If you lose it, create another key.
              </.notice>

              <div class="overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
                <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
                  <p class="font-mono text-[11px] text-zinc-500">API key (bearer token)</p>
                  <.copy_button id="copy-custom-secret" target="#custom-secret">
                    Copy key
                  </.copy_button>
                </div>
                <pre
                  id="custom-secret"
                  class="overflow-x-auto p-4 font-mono text-xs leading-6 text-zinc-200"
                ><%= @quick_secret %></pre>
              </div>
            <% end %>

            <.custom_key_panel
              form={@form}
              runners={@runners}
              selected_runner_ids={@selected_runner_ids}
              selected_runner_groups={@selected_runner_groups}
            />
          </div>
        <% @config && @config.kind == :remote -> %>
          <div class="space-y-6 px-6 py-5">
            <%= if @quick_secret do %>
              <.notice variant={:warning}>
                <span class="font-semibold">New key minted — it's live now.</span>
                Copy the bearer token below before you leave this page; we won't show it
                again. If you lose it, pick the client again to mint a new one.
              </.notice>
            <% end %>

            <.remote_mcp_panel
              client_id={@selected_client}
              client_label={client_label(@selected_client)}
              rpc_url={@config.rpc_url}
              auth_header={@config.auth_header}
              steps={@config.steps}
            />

            <.scope_block
              runners={@runners}
              selected_runner_ids={@selected_runner_ids}
              selected_runner_groups={@selected_runner_groups}
            />
          </div>
        <% @config -> %>
          <div class="space-y-6 px-6 py-5">
            <%= if @quick_secret do %>
              <.notice variant={:warning}>
                <span class="font-semibold">New key minted — it's live now.</span>
                The snippet below contains it — copy the whole snippet, not just part. We
                won't show this key again after you leave the page; pick the client again to
                mint a new one.
              </.notice>
            <% end %>

            <.local_install_block />

            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-300">
                Paste this into {client_label(@selected_client)}
              </h3>
              <p class="mt-1 text-[11px] text-zinc-500 font-mono">{@config.location}</p>
              <div class="mt-2 overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
                <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
                  <p class="font-mono text-[11px] text-zinc-500">snippet (contains your API key)</p>
                  <.copy_button
                    id={"copy-#{@selected_client}"}
                    target={"#snippet-#{@selected_client}"}
                  >
                    Copy snippet
                  </.copy_button>
                </div>
                <pre
                  id={"snippet-#{@selected_client}"}
                  class="overflow-x-auto p-4 font-mono text-xs leading-6 text-zinc-200"
                ><%= @config.body %></pre>
              </div>
              <p class="mt-2 text-xs text-zinc-500">
                Restart {client_label(@selected_client)} after pasting.
                <.link href={~p"/docs/connect-an-llm"} class="text-brand-400 hover:text-brand-300">
                  Troubleshooting →
                </.link>
              </p>
            </div>

            <.auto_permit_block
              client_id={@selected_client}
              client_label={client_label(@selected_client)}
              auto_permit={Map.get(@config, :auto_permit)}
            />

            <.scope_block
              runners={@runners}
              selected_runner_ids={@selected_runner_ids}
              selected_runner_groups={@selected_runner_groups}
            />
          </div>
      <% end %>
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

  # Renders only AFTER a local client is picked. The install line is the
  # same for every local client — extracting it keeps the per-client
  # snippet focused on just the config the operator needs to paste, and
  # cloud-LLM users never see it at all.
  defp local_install_block(assigns) do
    ~H"""
    <div>
      <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-300">
        Install the bridge
        <span class="ml-1 text-[10px] font-normal normal-case tracking-normal text-zinc-500">
          one-time, per machine
        </span>
      </h3>
      <div class="mt-2 overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
        <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-3 py-2">
          <p class="font-mono text-[10px] text-zinc-500">macOS / Linux</p>
          <.copy_button
            id="copy-install-mcp"
            target="#install-mcp-cmd"
            class="px-2 py-0.5 text-[11px]"
          >
            Copy
          </.copy_button>
        </div>
        <pre
          id="install-mcp-cmd"
          class="overflow-x-auto p-3 font-mono text-xs leading-5 text-zinc-200"
        >curl -sSL https://emisar.dev/install-mcp.sh | sudo bash</pre>
      </div>
      <p class="mt-2 text-[11px] text-zinc-500">
        Inspects the bridge first?
        <.link href={~p"/docs/connect-an-llm"} class="text-brand-400 hover:text-brand-300">
          Manual install →
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
    <details class="rounded-lg border border-zinc-800 bg-zinc-950/40">
      <summary class="flex cursor-pointer items-center justify-between gap-3 px-4 py-3 text-sm text-zinc-200 hover:bg-zinc-900/40">
        <span class="font-medium">
          Skip the per-tool prompts <span class="text-zinc-500">(optional)</span>
        </span>
        <span class="text-xs text-zinc-500">click to expand</span>
      </summary>
      <div class="border-t border-zinc-900 px-4 pb-4 pt-3">
        <.auto_permit_why client_label={@client_label} />
        <p class="mt-3 text-[11px] text-zinc-500 font-mono">{@auto_permit.location}</p>
        <div class="mt-2 overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
          <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
            <p class="font-mono text-[11px] text-zinc-500">
              {@client_label}'s setting — not an emisar config
            </p>
            <.copy_button id={"copy-permit-#{@client_id}"} target={"#permit-#{@client_id}"}>
              Copy
            </.copy_button>
          </div>
          <pre
            id={"permit-#{@client_id}"}
            class="overflow-x-auto p-4 font-mono text-xs leading-6 text-zinc-200"
          ><%= @auto_permit.body %></pre>
        </div>
      </div>
    </details>
    """
  end

  defp auto_permit_block(%{auto_permit: %{pointer: _}} = assigns) do
    ~H"""
    <details class="rounded-lg border border-zinc-800 bg-zinc-950/40">
      <summary class="flex cursor-pointer items-center justify-between gap-3 px-4 py-3 text-sm text-zinc-200 hover:bg-zinc-900/40">
        <span class="font-medium">
          Skip the per-tool prompts <span class="text-zinc-500">(optional)</span>
        </span>
        <span class="text-xs text-zinc-500">click to expand</span>
      </summary>
      <div class="border-t border-zinc-900 px-4 pb-4 pt-3">
        <.auto_permit_why client_label={@client_label} />
        <p class="mt-3 text-xs text-zinc-400">{@auto_permit.pointer}</p>
        <p class="mt-2 text-[11px] text-zinc-500">
          <.link
            href={@auto_permit.doc_url}
            target="_blank"
            rel="noopener noreferrer"
            class="text-brand-400 hover:text-brand-300"
          >
            {@client_label} MCP docs →
          </.link>
        </p>
      </div>
    </details>
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

  # Scope picker block. Wrapped as a collapsible "Restrict scope"
  # section because the default ("all runners, all groups") is the right
  # one for most operators — surfacing it as an optional refinement
  # that they can ignore feels less imposing than a step the wizard
  # demands an answer to.
  attr :runners, :list, required: true
  attr :selected_runner_ids, :list, required: true
  attr :selected_runner_groups, :list, required: true

  defp scope_block(assigns) do
    assigns =
      assign(assigns,
        scoped?: assigns.selected_runner_ids != [] or assigns.selected_runner_groups != []
      )

    ~H"""
    <details
      class="rounded-lg border border-zinc-800 bg-zinc-950/40"
      {if(@scoped?, do: %{open: ""}, else: %{})}
    >
      <summary class="flex cursor-pointer items-center justify-between gap-3 px-4 py-3 text-sm text-zinc-200 hover:bg-zinc-900/40">
        <div>
          <span class="font-medium">Restrict scope</span>
          <span class="ml-2 text-[11px] text-zinc-500">
            <%= if @scoped? do %>
              {scope_summary(@selected_runner_ids, @selected_runner_groups)}
            <% else %>
              defaults to all runners + all groups
            <% end %>
          </span>
        </div>
        <span class="text-xs text-zinc-500">click to {if @scoped?, do: "edit", else: "narrow"}</span>
      </summary>
      <div class="border-t border-zinc-900 px-4 pb-4 pt-3">
        <p class="text-xs text-zinc-500">
          Tick groups or specific runners to scope the next key mint. Re-picking your
          client re-mints with the current scope.
        </p>
        <div class="mt-3">
          <.scope_picker
            runners={@runners}
            selected_runner_ids={@selected_runner_ids}
            selected_runner_groups={@selected_runner_groups}
          />
        </div>
      </div>
    </details>
    """
  end

  attr :client_id, :string, required: true
  attr :client_label, :string, required: true
  attr :rpc_url, :string, required: true
  attr :auth_header, :string, required: true
  attr :steps, :list, required: true

  defp remote_mcp_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- The two values cloud LLMs need. Bearer header is rendered
           in full (operator just minted it) so they can copy the whole
           "Authorization: Bearer emk-..." string verbatim. --%>
      <div class="overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
        <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
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

      <%!-- Per-host step list. Each client config above stores its own
           list because the menu paths differ (Claude.ai uses "Custom
           connectors", ChatGPT uses "Connectors" under different
           settings). --%>
      <div class="rounded-lg border border-zinc-800 bg-zinc-950/40 p-4">
        <p class="text-xs font-semibold uppercase tracking-wider text-zinc-300">
          Steps for {@client_label}
        </p>
        <ol class="mt-2 list-decimal space-y-1 pl-5 text-xs text-zinc-300">
          <li :for={step <- @steps}>{step}</li>
        </ol>
      </div>

      <p class="text-xs text-zinc-500">
        Cloud LLM connectors need {@client_label} to be on a plan that
        supports custom MCP servers. Connection refused or 401?
        <.link href={~p"/docs/connect-an-llm"} class="text-brand-400 hover:text-brand-300">
          Troubleshooting →
        </.link>
      </p>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :runners, :list, required: true
  attr :selected_runner_ids, :list, required: true
  attr :selected_runner_groups, :list, required: true

  defp custom_key_panel(assigns) do
    ~H"""
    <div>
      <p class="text-xs text-zinc-500">
        Mints an MCP key with the standard <code class="font-mono text-zinc-300">actions:read</code>
        + <code class="font-mono text-zinc-300">actions:execute</code>
        scopes — the same shape the per-client tabs above use. The form below adds a
        name, description, and expiry on top of the shared scope picker.
      </p>
      <%!-- The scope picker narrows *runners*, not actions. Make the
           action reach explicit so the operator knows what they're granting. --%>
      <p class="mt-2 rounded-lg bg-amber-500/10 px-3 py-2 text-xs text-amber-200/90 ring-1 ring-amber-500/20">
        This key can read and execute every action your trusted packs expose on the selected
        runners; risky actions still require policy approval.
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

        <%!-- Runner / group restrictions read from the shared scope
             picker above the tab strip — propagate the current
             selection through the form so the Create button mints a
             key with the same scope a quick-mint would have. --%>
        <input
          :for={id <- @selected_runner_ids}
          type="hidden"
          name="api_key[runner_filter][]"
          value={id}
        />
        <input
          :for={group <- @selected_runner_groups}
          type="hidden"
          name="api_key[runner_group_filter][]"
          value={group}
        />

        <:actions>
          <.button phx-disable-with="Creating...">Create key</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  attr :runners, :list, required: true
  attr :selected_runner_ids, :list, required: true
  attr :selected_runner_groups, :list, required: true

  # Shared scope picker, rendered as the wizard's Step 2 body (always
  # visible, not collapsed). Applies to BOTH the quick-mint tabs and
  # the Custom-tab form. Defaults to "all runners / all groups";
  # ticking restricts the next mint. Posts `update_scope` on every
  # change so the selection state survives tab clicks; the actual
  # mint reads `selected_runner_ids` + `selected_runner_groups` from
  # the LV socket assigns at click time.
  defp scope_picker(assigns) do
    groups =
      assigns.runners
      |> Enum.map(& &1.group)
      |> Enum.uniq()
      |> Enum.sort()

    has_restrictions? =
      assigns.selected_runner_ids != [] or assigns.selected_runner_groups != []

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:has_restrictions?, has_restrictions?)

    ~H"""
    <div class="border-b border-zinc-900 bg-zinc-950/40">
      <form phx-change="update_scope" class="space-y-4 px-6 py-4">
        <%!-- Allowed groups — picked first because they scale better
             than per-runner ticks. Skipped when every runner is in
             the same default group. --%>
        <fieldset :if={length(@groups) > 1}>
          <legend class="text-sm font-medium text-zinc-200">Allowed runner groups</legend>
          <p class="mt-1 text-xs text-zinc-500">
            Tick groups this key may target. Auto-includes runners later added to the same group.
          </p>
          <div class="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
            <.checkbox
              :for={group <- @groups}
              class="flex items-center gap-2.5 rounded border border-zinc-800 bg-zinc-950/40 px-2 py-1.5 text-sm text-zinc-300 hover:border-brand-500/40"
              name="runner_group_filter[]"
              value={group}
              checked={group in @selected_runner_groups}
            >
              <span class="truncate">{group}</span>
            </.checkbox>
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
              <.checkbox
                :for={runner <- @runners}
                class="flex items-center gap-2.5 rounded px-1.5 py-1 text-sm text-zinc-300 hover:bg-zinc-900/60"
                name="runner_filter[]"
                value={runner.id}
                checked={runner.id in @selected_runner_ids}
              >
                <span class="flex-1 truncate">{runner.name}</span>
                <span class="text-xs text-zinc-500">{runner.group}</span>
              </.checkbox>
            </div>
          <% end %>
        </fieldset>

        <p :if={@has_restrictions?} class="text-[11px] text-zinc-500">
          Changing the scope <em>after</em> minting doesn't update the key —
          re-click your client tab in Step 3 to mint a fresh one with the new
          scope.
        </p>
      </form>
    </div>
    """
  end
end
