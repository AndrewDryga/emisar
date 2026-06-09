defmodule EmisarWeb.AuthKeysLive do
  use EmisarWeb, :live_view

  alias Emisar.{PubSub, Runners}
  alias Emisar.Runners.AuthKey
  alias EmisarWeb.{LiveTable, Permissions, UrlHelpers}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    # Subscribe to the per-account auth-keys topic so another operator's
    # create / revoke (or an auto-bind from a runner registration) reflows
    # this list without the viewer having to refresh.
    if connected?(socket),
      do: PubSub.subscribe_account_auth_keys(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:page_title, "Auth keys")
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)
     |> assign(:base_url, UrlHelpers.derive_base_url(socket))
     # IL-18: only hit the billing read on the connected mount; the
     # cap-warning banner just stays hidden until it loads.
     |> assign(:billing, connected?(socket) && fetch_billing(socket))
     |> assign_form(default_params())}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info({:list_changed, :auth_key, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp fetch_billing(socket) do
    case Emisar.Billing.billing_summary(
           socket.assigns.current_account,
           socket.assigns.current_subject
         ) do
      {:ok, summary} -> summary
      {:error, _} -> nil
    end
  end

  def handle_event("validate", %{"auth_key" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"auth_key" => params}, socket) do
    Permissions.gated(socket, :manage_auth_keys, &do_create(&1, params))
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(socket, :manage_auth_keys, fn s -> do_revoke(s, id) end)
  end

  def handle_event("filter", params, socket) do
    {:noreply, LiveTable.apply_filter(socket, ~p"/app/settings/runners/auth-keys", params)}
  end

  defp do_create(socket, params) do
    attrs =
      %{}
      |> put_if_present(:description, params["description"])
      |> put_if_present(:group, params["group"])
      |> Map.put(:reusable, truthy?(params["reusable"]))
      |> put_expires(params["expires_at"])
      |> put_max_uses(params["max_uses"])

    case Runners.create_auth_key(attrs, socket.assigns.current_subject) do
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Auth key created. Copy it now — you won't see it again.")
         |> assign(:new_secret, raw)
         |> assign(:new_key, key)
         |> assign_form(default_params())
         |> reload()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create key: #{humanize_errors(changeset)}")}
    end
  end

  defp do_revoke(socket, id) do
    case Enum.find(socket.assigns.auth_keys, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      key ->
        case Runners.revoke_auth_key(key, socket.assigns.current_subject) do
          {:ok, _} -> {:noreply, socket |> put_flash(:info, "Key revoked.") |> reload()}
          {:error, _} -> {:noreply, socket}
        end
    end
  end

  # Re-runs the current load with whatever filter/page params are
  # already on the URL — so a create or revoke doesn't bounce the
  # operator back to page 1 or wipe their filter.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  defp load(socket, params) do
    # Hide revoked keys by default — but only on the first load (a fresh visit).
    # LiveTable strips the dropdown's empty "All" value out of the URL, so once
    # the operator has touched the filter we can't tell "All" from "unset" by
    # the params alone: treat an absent status as their "All" rather than
    # snapping back to "active". `filter_params` is unset until the first load.
    params =
      if socket.assigns[:filter_params],
        do: params,
        else: Map.put_new(params, "status", "active")

    filters = AuthKey.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Runners.list_auth_keys(socket.assigns.current_subject, opts) do
      {:ok, auth_keys, meta} ->
        socket
        |> assign(:auth_keys, auth_keys)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      {:error, _} ->
        load(socket, %{})
    end
  end

  defp default_params do
    %{
      "description" => "",
      "group" => "default",
      "reusable" => "false",
      "expires_at" => "",
      "max_uses" => ""
    }
  end

  # Only set max_uses when reusable AND a positive integer was typed —
  # single-use keys ignore it (they self-cap at 1 via the schema), and
  # an empty string means "unlimited within the reusable window".
  defp put_max_uses(map, value) when value in [nil, ""], do: map

  defp put_max_uses(map, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> Map.put(map, :max_uses, n)
      _ -> map
    end
  end

  defp assign_form(socket, params) do
    assign(socket, :form, to_form(params, as: "auth_key"))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_expires(map, value) when value in [nil, ""], do: map

  defp put_expires(map, value) when is_binary(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, dt, _} -> Map.put(map, :expires_at, DateTime.truncate(dt, :microsecond))
      _ -> map
    end
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:auth_keys}
    >
      <:title>Auth keys</:title>
      <:actions :if={Permissions.can?(assigns, :manage_auth_keys)}>
        <button
          phx-click={show_create()}
          class="inline-flex items-center gap-1.5 rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
        >
          <.icon name="hero-plus" class="h-4 w-4" /> New key
        </button>
      </:actions>

      <.page_container max="5xl">
        <%!-- Runner-cap warning: a key minted here is useless if the
             runner that tries to use it bounces off a 402. --%>
        <div
          :if={@billing && Emisar.Billing.headroom(@billing, :runners) in [:warning, :at_limit]}
          class={[
            "flex items-start gap-3 rounded-xl border p-4 text-sm",
            if(Emisar.Billing.headroom(@billing, :runners) == :at_limit,
              do: "border-rose-500/40 bg-rose-500/10 text-rose-100",
              else: "border-amber-500/40 bg-amber-500/10 text-amber-100"
            )
          ]}
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 flex-none" />
          <div class="flex-1">
            <p class="font-semibold">
              <%= if Emisar.Billing.headroom(@billing, :runners) == :at_limit do %>
                At runner limit — new installs will fail.
              <% else %>
                One runner slot left on the {String.capitalize(@billing.plan)} plan.
              <% end %>
            </p>
            <p class="mt-1 text-xs opacity-90">
              {@billing.runner_count} of {@billing.runner_limit} runners in use.
              Issuing a key doesn't reserve a slot — the runner only counts after it registers.
            </p>
          </div>
          <.link
            navigate={~p"/app/settings/billing"}
            class="shrink-0 self-start rounded-lg bg-current/20 px-3 py-1.5 text-xs font-semibold hover:bg-current/30"
          >
            See plans →
          </.link>
        </div>

        <.secret_reveal
          :if={@new_secret}
          title="Copy this auth key now — it will not be shown again."
          secret={@new_secret}
          on_dismiss="dismiss_secret"
        >
          Treat it like a password. Anyone with this key can register a runner
          under <span class="font-semibold">{@current_account.name}</span>.
          <:install_command>
            curl -sSL {@base_url}/install.sh | sudo EMISAR_AUTH_KEY={@new_secret} EMISAR_URL={@base_url} bash
          </:install_command>
        </.secret_reveal>

        <%!-- Create panel — collapsed by default, opened by header
             button. Avoids a permanent form panel competing with the
             list when no key is being issued. --%>
        <section
          :if={Permissions.can?(assigns, :manage_auth_keys)}
          id="create-panel"
          class="hidden rounded-xl border border-zinc-900 bg-zinc-950/60 p-6"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-base font-semibold text-zinc-100">Issue a new auth key</h2>
              <p class="mt-1 text-sm text-zinc-500">
                Reusable keys suit stable fleets; single-use keys are right for autoscalers.
              </p>
            </div>
            <button
              type="button"
              phx-click={hide_create()}
              class="rounded-md p-1 text-zinc-500 hover:bg-zinc-900 hover:text-zinc-200"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
            </button>
          </div>

          <.simple_form
            for={@form}
            id="auth_key_form"
            phx-change="validate"
            phx-submit="create"
            class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2"
          >
            <.input
              field={@form[:description]}
              type="text"
              label="Description"
              placeholder="prod web tier"
            />
            <div>
              <.input
                field={@form[:group]}
                type="text"
                label="Group"
                placeholder="default"
              />
              <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
                Inherited as each registering runner's default group.
                Policies + API keys can target the group instead of one runner.
              </p>
            </div>
            <.input
              field={@form[:expires_at]}
              type="datetime-local"
              label="Expires at (UTC, optional)"
            />
            <div class="sm:col-span-2 flex items-center pb-2">
              <.input
                field={@form[:reusable]}
                type="checkbox"
                label="Reusable (many runners can register with this key)"
              />
            </div>
            <%!-- Max-uses only applies when Reusable is checked — single-
                 use keys self-cap at 1. Hiding it (vs disabling with a
                 disclaimer) follows the same progressive-disclosure rule
                 the agents wizard uses: don't ask irrelevant questions.
                 The field reappears with its inline hint as soon as the
                 reusable checkbox flips on. --%>
            <div
              :if={truthy?(@form[:reusable].value)}
              class="sm:col-span-2 grid grid-cols-1 sm:grid-cols-2 gap-4"
            >
              <.input
                field={@form[:max_uses]}
                type="number"
                min="1"
                label="Max uses"
                placeholder="unlimited"
              />
              <p class="text-xs leading-relaxed text-zinc-500 sm:self-end sm:pb-2">
                Caps how many runners can register before the key auto-revokes.
                Leave blank for unlimited.
              </p>
            </div>
            <:actions>
              <.button phx-disable-with="Creating...">Create key</.button>
            </:actions>
          </.simple_form>
        </section>

        <%!-- Key list — the LiveTable :cards shell renders the filter row, the
             bordered card list, and the count in its paginator footer, so this
             page matches audit / runs. The page heading is the dashboard_shell
             <:title> above — no extra section card around it. --%>
        <LiveTable.live_table
          layout={:cards}
          id="auth-keys"
          path={~p"/app/settings/runners/auth-keys"}
          rows={@auth_keys}
          metadata={@metadata}
          filters={@filters}
          filter_params={@filter_params}
        >
          <:item :let={key}>
            <li class="flex items-start gap-4 px-5 py-4">
              <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                <.icon name="hero-key" class="h-4 w-4" />
              </span>

              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="truncate font-medium text-zinc-100">
                    {key.description || "(no description)"}
                  </span>
                  <.chip>group: {key.group || "default"}</.chip>
                  <.chip :if={key.reusable} tone={:emerald}>Reusable</.chip>
                  <.chip :if={not key.reusable}>Single-use</.chip>
                  <.chip :if={key.revoked_at} tone={:rose}>Revoked</.chip>
                </div>
                <div class="mt-1 truncate font-mono text-[11px] text-zinc-500">
                  {key.key_prefix}… · {key.uses_count} {if key.uses_count == 1,
                    do: "use",
                    else: "uses"} ·
                  last used {last_used(key.last_used_at)}
                  <span :if={key.created_by}>· by {key.created_by.email}</span>
                </div>
              </div>

              <button
                :if={is_nil(key.revoked_at) and Permissions.can?(assigns, :manage_auth_keys)}
                phx-click="revoke"
                phx-value-id={key.id}
                data-confirm="Revoke this auth key? Existing runners aren't affected; new registrations will fail."
                class="shrink-0 rounded-lg border border-rose-500/40 px-2.5 py-1 text-xs font-medium text-rose-200 hover:bg-rose-500/10"
              >
                Revoke
              </button>
            </li>
          </:item>
          <:empty>
            <div class="mx-auto max-w-md">
              <.icon name="hero-key" class="mx-auto h-8 w-8 text-zinc-700" />
              <p class="mt-3 text-zinc-300">No auth keys yet.</p>
              <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                Auth keys are the bearer secret a fresh runner uses to register
                with cloud. Click
                <span class="rounded bg-zinc-900 px-1.5 py-0.5 text-[11px] font-medium text-zinc-300">
                  New key
                </span>
                above, then run the install command on the host.
              </p>
            </div>
          </:empty>
        </LiveTable.live_table>

        <p :if={not Permissions.can?(assigns, :manage_auth_keys)} class="text-xs text-zinc-500">
          Only owners and admins can issue or revoke auth keys.
        </p>
      </.page_container>
    </.dashboard_shell>
    """
  end

  defp show_create,
    do:
      JS.show(
        to: "#create-panel",
        transition: {"transition-all ease-out duration-150", "opacity-0", "opacity-100"}
      )

  defp hide_create,
    do:
      JS.hide(
        to: "#create-panel",
        transition: {"transition-all ease-in duration-100", "opacity-100", "opacity-0"}
      )
end
