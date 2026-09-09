defmodule EmisarWeb.AgentsLive do
  @moduledoc """
  "Agents" — the operator-facing view of API keys.

  Each API key represents one LLM client (Claude Code, Cursor, etc.)
  that can call the MCP tools API. The page mirrors the Runners page in
  layout: a status grid at top, a list of "connections" with live
  status badges, and a persistent "connect a new client" guide so the
  copy-paste config snippets are always one click away — not buried
  behind a "Generate key" button.

  `ApiKeys.key_facts/2` classifies each key's activity, liveness, expiry
  and rotation state; this page composes the emisar-mcp bridge's version
  status onto it (`ApiKeys.with_bridge_compatibility/2`) and renders the
  result — words, colors and countdowns only.

  Every #{15} s a self-scheduled `:tick` polls only the visible keys' ids and
  `last_used_at`, then recomputes time-based facts in memory. Key lifecycle
  PubSub events still reload the full page, so membership, pagination, owner,
  and rotation changes reflow immediately without doing that work per tick.
  The tick is the SLOW fallback, not how this page stays live: a key's first
  use broadcasts, and `last_used_at` is itself only re-stamped once a minute,
  so a faster poll could not observe anything sooner than the countdowns it
  renders change.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys, Compat}
  alias EmisarWeb.{AgentClientConfig, ConfirmDialog, LiveForm, LiveTable}
  alias EmisarWeb.{Permissions, URLHelpers, UserAgent}
  alias Phoenix.LiveView.JS

  @refresh_ms 15_000
  @connection_timeout_ms 120_000
  @remote_client_ids ~w(chatgpt claude_web)
  @platforms %{"linux" => :linux, "windows" => :windows, "macos" => :macos}
  @platform_tabs [
    %{os: :linux, label: "Linux"},
    %{os: :windows, label: "Windows"},
    %{os: :macos, label: "macOS"}
  ]
  # `@client_ids` ordering drives the tab strip in `connect_panel/1`. Within
  # each group the order is POPULARITY, not the alphabet — an operator scans
  # for their own client, and the common ones should be the first few tabs, not
  # wherever their name happens to sort. Map iteration order isn't guaranteed —
  # keep ids as a list and pair labels separately.
  #
  # `"custom"` is the trailing pseudo-client: picking it doesn't mint a
  # quick key + snippet, it surfaces a key-builder form instead. Keeps
  # the "I need a tighter scope" affordance discoverable next to the
  # client tabs, not hidden in a collapsed details further down.
  @client_ids ~w(chatgpt claude_web claude_code cursor vscode claude_desktop codex gemini copilot windsurf zed opencode goose grok openclaw pi hermes coop custom)
  @sandbox_guide_ids ~w(docker_sandboxes nono dev_containers)
  @sandbox_ids ["coop" | @sandbox_guide_ids]

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
    # disclosure is opened. co:op shows its configuration on selection.
    # Cloud clients use OAuth, so their backing key is
    # minted only after the user consents in the OAuth flow.
    {:ok,
     socket
     |> assign(:page_title, "AI agents")
     |> assign(:quick_secret, nil)
     # The snippet/custom paths watch their just-minted key for its first
     # call; the installer path (key ids minted at grant approval, unknown
     # here) watches for ANY key minted after this page opened connecting.
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)
     |> assign(:connection_wait, nil)
     |> assign(:connection_delayed?, false)
     |> assign(:watch_since, DateTime.utc_now())
     |> assign(:snippet_open?, false)
     |> assign(:bridge_paths, AgentClientConfig.default_paths())
     |> assign(:selected_client, nil)
     |> assign(:selected_sandbox, nil)
     |> assign(:base_url, URLHelpers.derive_base_url(socket))
     # Which install command to open on. `get_connect_info/2` is nil on the
     # dead render, which lands on the Linux default and corrects itself the
     # moment the socket connects — the block it feeds only renders after the
     # operator has picked a client, i.e. over that live socket.
     |> assign(:detected_os, UserAgent.platform(get_connect_info(socket, :user_agent)))
     |> ConfirmDialog.init()
     |> assign(:pending_key_action, nil)
     |> assign(:rotated, nil)
     |> assign_form(ApiKeys.change_key(default_params()))}
  end

  # IL-18: `handle_params` runs on the dead render too, and the list renders
  # `<.loading_state />` there — so the paginated key read (list + count) plus
  # the per-row fact projection were paid for and thrown away on the first
  # paint, then paid for again on connect. Same shape as runs / runners / audit.
  #
  # The filter bar IS part of that first paint, so its owner options are still
  # resolved: a deep-linked `?owner=…` has to name the member, not blank out.
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      {:noreply, load(socket, params)}
    else
      {:noreply, prepare_disconnected(socket, params)}
    end
  end

  defp prepare_disconnected(socket, params) do
    socket
    |> assign(:key_rows, [])
    |> assign(:member_key_expirations, %{})
    |> assign(:member_keys_usable, %{})
    |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
    |> assign(:filter_params, params)
    |> assign(:filters, with_owner_options(socket.assigns.current_subject, params))
    |> assign(:active_count, 0)
    |> assign(:idle_count, 0)
    |> assign(:dormant_count, 0)
    |> assign(:never_used_count, 0)
    |> assign(:issued_count, 0)
    # An unread list is not an empty account: the onboarding panel waits for
    # the socket rather than flashing at an account full of agents.
    |> assign(:show_connect_inline?, false)
    |> assign(:load_error?, false)
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/agents",
       params,
       socket.assigns.filters
     )}
  end

  # -- Events ----------------------------------------------------------

  def handle_event("select_client", %{"client" => "custom"}, socket) do
    # The custom tab swaps the snippet for a key-builder form — no quick mint,
    # the operator fills in the form and submits. Same ISSUE tier as the quick
    # flows beside it: a custom key is the same `:mcp` credential with an
    # operator-set name and expiry, bounded by the same membership scope.
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket ->
        {:noreply,
         socket
         |> assign(:selected_client, "custom")
         |> assign(:selected_sandbox, nil)
         |> assign(:quick_secret, nil)
         |> assign(:quick_key_id, nil)
         |> assign(:quick_connected?, false)
         |> clear_connection_wait()}
      end
    )
  end

  def handle_event("select_client", %{"client" => id}, socket) when id in @remote_client_ids do
    {:noreply,
     socket
     |> assign(:selected_client, id)
     |> assign(:selected_sandbox, nil)
     |> assign(:quick_secret, nil)
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)
     |> clear_connection_wait()}
  end

  def handle_event("select_client", %{"client" => "coop"}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket ->
        if socket.assigns.selected_client == "coop" and is_binary(socket.assigns.quick_secret) do
          {:noreply, socket}
        else
          socket
          |> assign(:selected_client, "coop")
          |> assign(:selected_sandbox, nil)
          |> assign(:quick_secret, nil)
          |> assign(:quick_key_id, nil)
          |> assign(:quick_connected?, false)
          |> assign(:snippet_open?, false)
          |> clear_connection_wait()
          |> mint_snippet_key()
        end
      end
    )
  end

  def handle_event("select_sandbox", %{"client" => id}, socket)
      when id in @sandbox_guide_ids do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket ->
        if socket.assigns.selected_sandbox == id and is_binary(socket.assigns.quick_secret) do
          {:noreply, socket}
        else
          socket
          |> assign(:selected_client, nil)
          |> assign(:selected_sandbox, id)
          |> assign(:quick_secret, nil)
          |> assign(:quick_key_id, nil)
          |> assign(:quick_connected?, false)
          |> assign(:snippet_open?, false)
          |> clear_connection_wait()
          |> mint_snippet_key()
        end
      end
    )
  end

  def handle_event("select_sandbox", _params, socket), do: {:noreply, socket}

  def handle_event("select_client", %{"client" => id}, socket) when id in @client_ids do
    # Picking a local client mints NOTHING — the installer's device-grant
    # approval mints the keys, and the manual snippet mints its own lazily on
    # reveal. Switching clients resets the lazy snippet state.
    {:noreply,
     socket
     |> assign(:selected_client, id)
     |> assign(:selected_sandbox, nil)
     |> assign(:quick_secret, nil)
     |> assign(:quick_key_id, nil)
     |> assign(:quick_connected?, false)
     |> assign(:snippet_open?, false)
     |> start_connection_wait()}
  end

  # A crafted event that drops a required key or names a client the picker
  # never rendered would otherwise match no clause (or crash `client_config/5`
  # in render) and take the page's unsaved state with it. Every mutating
  # handler on this page ends in this no-op.
  def handle_event("select_client", _params, socket), do: {:noreply, socket}

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

  def handle_event("select_os", %{"os" => os}, socket) when is_map_key(@platforms, os) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket -> {:noreply, assign(socket, :detected_os, @platforms[os])} end
    )
  end

  def handle_event("select_os", _params, socket), do: {:noreply, socket}

  def handle_event("select_upgrade_os", %{"os" => os}, socket) when is_map_key(@platforms, os) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_view_api_keys?(socket.assigns.current_subject),
      fn socket -> {:noreply, assign(socket, :detected_os, @platforms[os])} end
    )
  end

  def handle_event("select_upgrade_os", _params, socket), do: {:noreply, socket}

  def handle_event("bridge_path_changed", %{"os" => os, "path" => path}, socket)
      when is_map_key(@platforms, os) and is_binary(path) and byte_size(path) <= 4096 do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      fn socket ->
        paths = Map.put(socket.assigns.bridge_paths, @platforms[os], path)
        {:noreply, assign(socket, :bridge_paths, paths)}
      end
    )
  end

  def handle_event("bridge_path_changed", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"api_key" => params} = event, socket) do
    changeset = ApiKeys.change_key(params) |> LiveForm.on_change(event)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("create", %{"api_key" => params}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_issue_quick_key?(socket.assigns.current_subject),
      &do_create(&1, params)
    )
  end

  def handle_event("create", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("dismiss_rotated", _params, socket),
    do: {:noreply, assign(socket, :rotated, nil)}

  def handle_event("open_key_action", %{"action" => action, "id" => id}, socket)
      when action in ["rotate", "rotate_manual", "revoke"] do
    with_manageable_key(socket, id, fn socket, key ->
      facts = row_facts(key, DateTime.utc_now())

      if key_action_available?(action, facts) do
        pending = %{
          action: action,
          facts: facts,
          key: key,
          nonce: System.unique_integer([:positive])
        }

        {:noreply, assign(socket, :pending_key_action, pending)}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("open_key_action", _params, socket), do: {:noreply, socket}

  def handle_event("revoke", %{"id" => id}, socket),
    do: with_manageable_key(socket, id, &do_revoke/2)

  def handle_event("revoke", _params, socket), do: {:noreply, socket}

  def handle_event("revoke_member_keys", %{"membership-id" => membership_id}, socket) do
    # IL-15: the domain call re-checks permission; a scope reduced in another
    # tab comes back {:error, :unauthorized} and lands in the flash below.
    case ApiKeys.revoke_all_api_keys_for_member(membership_id, socket.assigns.current_subject) do
      {:ok, 0} ->
        {:noreply, socket |> put_flash(:info, "No usable keys to revoke.") |> reload()}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Revoked #{count} #{if count == 1, do: "key", else: "keys"}.")
         |> reload()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't revoke this member's keys. Refresh the page and try again."
         )}
    end
  end

  def handle_event("revoke_member_keys", _params, socket), do: {:noreply, socket}

  def handle_event("rotate", %{"id" => id}, socket),
    do: with_manageable_key(socket, id, &do_rotate/2)

  def handle_event("rotate", _params, socket), do: {:noreply, socket}

  def handle_event("rotate_manual", %{"id" => id}, socket),
    do: with_manageable_key(socket, id, &do_manual_rotate/2)

  def handle_event("rotate_manual", _params, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, refresh_key_activity(socket)}
  end

  def handle_info({:agent_connection_timeout, attempt}, socket) do
    case socket.assigns.connection_wait do
      {^attempt, _timer} ->
        {:noreply,
         socket
         |> clear_connection_wait()
         |> assign(:connection_delayed?, not socket.assigns.quick_connected?)}

      _stale_attempt ->
        {:noreply, socket}
    end
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

  # One timer per setup attempt. A cancelled timer may already have queued its
  # message, so the attempt reference also guards client/key switches.
  defp start_connection_wait(socket) do
    socket = clear_connection_wait(socket)
    attempt = make_ref()

    timer =
      Process.send_after(self(), {:agent_connection_timeout, attempt}, @connection_timeout_ms)

    assign(socket, :connection_wait, {attempt, timer})
  end

  defp clear_connection_wait(socket) do
    if socket.assigns.connection_wait do
      {_attempt, timer} = socket.assigns.connection_wait
      Process.cancel_timer(timer)
    end

    socket
    |> assign(:connection_wait, nil)
    |> assign(:connection_delayed?, false)
  end

  defp assign_quick_connection(socket, rows) do
    socket = assign(socket, :quick_connected?, quick_key_connected?(socket, rows))

    if socket.assigns.quick_connected?, do: clear_connection_wait(socket), else: socket
  end

  # Shared by sandbox selection and manual-snippet reveal. The key is named
  # after the selected setup so it remains recognizable in the agents list and
  # audit rows.
  defp mint_snippet_key(socket) do
    selected = socket.assigns.selected_sandbox || socket.assigns.selected_client
    name = client_label(selected)

    case ApiKeys.mint_quick_key(socket.assigns.current_subject, name: name) do
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign(:quick_key_id, key.id)
         |> assign(:quick_connected?, false)
         |> start_connection_wait()
         |> reload()}

      {:error, _reason}
      when socket.assigns.selected_client == "coop" or
             socket.assigns.selected_sandbox in @sandbox_guide_ids ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:snippet_open?, false)
         |> put_flash(:error, "Couldn't create the key. Open manual setup to try again.")}
    end
  end

  defp do_create(socket, params) do
    # A Custom key is a plain `:mcp` key — identity + expiry only. It carries no
    # per-key scope: account Policy + the operator's own runner scope decide
    # what it may do, same as a quick-mint. ApiKeys owns how the posted fields
    # are read, so the form and the mint can't drift.
    case ApiKeys.create_key(params, socket.assigns.current_subject) do
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> assign(:quick_secret, raw)
         |> assign(:quick_key_id, key.id)
         |> assign(:quick_connected?, false)
         |> start_connection_wait()
         |> assign_form(ApiKeys.change_key(default_params()))
         |> reload()}

      # Field errors (required name, length, or a DB constraint) render inline
      # on the form via <.input>/<.error> — no flash dump.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      # The form mints `:mcp`, but `create_key/2` picks its permission from the
      # posted kind — a crafted `audit_export` post from this page is refused
      # there, and lands here rather than crashing the socket.
      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't create the key. Refresh the page and try again.")}
    end
  end

  # Managing a key is a PER-KEY question now — you always manage what you minted
  # — so the event backstop asks it about the key the click names, not about the
  # account. Reading it first also stops an id this account can't see from
  # reaching the domain: `fetch_api_key_by_id/2` is account-scoped, and a miss
  # stays silent rather than confirming the key exists somewhere.
  defp with_manageable_key(socket, id, fun) do
    subject = socket.assigns.current_subject

    case ApiKeys.fetch_api_key_by_id(id, subject) do
      {:ok, key} ->
        Permissions.gated(
          socket,
          ApiKeys.subject_can_manage_api_key?(key, subject),
          &fun.(&1, key)
        )

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp do_revoke(socket, key) do
    # `{:ok, _} =` here crashed the socket for an operator whose role was
    # reduced in another tab: revoke_api_key returns {:error, :unauthorized},
    # the page blanked to "Reconnecting", remounted, and the key was still
    # live with nothing said.
    case ApiKeys.revoke_api_key(key, socket.assigns.current_subject) do
      {:ok, _revoked} ->
        {:noreply,
         socket
         |> assign(:pending_key_action, nil)
         |> put_flash(:info, "API key revoked.")
         |> reload()}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:pending_key_action, nil)
         |> put_flash(:error, "Couldn't revoke the key. Refresh the page and try again.")}
    end
  end

  defp do_rotate(socket, key) do
    case ApiKeys.request_api_key_rotation(key, socket.assigns.current_subject) do
      {:ok, _requested} ->
        {:noreply,
         socket
         |> assign(:pending_key_action, nil)
         |> put_flash(
           :info,
           "Rotation requested. The agent will update its key on its next call."
         )
         |> reload()}

      {:error, :manual_required} ->
        do_manual_rotate(socket, key)

      {:error, reason} ->
        rotation_error(socket, reason)
    end
  end

  defp do_manual_rotate(socket, key) do
    case ApiKeys.rotate_api_key(key, socket.assigns.current_subject) do
      # The successor's one-time secret shows in a compact reveal banner right
      # here on the index — never by dumping the whole connect panel + custom
      # key form onto the list page. No flash: the banner IS the confirmation,
      # and it stays until dismissed (a flash would auto-close over the only
      # copy of the secret's instructions).
      {:ok, raw, _new_key} ->
        {:noreply,
         socket
         |> assign(:pending_key_action, nil)
         |> assign(:rotated, %{name: key.name, secret: raw})
         |> reload()}

      {:error, reason} ->
        rotation_error(socket, reason)
    end
  end

  defp rotation_error(socket, :already_rotated) do
    {:noreply,
     socket
     |> assign(:pending_key_action, nil)
     |> put_flash(
       :info,
       "Rotation has already started. Waiting for the agent to use its new key."
     )
     |> reload()}
  end

  defp rotation_error(socket, _reason) do
    {:noreply,
     socket
     |> assign(:pending_key_action, nil)
     |> put_flash(:error, "Couldn't rotate the key. Refresh the page and try again.")}
  end

  defp key_action_available?(action, facts) when action in ["rotate", "rotate_manual"],
    do: facts.rotatable?

  defp key_action_available?("revoke", facts), do: not facts.revoked?

  # Structural refresh-in-place (PubSub / mutation): re-runs with current URL
  # params so the operator doesn't jump back to page 1 after a lifecycle change.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  # A tick changes only activity timestamps and facts derived from `now`.
  # Lifecycle broadcasts own structural reloads, so owner options, pagination,
  # the total count, creator joins, and rotation preloads stay untouched here.
  defp refresh_key_activity(socket) do
    ids = Enum.map(socket.assigns.key_rows, fn {key, _facts} -> key.id end)

    usage_by_id =
      case ApiKeys.list_key_usage_timestamps(ids, socket.assigns.current_subject) do
        {:ok, usage} -> Map.new(usage)
        {:error, _reason} -> %{}
      end

    now = DateTime.utc_now()

    rows =
      Enum.map(socket.assigns.key_rows, fn {key, _facts} ->
        key = %{key | last_used_at: Map.get(usage_by_id, key.id, key.last_used_at)}
        {key, row_facts(key, now)}
      end)

    summary = ApiKeys.summarize_key_facts(Enum.map(rows, fn {_key, facts} -> facts end))

    socket
    |> assign(:key_rows, rows)
    |> assign_member_key_availability(now)
    |> assign(:active_count, summary.activity.active)
    |> assign(:idle_count, summary.activity.idle)
    |> assign(:dormant_count, summary.activity.dormant)
    |> assign(:never_used_count, summary.activity.never_used)
    |> assign(:issued_count, summary.live)
    |> assign_quick_connection(rows)
    |> assign_connect_inline()
  end

  # The connect panel embeds INLINE only while connecting IS the page's job:
  # a fleet with no live agent keys (onboarding — the runners-wizard pattern),
  # an operator already working through a selected client, or a one-time secret
  # on screen (a quick mint / rotation reveal must not vanish when the reload
  # lands). Otherwise the flow lives on its own /connect page behind the title
  # CTA.
  defp assign_connect_inline(socket) do
    # Paginator count is the FILTERED total. It proves onboarding only when
    # the default (live agents) view itself is empty; a search miss or an
    # explicit revoked/all view says nothing about the account's real state.
    account_empty? =
      socket.assigns.metadata.count == 0 and
        not LiveTable.has_active_filters?(socket.assigns.filter_params, socket.assigns.filters)

    inline? =
      account_empty? or socket.assigns.selected_client != nil or
        socket.assigns.quick_secret != nil

    assign(socket, :show_connect_inline?, inline?)
  end

  # Derives the connect flow's waiting→connected flip from the loaded keys —
  # sticky once true. Two watch modes: the snippet/custom paths watch their
  # just-minted key's id; the installer path — whose key ids are minted by the
  # device-grant approval and unknown to this page — watches for any key
  # minted AFTER this page opened making its first call (a pre-existing
  # agent's activity can never flip it; scoped-advance discipline).
  defp quick_key_connected?(%{assigns: %{quick_connected?: true}}, _rows), do: true

  defp quick_key_connected?(%{assigns: %{quick_key_id: id}}, rows) when is_binary(id),
    do: Enum.any?(rows, fn {key, facts} -> key.id == id and facts.used? end)

  defp quick_key_connected?(%{assigns: assigns}, rows) do
    local_client?(assigns.selected_client) and assigns.selected_client != "coop" and
      Enum.any?(rows, fn {key, facts} ->
        facts.used? and DateTime.compare(key.inserted_at, assigns.watch_since) == :gt
      end)
  end

  # Fill the static Owner filter's options with the account's real key creators
  # (the filter's SQL still comes from the Query module's `fun`).
  defp with_owner_options(subject, params) do
    owners =
      case ApiKeys.list_key_owner_options(subject) do
        {:ok, options} -> options
        _ -> []
      end

    # Profile can link to your own agents before you have any. Keep that selected
    # owner readable without offering every member as an empty filter option.
    owners =
      if subject.actor.id in List.wrap(params["owner"]) do
        List.keystore(
          owners,
          subject.actor.id,
          0,
          {subject.actor.id, subject.actor.email || "You"}
        )
      else
        owners
      end

    Enum.map(ApiKeys.api_key_filters(), fn
      %{name: :owner} = filter -> %{filter | values: owners}
      filter -> filter
    end)
  end

  defp load(socket, params) do
    # The status filter defaults to "live" (declared on the filter itself, so
    # LiveTable applies it AND renders it un-highlighted) — no need to inject it
    # into the params here.
    filters = with_owner_options(socket.assigns.current_subject, params)
    opts = LiveTable.params_to_opts(params, filters)

    case ApiKeys.list_api_keys_for_account(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:created_by, :replaces])
         ) do
      {:ok, keys, meta} ->
        # One `now` for the whole page, so every row's activity, expiry and
        # rotation state is judged against the same instant.
        now = DateTime.utc_now()
        rows = Enum.map(keys, &{&1, row_facts(&1, now)})
        summary = ApiKeys.summarize_key_facts(Enum.map(rows, fn {_key, facts} -> facts end))

        socket
        |> assign(:key_rows, rows)
        |> load_member_key_expirations(keys, now)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:active_count, summary.activity.active)
        |> assign(:idle_count, summary.activity.idle)
        |> assign(:dormant_count, summary.activity.dormant)
        |> assign(:never_used_count, summary.activity.never_used)
        |> assign(:issued_count, summary.live)
        |> assign_quick_connection(rows)
        |> assign_connect_inline()
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — flag it
      # so the list says "couldn't load" instead of a silent empty list (which
      # would read "no keys" when really the read failed).
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:key_rows, [])
        |> assign(:member_key_expirations, %{})
        |> assign(:member_keys_usable, %{})
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

  defp load_member_key_expirations(socket, keys, now) do
    ids = Enum.map(keys, & &1.created_by_membership_id)

    expirations =
      case ApiKeys.list_member_key_expirations(ids, socket.assigns.current_subject) do
        {:ok, expirations} -> expirations
        {:error, _reason} -> nil
      end

    socket
    |> assign(:member_key_expirations, expirations)
    |> assign_member_key_availability(now)
  end

  defp assign_member_key_availability(socket, now) do
    availability =
      case socket.assigns.member_key_expirations do
        nil ->
          nil

        expirations ->
          Map.new(expirations, fn {id, expiry} ->
            {id, ApiKeys.member_keys_usable?(expiry, now)}
          end)
      end

    assign(socket, :member_keys_usable, availability)
  end

  defp member_keys_disabled_reason(nil, _membership_id),
    do: "Couldn't check keys. Refresh the page and try again."

  defp member_keys_disabled_reason(availability, membership_id) do
    if availability[membership_id], do: nil, else: "No active agent keys to revoke."
  end

  # A row pairs the key with the domain's reading of it, plus this control
  # plane's bridge-version policy — the one place the two are composed.
  defp row_facts(key, now) do
    facts = ApiKeys.key_facts(key, now)
    ApiKeys.with_bridge_compatibility(facts, Compat.mcp_status(facts.bridge_version))
  end

  defp open_key_action_dialog(%{action: "revoke", facts: %{expiry: expiry}})
       when expiry != :expired,
       do: show_confirm_dialog("agent-key-action")

  defp open_key_action_dialog(_pending), do: open_confirm("agent-key-action")

  defp pending_key_confirm_token(%{action: "revoke", facts: %{expiry: expiry}, key: key})
       when expiry != :expired,
       do: key.name

  defp pending_key_confirm_token(_pending), do: nil

  defp confirm_key_action(%{action: action, key: key})
       when action in ["rotate", "rotate_manual"] do
    JS.push(action, value: %{id: key.id}) |> close_confirm("agent-key-action")
  end

  defp confirm_key_action(%{facts: %{expiry: :expired}, key: key}) do
    JS.push("revoke", value: %{id: key.id}) |> close_confirm("agent-key-action")
  end

  defp confirm_key_action(%{key: key}) do
    JS.push("revoke", value: %{id: key.id}) |> hide_confirm_dialog("agent-key-action")
  end

  # The issuing human — the grouping key for the list, carrying the membership
  # id so the header's bulk revoke can act on the group. Falls back to "Auto"
  # for system-minted keys with no creator.
  defp owner_group({%{created_by: %{} = user} = key, _facts}),
    do: {Accounts.user_display_name(user), key.created_by_membership_id}

  defp owner_group({_key, _facts}), do: {"Auto-minted", nil}

  # Pre-sort by owner so each `group_by={&owner_group/1}` cluster is one
  # contiguous run under a single header; within a cluster the context's
  # recent-first order holds.
  defp sort_by_owner(rows), do: Enum.sort_by(rows, &elem(owner_group(&1), 0))

  defp default_params do
    %{"name" => "", "description" => "", "expires_at" => ""}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "api_key"))

  # Past expiry reads rose (the key is dead); inside the rotation window, amber
  # (rotate soon); otherwise muted like the rest of the meta line.
  defp expiry_class(:expired), do: "text-rose-400"
  defp expiry_class(:expiring_soon), do: "text-amber-400"
  defp expiry_class(_expiry), do: "text-zinc-400"

  # The upgrade notice speaks for the bridges an operator can still reach —
  # a dead key's stale bridge is not something anyone needs to go fix.
  defp usable_mcp_bridge_versions(rows) do
    for {_key, facts} <- rows, facts.usable?, do: facts.bridge_version
  end

  defp status_label(:active), do: "Active"
  defp status_label(:idle), do: "Idle"
  defp status_label(:dormant), do: "Dormant"
  defp status_label(:never_used), do: "Never used"
  defp status_label(:revoked), do: "Revoked"
  defp status_label(:unsupported), do: "Unsupported"

  # -- Client configs --------------------------------------------------
  #
  # Single source of truth for the "Connect a client" panel. Each entry
  # describes one MCP client: label, where its config lives, and a
  # body templated with this operator's URL + key.

  @client_labels %{
    "chatgpt" => "ChatGPT",
    "claude_web" => "Claude.ai",
    "claude_code" => "Claude Code",
    "cursor" => "Cursor",
    "vscode" => "VS Code",
    "claude_desktop" => "Claude Desktop",
    "codex" => "Codex CLI",
    "gemini" => "Gemini CLI",
    "copilot" => "Copilot CLI",
    "windsurf" => "Windsurf",
    "zed" => "Zed",
    "opencode" => "OpenCode",
    "goose" => "Goose",
    "grok" => "Grok CLI",
    "openclaw" => "OpenClaw",
    "pi" => "Pi",
    "hermes" => "Hermes",
    "coop" => "co:op",
    "docker_sandboxes" => "Docker Sandboxes",
    "nono" => "nono",
    "dev_containers" => "Dev Containers",
    "custom" => "Custom"
  }

  # Kind partition of the local picker — a scanning aid now that it holds 15
  # tabs. Membership only: the render order still comes from `@client_ids`
  # (popularity), and a client in neither set lands under CLI agents, which is
  # where almost every new MCP client belongs.
  @editor_client_ids ~w(cursor vscode claude_desktop windsurf zed)

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

  # Public: this list IS the "N local clients" claim in the home-page MCP FAQ,
  # and `marketing_test.exs` asserts the sentence against it — so adding a client
  # tab fails that test until the copy moves with it.
  def local_client_ids,
    do: Enum.reject(@client_ids, &(remote_client?(&1) or &1 in ["custom", "coop"]))

  defp cli_agent_ids, do: Enum.reject(local_client_ids(), &(&1 in @editor_client_ids))
  defp editor_client_ids, do: Enum.filter(local_client_ids(), &(&1 in @editor_client_ids))

  defp sandbox_ids, do: @sandbox_ids

  defp sandbox_guide("docker_sandboxes") do
    %{
      title: "Docker Sandboxes",
      path: ~p"/docs/connect-docker-sandboxes",
      summary:
        "Run Codex in an isolated Docker microVM and connect it through Docker's host-side MCP gateway."
    }
  end

  defp sandbox_guide("nono") do
    %{
      title: "nono",
      path: ~p"/docs/connect-nono",
      summary:
        "Run Codex with its file, environment, command, and network access constrained by a nono profile."
    }
  end

  defp sandbox_guide("dev_containers") do
    %{
      title: "Dev Containers",
      path: ~p"/docs/connect-dev-containers",
      summary: "Run Codex and the emisar bridge inside your development container."
    }
  end

  defp sandbox_guide(_id), do: nil

  defp config_target_is_file?(%{location: location}), do: not is_nil(location)

  defp client_config(client, url, key, os, path) do
    if remote_client?(client),
      do: client_config(client, url, key),
      else: AgentClientConfig.render(client, url, key, os, path)
  end

  defp client_config("claude_web", url, _key) do
    %{
      kind: :remote,
      connector_name: "emisar",
      connector_name_label: "Connector name",
      rpc_url: "#{url}/api/mcp/rpc",
      rpc_url_label: "Remote MCP server URL",
      oauth_note: %{
        title: "Leave OAuth credentials empty",
        body:
          "OAuth Client ID and OAuth Client Secret are optional. Claude.ai discovers Emisar's OAuth metadata and registers itself."
      },
      steps: [
        "In Claude, open Customize → Connectors and choose Add custom connector.",
        "Paste the connector name and Remote MCP server URL below.",
        "Select Add, then Connect, and complete the emisar sign-in and consent screen.",
        "Start a chat, open + → Connectors, and turn on emisar. Ask which runners it can access."
      ],
      # The copy fields render inside this step (paste the values), so the guide
      # reads paste → values → next step without scrolling back up.
      form_at_step: 2,
      auto_permit: %{
        pointer:
          "After connecting, open Customize → Connectors → emisar, then set Read-only tools and Write/delete tools to Always allow.",
        doc_url: nil
      }
    }
  end

  defp client_config("chatgpt", url, _key) do
    %{
      kind: :remote,
      connector_name: "emisar",
      connector_name_label: "Name",
      rpc_url: "#{url}/api/mcp/rpc",
      rpc_url_label: "MCP Server URL",
      oauth_note: %{
        title: "Use OAuth",
        body:
          "No API key is required. ChatGPT discovers Emisar's OAuth metadata from the server URL."
      },
      steps: [
        "Open ChatGPT's Settings and select Security and login.",
        "Turn on Developer mode. If the option is missing, check your account's eligibility or ask your workspace admin about access.",
        "Open ChatGPT Plugins and click + next to the search box.",
        "Set Connection to Server URL, paste the Name and MCP Server URL below, then choose OAuth.",
        "Review the connection details, click Create, then complete the emisar sign-in and consent screen.",
        "Start a new chat and add emisar from the tools menu. Ask which runners it can access."
      ],
      # The copy fields render inside this step (paste the values), so the guide
      # reads paste → values → next step without scrolling back up.
      form_at_step: 4,
      auto_permit: %{
        pointer:
          "Open emisar → Permissions and choose Allow all actions to skip ChatGPT's per-tool prompts for this connection.",
        doc_url: "https://developers.openai.com/plugins/deploy/connect-chatgpt"
      }
    }
  end

  # -- Render ----------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:agents}
      width={:table}
    >
      <:title>
        <%!-- The connect flow is a title-row CTA (the Runners "Connect a runner" /
             audit "SIEM export" pattern) — except while the inline panel IS
             the page (onboarding / a secret reveal), where a second CTA to the
             same flow would just duplicate it. --%>
        <%= if @live_action == :connect do %>
          <.back_link navigate={~p"/app/#{@current_account}/agents"}>AI agents</.back_link>
          Connect an agent
        <% else %>
          AI agents
        <% end %>
      </:title>
      <:actions :if={
        @live_action == :index and not @show_connect_inline? and
          ApiKeys.subject_can_issue_quick_key?(@current_subject)
      }>
        <.button
          navigate={~p"/app/#{@current_account}/agents/connect"}
          size={:md}
          icon="action.add"
        >
          Connect an agent
        </.button>
      </:actions>

      <.page_intro :if={@live_action == :index}>
        Connect Claude, ChatGPT, Cursor, or another AI agent to run actions through emisar.
        Review each agent’s activity and manage its access here.
        <.doc_link href={~p"/docs/agents-and-keys"}>Agent docs</.doc_link>
      </.page_intro>

      <.page_intro :if={@live_action == :connect}>
        Connect your AI app to inspect your infrastructure and run actions through emisar.
        Choose the app below for setup instructions.
        <.doc_link href={~p"/docs/agents-and-keys"}>Setup guide</.doc_link>
      </.page_intro>

      <.empty_state
        :if={
          @live_action == :connect and
            not ApiKeys.subject_can_issue_quick_key?(@current_subject)
        }
        variant={:bare}
        icon="product.runner"
        title="You don't have permission to connect agents."
      >
        Ask an owner or admin to grant you an operator role.
      </.empty_state>

      <.connect_panel
        :if={@live_action == :connect and ApiKeys.subject_can_issue_quick_key?(@current_subject)}
        configs_for={&client_config(&1, @base_url, @quick_secret || "emk-…", &2, @bridge_paths[&2])}
        bridge_paths={@bridge_paths}
        selected_client={@selected_client}
        selected_sandbox={@selected_sandbox}
        base_url={@base_url}
        detected_os={@detected_os}
        quick_secret={@quick_secret}
        quick_key_id={@quick_key_id}
        quick_connected?={@quick_connected?}
        connection_delayed?={@connection_delayed?}
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
        icon="identity.credential"
        tone={:amber}
        title="New key ready—update your agent"
      >
        <:body>
          Copy this key into <span class="font-medium text-zinc-200">{@rotated.name}</span>'s
          connection settings. It won't be shown again. The old key works until the agent
          uses this one or the old key expires.
        </:body>
        <.code_panel
          id="rotated-key"
          label="API key"
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
           pattern): no live agents in the unfiltered view → the panel renders
           right here, no detour. A filtered miss never opens onboarding. It
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
          You don't have permission to connect agents.
          Ask an owner or admin to grant you an operator role.
        </p>
        <div :if={ApiKeys.subject_can_issue_quick_key?(@current_subject)}>
          <.connect_panel
            configs_for={
              &client_config(&1, @base_url, @quick_secret || "emk-…", &2, @bridge_paths[&2])
            }
            bridge_paths={@bridge_paths}
            selected_client={@selected_client}
            selected_sandbox={@selected_sandbox}
            base_url={@base_url}
            detected_os={@detected_os}
            quick_secret={@quick_secret}
            quick_key_id={@quick_key_id}
            quick_connected?={@quick_connected?}
            connection_delayed?={@connection_delayed?}
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
            not (@show_connect_inline? and @key_rows == [] and
                   not LiveTable.has_active_filters?(@filter_params, @filters))
        }
        class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start"
      >
        <%!-- :table leaves the agents list narrow-of-content and wide-of-page;
             pair it with a docs rail (main+aside) — the list leads, a plain-terms
             "what's an AI agent" teaches beside it. The rail is a FIXED 22rem
             track that only splits off at xl (its prose never squeezes); below
             xl it stacks full-width. --%>
        <div class="min-w-0">
          <.version_upgrade_notice
            id="mcp-upgrade"
            kind={:mcp}
            versions={usable_mcp_bridge_versions(@key_rows)}
            base_url={@base_url}
            class="mb-10"
          />
          <%!-- NAKED posture line (the runners grammar): page-level notices
               come first, then activity, then filters/data on every list page. --%>
          <%!-- Each activity word explains itself through the shared <.tooltip>
               (focusable + aria-describedby), never a raw title= on a plain span
               a keyboard/touch operator can't reach. Left-aligned bubbles: the
               line hugs the content's left edge, so a right-anchored bubble
               would grow off-page. --%>
          <div
            :if={@issued_count > 0}
            class="flex flex-wrap items-center gap-x-5 gap-y-1 pb-4 text-xs"
          >
            <.tooltip
              id="agents-active-tip"
              align={:left}
              text="called an action in the last 5 minutes"
            >
              <span class="flex items-center gap-1.5">
                <.status_dot
                  tone={if @active_count > 0, do: :brand, else: :neutral}
                  size={:sm}
                  animate={if @active_count > 0, do: :ping, else: :none}
                />
                <span class="tabular-nums text-zinc-400">{@active_count} active now</span>
              </span>
            </.tooltip>
            <.tooltip
              :if={@idle_count > 0}
              id="agents-idle-tip"
              align={:left}
              text="last call within 24 hours"
            >
              <span class="flex items-center gap-1.5">
                <.status_dot tone={:neutral} size={:sm} />
                <span class="tabular-nums text-zinc-400">{@idle_count} idle</span>
              </span>
            </.tooltip>
            <.tooltip
              :if={@dormant_count > 0}
              id="agents-dormant-tip"
              align={:left}
              text="no call for over 24 hours"
            >
              <span class="flex items-center gap-1.5">
                <.status_dot tone={:neutral} size={:sm} />
                <span class="tabular-nums text-zinc-400">{@dormant_count} dormant</span>
              </span>
            </.tooltip>
            <span :if={@never_used_count > 0} class="flex items-center gap-1.5">
              <.status_dot tone={:neutral} size={:sm} />
              <span class="tabular-nums text-zinc-400">{@never_used_count} never used</span>
            </span>
          </div>
          <LiveTable.live_table
            layout={:cards}
            id="agents"
            path={~p"/app/#{@current_account}/agents"}
            rows={sort_by_owner(@key_rows)}
            metadata={@metadata}
            filter_params={@filter_params}
            filters={@filters}
            wrapper_class="divide-y divide-zinc-800/70"
            group_by={&owner_group/1}
          >
            <%!-- The issuing human heads their run of keys ONCE (the runners
                 group-by-group grammar), so the per-row meta stops repeating
                 "owner Andrew Dryga" down the whole list. Rows are pre-sorted by
                 owner so each header opens one contiguous cluster. --%>
            <:group_header :let={{owner, membership_id}}>
              <.list_group_header label={owner}>
                <:action :if={
                  membership_id &&
                    ApiKeys.subject_can_revoke_member_keys?(membership_id, @current_subject)
                }>
                  <% disabled_reason = member_keys_disabled_reason(@member_keys_usable, membership_id) %>
                  <%!-- The stolen-laptop move: every key this member owns, one
                       act. Typed on the member's name — a live-credential kill
                       keeps the typed confirm (§5). --%>
                  <.button
                    :if={is_nil(disabled_reason)}
                    id={"revoke-member-keys-button-#{membership_id}"}
                    size={:sm}
                    variant={:secondary}
                    tone={:rose}
                    phx-click={show_confirm_dialog("revoke-member-keys-#{membership_id}")}
                  >
                    Revoke all
                  </.button>
                  <.tooltip
                    :if={disabled_reason}
                    id={"revoke-member-keys-disabled-#{membership_id}"}
                    text={disabled_reason}
                  >
                    <.button
                      id={"revoke-member-keys-button-#{membership_id}"}
                      size={:sm}
                      variant={:secondary}
                      tone={:rose}
                      disabled
                    >
                      Revoke all
                    </.button>
                  </.tooltip>
                  <.confirm_dialog
                    :if={is_nil(disabled_reason)}
                    id={"revoke-member-keys-#{membership_id}"}
                    title={"Revoke every key #{owner} owns?"}
                    confirm_label="Revoke all keys"
                    confirm_token={owner}
                    typed={@typed}
                    on_confirm={
                      JS.push("revoke_member_keys", value: %{"membership-id" => membership_id})
                      |> hide_confirm_dialog("revoke-member-keys-#{membership_id}")
                    }
                  >
                    <:body>
                      Revokes all of {owner}'s keys, including rotated replacements.
                      Their agents will lose access on their next request. This can't be undone.
                    </:body>
                  </.confirm_dialog>
                </:action>
              </.list_group_header>
            </:group_header>
            <:item :let={{key, facts}}>
              <.list_row padding="py-4" meta_wrap>
                <:title>
                  <span class="truncate font-medium text-zinc-100">{key.name}</span>
                  <%!-- The emisar-mcp bridge version this key last connected through —
                     mono + muted in the identity line so bridges are comparable at a
                     glance across agents, the same v{version} grammar the runners list
                     uses. A remote connector reports no bridge → nothing here. --%>
                  <span
                    :if={facts.bridge_version}
                    class="font-mono text-[11px] text-zinc-400"
                  >
                    v{facts.bridge_version}
                  </span>
                  <.client_status_pill status={facts.status} />
                  <%!-- Status names support; the update icon provides the remedy. --%>
                  <.version_chip
                    kind={:mcp}
                    version={facts.bridge_version}
                    id={"mcp-version-#{key.id}"}
                    base_url={@base_url}
                    detected_os={@detected_os}
                    on_os_change="select_upgrade_os"
                  />
                </:title>
                <:meta>
                  <%!-- Liveness + lifecycle only. The owner heads the group above,
                     so it's off the row; the scopes are a fixed MCP shape nobody
                     manages here, so they earn no chips. No key prefix: truncated
                     it rendered the SAME shared literal on every row. --%>
                  <%!-- wrap: the swap-pending segment explains itself through a
                     <.tooltip>, whose bubble the clamp would clip away. --%>
                  <.meta_line wrap class="text-[11px]">
                    <%!-- The client only earns a seg when it ADDS to the name —
                       a quick-mint names the key after its client, so the seg
                       would just echo the title; a custom-named key keeps it. --%>
                    <:seg :if={facts.distinct_client}>
                      client <span class="text-zinc-300">{facts.distinct_client}</span>
                    </:seg>
                    <%!-- Rotation lineage shows ONLY while the swap is unproven:
                       the replaced key keeps working until this one's first use
                       auto-revokes it, so "swap pending" is the actionable state.
                       Once settled the lineage is forensic — the audit trail keeps
                       it — not a per-row fact on every rotated key forever. --%>
                    <:seg :if={facts.rotation == :swap_pending}>
                      <.tooltip
                        id={"swap-pending-#{key.id}"}
                        align={:left}
                        text="Replaces a rotated key — the old key is revoked automatically the first time this key is used"
                      >
                        <span class="text-amber-300/90">
                          replaces <span class="font-mono">{facts.replaced_key_prefix}…</span>
                          · awaiting first use
                        </span>
                      </.tooltip>
                    </:seg>
                    <:seg>
                      last call{" "}<.local_time
                        id={"agent-key-used-#{key.id}"}
                        value={facts.last_used_at}
                        mode={:relative}
                        placeholder="never"
                      />
                    </:seg>
                    <:seg :if={facts.rotation_requested?}>
                      <span class="text-amber-300">Rotation requested — waiting for the agent</span>
                    </:seg>
                    <:seg :if={facts.successor_pending?}>
                      <span class="text-amber-300">Waiting for the new key's first use</span>
                    </:seg>
                    <:seg :if={facts.expires_at}>
                      <span class={expiry_class(facts.expiry)}>
                        {if facts.expiry == :expired, do: "expired", else: "expires"}
                        <.local_time
                          id={"agent-key-expires-#{key.id}"}
                          value={facts.expires_at}
                          mode={:relative}
                          styled_tooltip
                        />
                      </span>
                    </:seg>
                    <:seg :if={facts.oauth_backing?}>
                      <.tooltip
                        id={"agent-oauth-expiry-#{key.id}"}
                        text="This connection has no fixed key expiry. The client refreshes its OAuth tokens automatically."
                      >
                        <span>OAuth-managed expiry</span>
                      </.tooltip>
                    </:seg>
                    <:seg :if={is_nil(facts.expires_at) and not facts.oauth_backing?}>
                      No expiration date
                    </:seg>
                  </.meta_line>
                </:meta>
                <:actions>
                  <%!-- A live row you can manage — an admin's, or your own key —
                     carries four verbs, past the labeled-menu threshold (§7.47,
                     the team-roster grammar: bordered `Actions ▾` trigger, ghost
                     faces only on the menu rows). Someone else's key, and every
                     revoked row, keeps the two read paths as bordered buttons —
                     two verbs in one row, so they wear the same face the trigger
                     does rather than reading as a run-on pair of links. --%>
                  <%= if not facts.revoked? and ApiKeys.subject_can_manage_api_key?(key, @current_subject) do %>
                    <.dropdown
                      class="inline-block shrink-0 text-left"
                      summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                      panel_class="z-10 mt-2 w-48 p-1 text-xs shadow-xl"
                    >
                      <:trigger>
                        Actions
                        <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
                      </:trigger>
                      <%!-- An agent's activity is its RUNS (scoped by api_key_id); the
                         audit actor filter is empty for an api_key (terminal run events
                         are engine-attributed), so this pivots to the runs feed. Both
                         params: source picks the Dispatched-by kind, api_key_id the
                         agent — the bar lands with the pair visibly active. --%>
                      <.menu_item
                        navigate={
                          ~p"/app/#{@current_account}/runs?#{[source: "mcp", api_key_id: key.id]}"
                        }
                        icon="agent.permissions"
                      >
                        View activity
                      </.menu_item>
                      <.menu_item
                        navigate={
                          ~p"/app/#{@current_account}/audit?#{[target_kind: "api_key", target_id: key.id]}"
                        }
                        icon="product.audit"
                      >
                        View audit trail
                      </.menu_item>
                      <%!-- The support handle: a pasted id beats describing a key
                           by kind and name, and the secret is never viewable —
                           the id is the one safe identifier to share. Delegated
                           [data-copy-text] listener; the click stops at the
                           button, so the menu stays open to show "Copied". --%>
                      <.menu_item
                        icon="action.copy"
                        data-copy-text={key.id}
                        data-copy-label-copied="Copied"
                      >
                        Copy ID
                      </.menu_item>
                      <%!-- OAuth backing keys hide Rotate: a fresh emk- secret can't
                         reach the OAuth client (it holds tokens bound to the old
                         backing-key id), so rotation would only break the connection.
                         Revoke stays — it's the operator's off-switch. --%>
                      <.menu_item
                        :if={facts.rotatable? and not facts.rotation_requested?}
                        icon="action.refresh"
                        phx-click="open_key_action"
                        phx-value-action="rotate"
                        phx-value-id={key.id}
                      >
                        Rotate
                      </.menu_item>
                      <.menu_item
                        :if={facts.rotatable? and facts.rotation_requested?}
                        icon="action.refresh"
                        phx-click="open_key_action"
                        phx-value-action="rotate_manual"
                        phx-value-id={key.id}
                      >
                        Rotate manually
                      </.menu_item>
                      <div class="my-1 border-t border-zinc-800/70"></div>
                      <.menu_item
                        tone={:rose}
                        icon="state.revoked"
                        phx-click="open_key_action"
                        phx-value-action="revoke"
                        phx-value-id={key.id}
                      >
                        Revoke
                      </.menu_item>
                    </.dropdown>
                  <% else %>
                    <%!-- "What did this agent do" matters most right after a key is
                       revoked, so the read verbs stay on revoked rows too. Every
                       role that can see this page also holds view_audit. TWO verbs
                       in one row, so they wear the bordered face the manager
                       branch's `Actions ▾` trigger wears — a pair of bare links
                       reads as prose, not as this row's affordances (§7.47). --%>
                    <.button
                      navigate={
                        ~p"/app/#{@current_account}/runs?#{[source: "mcp", api_key_id: key.id]}"
                      }
                      variant={:secondary}
                      size={:sm}
                    >
                      View activity
                    </.button>
                    <.button
                      navigate={
                        ~p"/app/#{@current_account}/audit?#{[target_kind: "api_key", target_id: key.id]}"
                      }
                      variant={:secondary}
                      size={:sm}
                    >
                      Audit trail
                    </.button>
                  <% end %>
                </:actions>
              </.list_row>
            </:item>
            <:empty>
              <%= cond do %>
                <% @load_error? -> %>
                  <.empty_state
                    tone={:danger}
                    icon="state.warning"
                    title="Couldn't load your agents"
                  >
                    Refresh the page to try again. If it keeps failing, contact support.
                  </.empty_state>
                <% LiveTable.has_active_filters?(@filter_params, @filters) -> %>
                  <span class="text-zinc-400">No agents match these filters.</span>
                <% not connected?(@socket) -> %>
                  <%!-- Dead/pre-connect render: the list hasn't been read, so
                       don't claim the account has no agents. --%>
                  <.loading_state />
                <% true -> %>
                  <.empty_state icon="product.agent" title="No agents connected yet.">
                    Pick a client above. Cloud clients use OAuth; local clients get a key +
                    pre-filled snippet. The agent shows up here on its first MCP call.
                  </.empty_state>
              <% end %>
            </:empty>
          </LiveTable.live_table>

          <%!-- Render one dialog only after the chosen row has been fetched
               through the account-scoped context and re-authorized. The keyed
               mount opens it after its complete contents arrive, avoiding the
               blank first frame that the old page-level experiment produced. --%>
          <div
            :if={@pending_key_action}
            id={"agent-key-action-mount-#{@pending_key_action.nonce}"}
            phx-mounted={open_key_action_dialog(@pending_key_action)}
          >
            <.confirm_dialog
              id="agent-key-action"
              title={
                if @pending_key_action.action in ["rotate", "rotate_manual"],
                  do: "Rotate this key?",
                  else: "Revoke this agent key"
              }
              confirm_label={
                if @pending_key_action.action in ["rotate", "rotate_manual"],
                  do: "Rotate key",
                  else: "Revoke key"
              }
              confirm_token={pending_key_confirm_token(@pending_key_action)}
              typed={@typed}
              on_confirm={confirm_key_action(@pending_key_action)}
            >
              <:body>
                <%= cond do %>
                  <% @pending_key_action.action == "rotate_manual" -> %>
                    Cancels the pending automatic rotation and gives you a new key to copy into
                    the agent's settings. The current key keeps working until the new key is used
                    or the current key expires.
                  <% @pending_key_action.action == "rotate" and
                       @pending_key_action.facts.auto_rotation_supported? and
                       @pending_key_action.facts.usable? -> %>
                    The agent will update its key on its next call. If automatic rotation isn't
                    available, you'll get a new key to copy into the agent's settings.
                  <% @pending_key_action.action == "rotate" -> %>
                    You'll get a new key to copy into the agent's settings. The current key keeps
                    working until the new key is used or the current key expires.
                  <% @pending_key_action.facts.expiry == :expired -> %>
                    Permanently marks
                    <span class="font-mono font-medium text-zinc-200">
                      {@pending_key_action.key.name}
                    </span>
                    as revoked. It has already expired and cannot authenticate or run actions.
                  <% true -> %>
                    Revoking
                    <span class="font-mono font-medium text-zinc-200">
                      {@pending_key_action.key.name}
                    </span>
                    blocks the agent's next request. Reconnect the agent to restore access.
                    This can't be undone.
                <% end %>
              </:body>
            </.confirm_dialog>
          </div>
        </div>

        <.agent_docs_rail current_account={@current_account} />
      </section>
    </.console_shell>
    """
  end

  # Management guidance for the agents list. The connect flow introduces the
  # concept separately, before the reader needs key-lifecycle details.
  attr :current_account, :any, required: true

  defp agent_docs_rail(assigns) do
    ~H"""
    <.docs_rail title="Connections and access">
      <p>
        Agents are grouped by the team member who connected them. Each agent uses that
        member’s runner access. To change which runners their agents can reach, update
        the member’s access in <.link
          navigate={~p"/app/#{@current_account}/settings/team"}
          class="font-medium text-brand-400 hover:text-brand-300"
        >Team</.link>.
      </p>
      <p>
        Each connection has its own key. For local agents using the emisar MCP bridge,
        expiring keys rotate automatically. <.doc_link href={~p"/docs/agents-and-keys" <> "#rotating"}>How key rotation works</.doc_link>.
      </p>
      <p>
        Revoke a key when the connection is no longer needed or the key may have been exposed.
        To use that connection again, reconnect the agent. <.doc_link href={~p"/docs/agents-and-keys" <> "#revoking"}>How to revoke access</.doc_link>.
      </p>
    </.docs_rail>
    """
  end

  attr :status, :atom, required: true

  # Sanctioned page-local status (composes the shared `<.status_dot>` + a toned
  # word — the status_badge grammar): the words are the agents-specific activity
  # ladder overridden by a blocked bridge, and :active carries the live ping
  # status_badge can't express.
  defp client_status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap text-[11px] font-medium",
      status_word_class(@status)
    ]}>
      <.status_dot
        tone={status_dot_tone(@status)}
        size={:sm}
        animate={if @status == :active, do: :ping, else: :none}
      />
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
  attr :bridge_paths, :map, required: true
  attr :selected_client, :any, required: true
  attr :selected_sandbox, :any, required: true
  attr :base_url, :string, required: true
  attr :detected_os, :atom, required: true
  attr :quick_secret, :string, default: nil
  attr :quick_key_id, :string, default: nil
  attr :quick_connected?, :boolean, default: false
  attr :connection_delayed?, :boolean, default: false
  attr :snippet_open?, :boolean, default: false
  attr :current_account, :any, required: true
  attr :form, :any, default: nil

  defp connect_panel(assigns) do
    config =
      cond do
        assigns.selected_client == nil -> nil
        assigns.selected_client == "custom" -> nil
        true -> assigns.configs_for.(assigns.selected_client, assigns.detected_os)
      end

    variants =
      if config && config.kind == :local do
        Enum.map(@platform_tabs, fn tab ->
          tab
          |> Map.put(:config, assigns.configs_for.(assigns.selected_client, tab.os))
          |> Map.put(
            :downloads,
            AgentClientConfig.download_links(tab.os, Emisar.Compat.mcp_target())
          )
        end)
      else
        []
      end

    connection_state =
      cond do
        assigns.quick_connected? -> :connected
        assigns.connection_delayed? -> :delayed
        true -> :waiting
      end

    connection_title =
      case connection_state do
        :connected -> "Agent connected"
        :delayed -> "Still waiting for your agent"
        :waiting -> "Waiting for your agent"
      end

    sandbox_setup =
      if assigns.selected_sandbox do
        AgentClientConfig.sandbox_setup(
          assigns.selected_sandbox,
          assigns.base_url,
          assigns.quick_secret || "emk-…"
        )
      end

    assigns =
      assigns
      |> assign(:config, config)
      |> assign(:sandbox_guide, sandbox_guide(assigns.selected_sandbox))
      |> assign(:sandbox_setup, sandbox_setup)
      |> assign(:setup_label, client_label(assigns.selected_sandbox || assigns.selected_client))
      |> assign(
        :connection_step,
        if(assigns.selected_client == "coop" or not is_nil(assigns.selected_sandbox),
          do: 4,
          else: 2
        )
      )
      |> assign(
        :connection_url,
        if(sandbox_setup, do: sandbox_setup.connection_url, else: assigns.base_url)
      )
      |> assign(:variants, variants)
      |> assign(:connection_state, connection_state)
      |> assign(:connection_title, connection_title)

    ~H"""
    <%!-- CONTENT ON CANVAS, task + rail (the install-wizard / keys-new
         grammar) at the same 7xl column as the list it's reached from, so the
         header never jumps: the picker + per-client setup are the task on the
         left; beginner guidance fills the rail on the right. --%>
    <div class="xl:grid xl:grid-cols-[minmax(0,1fr)_22rem] xl:gap-x-16">
      <div id="connect-panel">
        <%!-- Client picker on the canvas — grouped into two transport families.
           Cloud first (the no-install path most new users want); Local below
           for everything that goes through the stdio bridge, partitioned by
           the KIND the operator recognizes — terminal agent vs editor/desktop
           app — because fifteen mixed tabs outgrew one scan. Small group
           labels organize the tabs; the pick step is framed by the page
           intro / section header above, so the picker carries no header. --%>
        <div>
          <p class="text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Web apps<span class="normal-case tracking-normal text-zinc-400"> — connect by signing in</span>
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
            On your computer<span class="normal-case tracking-normal text-zinc-400"> — use the emisar installer</span>
          </p>
          <%!-- Kind sub-labels are the smaller member of the group-label
             family (the docs rail's subgroup grammar): the transport fact
             stays once on the parent, the sub-label only partitions the
             scan. Tighter mt-4 between subgroups than the mt-6 between
             transport groups, so the hierarchy reads from distance. --%>
          <p
            id="client-kind-cli"
            class="mt-2.5 text-[10px] font-medium uppercase tracking-wide text-zinc-400"
          >
            Terminal apps
          </p>
          <div class="mt-1.5 flex flex-wrap gap-1.5">
            <.client_tab
              :for={id <- cli_agent_ids()}
              id={id}
              label={client_label(id)}
              selected={id == @selected_client}
            />
          </div>
          <p
            id="client-kind-editors"
            class="mt-4 text-[10px] font-medium uppercase tracking-wide text-zinc-400"
          >
            Editors &amp; desktop apps
          </p>
          <div class="mt-1.5 flex flex-wrap gap-1.5">
            <.client_tab
              :for={id <- editor_client_ids()}
              id={id}
              label={client_label(id)}
              selected={id == @selected_client}
            />
          </div>

          <p class="mt-6 text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Agent sandboxes
          </p>
          <div id="agent-sandbox-options" class="mt-2.5 flex flex-wrap gap-1.5">
            <.client_tab
              :for={id <- sandbox_ids()}
              id={id}
              label={client_label(id)}
              event={if id == "coop", do: "select_client", else: "select_sandbox"}
              selected={if id == "coop", do: @selected_client == id, else: @selected_sandbox == id}
            />
          </div>

          <p class="mt-6 text-[11px] font-medium uppercase tracking-wider text-zinc-400">
            Custom setup
          </p>
          <div class="mt-2.5 flex flex-wrap gap-1.5">
            <%!-- Custom key is the same ISSUE tier as the quick flows above: it
               mints the same `:mcp` credential, bounded by the same membership
               scope, with an operator-set name and expiry. The panel only
               renders for a member who may mint, so the tab is always live —
               the "create"/"select_client" handlers still gate (IL-15). --%>
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
          <% is_nil(@selected_client) and is_nil(@selected_sandbox) -> %>
            <%!-- Nothing picked → nothing rendered: the picker is the prompt;
               480px of reserved dead space buried the agents list. --%>
            <span></span>
          <% @sandbox_guide -> %>
            <.sandbox_setup
              sandbox={@selected_sandbox}
              guide={@sandbox_guide}
              setup={@sandbox_setup}
              ready?={is_binary(@quick_secret)}
            />
          <% @selected_client == "custom" -> %>
            <div id="custom-key-flow" class="mt-6 border-t border-zinc-800/70 pt-6">
              <%= if @quick_secret do %>
                <section id="custom-key-save-step" class="space-y-4">
                  <.step_header step={1} title="Save your key" />
                  <%!-- AMBER: a single-secret reveal wears the pending tone
                       (design-system §8.1) — the key is in the operator's hands
                       and unrecoverable once they leave, which is exactly the
                       "act before you move on" state amber names. Matches the
                       install wizard and the rotation reveal; one event, one
                       color, everywhere. --%>
                  <.event_block
                    icon="identity.credential"
                    tone={:amber}
                    title="API key created"
                  >
                    <:body>
                      Copy the API key below before you leave this page; we won't show it
                      again.
                      <.doc_link href={~p"/docs/agents-and-keys"}>Manage agents & keys docs</.doc_link>
                    </:body>
                  </.event_block>

                  <.code_panel
                    id="custom-secret"
                    label="API key"
                    copy
                    copy_label="Copy key"
                    code={@quick_secret}
                  />
                </section>
              <% else %>
                <section id="custom-key-create-step">
                  <.step_header step={1} title="Create a key" />
                  <.custom_key_panel form={@form} />
                </section>
              <% end %>
            </div>
          <% @config && @config.kind == :coop -> %>
            <div id="coop-setup" class="mt-6 space-y-8 border-t border-zinc-800/70 pt-6">
              <p class="text-sm text-zinc-400">
                co:op is a free, open-source tool for running AI agents in a local sandbox.
                It limits access to files, secrets, and tools on your machine; emisar extends that
                control to your infrastructure and third-party tools.
                <.doc_link href={~p"/docs/connect-coop"}>Full co:op guide</.doc_link>
              </p>
              <section id="coop-install-step" class="space-y-4">
                <.step_header step={1} title="Install co:op" />
                <div class="ml-6 space-y-4 text-sm text-zinc-400">
                  <p>On Linux or macOS, start Docker and run:</p>
                  <.code_line
                    id="coop-install"
                    label="On your computer"
                    value="curl -fsSL https://raw.githubusercontent.com/AndrewDryga/coop/main/install.sh | sh"
                  />
                  <p>
                    Follow any PATH instructions, then initialize your repository and sign in.
                    Replace
                    <.inline_code>codex</.inline_code>
                    with <.inline_code>claude</.inline_code>, <.inline_code>gemini</.inline_code>, or
                    <.inline_code>grok</.inline_code>
                    for another agent.
                  </p>
                  <.code_panel
                    id="coop-init"
                    label="From your repository"
                    code={~s(coop init\ncoop login codex)}
                    copy
                  />
                </div>
              </section>
              <section id="coop-container-step" class="space-y-4">
                <.step_header step={2} title="Prepare the container" />
                <div class="ml-6 space-y-4 text-sm text-zinc-400">
                  <p>
                    Create
                    <.inline_code>.agent/Dockerfile</.inline_code>
                    with this content.
                    If you already have one, add the installation steps and keep your existing
                    toolchain and final user; give that user ownership of <.inline_code>/config</.inline_code>.
                  </p>
                  <.code_panel
                    id="coop-dockerfile"
                    label=".agent/Dockerfile"
                    code={AgentClientConfig.coop_dockerfile()}
                    max_h="max-h-64"
                    copy
                  />
                  <p>
                    In
                    <.inline_code>~/.config/coop/coop.conf</.inline_code>
                    on your computer,
                    add or update these settings. Append the mount if
                    <.inline_code>COOP_RUN_ARGS</.inline_code>
                    already exists.
                    Keep this volume so replacement keys survive new containers.
                  </p>
                  <.code_panel
                    id="coop-storage"
                    label="coop.conf"
                    code={~s(COOP_RUNTIME=docker\nCOOP_RUN_ARGS=-v coop-emisar-config:/config)}
                    copy
                  />
                  <.code_line
                    id="coop-build"
                    label="From your repository"
                    value="coop build && coop doctor"
                  />
                </div>
              </section>
              <section id="coop-config-step" class="space-y-4">
                <.step_header step={3} title="Copy the MCP configuration" />
                <div class="ml-6">
                  <%= if @quick_secret do %>
                    <div class="space-y-5 text-sm text-zinc-400">
                      <p>
                        Merge this emisar entry into
                        <.inline_code>~/.config/coop/agents/mcp.json</.inline_code>
                        on your computer, preserving other servers. Create the file and parent
                        directories if needed. Keep it outside your repository and readable only by
                        your user; this key is shown only during setup.
                      </p>
                      <.code_panel
                        id="coop-config"
                        label="mcp.json"
                        code={@config.body}
                        copy
                      />
                      <p>
                        If your runners require signed dispatch, add the signing credentials from <.doc_link href={
                          ~p"/docs/signed-dispatch"
                        }>Set up signed dispatch</.doc_link>.
                      </p>
                    </div>
                  <% else %>
                    <div id="coop-config-error" role="alert" class="space-y-3">
                      <.error>Couldn't prepare the configuration.</.error>
                      <.button
                        variant={:secondary}
                        phx-click="select_client"
                        phx-value-client="coop"
                      >
                        Try again
                      </.button>
                    </div>
                  <% end %>
                </div>
              </section>
            </div>
          <% @config && @config.kind == :remote -> %>
            <div class="mt-6 space-y-8 border-t border-zinc-800/70 pt-6">
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
            <div class="mt-6 space-y-8 border-t border-zinc-800/70 pt-6">
              <div :if={@selected_client == "pi"} class="space-y-3 text-sm text-zinc-400">
                <p>
                  Pi needs an MCP extension. Install the third-party
                  <.doc_link href="https://github.com/nicobailon/pi-mcp-adapter">pi-mcp-adapter</.doc_link>
                  before connecting emisar:
                </p>
                <.code_line id="pi-install-adapter" value="pi install npm:pi-mcp-adapter" />
              </div>
              <p
                :if={@selected_client in ["hermes", "goose"] && @detected_os == :windows}
                class="text-sm text-zinc-400"
              >
                On Windows, use manual setup below to save the configuration in the right folder.
              </p>
              <.local_install_block base_url={@base_url} detected_os={@detected_os} />

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
                    Set up {client_label(@selected_client)} manually
                  </span>
                </:summary>
                <%= if @quick_secret do %>
                  <ol class="list-decimal space-y-6 pl-5 text-sm text-zinc-400">
                    <li class="space-y-3">
                      <p class="font-medium text-zinc-200">Download and check the bridge</p>
                      <div
                        :for={variant <- @variants}
                        id={"manual-path-#{variant.os}"}
                        data-os={variant.os}
                        class={["space-y-3", variant.os != @detected_os && "hidden"]}
                      >
                        <p>
                          The emisar MCP bridge connects your AI app to emisar.
                          <%= if variant.downloads != [] do %>
                            Download it for {variant.label}:<%= for {{label, href}, index} <- Enum.with_index(variant.downloads) do %>
                              {if index == 0, do: " ", else: " or "}<.doc_link href={href}>{label}</.doc_link>
                            <% end %>.
                            Extract the archive, keep the executable in a permanent folder, and enter
                            its full path below. If it's already installed, use its existing path.
                          <% else %>
                            Install it using the command above, then enter its full path below.
                          <% end %>
                        </p>
                        <.bridge_path_form os={variant.os} path={@bridge_paths[variant.os]} />
                      </div>
                    </li>
                    <li class="space-y-3">
                      <p class="font-medium text-zinc-200">
                        Add emisar to {client_label(@selected_client)}
                      </p>
                      <div
                        :for={variant <- @variants}
                        data-os={variant.os}
                        class={["space-y-3", variant.os != @detected_os && "hidden"]}
                      >
                        <%= cond do %>
                          <% @selected_client == "claude_desktop" -> %>
                            <p>
                              In Claude Desktop, open Settings → Developer → Edit Config.
                              Merge the snippet into the file and save it. These settings connect
                              Desktop Chat, not the Code tab.
                            </p>
                          <% @selected_client == "vscode" -> %>
                            <p>
                              Open the Command Palette and run MCP: Open User Configuration.
                              Merge the snippet into the file for your current profile and save it.
                            </p>
                          <% config_target_is_file?(variant.config) -> %>
                            <p>
                              Open
                              <.inline_code surface={:prominent} size={:sm} class="break-all">
                                {variant.config.location}
                              </.inline_code>
                              and merge the snippet into your configuration. If the file doesn't
                              exist, create it and any missing folders. Save the file.
                            </p>
                          <% true -> %>
                            <p>
                              Run the command in {if variant.os == :windows,
                                do: "PowerShell",
                                else: "your terminal"}.
                            </p>
                        <% end %>
                      </div>
                      <.code_panel
                        :if={Map.get(@config, :secret_separate, false)}
                        id={"secret-#{@selected_client}"}
                        label="API key"
                        annotation="paste when the client prompts; shown once"
                        copy
                        copy_label="Copy key"
                        code={@quick_secret}
                      />
                      <p class="text-xs text-zinc-400">
                        {if @config.secret_separate,
                          do: "The snippet does not contain your API key.",
                          else: "The snippet contains your API key; keep the configuration private."}
                      </p>
                      <.os_code_panel
                        id={"snippet-#{@selected_client}"}
                        detected={@detected_os}
                        on_change="select_os"
                      >
                        <:tab
                          :for={variant <- @variants}
                          os={variant.os}
                          label={variant.label}
                          code={variant.config.body}
                          unavailable="Enter a full executable path above to generate this snippet."
                        />
                      </.os_code_panel>
                    </li>
                    <li class="space-y-3">
                      <p class="font-medium text-zinc-200">Check the connection</p>
                      <p :for={instruction <- AgentClientConfig.connection_steps(@selected_client)}>
                        {instruction}
                      </p>
                      <p class="text-xs text-zinc-400">
                        <.doc_link href={~p"/docs/connect-cli-agent" <> "#troubleshooting"}>Troubleshooting</.doc_link>
                      </p>
                    </li>
                  </ol>
                <% else %>
                  <p class="text-sm text-zinc-400">Creating your API key…</p>
                <% end %>
              </.disclosure>
            </div>
        <% end %>

        <%!-- Step 2 — Connect your agent: the live connection status (the
             agents analog of the runner-install "waiting → connected"
             watchdog). The snippet/custom paths watch their minted key's id;
             the installer path watches for any key minted after this page
             opened making its first call (quick_key_connected?/2 — a
             pre-existing agent can't flip it). The neutral waiting state and
             green connected state share one stable, politely announced row. --%>
        <section
          :if={@quick_key_id || local_client?(@selected_client)}
          id="agent-connect-step"
          class="mt-8"
        >
          <.step_header
            step={@connection_step}
            title="Connect your agent"
          >
            <:subtitle>
              <%= cond do %>
                <% @selected_client == "coop" -> %>
                  Start a fresh session from your repository, then send the example prompt.
                <% @selected_sandbox -> %>
                  Start the sandboxed Codex session, then send the example prompt.
                <% @selected_client == "custom" -> %>
                  Add an MCP server in your app and choose Streamable HTTP.
                <% true -> %>
                  Finish setup in {client_label(@selected_client)}, then try the example prompt.
              <% end %>
            </:subtitle>
          </.step_header>
          <div class="ml-6 max-w-prose space-y-5">
            <div
              :if={@selected_client != "coop" && local_client?(@selected_client) && !@snippet_open?}
              class="space-y-3 text-sm text-zinc-400"
            >
              <p :for={
                instruction <- AgentClientConfig.connection_steps(@selected_client, :installer)
              }>
                {instruction}
              </p>
            </div>
            <div :if={@selected_client == "custom"} class="space-y-3">
              <.code_line
                id="custom-rpc-url"
                label="Server URL"
                value={@base_url <> "/api/mcp/rpc"}
                copy_label="Copy URL"
              />
              <p class="text-sm text-zinc-400">
                Set the Authorization header to
                <.inline_code surface={:prominent} size={:sm}>Bearer</.inline_code>
                followed by a space and the API key above. Save the connection, then send the
                prompt below.
                <.doc_link href={~p"/docs/connect-cli-agent" <> "#direct-http"}>Direct HTTP setup</.doc_link>
              </p>
            </div>

            <div :if={@selected_sandbox} class="space-y-3">
              <.code_line
                id={"#{@selected_sandbox}-start"}
                label={
                  if @selected_sandbox == "dev_containers",
                    do: "Inside the container",
                    else: "From your repository"
                }
                value={@sandbox_setup.start}
              />
            </div>

            <%= if @selected_client == "coop" do %>
              <.code_line id="coop-start" label="From your repository" value="coop codex" />
              <p class="text-sm text-zinc-400">
                Replace
                <.inline_code>codex</.inline_code>
                with the agent you signed in to.
              </p>
              <.code_panel
                id="agent-example-prompt"
                label="Example prompt"
                code="Use emisar to find a runner with linux.uptime, run that action, and show me the output."
                copy
                copy_label="Copy prompt"
                wrap
              />
              <p class="text-sm text-zinc-400">
                You'll need an online runner with the linux-core pack trusted. Allow the tool call
                if your agent asks, and complete any approval required by your policy. Check the
                returned uptime, then confirm the action, runner, and operator in <.link
                  navigate={~p"/app/#{@current_account}/audit"}
                  class="text-brand-400 hover:text-brand-300"
                >Audit</.link>.
              </p>
              <.disclosure id="coop-tool-prompts" size={:md}>
                <:summary>
                  <span class="font-medium">
                    Skip emisar tool-call prompts <span class="text-zinc-400">(optional)</span>
                  </span>
                </:summary>
                <div class="space-y-3 text-sm text-zinc-400">
                  <p>
                    co:op's default agent commands already skip local permission prompts for all
                    tools inside the sandbox, including emisar.
                  </p>
                  <p>
                    If you've customized your agent's command, follow the <.doc_link href={
                      ~p"/docs/connect-coop#tool-permissions"
                    }>co:op tool-permission guide</.doc_link>.
                    Your
                    <.doc_link href={~p"/docs/policies-and-approvals"}>emisar policies and approvals</.doc_link>
                    still apply.
                  </p>
                </div>
              </.disclosure>
            <% else %>
              <.agent_example_prompt id="agent-example-prompt" />
            <% end %>

            <.connection_status
              id="agent-connection-status"
              state={@connection_state}
              title={@connection_title}
            >
              <%= cond do %>
                <% @connection_state == :connected -> %>
                  Manage its access in
                  <.link
                    navigate={~p"/app/#{@current_account}/agents"}
                    class="text-brand-400 hover:text-brand-300"
                  >AI agents</.link>
                  or view its activity in <.link
                    navigate={~p"/app/#{@current_account}/runs"}
                    class="text-brand-400 hover:text-brand-300"
                  >Runs</.link>.
                <% @connection_state == :delayed -> %>
                  If you've finished setup, check the connection in {if @selected_client == "custom",
                    do: "your AI app",
                    else: @setup_label}:
                <% true -> %>
                  You can leave this page. Your agent will appear in
                  <.link
                    navigate={~p"/app/#{@current_account}/agents"}
                    class="text-brand-400 hover:text-brand-300"
                  >AI agents</.link>
                  when it connects.
              <% end %>
              <:details :if={@connection_state == :delayed}>
                <.steps>
                  <:step>
                    <%= cond do %>
                      <% @selected_client == "custom" -> %>
                        Confirm the server URL and Authorization header match the values above.
                      <% @selected_sandbox == "docker_sandboxes" -> %>
                        Run
                        <.inline_code>sbx mcp ls</.inline_code>
                        and check that the host launcher
                        starts without an error.
                      <% @selected_sandbox == "nono" -> %>
                        Check the Codex configuration and the emisar domain allowed by the nono command.
                      <% @selected_sandbox == "dev_containers" -> %>
                        Check the Codex configuration and run
                        <.inline_code>emisar-mcp --version</.inline_code>
                        inside the rebuilt container.
                      <% true -> %>
                        Restart {@setup_label} and check its MCP connection output for errors.
                    <% end %>
                  </:step>
                  <:step :if={@selected_client not in ["custom", "coop"] && @quick_secret}>
                    Confirm the bridge path and save the configuration shown in manual setup.
                  </:step>
                  <:step :if={@selected_client == "coop"}>
                    Check co:op's shared mcp.json, rebuild its image if the bridge is missing,
                    and start a new session.
                  </:step>
                  <:step>
                    Make sure the environment running your agent can reach <code class="break-all font-mono text-zinc-300">{@connection_url}</code>.
                  </:step>
                  <:step>
                    Send the example prompt and allow the emisar tool call if your app asks.
                  </:step>
                </.steps>
                <p class="mt-3 text-sm">
                  <.doc_link href={
                    if @sandbox_guide,
                      do: @sandbox_guide.path,
                      else: ~p"/docs/connect-cli-agent" <> "#troubleshooting"
                  }>Troubleshooting</.doc_link>
                </p>
              </:details>
            </.connection_status>
          </div>
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

      <%!-- Onboarding teaches the concept; list-page help owns managing keys.
           Keep this introduction reachable on narrow screens too. --%>
      <div class="mt-10 xl:mt-0">
        <.docs_rail title="What's an AI agent?">
          <p>
            An AI agent is an app, such as Claude, ChatGPT, or Cursor, that can use tools
            to carry out tasks for you.
          </p>
          <p>
            emisar connects that app to your infrastructure. Ask it to investigate an incident
            across your fleet, carry out recovery steps, and verify the result using the
            actions you make available.
          </p>
        </.docs_rail>
      </div>
    </div>
    """
  end

  attr :sandbox, :string, required: true
  attr :guide, :map, required: true
  attr :setup, :map, required: true
  attr :ready?, :boolean, required: true

  defp sandbox_setup(assigns) do
    ~H"""
    <section
      id={"sandbox-guide-#{@sandbox}"}
      class="mt-6 space-y-8 border-t border-zinc-800/70 pt-6"
    >
      <div class="max-w-prose space-y-2 text-sm leading-relaxed text-zinc-400">
        <p>{@guide.summary}</p>
        <p>
          This walkthrough uses Codex.
          <.doc_link href={@guide.path}>Read about {@guide.title}</.doc_link>
        </p>
      </div>

      <%= if @ready? do %>
        <%= case @sandbox do %>
          <% "docker_sandboxes" -> %>
            <section id="docker-sandboxes-host-tools" class="space-y-4">
              <.step_header step={1} title="Install the host tools" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Install Docker Sandboxes using Docker's <.doc_link href="https://docs.docker.com/ai/sandboxes/install/">platform instructions</.doc_link>,
                  then sign in and install the emisar bridge on your computer. This walkthrough
                  supports macOS and Ubuntu; Windows needs an equivalent owner-only launcher.
                </p>
                <.code_panel
                  id="docker-sandboxes-install"
                  label="On your computer"
                  code={@setup.install}
                  copy
                />
              </div>
            </section>

            <section id="docker-sandboxes-bridge" class="space-y-4">
              <.step_header step={2} title="Create the host bridge" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Create <.inline_code>~/.config/emisar/docker-sandboxes</.inline_code>, then
                  save these two files there. Keep them outside your repository: the environment
                  file contains the API key shown only during this setup.
                </p>
                <.code_line
                  id="docker-sandboxes-directory"
                  label="On your computer"
                  value="mkdir -p ~/.config/emisar/docker-sandboxes"
                />
                <.code_panel
                  id="docker-sandboxes-env"
                  label="bridge.env"
                  code={@setup.bridge_env}
                  copy
                />
                <.code_panel
                  id="docker-sandboxes-launcher"
                  label="launch-emisar"
                  code={@setup.launcher}
                  copy
                />
                <.code_panel
                  id="docker-sandboxes-protect"
                  label="On your computer"
                  code={@setup.protect}
                  copy
                />
                <p>
                  If your runners require signed dispatch, add
                  <.inline_code>EMISAR_SIGNING_KEY</.inline_code>
                  and
                  <.inline_code>EMISAR_SIGNING_CERT</.inline_code>
                  from <.doc_link href={~p"/docs/signed-dispatch"}>Set up signed dispatch</.doc_link>
                  to <.inline_code>bridge.env</.inline_code>.
                </p>
              </div>
            </section>

            <section id="docker-sandboxes-register" class="space-y-4">
              <.step_header step={3} title="Register emisar" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Register the launcher with Docker's host-side MCP gateway. The API key stays on
                  your computer instead of entering the sandbox.
                </p>
                <.code_panel
                  id="docker-sandboxes-register-command"
                  label="On your computer"
                  code={@setup.register}
                  copy
                />
              </div>
            </section>

            <section id="docker-sandboxes-limits" class="ml-6 max-w-prose space-y-3">
              <h3 class="text-base font-semibold leading-6 text-zinc-200">Limits &amp; risks</h3>
              <ul class="list-disc space-y-2 pl-5 text-sm text-zinc-400">
                <li>The agent can read and change the project you give the sandbox.</li>
                <li>The host launcher runs with your computer's permissions.</li>
                <li>The sandbox can create containers inside its own Docker environment.</li>
                <li>Review the sandbox's network policy to control which services it can reach.</li>
              </ul>
            </section>
          <% "nono" -> %>
            <section id="nono-install-step" class="space-y-4">
              <.step_header step={1} title="Install nono and the bridge" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>Install both tools on your computer and check that they start.</p>
                <.code_panel id="nono-install" label="On your computer" code={@setup.install} copy />
              </div>
            </section>

            <section id="nono-config-step" class="space-y-4">
              <.step_header step={2} title="Configure Codex" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Merge this entry into <.inline_code>~/.codex/config.toml</.inline_code>.
                  Preserve your other MCP servers and keep the file private; it contains the API
                  key shown only during this setup.
                </p>
                <.code_panel
                  id="nono-codex-config"
                  label="config.toml"
                  code={@setup.agent_config}
                  copy
                />
                <p>
                  If your runners require signed dispatch, add the signing credentials from
                  <.doc_link href={~p"/docs/signed-dispatch"}>Set up signed dispatch</.doc_link>
                  to the same
                  <.inline_code>env</.inline_code>
                  table.
                </p>
              </div>
            </section>

            <section id="nono-profile-step" class="space-y-4">
              <.step_header step={3} title="Review the sandbox profile" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Review the maintained Codex profile before running it. Start in the repository
                  Codex should access, and add file, command, or network access only when needed.
                </p>
                <.code_panel
                  id="nono-profile"
                  label="From your repository"
                  code={@setup.profile}
                  copy
                />
              </div>
            </section>

            <section id="nono-limits" class="ml-6 max-w-prose space-y-3">
              <h3 class="text-base font-semibold leading-6 text-zinc-200">Limits &amp; risks</h3>
              <ul class="list-disc space-y-2 pl-5 text-sm text-zinc-400">
                <li>The profile you run is the sandbox boundary; review every access you add.</li>
                <li>Codex can read its own configuration, including this setup key.</li>
                <li>
                  Automatic bridge key rotation is unavailable in the strict profile; rotate it manually.
                </li>
              </ul>
            </section>
          <% "dev_containers" -> %>
            <section id="dev-containers-image-step" class="space-y-4">
              <.step_header step={1} title="Install the bridge in the container" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Add these lines to <.inline_code>.devcontainer/Dockerfile</.inline_code>.
                  If you already have one, keep its base image, toolchain, and final non-root user.
                </p>
                <.code_panel
                  id="dev-containers-dockerfile"
                  label=".devcontainer/Dockerfile"
                  code={@setup.dockerfile}
                  copy
                />
              </div>
            </section>

            <section id="dev-containers-config-step" class="space-y-4">
              <.step_header step={2} title="Restrict and rebuild the container" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Merge these settings into <.inline_code>.devcontainer/devcontainer.json</.inline_code>.
                  The named volume retains rotated bridge credentials when the container is rebuilt.
                </p>
                <.code_panel
                  id="dev-containers-config"
                  label=".devcontainer/devcontainer.json"
                  code={@setup.devcontainer}
                  max_h="max-h-80"
                  copy
                />
                <.code_panel
                  id="dev-containers-rebuild"
                  label="From your repository"
                  code={@setup.rebuild}
                  copy
                />
              </div>
            </section>

            <section id="dev-containers-agent-step" class="space-y-4">
              <.step_header step={3} title="Configure Codex in the container" />
              <div class="ml-6 space-y-4 text-sm text-zinc-400">
                <p>
                  Inside the rebuilt container, merge this entry into <.inline_code>~/.codex/config.toml</.inline_code>. Keep the API key out of the
                  Dockerfile, dev container settings, image layers, and repository.
                </p>
                <.code_panel
                  id="dev-containers-codex-config"
                  label="Inside the container · ~/.codex/config.toml"
                  code={@setup.agent_config}
                  copy
                />
                <p :if={@setup.local_http?}>
                  This local setup uses
                  <.inline_code>host.docker.internal</.inline_code>
                  to reach
                  emisar on your computer and enables plain HTTP only for that local address.
                  Hosted HTTPS setups do not need the opt-in.
                </p>
                <p>
                  If your runners require signed dispatch, add the signing credentials from
                  <.doc_link href={~p"/docs/signed-dispatch"}>Set up signed dispatch</.doc_link>
                  to the same
                  <.inline_code>env</.inline_code>
                  table.
                </p>
              </div>
            </section>

            <section id="dev-containers-limits" class="ml-6 max-w-prose space-y-3">
              <h3 class="text-base font-semibold leading-6 text-zinc-200">Limits &amp; risks</h3>
              <ul class="list-disc space-y-2 pl-5 text-sm text-zinc-400">
                <li>The agent can read every file mounted into the container.</li>
                <li>This configuration does not restrict outbound network access.</li>
                <li>
                  Your editor may share Git or SSH credentials separately from this configuration.
                </li>
              </ul>
            </section>
        <% end %>
      <% else %>
        <div id="sandbox-config-error" role="alert" class="space-y-3">
          <.error>Couldn't prepare the configuration.</.error>
          <.button
            variant={:secondary}
            phx-click="select_sandbox"
            phx-value-client={@sandbox}
          >
            Try again
          </.button>
        </div>
      <% end %>
    </section>
    """
  end

  attr :os, :atom, required: true
  attr :path, :string, required: true

  defp bridge_path_form(assigns) do
    error = if assigns.path != "", do: AgentClientConfig.path_error(assigns.path, assigns.os)
    form = to_form(%{"os" => to_string(assigns.os), "path" => assigns.path})

    assigns =
      assigns
      |> assign(:error, error)
      |> assign(:path_form, form)
      |> assign(:version_command, AgentClientConfig.version_command(assigns.path, assigns.os))

    ~H"""
    <.form
      for={@path_form}
      id={"bridge-path-form-#{@os}"}
      phx-change="bridge_path_changed"
      phx-submit="bridge_path_changed"
    >
      <input type="hidden" name="os" value={@os} />
      <.input
        id={"bridge-path-#{@os}"}
        name="path"
        label="MCP bridge path"
        value={@path}
        errors={if @error, do: [@error], else: []}
        placeholder={
          if @os == :windows,
            do: "C:\\Users\\you\\AppData\\Local\\Programs\\Emisar\\bin\\emisar-mcp.exe"
        }
        autocomplete="off"
        spellcheck="false"
        maxlength="4096"
        phx-debounce="300"
        class="font-mono"
      />
    </.form>
    <p :if={@version_command} class="text-xs text-zinc-400">
      Run this in {if @os == :windows, do: "PowerShell", else: "your terminal"} to check that
      the bridge starts. It should print its version:
    </p>
    <.code_line
      :if={@version_command}
      id={"bridge-check-#{@os}"}
      value={@version_command}
    />
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :event, :string, default: "select_client"
  attr :selected, :boolean, default: false

  defp client_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-client={@id}
      class={[
        "inline-flex min-h-10 min-w-10 items-center justify-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition",
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
    <div class="mb-4 flex items-baseline gap-3 [&>header]:mb-0">
      <span class="w-3 shrink-0 font-display text-xl font-medium leading-7 tabular-nums text-zinc-400">
        {@step}
      </span>
      <.section_header title={@title} class="min-w-0 flex-1">
        <:subtitle :if={@subtitle != []}>{render_slot(@subtitle)}</:subtitle>
        <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
      </.section_header>
    </div>
    """
  end

  # Renders only AFTER a local client is picked. The install line is the
  # same for every local client — extracting it keeps the per-client
  # snippet focused on just the config the operator needs to paste, and
  # cloud-LLM users never see it at all. The command comes from
  # URLHelpers.mcp_install_command/1, so a dev or self-hosted portal's
  # base URL rides along as EMISAR_URL.
  attr :base_url, :string, required: true
  attr :detected_os, :atom, required: true

  defp local_install_block(assigns) do
    ~H"""
    <div>
      <%!-- Inspect-first links (manual install · verify the release) sit on the
           RIGHT as header actions — they open the docs/trust pages in a new tab
           (doc_link's ↗), so a security-conscious operator can vet the curl|bash
           without losing this flow. --%>
      <.step_header step={1} title="Run the installer">
        <:subtitle>On the computer where you use your AI app.</:subtitle>
        <:actions>
          <%!-- text-xs so these header-action links stay subordinate to the
               section heading — doc_link inherits ambient size, and step_header's
               actions slot sets none. --%>
          <div class="flex items-center gap-3 text-xs">
            <.doc_link href={~p"/docs/connect-cli-agent"}>Manual install</.doc_link>
            <.doc_link href={~p"/trust" <> "#release-integrity"}>Verify the release</.doc_link>
          </div>
        </:actions>
      </.step_header>
      <%= case {URLHelpers.mcp_install_command(@base_url), URLHelpers.mcp_windows_install_command(@base_url)} do %>
        <% {{:ok, command}, {:ok, windows_command}} -> %>
          <.os_code_panel id="install-mcp-cmd" detected={@detected_os} on_change="select_os">
            <:tab os={:linux} label="Linux" code={command} />
            <:tab os={:windows} label="Windows" code={windows_command} />
            <:tab os={:macos} label="macOS" code={command} />
          </.os_code_panel>
          <p class="mt-2 text-xs leading-5 text-zinc-400">
            The installer offers to connect emisar to the AI apps it finds.
            Approve the connection in your browser when prompted. No key to copy.
          </p>
        <% {{:error, :insecure_base_url}, _windows} -> %>
          <.install_transport_refusal />
        <% _error -> %>
          <.install_command_unavailable />
      <% end %>
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
      <.auto_permit_installer_note :if={@auto_permit[:installer]} />
      <p class="mt-3 break-all text-[11px] text-zinc-400 font-mono">{@auto_permit.location}</p>
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
      <.auto_permit_installer_note :if={@auto_permit[:installer]} />
      <p class="mt-3 text-xs text-zinc-400">{@auto_permit.pointer}</p>
      <p :if={@auto_permit.doc_url} class="mt-2 text-[11px] text-zinc-400">
        <.link
          href={@auto_permit.doc_url}
          target="_blank"
          rel="noopener noreferrer"
          class="group text-brand-400 hover:text-brand-300"
        >
          {@client_label} MCP docs <.icon name="action.external_link" class="ml-0.5 h-3 w-3" />
        </.link>
      </p>
    </.disclosure>
    """
  end

  defp auto_permit_installer_note(assigns) do
    ~H"""
    <p class="mt-2 text-xs text-zinc-400">
      The bridge installer offers to set this for you. Do it by hand if you declined.
    </p>
    """
  end

  # One direct safety sentence; the client-specific instruction follows it.
  attr :client_label, :string, required: true

  defp auto_permit_why(assigns) do
    ~H"""
    <p class="text-xs text-zinc-400">
      Your emisar policies still decide which actions are allowed, require approval, or are blocked.
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
             (Claude.ai pastes at step 2, ChatGPT at step 4). --%>
        <.section_header title={"Steps for #{@client_label}"} />
        <p :if={@client_id == "claude_web"} class="mt-3 text-sm text-zinc-400">
          On Claude Team or Enterprise, an organization owner must add the connector first:
          Organization settings → Connectors → Add → Custom → Web. Members then choose
          Connect under Customize → Connectors and sign in to emisar.
        </p>
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
              <p class="text-xs text-zinc-400">
                The server URL must be publicly reachable over HTTPS. localhost and private
                network addresses won't work with this connection method.
              </p>
              <.callout tone={:neutral} title={@oauth_note.title}>
                {@oauth_note.body}
              </.callout>
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
        Your account and workspace settings must allow custom MCP connections.
        <.doc_link href={
          if @client_id == "chatgpt", do: ~p"/docs/connect-chatgpt", else: ~p"/docs/connect-claude-ai"
        }>Full setup guide</.doc_link>
      </p>
    </div>
    """
  end

  attr :form, :any, required: true

  defp custom_key_panel(assigns) do
    ~H"""
    <div class="space-y-5">
      <p class="text-sm leading-relaxed text-zinc-400">
        Use a custom key for an agent that isn't one of the presets above, or when you
        want to set its name and expiry date.
      </p>

      <.simple_form
        for={@form}
        id="api_key_form"
        phx-change="validate"
        phx-submit="create"
      >
        <%!-- autocomplete="off": this names a KEY, not a person, but the field is
             labeled "Name" — enough for a browser to offer the operator's own. --%>
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          autocomplete="off"
          placeholder="e.g. Claude Desktop on laptop"
          required
        />

        <.input
          field={@form[:description]}
          type="textarea"
          label="Description (optional)"
          placeholder="Optional — what is this key for? Who uses it?"
          rows="2"
        />

        <%!-- `datetime-local` posts as "YYYY-MM-DDTHH:MM" with no
             timezone; ApiKeys reads it as UTC. Operators typing
             "expires Dec 25 at 10am" get a key that expires at
             10:00 UTC on that date, which is close enough for an
             audit-friendly default without dragging browser-tz
             guessing into the server. --%>
        <.input
          field={@form[:expires_at]}
          type="datetime-local"
          label="Expiration date (UTC, optional)"
        />
        <p class="mt-1 text-xs text-zinc-400">
          Leave blank to expire the key in 30 days.
        </p>

        <:actions>
          <.button phx-disable-with="Creating...">Create key</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
