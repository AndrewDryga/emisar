defmodule EmisarWeb.AuthKeysLive do
  use EmisarWeb, :live_view
  alias Emisar.Runners
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions, UrlHelpers}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    # Manage-only page (auth keys have no view-only permission): anyone
    # without manage lands on not-found at LOAD time, not on first submit.
    if Runners.subject_can_manage_auth_keys?(socket.assigns.current_subject) do
      # Subscribe to the per-account auth-keys topic so another operator's
      # create / revoke (or an auto-bind from a runner registration) reflows
      # this list without the viewer having to refresh.
      if connected?(socket),
        do: Runners.subscribe_account_auth_keys(socket.assigns.current_account.id)

      {:ok,
       socket
       |> assign(:page_title, "Runner keys")
       |> assign(:new_secret, nil)
       |> assign(:new_key, nil)
       |> assign(:base_url, UrlHelpers.derive_base_url(socket))
       # IL-18: only hit the billing read on the connected mount; the
       # cap-warning banner just stays hidden until it loads.
       |> assign(:billing, connected?(socket) && fetch_billing(socket))
       |> ConfirmDialog.init()
       |> assign_form(Runners.change_auth_key())}
    else
      {:ok,
       socket
       |> put_flash(:info, "Runner keys need an owner or admin role.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
    end
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
    changeset = Runners.change_auth_key(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"auth_key" => params}, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_auth_keys?(socket.assigns.current_subject),
      &do_create(&1, params)
    )
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_auth_keys?(socket.assigns.current_subject),
      &do_revoke(&1, id)
    )
  end

  # Typed-confirm state for the "Revoke auth key" dialog (UX friction only —
  # `revoke` above stays the server gate).
  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/runners/keys",
       params,
       Runners.AuthKey.Query.filters()
     )}
  end

  defp do_create(socket, params) do
    changeset = Runners.change_auth_key(params)

    if changeset.valid? do
      attrs =
        %{}
        |> put_if_present(:description, params["description"])
        |> Map.put(:reusable, truthy?(params["reusable"]))
        |> put_expires(params["expires_at"])
        |> put_max_uses(params["max_uses"])

      case Runners.create_auth_key(attrs, socket.assigns.current_subject) do
        {:ok, raw, key} ->
          {:noreply,
           socket
           |> put_flash(:info, "Runner key created. Copy it now — you won't see it again.")
           |> assign(:new_secret, raw)
           |> assign(:new_key, key)
           |> assign_form(Runners.change_auth_key())
           |> reload()}

        # Field errors (e.g. a DB constraint) render inline on the form.
        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    else
      {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
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
    # Revoked keys hide by default via the status filter's `%Filter{default:}` —
    # LiveTable resolves absent → "active" and keeps an explicit "All" in the
    # URL (apply_filter gets the filters below), so no param injection here.
    filters = Runners.AuthKey.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

    case Runners.list_auth_keys(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:created_by])
         ) do
      {:ok, auth_keys, meta} ->
        socket
        |> assign(:auth_keys, auth_keys)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      # A clean reload can fail too (e.g. the subject can't list keys) —
      # degrade to an empty list rather than recursing forever.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:auth_keys, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
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

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "auth_key"))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_expires(map, value) when value in [nil, ""], do: map

  defp put_expires(map, value) when is_binary(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, datetime, _} -> Map.put(map, :expires_at, datetime)
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
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runners}
      width={:table}
    >
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link> Runner keys
      </:title>
      <:actions :if={Runners.subject_can_manage_auth_keys?(@current_subject)}>
        <.button phx-click={show_create()} size={:md} icon="hero-plus">
          New key
        </.button>
      </:actions>

      <.page_intro>
        Enrollment keys register new hosts as runners — a single-use key is spent on first
        registration; a reusable key keeps enrolling hosts until it expires or hits its max-uses cap.
        <.doc_link href="/docs/runners">Runner setup docs</.doc_link>
      </.page_intro>

      <div class="space-y-6">
        <%!-- Runner-cap warning: a key minted here is useless if the
             runner that tries to use it bounces off a 402. --%>
        <.callout
          :if={@billing && Emisar.Billing.headroom(@billing, :runners) in [:warning, :at_limit]}
          tone={runner_cap_tone(@billing)}
          icon="hero-exclamation-triangle"
          title={runner_cap_title(@billing)}
        >
          {@billing.runner_count} of {@billing.runner_limit} runners in use.
          Issuing a key doesn't reserve a slot — the runner only counts after it registers.
          <:action>
            <.button
              variant={:secondary}
              size={:md}
              navigate={~p"/app/#{@current_account}/settings/billing"}
            >
              See plans →
            </.button>
          </:action>
        </.callout>

        <.secret_reveal
          :if={@new_secret}
          title="Copy this runner key now — it will not be shown again."
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
        <.panel
          :if={Runners.subject_can_manage_auth_keys?(@current_subject)}
          id="create-panel"
          class="hidden"
          padding="p-6"
          title="Issue a runner key"
        >
          <:subtitle>
            Reusable keys suit stable fleets; single-use keys are right for autoscalers.
          </:subtitle>
          <:actions>
            <.icon_button icon="hero-x-mark" label="Close" phx-click={hide_create()} />
          </:actions>

          <.simple_form
            for={@form}
            id="auth_key_form"
            phx-change="validate"
            phx-submit="create"
            class="grid grid-cols-1 gap-4 sm:grid-cols-2"
          >
            <.input
              field={@form[:description]}
              type="text"
              label="Description"
              placeholder="prod web tier"
            />
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
        </.panel>

        <%!-- Key list — the LiveTable :cards shell renders the filter row, the
             bordered card list, and the count in its paginator footer, so this
             page matches audit / runs. The page heading is the dashboard_shell
             <:title> above — no extra section card around it. --%>
        <LiveTable.live_table
          layout={:cards}
          id="auth-keys"
          path={~p"/app/#{@current_account}/runners/keys"}
          rows={@auth_keys}
          metadata={@metadata}
          filters={@filters}
          filter_params={@filter_params}
          wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
        >
          <%!-- Canvas rows; the per-row icon disc died with the island. --%>
          <:item :let={key}>
            <.list_row padding="py-4">
              <:title>
                <span class="truncate font-medium text-zinc-100">
                  {key.description || "(no description)"}
                </span>
              </:title>
              <:chips>
                <.chip :if={key.reusable}>reusable</.chip>
                <%!-- A reusable key with no expiry is a standing fleet-enrollment secret —
                     flag it amber so a long-lived multi-host credential isn't read as routine. --%>
                <.chip
                  :if={key.reusable and is_nil(key.expires_at) and is_nil(key.revoked_at)}
                  tone={:amber}
                >
                  no expiry
                </.chip>
                <.chip :if={not key.reusable}>single-use</.chip>
                <.chip :if={key.revoked_at} tone={:rose}>revoked</.chip>
              </:chips>
              <:meta>
                <.meta_line class="text-[11px]">
                  <:seg mono>{key.key_prefix}…</:seg>
                  <:seg>{key.uses_count} {if key.uses_count == 1, do: "use", else: "uses"}</:seg>
                  <:seg>
                    last used{" "}<.local_time
                      value={key.last_used_at}
                      mode={:relative}
                      placeholder="never"
                    />
                  </:seg>
                  <:seg :if={key.created_by}>by {key.created_by.email}</:seg>
                </.meta_line>
              </:meta>
              <:actions>
                <%!-- IRREVERSIBLE — typed-confirm modal instead of data-confirm.
                     The button only OPENS the dialog; `revoke` still fires from
                     Confirm and stays server-authz-gated (subject_can_manage_auth_keys?). --%>
                <.button
                  :if={
                    is_nil(key.revoked_at) and Runners.subject_can_manage_auth_keys?(@current_subject)
                  }
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  type="button"
                  phx-click={show_confirm_dialog("revoke-key-#{key.id}")}
                >
                  Revoke
                </.button>
                <.confirm_dialog
                  :if={is_nil(key.revoked_at)}
                  id={"revoke-key-#{key.id}"}
                  title="Revoke runner key"
                  confirm_label="Revoke key"
                  confirm_token={key.key_prefix}
                  typed={@typed}
                  on_confirm={
                    JS.push("revoke", value: %{id: key.id})
                    |> hide_confirm_dialog("revoke-key-#{key.id}")
                  }
                >
                  <:body>
                    Permanently revokes <span class="font-mono font-medium text-rose-100">{key.key_prefix}…</span>.
                    Existing runners aren't affected, but new registrations with this key will
                    fail. This can't be undone — issue a fresh key instead.
                  </:body>
                </.confirm_dialog>
              </:actions>
            </.list_row>
          </:item>
          <:empty>
            <.empty_state variant={:bare} icon="hero-key" title="No runner keys yet.">
              A runner key is the bearer secret a fresh host enrolls with — mint a
              reusable one for image bakes and cloud-init fleets. The install
              wizard's one-time keys appear here too, revocable until used.
              <.button
                :if={Runners.subject_can_manage_auth_keys?(@current_subject)}
                phx-click={show_create()}
                variant={:secondary}
                size={:sm}
                icon="hero-plus"
                class="mt-4"
              >
                New runner key
              </.button>
            </.empty_state>
          </:empty>
        </LiveTable.live_table>

        <p
          :if={not Runners.subject_can_manage_auth_keys?(@current_subject)}
          class="text-xs text-zinc-500"
        >
          Only owners and admins can issue or revoke runner keys.
        </p>
      </div>
    </.dashboard_shell>
    """
  end

  defp runner_cap_tone(billing) do
    if Emisar.Billing.headroom(billing, :runners) == :at_limit, do: :rose, else: :amber
  end

  defp runner_cap_title(billing) do
    if Emisar.Billing.headroom(billing, :runners) == :at_limit do
      "At runner limit — new installs will fail."
    else
      "One runner slot left on the #{String.capitalize(billing.plan)} plan."
    end
  end

  defp show_create do
    JS.show(
      to: "#create-panel",
      transition: {"transition-opacity ease-out duration-150", "opacity-0", "opacity-100"}
    )
  end

  defp hide_create do
    JS.hide(
      to: "#create-panel",
      transition: {"transition-opacity ease-in duration-100", "opacity-100", "opacity-0"}
    )
  end
end
