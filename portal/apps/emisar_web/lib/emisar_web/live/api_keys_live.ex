defmodule EmisarWeb.ApiKeysLive do
  use EmisarWeb, :live_view

  alias Emisar.{Runners, ApiKeys}
  alias Emisar.ApiKeys.ApiKey
  alias EmisarWeb.Permissions

  @all_scopes ApiKey.valid_scopes()

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    {:ok,
     socket
     |> assign(:page_title, "API keys")
     |> assign(:all_scopes, @all_scopes)
     |> assign(:runners, Runners.list_runners_for_account(account_id))
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)
     |> assign(:selected_client, "claude_code")
     |> assign(:base_url, derive_base_url(socket))
     |> assign_form(default_params())
     |> load()}
  end

  # Mirror of dashboard_live's URL detection: use socket.host_uri so
  # dev (http://localhost:4000) and prod (https://app.emisar.com)
  # both produce the right snippet to paste into a client config.
  defp derive_base_url(socket) do
    case socket.host_uri do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        scheme = scheme || "http"
        port_part = default_port_suffix(scheme, port)
        "#{scheme}://#{host}#{port_part}"

      _ ->
        "https://app.emisar.com"
    end
  end

  defp default_port_suffix(_scheme, nil), do: ""
  defp default_port_suffix("https", 443), do: ""
  defp default_port_suffix("http", 80), do: ""
  defp default_port_suffix(_scheme, port), do: ":#{port}"

  def handle_event("validate", %{"api_key" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    Permissions.gated(socket, :manage_api_keys, fn s -> do_create(s, params) end)
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)}
  end

  def handle_event("select_client", %{"client" => id}, socket) do
    {:noreply, assign(socket, :selected_client, id)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(socket, :manage_api_keys, fn s -> do_revoke(s, id) end)
  end

  defp do_create(socket, params) do
    account_id = socket.assigns.current_account.id
    user_id = socket.assigns.current_user.id

    attrs = %{
      name: params["name"] || "",
      scopes: selected_scopes(params),
      runner_filter: selected_agents(params, socket.assigns.runners)
    }

    case ApiKeys.create_key(account_id, user_id, attrs) do
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> assign(:new_secret, raw)
         |> assign(:new_key, key)
         |> assign(:selected_client, "claude_code")
         |> assign_form(default_params())
         |> load()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create key: #{inspect(changeset.errors)}")}
    end
  end

  defp do_revoke(socket, id) do
    account_id = socket.assigns.current_account.id
    user_id = socket.assigns.current_user.id

    case ApiKeys.get_key(account_id, id) do
      nil ->
        {:noreply, socket}

      key ->
        {:ok, _} = ApiKeys.revoke(key, user_id)
        {:noreply, socket |> put_flash(:info, "API key revoked.") |> load()}
    end
  end

  defp load(socket) do
    assign(socket, :api_keys, ApiKeys.list_for_account(socket.assigns.current_account.id))
  end

  defp default_params do
    %{"name" => "", "scopes" => [], "runner_filter" => []}
  end

  # Allowlist the submitted runner IDs against the account's real runners
  # so a malicious POST can't sneak in runner IDs from another account.
  defp selected_agents(%{"runner_filter" => ids}, runners) when is_list(ids) do
    allowed = MapSet.new(Enum.map(runners, & &1.id))
    Enum.filter(ids, &MapSet.member?(allowed, &1))
  end

  defp selected_agents(%{"runner_filter" => ids}, runners) when is_map(ids) do
    allowed = MapSet.new(Enum.map(runners, & &1.id))

    ids
    |> Enum.filter(fn {_k, v} -> v in ["true", "on", true] end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.filter(&MapSet.member?(allowed, &1))
  end

  defp selected_agents(_, _), do: []

  defp format_runner_filter([], _agents), do: "All runners"

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

  defp assign_form(socket, params) do
    runners = socket.assigns[:runners] || []

    socket
    |> assign(:form, to_form(params, as: "api_key"))
    |> assign(:selected_scopes, selected_scopes(params))
    |> assign(:selected_runner_ids, selected_agents(params, runners))
  end

  defp selected_scopes(%{"scopes" => scopes}) when is_list(scopes),
    do: Enum.filter(scopes, &(&1 in @all_scopes))

  defp selected_scopes(%{"scopes" => scopes}) when is_map(scopes) do
    scopes
    |> Enum.filter(fn {_k, v} -> v in ["true", "on", true] end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.filter(&(&1 in @all_scopes))
  end

  defp selected_scopes(_), do: []

  # -- client configs ----------------------------------------------------
  #
  # Single source of truth for the "Connect a client" panel. Each entry
  # describes one MCP client: its label, where its config file lives,
  # and a pre-filled snippet body with the operator's URL + key inlined.

  defp client_configs(url, key) do
    [
      %{
        id: "claude_code",
        label: "Claude Code",
        location: "One command — registers the bridge globally",
        body: """
        claude mcp add emisar /usr/local/bin/emisar-mcp \\
            --scope user \\
            -e EMISAR_URL=#{url} \\
            -e EMISAR_API_KEY=#{key}\
        """
      },
      %{
        id: "claude_desktop",
        label: "Claude Desktop",
        location: "~/Library/Application Support/Claude/claude_desktop_config.json",
        body: mcp_json_snippet(url, key)
      },
      %{
        id: "cursor",
        label: "Cursor",
        location: "~/.cursor/mcp.json",
        body: mcp_json_snippet(url, key, "emisar-mcp")
      },
      %{
        id: "gemini",
        label: "Gemini CLI",
        location: "~/.gemini/settings.json",
        body: mcp_json_snippet(url, key)
      },
      %{
        id: "codex",
        label: "Codex CLI",
        location: "~/.codex/config.toml",
        body: """
        [mcp_servers.emisar]
        command = "/usr/local/bin/emisar-mcp"
        env = { EMISAR_URL = "#{url}", EMISAR_API_KEY = "#{key}" }\
        """
      }
    ]
  end

  defp mcp_json_snippet(url, key, command \\ "/usr/local/bin/emisar-mcp") do
    """
    {
      "mcpServers": {
        "emisar": {
          "command": "#{command}",
          "env": {
            "EMISAR_URL": "#{url}",
            "EMISAR_API_KEY": "#{key}"
          }
        }
      }
    }\
    """
  end

  defp client_by_id(configs, id), do: Enum.find(configs, hd(configs), &(&1.id == id))

  # -- render ------------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:api_keys}
    >
      <:title>API keys</:title>

      <%= if @new_secret do %>
        <.connection_setup
          secret={@new_secret}
          base_url={@base_url}
          selected_client={@selected_client}
          configs={client_configs(@base_url, @new_secret)}
        />
      <% else %>
        <p class="-mt-4 mb-8 max-w-2xl text-sm text-zinc-400">
          API keys give LLMs and scripts MCP access to your action catalog.
          Issue a key here, then paste the prefilled snippet into Claude Code,
          Cursor, Gemini, or any MCP-aware client.
        </p>
      <% end %>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.create_panel
          :if={Permissions.can?(assigns, :manage_api_keys)}
          form={@form}
          all_scopes={@all_scopes}
          selected_scopes={@selected_scopes}
          runners={@runners}
          selected_runner_ids={@selected_runner_ids}
        />

        <.card :if={!Permissions.can?(assigns, :manage_api_keys)} class="lg:col-span-1">
          <.section_header title="Issue a key" />
          <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
            Only owners and admins can issue API keys.
          </p>
        </.card>

        <.keys_table_panel api_keys={@api_keys} runners={@runners} can_manage={Permissions.can?(assigns, :manage_api_keys)} />
      </div>
    </.dashboard_shell>
    """
  end

  # ---------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------

  # The full post-creation flow: key reveal + client picker + snippet.
  # Owns the visual top of the page when a fresh key exists.

  attr :secret, :string, required: true
  attr :base_url, :string, required: true
  attr :selected_client, :string, required: true
  attr :configs, :list, required: true

  defp connection_setup(assigns) do
    selected = client_by_id(assigns.configs, assigns.selected_client)
    assigns = assign(assigns, :selected, selected)

    ~H"""
    <div class="mb-10 overflow-hidden rounded-2xl border border-emerald-500/20 bg-gradient-to-br from-emerald-950/40 via-zinc-950 to-zinc-950">
      <div class="flex items-start justify-between gap-4 border-b border-emerald-900/30 px-6 py-4">
        <div class="flex items-center gap-3">
          <span class="grid h-8 w-8 place-items-center rounded-full bg-emerald-500/20 text-emerald-300">
            <.icon name="hero-check" class="h-4 w-4" />
          </span>
          <div>
            <h2 class="text-base font-semibold text-zinc-50">API key created</h2>
            <p class="text-xs text-zinc-400">Two steps left: save the key, then wire it into your client.</p>
          </div>
        </div>
        <button
          phx-click="dismiss_secret"
          class="rounded-lg p-1.5 text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
          aria-label="Dismiss"
        >
          <.icon name="hero-x-mark" class="h-5 w-5" />
        </button>
      </div>

      <%!-- Step 1: save the key --%>
      <div class="border-b border-zinc-900 px-6 py-6">
        <div class="flex items-baseline gap-3">
          <span class="grid h-5 w-5 place-items-center rounded-full bg-zinc-800 text-[10px] font-semibold text-zinc-300">1</span>
          <h3 class="text-sm font-semibold text-zinc-100">Save the key</h3>
          <span class="text-xs text-amber-200/80">— shown only once</span>
        </div>
        <div class="mt-3 flex items-stretch gap-2">
          <input
            id="api-key-secret"
            type="text"
            value={@secret}
            readonly
            class="flex-1 rounded-lg border border-zinc-800 bg-black/60 px-3 py-2 font-mono text-xs text-zinc-100 focus:border-emerald-500/40 focus:outline-none focus:ring-1 focus:ring-emerald-500/30"
          />
          <button
            type="button"
            class="rounded-lg bg-emerald-500/20 px-4 py-2 text-sm font-medium text-emerald-100 hover:bg-emerald-500/30"
            onclick={"navigator.clipboard.writeText(document.getElementById('api-key-secret').value); this.innerText='Copied'"}
          >
            Copy
          </button>
        </div>
      </div>

      <%!-- Step 2: connect a client --%>
      <div class="px-6 py-6">
        <div class="flex items-baseline gap-3">
          <span class="grid h-5 w-5 place-items-center rounded-full bg-zinc-800 text-[10px] font-semibold text-zinc-300">2</span>
          <h3 class="text-sm font-semibold text-zinc-100">Connect a client</h3>
        </div>

        <%!-- Tab strip --%>
        <div class="mt-4 flex flex-wrap gap-1.5">
          <button
            :for={c <- @configs}
            type="button"
            phx-click="select_client"
            phx-value-client={c.id}
            class={[
              "rounded-lg px-3 py-1.5 text-sm font-medium transition",
              if(c.id == @selected_client,
                do: "bg-zinc-100 text-zinc-950",
                else: "bg-zinc-900 text-zinc-300 hover:bg-zinc-800"
              )
            ]}
          >
            {c.label}
          </button>
        </div>

        <%!-- Snippet panel --%>
        <div class="mt-4 overflow-hidden rounded-lg border border-zinc-800 bg-black/80">
          <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
            <p class="font-mono text-[11px] text-zinc-500">{@selected.location}</p>
            <button
              type="button"
              id={"copy-#{@selected.id}"}
              class="rounded bg-zinc-800/80 px-2.5 py-1 text-xs font-medium text-zinc-200 hover:bg-zinc-700"
              onclick={"const el = document.getElementById('snippet-#{@selected.id}'); navigator.clipboard.writeText(el.textContent); this.innerText='Copied'"}
            >
              Copy
            </button>
          </div>
          <pre
            id={"snippet-#{@selected.id}"}
            class="overflow-x-auto p-4 font-mono text-xs leading-6 text-zinc-200"
          ><%= @selected.body %></pre>
        </div>

        <p class="mt-4 text-xs text-zinc-500">
          Don't have <code class="rounded bg-zinc-900 px-1 py-0.5">emisar-mcp</code> installed yet?
          <.link href={~p"/docs/connect-an-llm"} class="text-emerald-400 hover:text-emerald-300">
            Install instructions →
          </.link>
        </p>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :all_scopes, :list, required: true
  attr :selected_scopes, :list, required: true
  attr :runners, :list, required: true
  attr :selected_runner_ids, :list, required: true

  defp create_panel(assigns) do
    ~H"""
    <.card class="lg:col-span-1">
      <.section_header title="Issue a key" />

      <.simple_form for={@form} id="api_key_form" phx-change="validate" phx-submit="create">
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          placeholder="e.g. Claude Desktop, GPT bot"
          required
        />

        <fieldset>
          <legend class="text-sm font-medium text-zinc-200">Scopes</legend>
          <p class="mt-1 text-xs text-zinc-500">What the key can do.</p>
          <div class="mt-2 space-y-1.5">
            <label :for={scope <- @all_scopes} class="flex items-center gap-2.5 rounded px-1 py-1 text-sm text-zinc-300 hover:bg-zinc-900/40">
              <input
                type="checkbox"
                name="api_key[scopes][]"
                value={scope}
                checked={scope in @selected_scopes}
                class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40 focus:ring-offset-0"
              />
              <span class="font-mono text-xs">{scope}</span>
            </label>
          </div>
        </fieldset>

        <fieldset>
          <legend class="text-sm font-medium text-zinc-200">Allowed runners</legend>
          <p class="mt-1 text-xs text-zinc-500">
            Empty = all runners in the account. Tick to lock down.
          </p>
          <%= if @runners == [] do %>
            <p class="mt-2 rounded-lg bg-zinc-900/60 p-3 text-xs text-zinc-400">
              No runners registered yet. Issue an auth key first and connect a host.
            </p>
          <% else %>
            <div class="mt-2 max-h-40 space-y-1 overflow-y-auto rounded-lg border border-zinc-800 bg-zinc-950/40 p-2">
              <label :for={runner <- @runners} class="flex items-center gap-2.5 rounded px-1.5 py-1 text-sm text-zinc-300 hover:bg-zinc-900/60">
                <input
                  type="checkbox"
                  name="api_key[runner_filter][]"
                  value={runner.id}
                  checked={runner.id in @selected_runner_ids}
                  class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40 focus:ring-offset-0"
                />
                <span class="flex-1 truncate">{runner.name}</span>
                <span class="text-xs text-zinc-500">{runner.group}</span>
              </label>
            </div>
          <% end %>
        </fieldset>

        <:actions>
          <.button phx-disable-with="Creating..." class="w-full">
            Create key
          </.button>
        </:actions>
      </.simple_form>
    </.card>
    """
  end

  attr :api_keys, :list, required: true
  attr :runners, :list, required: true
  attr :can_manage, :boolean, required: true

  defp keys_table_panel(assigns) do
    ~H"""
    <.card class="lg:col-span-2">
      <.section_header title="Current keys" />

      <%= if @api_keys == [] do %>
        <div class="mt-4">
          <.empty_state icon="hero-finger-print" title="No keys yet">
            Issue one to let an LLM call your tools.
          </.empty_state>
        </div>
      <% else %>
        <div class="mt-4">
          <.list_table id="api-keys" rows={@api_keys}>
            <:col :let={key} label="Name">
              <div class="flex flex-col">
                <span class="text-sm text-zinc-200">{key.name}</span>
                <span class="font-mono text-[11px] text-zinc-500">{key.key_prefix}…</span>
              </div>
            </:col>
            <:col :let={key} label="Scopes">
              <div class="flex flex-wrap gap-1">
                <span
                  :for={scope <- key.scopes || []}
                  class="rounded bg-indigo-500/10 px-1.5 py-0.5 font-mono text-[10px] text-indigo-200 ring-1 ring-indigo-500/30"
                >
                  {scope}
                </span>
              </div>
            </:col>
            <:col :let={key} label="Runners">
              <span class="text-xs text-zinc-400">
                {format_runner_filter(key.runner_filter || [], @runners)}
              </span>
            </:col>
            <:col :let={key} label="Last used">
              <span class="text-xs text-zinc-400">{relative_time(key.last_used_at)}</span>
            </:col>
            <:action :let={key}>
              <%= cond do %>
                <% key.revoked_at -> %>
                  <span class="text-xs text-zinc-500">revoked</span>
                <% @can_manage -> %>
                  <button
                    phx-click="revoke"
                    phx-value-id={key.id}
                    data-confirm="Revoke this API key? Any client using it will start getting 401s."
                    class="rounded px-2 py-1 text-xs font-medium text-rose-300 ring-1 ring-rose-500/30 hover:bg-rose-500/10"
                  >
                    Revoke
                  </button>
                <% true -> %>
                  <span></span>
              <% end %>
            </:action>
          </.list_table>
        </div>
      <% end %>
    </.card>
    """
  end
end
