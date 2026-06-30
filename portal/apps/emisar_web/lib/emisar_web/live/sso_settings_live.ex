defmodule EmisarWeb.SSOSettingsLive do
  use EmisarWeb, :live_view
  alias Emisar.SSO
  alias EmisarWeb.{ConfirmDialog, Permissions}
  alias Phoenix.LiveView.JS

  # Humanized provider-kind labels for the select + the row badge — the enum's
  # atoms don't title-case cleanly ("openid_connect" → "OpenID Connect").
  @kind_labels %{
    google_workspace: "Google Workspace",
    okta: "Okta",
    jumpcloud: "JumpCloud",
    keycloak: "Keycloak",
    openid_connect: "OpenID Connect"
  }

  # The provider-kind select. `{label, value}` pairs from the schema's enum;
  # the value stays the atom's string form.
  @kind_options Enum.map(
                  SSO.IdentityProvider.kinds(),
                  &{Map.fetch!(@kind_labels, &1), Atom.to_string(&1)}
                )

  # Both the default-role and group→role selects OMIT :owner — neither JIT nor
  # directory sync may assign owner (the changeset rejects it too; owner is a
  # deliberate human grant). Don't offer what can't be chosen.
  @role_options Enum.map(
                  Emisar.Auth.Role.all() -- [:owner],
                  &{&1 |> Atom.to_string() |> String.capitalize(), Atom.to_string(&1)}
                )

  @mapping_role_options @role_options

  # New-user provisioning modes for the form's select. JIT auto-creates a user on
  # first sign-in; manual parks first sign-ins as pending requests an admin
  # approves. Bespoke prose labels, so a literal list (not capitalized atoms).
  @provisioner_options [
    {"Auto-provision new users on first sign-in", "jit"},
    {"Manual — an admin approves each new user", "manual"}
  ]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Single sign-on")
      |> assign(:can_configure?, SSO.subject_can_configure_sso?(socket.assigns.current_subject))
      |> assign(
        :can_configure_directory_sync?,
        SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject)
      )
      |> assign(:kind_options, @kind_options)
      |> assign(:role_options, @role_options)
      |> assign(:mapping_role_options, @mapping_role_options)
      |> assign(:provisioner_options, @provisioner_options)
      |> assign(:editing_id, nil)
      |> assign(:edit_form, nil)
      # Pending manual-link requests across the account — loaded on :index, where
      # the overview triages them (the detail page is config-only).
      |> assign(:pending_requests, [])
      # Connection(s) in scope: ALL on :index (a list), the one on :show (detail).
      # Set per-action in handle_params.
      |> assign(:providers, [])
      # Group→role mapping state: the per-provider lists + create forms, and the
      # single open inline edit (id + form). Keyed by provider id so each
      # provider's directory-sync panel owns its own mappings + form.
      |> assign(:group_mappings, %{})
      |> assign(:synced_groups, %{})
      |> assign(:mapping_forms, %{})
      |> assign(:editing_mapping_id, nil)
      |> assign(:mapping_edit_form, nil)
      |> assign(:scim_base_url, "#{Emisar.PublicUrl.base()}/scim/v2")
      # The fixed OIDC redirect URI the operator registers in their IdP — shown
      # in the per-provider setup guide so they paste the exact value.
      |> assign(:callback_url, "#{Emisar.PublicUrl.base()}/sign_in/sso/callback")
      # The branded sign-in URL to hand to members — absolute, slug-based (the
      # canonical UI form), so the admin can copy it straight into onboarding docs.
      |> assign(
        :sign_in_url,
        Emisar.PublicUrl.base() <> ~p"/app/#{socket.assigns.current_account}/sign_in"
      )
      # The freshly-minted SCIM token, shown ONCE: `%{provider_id, token}` or
      # nil. Never re-rendered from a stored value — write-only, like every
      # emisar secret.
      |> assign(:scim_token, nil)
      # False until the connected mount pass runs the list read — so the
      # "No connections yet" empty state never flashes for a team that *has*
      # connections (the first, unconnected pass renders chrome only).
      |> assign(:loaded?, false)
      |> ConfirmDialog.init()

    {:ok, socket}
  end

  # Action-dependent data loads. mount runs before the action is settled for live
  # nav, and handle_params re-fires on navigation, so the per-action read lives
  # here. IL-18: the DB reads run only once connected; the dead pass renders chrome.
  def handle_params(params, _uri, socket) do
    {:noreply, load_for_action(socket, params)}
  end

  defp load_for_action(%{assigns: %{can_configure?: false}} = socket, _params), do: socket

  defp load_for_action(socket, params) do
    if connected?(socket) do
      case socket.assigns.live_action do
        :index -> load_index(socket)
        :show -> load_show(socket, params["id"])
        :new -> assign_form(socket, SSO.change_provider())
      end
    else
      # A synchronous changeset (no DB read) so /new renders on the dead pass.
      assign_form(socket, SSO.change_provider())
    end
  end

  # Overview: ALL connections + the account-wide pending requests (the
  # needs-attention block). No per-connection scim/mapping load — that's :show.
  defp load_index(socket) do
    socket
    |> assign(:loaded?, true)
    |> assign(:providers, list_providers(socket))
    |> assign(:pending_requests, list_pending_requests(socket))
  end

  # Detail: ONE connection (account-scoped — a cross-account or unknown id is
  # not_found → back to the overview) + its group→role mappings / synced groups.
  defp load_show(socket, id) do
    case SSO.fetch_provider_by_id(id, socket.assigns.current_subject) do
      {:ok, provider} ->
        socket
        |> assign(:loaded?, true)
        |> assign(:providers, [provider])
        |> load_group_mappings([provider])
        |> assign_form(SSO.change_provider())

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Connection not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/sso")
    end
  end

  defp list_pending_requests(socket) do
    case SSO.list_pending_link_requests_for_account(socket.assigns.current_subject) do
      {:ok, requests, _meta} -> requests
      {:error, _} -> []
    end
  end

  defp list_providers(socket) do
    case SSO.list_providers_for_account(socket.assigns.current_subject) do
      {:ok, providers, _meta} -> providers
      {:error, _} -> []
    end
  end

  # Group→role mappings only exist for SCIM-enabled providers; load each one's
  # list + seed a fresh create form, both keyed by provider id.
  defp load_group_mappings(socket, providers) do
    scim_providers = Enum.filter(providers, & &1.scim_enabled)

    mappings =
      Map.new(scim_providers, fn provider ->
        {provider.id, list_mappings(socket, provider)}
      end)

    # The external group ids the IdP has actually synced — the map-after-first-
    # sync picker, so an admin keys a mapping on a real group, not a guessed id.
    synced =
      Map.new(scim_providers, fn provider ->
        {provider.id, list_synced_groups(socket, provider)}
      end)

    forms = Map.new(scim_providers, &{&1.id, mapping_form(&1)})

    socket
    |> assign(:group_mappings, mappings)
    |> assign(:synced_groups, synced)
    |> assign(:mapping_forms, forms)
  end

  defp list_synced_groups(socket, provider) do
    case SSO.list_synced_groups(provider, socket.assigns.current_subject) do
      {:ok, groups} -> groups
      {:error, _} -> []
    end
  end

  defp list_mappings(socket, provider) do
    case SSO.list_group_mappings(provider, socket.assigns.current_subject) do
      {:ok, mappings, _meta} -> mappings
      {:error, _} -> []
    end
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      SSO.change_provider(%SSO.IdentityProvider{}, params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"provider" => params}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_create(&1, params))
  end

  def handle_event("start_edit", %{"id" => id}, socket) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply,
         socket
         |> assign(:editing_id, id)
         |> assign(:edit_form, edit_form(provider))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}
  end

  def handle_event("validate_edit", %{"provider_id" => id, "provider" => params}, socket) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply, assign(socket, :edit_form, edit_form(provider, params, :validate))}
    end
  end

  def handle_event("update", %{"provider_id" => id, "provider" => params}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_update(&1, id, params))
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_delete(&1, id))
  end

  # -- Directory sync (SCIM) ------------------------------------------

  def handle_event("enable_scim", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_enable_scim(&1, id)
    )
  end

  def handle_event("rotate_scim", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_rotate_scim(&1, id)
    )
  end

  def handle_event("disable_scim", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_disable_scim(&1, id)
    )
  end

  def handle_event("dismiss_scim_token", _params, socket) do
    {:noreply, assign(socket, :scim_token, nil)}
  end

  # -- Group → role mapping -------------------------------------------

  def handle_event("validate_mapping", %{"provider_id" => id, "mapping" => params}, socket) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        changeset = mapping_changeset(provider, params) |> Map.put(:action, :validate)
        {:noreply, put_mapping_form(socket, id, mapping_to_form(provider, changeset))}
    end
  end

  def handle_event("create_mapping", %{"provider_id" => id, "mapping" => params}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_create_mapping(&1, id, params)
    )
  end

  def handle_event("start_edit_mapping", %{"id" => id}, socket) do
    case find_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        {:noreply,
         socket
         |> assign(:editing_mapping_id, id)
         |> assign(:mapping_edit_form, mapping_edit_form(mapping))}
    end
  end

  def handle_event("cancel_edit_mapping", _params, socket) do
    {:noreply, socket |> assign(:editing_mapping_id, nil) |> assign(:mapping_edit_form, nil)}
  end

  def handle_event("validate_edit_mapping", %{"mapping_id" => id, "mapping" => params}, socket) do
    case find_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        {:noreply, assign(socket, :mapping_edit_form, mapping_edit_form(mapping, params))}
    end
  end

  def handle_event("update_mapping", %{"mapping_id" => id, "mapping" => params}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_update_mapping(&1, id, params)
    )
  end

  def handle_event("delete_mapping", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_delete_mapping(&1, id)
    )
  end

  # -- Manual link requests -------------------------------------------

  def handle_event("approve_request", %{"id" => id}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_approve_request(&1, id))
  end

  def handle_event("dismiss_request", %{"id" => id}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_dismiss_request(&1, id))
  end

  # Typed-confirm state for the "Delete connection" dialog (UX friction only —
  # `delete` above stays the server gate).
  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  # No-op for the on_mount badge/fleet hooks' broadcasts (approvals, packs,
  # runner presence). Those nav cues are owned by the hooks; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp do_create(socket, params) do
    case SSO.configure_provider(strip_blank_secret(params), socket.assigns.current_subject) do
      {:ok, provider} ->
        # Adding is its own view; return to the connection list (a fresh mount
        # there reloads the providers, so no explicit reload here).
        {:noreply,
         socket
         |> put_flash(:info, "Single sign-on connection \"#{provider.name}\" added.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/sso")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp do_update(socket, id, params) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        case SSO.update_provider(
               provider,
               strip_blank_secret(params),
               socket.assigns.current_subject
             ) do
          {:ok, _provider} ->
            {:noreply,
             socket
             |> put_flash(:info, "Connection updated.")
             |> assign(:editing_id, nil)
             |> assign(:edit_form, nil)
             |> reload()}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, assign(socket, :edit_form, edit_form(provider, params, :insert))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_delete(socket, id) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        case SSO.delete_provider(provider, socket.assigns.current_subject) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Connection deleted.")
             |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/sso")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  # enable_scim / rotate_scim_token both mint a fresh token and return it
  # once; disable clears it. The raw token is stashed in `:scim_token` for the
  # one-time reveal and never read back from the provider.
  defp do_enable_scim(socket, id) do
    with_provider(socket, id, fn provider ->
      case SSO.enable_scim(provider, socket.assigns.current_subject) do
        {:ok, provider, raw} -> token_revealed(socket, provider, raw, "Directory sync enabled.")
        {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp do_rotate_scim(socket, id) do
    with_provider(socket, id, fn provider ->
      case SSO.rotate_scim_token(provider, socket.assigns.current_subject) do
        {:ok, provider, raw} -> token_revealed(socket, provider, raw, "SCIM token rotated.")
        {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp do_disable_scim(socket, id) do
    with_provider(socket, id, fn provider ->
      case SSO.disable_scim(provider, socket.assigns.current_subject) do
        {:ok, _provider} ->
          {:noreply,
           socket
           |> put_flash(:info, "Directory sync disabled.")
           |> assign(:scim_token, nil)
           |> reload()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp token_revealed(socket, provider, raw, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign(:scim_token, %{provider_id: provider.id, token: raw})
     |> reload()}
  end

  defp with_provider(socket, id, fun) do
    case find_provider(socket, id) do
      nil -> {:noreply, socket}
      provider -> fun.(provider)
    end
  end

  defp do_create_mapping(socket, provider_id, params) do
    with_provider(socket, provider_id, fn provider ->
      case SSO.create_group_mapping(provider, params, socket.assigns.current_subject) do
        {:ok, _mapping} ->
          {:noreply,
           socket
           |> put_flash(:info, "Group mapping added.")
           |> put_mapping_form(provider_id, mapping_form(provider))
           |> reload_mappings(provider)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, put_mapping_form(socket, provider_id, mapping_to_form(provider, changeset))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp do_update_mapping(socket, id, params) do
    case find_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        case SSO.update_group_mapping(mapping, params, socket.assigns.current_subject) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Group mapping updated.")
             |> assign(:editing_mapping_id, nil)
             |> assign(:mapping_edit_form, nil)
             |> reload_mappings_for_id(updated.provider_id)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :mapping_edit_form, mapping_edit_form(mapping, changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_delete_mapping(socket, id) do
    case find_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        case SSO.delete_group_mapping(mapping, socket.assigns.current_subject) do
          {:ok, deleted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Group mapping deleted.")
             |> reload_mappings_for_id(deleted.provider_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_approve_request(socket, id) do
    with_request(socket, id, fn request ->
      case SSO.approve_link_request(request, socket.assigns.current_subject) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{request_label(request)} approved — they can sign in now.")
           |> reload()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp do_dismiss_request(socket, id) do
    with_request(socket, id, fn request ->
      case SSO.dismiss_link_request(request, socket.assigns.current_subject) do
        {:ok, _request} ->
          {:noreply, socket |> put_flash(:info, "Access request dismissed.") |> reload()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp with_request(socket, id, fun) do
    case find_request(socket, id) do
      nil -> {:noreply, socket}
      request -> fun.(request)
    end
  end

  # A full reload after a provider mutation: refresh the connection list, the
  # group→role mappings, AND the pending manual-link requests — so enabling
  # directory sync (re)seeds a provider's panels, and approving/dismissing a
  # request drops it from the list.
  defp reload(socket) do
    case socket.assigns.live_action do
      :index -> load_index(socket)
      :show -> reload_show(socket)
    end
  end

  # Re-fetch the one connection :show is on (its row may have changed — SCIM
  # toggled, edited). If it vanished (deleted), load_show falls back to the overview.
  defp reload_show(socket) do
    case socket.assigns.providers do
      [provider | _] -> load_show(socket, provider.id)
      _ -> socket
    end
  end

  # Refresh just one provider's mapping list (after a mapping CRUD), leaving the
  # other providers' panels untouched.
  defp reload_mappings(socket, provider),
    do: put_mappings(socket, provider.id, list_mappings(socket, provider))

  defp reload_mappings_for_id(socket, provider_id) do
    case find_provider(socket, provider_id) do
      nil -> socket
      provider -> reload_mappings(socket, provider)
    end
  end

  defp put_mappings(socket, provider_id, mappings) do
    assign(
      socket,
      :group_mappings,
      Map.put(socket.assigns.group_mappings, provider_id, mappings)
    )
  end

  defp put_mapping_form(socket, provider_id, form),
    do: assign(socket, :mapping_forms, Map.put(socket.assigns.mapping_forms, provider_id, form))

  defp find_provider(socket, id), do: Enum.find(socket.assigns.providers, &(&1.id == id))

  defp find_mapping(socket, id) do
    socket.assigns.group_mappings
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == id))
  end

  defp find_request(socket, id), do: Enum.find(socket.assigns.pending_requests, &(&1.id == id))

  # The create-form changeset for a provider's mapping. Built over
  # The context's form builder — phx-change validation (required fields + the
  # owner-exclusion) matches the server create path exactly. account_id /
  # provider_id come from the provider whose panel owns the form.
  defp mapping_changeset(provider, params \\ %{}),
    do: SSO.change_group_mapping(provider, params)

  defp mapping_form(provider), do: mapping_to_form(provider, mapping_changeset(provider))

  defp mapping_to_form(provider, %Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: "mapping", id: "create-mapping-#{provider.id}")

  # The inline edit form for one mapping. Accepts raw phx-change params (a map)
  # or a rejected changeset (on a failed update — surfaces the owner error
  # inline). Built over `update/2` so only the editable fields (display, role)
  # are cast.
  defp mapping_edit_form(mapping, params_or_changeset \\ %{})

  defp mapping_edit_form(mapping, %Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: "mapping", id: "edit-mapping-#{mapping.id}")

  defp mapping_edit_form(mapping, params) do
    changeset =
      mapping
      |> SSO.change_group_mapping(params)
      |> Map.put(:action, :validate)

    to_form(changeset, as: "mapping", id: "edit-mapping-#{mapping.id}")
  end

  # An empty client_secret on submit means "leave the stored one" (write-only
  # field): drop the key so the changeset doesn't clobber the secret with "".
  defp strip_blank_secret(%{"client_secret" => secret} = params) when secret in ["", nil],
    do: Map.delete(params, "client_secret")

  defp strip_blank_secret(params), do: params

  defp error_message(:sso_not_available), do: "Single sign-on requires an Enterprise plan."
  defp error_message(:unauthorized), do: "You don't have permission to configure single sign-on."
  defp error_message(:not_found), do: "That no longer exists — it may have just been removed."

  defp error_message(:require_sso_last_provider) do
    "This is the only active SSO connection and the account requires single sign-on. Turn off the SSO requirement (Team → Single sign-on) before disabling or deleting it."
  end

  defp error_message(:email_taken) do
    "A user with that email already exists. Approving would create a duplicate, so this request can't be auto-approved."
  end

  defp error_message(_) do
    "That action didn't complete. Refresh to see the connection's current state, then try again."
  end

  # The create form and any open inline edit form coexist in the DOM, so each
  # gets its own `id` — otherwise their inputs collide on `provider_<field>`.
  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "provider", id: "create-provider"))

  # The inline edit form. client_secret is WRITE-ONLY — the display data has
  # its stored value cleared so the password input is never pre-filled with the
  # real secret; a typed value still shows (it lands in the changeset's
  # `changes`, which `Phoenix.HTML.Form` prefers over the data). The actual
  # `update_provider` runs against the real struct, so leaving the field blank
  # keeps the stored secret (see `strip_blank_secret/1`).
  defp edit_form(provider, params \\ %{}, action \\ nil) do
    changeset =
      %{provider | client_secret: nil}
      |> SSO.change_provider(params)
      |> maybe_put_action(action)

    to_form(changeset, as: "provider", id: "edit-provider-#{provider.id}")
  end

  defp maybe_put_action(changeset, nil), do: changeset
  defp maybe_put_action(changeset, action), do: Map.put(changeset, :action, action)

  defp kind_label(kind), do: Map.fetch!(@kind_labels, kind)

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
      section={:sso}
      width={:settings}
    >
      <:title>Single sign-on</:title>
      <:actions :if={@can_configure? and @live_action == :index}>
        <.button navigate={~p"/app/#{@current_account}/settings/sso/new"} size="md" icon="hero-plus">
          Add connection
        </.button>
      </:actions>

      <div :if={not @can_configure?}>
        <.locked current_account={@current_account} />
      </div>

      <div :if={@can_configure?} class="space-y-6">
        <.page_intro :if={@live_action == :index}>
          Connect your organization's identity provider so members sign in through it. New
          users are provisioned on first sign-in; you choose the role they land with.
          <.doc_link href="/docs/sso">Single sign-on docs</.doc_link>
        </.page_intro>

        <%!-- The branded sign-in link to hand to the team. Always useful (the page
             offers email sign-in even with no SSO), so it's not gated on providers. --%>
        <.card :if={@live_action == :index} padding="p-5">
          <p class="text-sm font-medium text-zinc-200">Your team's sign-in link</p>
          <p class="mt-1 text-xs leading-relaxed text-zinc-500">
            Share this with your members — it opens this team's sign-in page with your SSO
            connections (and email sign-in as a fallback).
          </p>
          <div class="mt-3 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-2 ring-1 ring-zinc-800">
            <code id="sso-sign-in-link" class="flex-1 break-all font-mono text-xs text-zinc-300">
              {@sign_in_url}
            </code>
            <.copy_button target="#sso-sign-in-link">Copy</.copy_button>
          </div>
        </.card>

        <%!-- Adding a connection is its own view (/settings/sso/new) so the form
             + per-provider setup guide get the full width and don't compete with
             the connection list. --%>
        <.panel :if={@live_action == :new} padding="p-6" title="Add an identity provider">
          <:subtitle>
            We'll use the issuer's OIDC discovery document. Follow the steps below to create an
            OAuth/OIDC app at your provider, then paste its client ID and secret.
          </:subtitle>
          <:actions>
            <.button navigate={~p"/app/#{@current_account}/settings/sso"} variant="ghost" size="sm">
              Back to connections
            </.button>
          </:actions>

          <.simple_form
            :if={@form}
            for={@form}
            id="provider_form"
            phx-change="validate"
            phx-submit="create"
          >
            <.provider_fields
              form={@form}
              kind_options={@kind_options}
              role_options={@role_options}
              provisioner_options={@provisioner_options}
              guide_id="new"
              callback_url={@callback_url}
            />
            <:actions>
              <.button phx-disable-with="Saving...">Add connection</.button>
            </:actions>
          </.simple_form>
        </.panel>

        <%!-- ── Pending access requests (needs attention) ──────────────────
             People blocked waiting for an admin, across ALL connections. The
             time-sensitive job, so it leads the overview. --%>
        <section :if={@live_action == :index and @pending_requests != []}>
          <.section_header
            title="Pending access requests"
            count={length(@pending_requests)}
            count_tone={:amber}
          />
          <.card padding="p-0">
            <ul class="divide-y divide-zinc-900">
              <li
                :for={request <- @pending_requests}
                class="flex flex-wrap items-center justify-between gap-3 px-5 py-3.5"
              >
                <div class="min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="truncate text-sm text-zinc-200">
                      {request.full_name || request.email || "Unknown user"}
                    </span>
                    <.chip :if={request.matched_user_id} tone={:amber}>Existing account</.chip>
                  </div>
                  <div class="mt-0.5 truncate text-xs text-zinc-500">
                    <span :if={request.email}>{request.email}</span>
                    <span :if={request.email} class="text-zinc-600">·</span>
                    <span class="font-mono">{request.provider_identifier}</span>
                  </div>
                  <p :if={request.matched_user_id} class="mt-1 max-w-prose text-xs text-amber-300/80">
                    Approving lets this connection sign in as the existing {request.email} account.
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-2">
                  <.button
                    variant="secondary"
                    size="sm"
                    phx-click="approve_request"
                    phx-value-id={request.id}
                    data-confirm={approve_confirm(request)}
                  >
                    Approve
                  </.button>
                  <.button
                    variant="ghost"
                    tone="danger"
                    size="sm"
                    phx-click="dismiss_request"
                    phx-value-id={request.id}
                    data-confirm="Dismiss this access request? They'll need to sign in again to re-request."
                  >
                    Dismiss
                  </.button>
                </div>
              </li>
            </ul>
          </.card>
        </section>

        <%!-- ── Connections (overview) ──────────────────────────────────────
             A bounded set; each row is a SUMMARY that opens its own detail page.
             Config (edit, SCIM, group→role) lives on the detail, not here. --%>
        <section :if={@live_action == :index}>
          <.section_header title="Connections" count={length(@providers)} count_tone={:neutral} />

          <.card :if={@providers != []} padding="p-0">
            <ul class="divide-y divide-zinc-900">
              <li :for={provider <- @providers}>
                <.link
                  navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
                  class="flex items-center gap-4 px-5 py-4 transition-colors hover:bg-zinc-900/40"
                >
                  <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                    <.icon name="hero-key" class="h-4 w-4" />
                  </span>
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="truncate font-medium text-zinc-100">{provider.name}</span>
                      <.chip>{kind_label(provider.kind)}</.chip>
                      <.chip :if={provider.enabled} tone={:brand}>Enabled</.chip>
                      <.chip :if={not provider.enabled} tone={:amber}>Disabled</.chip>
                      <.chip :if={provider.scim_enabled}>Directory sync</.chip>
                    </div>
                    <div class="mt-1 truncate text-xs text-zinc-500">
                      {provider.issuer} · {provisioner_label(provider.provisioner)}
                    </div>
                  </div>
                  <.icon name="hero-chevron-right" class="h-4 w-4 shrink-0 text-zinc-600" />
                </.link>
              </li>
            </ul>
          </.card>

          <.empty_state :if={@loaded? and @providers == []} icon="hero-key" title="No connections yet">
            Connect your identity provider to let your team sign in through it. You'll need an
            OAuth/OIDC app at your provider with its client ID and secret.
            <:cta navigate={~p"/app/#{@current_account}/settings/sso/new"}>Add connection</:cta>
          </.empty_state>
        </section>

        <%!-- ── Connection detail (/settings/sso/:id) ───────────────────────
             One connection: identity + status + config (edit, directory sync,
             group→role). @providers holds exactly the one handle_params loaded. --%>
        <div :if={@live_action == :show} class="space-y-6">
          <.link
            navigate={~p"/app/#{@current_account}/settings/sso"}
            class="inline-flex items-center gap-1 text-sm text-zinc-400 hover:text-zinc-200"
          >
            <.icon name="hero-arrow-left" class="h-4 w-4" /> Connections
          </.link>

          <div :for={provider <- @providers} class="space-y-6">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <h2 class="truncate text-lg font-semibold text-zinc-100">{provider.name}</h2>
                  <.chip>{kind_label(provider.kind)}</.chip>
                  <.chip :if={provider.enabled} tone={:brand}>Enabled</.chip>
                  <.chip :if={not provider.enabled} tone={:amber}>Disabled</.chip>
                </div>
                <p class="mt-1 truncate text-xs text-zinc-500">
                  {provider.issuer}
                  <span :if={provider.allowed_email_domain}>· @{provider.allowed_email_domain}</span>
                  · {provisioner_label(provider.provisioner)}
                </p>
              </div>
              <div class="flex shrink-0 items-center gap-2">
                <.button
                  :if={@editing_id != provider.id}
                  variant="secondary"
                  size="sm"
                  phx-click="start_edit"
                  phx-value-id={provider.id}
                >
                  Edit
                </.button>
                <.button
                  variant="ghost"
                  tone="danger"
                  size="sm"
                  type="button"
                  phx-click={show_confirm_dialog("delete-provider-#{provider.id}")}
                >
                  Delete
                </.button>
              </div>
            </div>

            <div
              :if={@editing_id == provider.id and @edit_form}
              class="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4"
            >
              <.simple_form
                for={@edit_form}
                id={"edit-provider-#{provider.id}"}
                phx-change="validate_edit"
                phx-submit="update"
              >
                <input type="hidden" name="provider_id" value={provider.id} />
                <.provider_fields
                  form={@edit_form}
                  kind_options={@kind_options}
                  role_options={@role_options}
                  provisioner_options={@provisioner_options}
                  guide_id={provider.id}
                  callback_url={@callback_url}
                  editing?
                />
                <:actions>
                  <.button phx-disable-with="Saving...">Save changes</.button>
                  <.button variant="ghost" type="button" phx-click="cancel_edit">Cancel</.button>
                </:actions>
              </.simple_form>
            </div>

            <.scim_panel
              :if={@can_configure_directory_sync?}
              provider={provider}
              scim_base_url={@scim_base_url}
              scim_token={@scim_token}
              mappings={Map.get(@group_mappings, provider.id, [])}
              synced_groups={Map.get(@synced_groups, provider.id, [])}
              mapping_form={Map.get(@mapping_forms, provider.id)}
              mapping_role_options={@mapping_role_options}
              editing_mapping_id={@editing_mapping_id}
              mapping_edit_form={@mapping_edit_form}
              typed={@typed}
            />
            <div
              :if={!@can_configure_directory_sync?}
              class="rounded-lg border border-zinc-800 bg-zinc-950/40 p-4 text-sm leading-relaxed text-zinc-400"
            >
              <span class="font-medium text-zinc-200">SCIM directory sync</span>
              — automatic provisioning and offboarding from your IdP, plus group→role mapping —
              is available on the Enterprise plan.
              <.link navigate={~p"/pricing"} class="font-medium text-brand-400 hover:text-brand-300">
                See plans
              </.link>
              or <a
                href="mailto:sales@emisar.dev"
                class="font-medium text-brand-400 hover:text-brand-300"
              >talk to us</a>.
            </div>

            <.confirm_dialog
              id={"delete-provider-#{provider.id}"}
              title="Delete connection"
              confirm_label="Delete connection"
              confirm_token={provider.name}
              typed={@typed}
              on_confirm={
                JS.push("delete", value: %{id: provider.id})
                |> hide_confirm_dialog("delete-provider-#{provider.id}")
              }
            >
              <:body>
                Permanently removes the <span class="font-medium text-rose-100">{provider.name}</span>
                connection. Members who sign in only through it lose access until it's re-added.
                Existing sessions aren't ended. This can't be undone.
              </:body>
            </.confirm_dialog>
          </div>

          <div :if={not @loaded?} class="text-sm text-zinc-500">Loading…</div>
        </div>
      </div>
    </.dashboard_shell>
    """
  end

  # The Enterprise upsell shown to anyone who can't configure SSO — a member
  # without manage_sso, or any account below the Enterprise plan. Never crashes;
  # the gate is also re-checked in every handler.
  attr :current_account, :map, required: true

  defp locked(assigns) do
    ~H"""
    <.empty_state icon="hero-lock-closed" title="Single sign-on is a paid feature">
      Connect Okta, Google Workspace, Keycloak, or any OIDC provider so your team signs in
      through it — with just-in-time provisioning and per-provider MFA. Available on the
      Team and Enterprise plans (SCIM directory sync is Enterprise).
      <:cta navigate={~p"/app/#{@current_account}/settings/billing"}>See plans</:cta>
    </.empty_state>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :kind_options, :list, required: true
  attr :role_options, :list, required: true
  attr :provisioner_options, :list, required: true
  attr :guide_id, :string, required: true
  attr :callback_url, :string, required: true
  attr :editing?, :boolean, default: false

  defp provider_fields(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
      <.input field={@form[:kind]} type="select" label="Provider type" options={@kind_options} />
      <.input field={@form[:name]} type="text" label="Display name" placeholder="Acme Okta" />
      <%!-- Setup steps for the SELECTED provider, right under the dropdown that
           drives them — pick a provider, then read what to create + paste. --%>
      <div class="sm:col-span-2">
        <.provider_setup_guide
          id={@guide_id}
          kind={form_kind(@form, @kind_options)}
          callback_url={@callback_url}
        />
      </div>
      <div class="sm:col-span-2">
        <.input
          field={@form[:issuer]}
          type="url"
          label="Issuer URL"
          placeholder="https://acme.okta.com"
          class="font-mono"
        />
        <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
          The OIDC issuer — its discovery document is fetched from here. Must be HTTPS.
        </p>
      </div>
      <.input field={@form[:client_id]} type="text" label="Client ID" />
      <.input
        field={@form[:client_secret]}
        type="password"
        label="Client secret"
        placeholder={if @editing?, do: "Leave blank to keep current", else: nil}
        autocomplete="off"
      />
      <div class="sm:col-span-2">
        <.input
          field={@form[:provisioner]}
          type="select"
          label="New-user provisioning"
          options={@provisioner_options}
        />
        <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
          <span class="font-medium text-zinc-400">Auto-provision</span>
          creates a user on first sign-in. <span class="font-medium text-zinc-400">Manual</span>
          holds first-time sign-ins as pending requests for an admin to approve. Either way
          they land at the default role below.
        </p>
      </div>
      <div>
        <.input
          field={@form[:identifier_claim]}
          type="select"
          label="Identifier claim"
          options={[{"sub — OIDC standard", "sub"}, {"oid — Microsoft Entra", "oid"}]}
        />
        <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
          The stable, provider-issued claim that identifies a user — restricted to immutable
          subject identifiers (a mutable claim like email would allow account takeover). Leave
          as <code>sub</code> unless your provider (e.g. Microsoft Entra) requires <code>oid</code>.
        </p>
      </div>
      <.input
        field={@form[:default_role]}
        type="select"
        label="Default role for new users"
        options={@role_options}
      />
      <div class="sm:col-span-2">
        <.input
          field={@form[:allowed_email_domain]}
          type="text"
          label="Allowed email domain (optional)"
          placeholder="acme.com"
        />
        <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
          Restricts sign-in to verified emails on this domain and routes that domain's
          sign-ins here. Leave blank to accept any address the provider asserts.
        </p>
      </div>
      <div class="space-y-3 sm:col-span-2">
        <div>
          <.input
            field={@form[:satisfies_mfa]}
            type="checkbox"
            label="Sign-in through this provider satisfies the account's 2FA requirement"
          />
          <p class="mt-1 text-[11px] leading-relaxed text-amber-300/80">
            Only enable if this provider enforces MFA itself — otherwise members who sign in
            through it bypass your 2FA requirement.
          </p>
        </div>
        <.input
          field={@form[:enabled]}
          type="checkbox"
          label="Enabled (members can sign in through this connection)"
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :callback_url, :string, required: true

  # Per-provider OIDC setup steps shown beside the form — the operator reads
  # what to create in their IdP and what to paste here. The redirect URI is the
  # one value they register on the IdP side (we never accept it from them — H2).
  defp provider_setup_guide(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
      <p class="text-sm font-medium text-zinc-200">Setting up {setup_kind_label(@kind)}</p>
      <ol class="mt-3 space-y-3 text-xs leading-relaxed text-zinc-400">
        <li>
          <span class="font-semibold text-zinc-300">1.</span>
          Create an OAuth / OIDC <span class="text-zinc-300">web app</span> {oidc_app_hint(@kind)}.
        </li>
        <li>
          <span class="font-semibold text-zinc-300">2.</span>
          Register this <span class="text-zinc-300">redirect URI</span>
          on the app:
          <div class="mt-1.5 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-2 ring-1 ring-zinc-800">
            <code id={"sso-callback-#{@id}"} class="flex-1 break-all font-mono text-zinc-300">
              {@callback_url}
            </code>
            <.copy_button target={"#sso-callback-#{@id}"}>Copy</.copy_button>
          </div>
        </li>
        <li>
          <span class="font-semibold text-zinc-300">3.</span>
          Set the <span class="text-zinc-300">Issuer URL</span>
          below to <span class="font-mono text-zinc-300">{issuer_hint(@kind)}</span>.
          <span class="text-zinc-500">{issuer_where_hint(@kind)}</span>
        </li>
        <li>
          <span class="font-semibold text-zinc-300">4.</span>
          Paste the app's <span class="text-zinc-300">Client ID</span>
          and <span class="text-zinc-300">Client secret</span>
          into the fields below.
        </li>
      </ol>
      <p class="mt-3 text-xs leading-relaxed text-zinc-500">
        Leave <span class="text-zinc-400">DPoP</span> (sender-constrained tokens) OFF. emisar
        reads the ID token only and never presents the access token to an API, so DPoP adds no
        security here and turning it on would break the token request.
      </p>
    </div>
    """
  end

  defp setup_kind_label("google_workspace"), do: "Google Workspace"
  defp setup_kind_label("okta"), do: "Okta"
  defp setup_kind_label("jumpcloud"), do: "JumpCloud"
  defp setup_kind_label("keycloak"), do: "Keycloak"
  defp setup_kind_label(_), do: "a generic OIDC provider"

  defp oidc_app_hint("google_workspace") do
    "in Google Cloud Console → APIs & Services → Credentials → Create OAuth client ID (Web application)"
  end

  defp oidc_app_hint("okta") do
    "in the Okta admin console → Applications → Create App Integration → OIDC, Web Application"
  end

  defp oidc_app_hint("jumpcloud") do
    "in the JumpCloud admin console → SSO Applications → Add New Application → Custom Application, with the OIDC connector enabled"
  end

  defp oidc_app_hint("keycloak") do
    "in the Keycloak admin console → Clients → Create client → OpenID Connect (enable Client authentication)"
  end

  defp oidc_app_hint(_), do: "with your provider — a confidential web client with a client secret"

  defp issuer_hint("google_workspace"), do: "https://accounts.google.com"
  defp issuer_hint("okta"), do: "https://YOUR-ORG.okta.com"
  defp issuer_hint("jumpcloud"), do: "https://oauth.id.jumpcloud.com/"
  defp issuer_hint("keycloak"), do: "https://YOUR-HOST/realms/YOUR-REALM"
  defp issuer_hint(_), do: "your provider's OIDC issuer URL (the discovery base)"

  # Where to FIND the issuer — it's an org/realm-level value, not on the app
  # page, which is the usual point of confusion.
  defp issuer_where_hint("okta") do
    "It's your Okta org URL — the domain you use for the admin console, not a per-app field. Use the ORG authorization server (Security → API → Authorization Servers, the org row's Issuer URI), not a custom one: that keeps the OIDC `sub` equal to the Okta user id, which is exactly what SCIM provisions on, so sign-in and directory sync converge on one identity."
  end

  defp issuer_where_hint("jumpcloud") do
    "Always this exact value for JumpCloud — including the trailing slash. JumpCloud echoes back the `externalId` SCIM sent, so the OIDC `sub` and the SCIM identity converge automatically; nothing to look up."
  end

  defp issuer_where_hint("google_workspace"),
    do: "Always this exact value for Google — nothing to look up."

  defp issuer_where_hint("keycloak") do
    "Your realm's base URL; Realm settings → Endpoints → OpenID Endpoint Configuration confirms the exact value."
  end

  defp issuer_where_hint(_) do
    "Whatever URL serves its OIDC discovery document at /.well-known/openid-configuration — emisar fetches it from there."
  end

  defp scim_location_hint(:okta) do
    "in a SEPARATE Okta app — Okta's OIDC login app can't do SCIM. Add the \"SCIM 2.0 Test App (Header Auth)\" from the OIN catalog (its Sign-On tab is unused — SCIM lives entirely on the Provisioning tab): Configure API Integration → Enable, set the Base URL to the value above and paste the `ems-` token as the API token, then enable Create / Update / Deactivate. Okta sends the token as a raw header with no `Bearer` scheme, which emisar accepts"
  end

  defp scim_location_hint(:jumpcloud) do
    "on the same JumpCloud app — add a \"Custom SCIM\" identity-management config, set the Base URL to the value above and paste the `ems-` token as the Token Key (Bearer)"
  end

  defp scim_location_hint(:google_workspace) do
    "through a SCIM connector — Google Workspace has no built-in SCIM server, so members are otherwise auto-provisioned on first sign-in"
  end

  defp scim_location_hint(_), do: "in your provider's SCIM / user-provisioning settings"

  # The kind currently selected in the form (string), for the live setup guide;
  # defaults to the first option — what the select shows before any change.
  defp form_kind(form, kind_options) do
    case form[:kind].value do
      blank when blank in [nil, ""] -> elem(hd(kind_options), 1)
      value -> to_string(value)
    end
  end

  attr :provider, :map, required: true
  attr :scim_base_url, :string, required: true
  attr :scim_token, :map, default: nil
  attr :mappings, :list, default: []
  attr :mapping_form, Phoenix.HTML.Form, default: nil
  attr :mapping_role_options, :list, required: true
  attr :editing_mapping_id, :string, default: nil
  attr :mapping_edit_form, Phoenix.HTML.Form, default: nil
  attr :typed, :string, default: ""
  attr :synced_groups, :list, default: []

  # Directory sync (SCIM) controls for one connection. The bearer is shown
  # ONCE on enable/rotate (write-only); after that only the base URL + the
  # enabled state render — the token is never read back from the provider.
  defp scim_panel(assigns) do
    provider_id = assigns.provider.id

    revealed_token =
      case assigns.scim_token do
        %{provider_id: ^provider_id, token: token} -> token
        _ -> nil
      end

    assigns = assign(assigns, :revealed_token, revealed_token)

    ~H"""
    <div class="mt-4 rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-zinc-200">Directory sync (SCIM)</span>
            <.chip :if={@provider.scim_enabled} tone={:brand}>Enabled</.chip>
            <.chip :if={not @provider.scim_enabled}>Disabled</.chip>
          </div>
          <p class="mt-1 max-w-prose text-xs text-zinc-500">
            Let your IdP push joins and — critically — offboards: a member removed from
            your directory is suspended here automatically. Point your provider's SCIM
            connector at the base URL below and authenticate with the bearer token — until
            that's wired up, nothing syncs.
          </p>
        </div>

        <div class="flex shrink-0 items-center gap-2">
          <.button
            :if={not @provider.scim_enabled}
            variant="secondary"
            size="sm"
            phx-click="enable_scim"
            phx-value-id={@provider.id}
          >
            Enable directory sync
          </.button>
          <.button
            :if={@provider.scim_enabled}
            variant="secondary"
            size="sm"
            phx-click="rotate_scim"
            phx-value-id={@provider.id}
            data-confirm="Rotate the SCIM token? Your IdP will lose access until you paste the new one."
          >
            Rotate token
          </.button>
          <.button
            :if={@provider.scim_enabled}
            variant="ghost"
            tone="danger"
            size="sm"
            phx-click="disable_scim"
            phx-value-id={@provider.id}
            data-confirm="Disable directory sync? Your IdP can no longer provision or deprovision members through it."
          >
            Disable
          </.button>
        </div>
      </div>

      <div :if={@provider.scim_enabled} class="mt-3">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          SCIM base URL
        </span>
        <div class="mt-1 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-2.5 ring-1 ring-zinc-800">
          <code
            id={"scim-url-#{@provider.id}"}
            class="flex-1 break-all font-mono text-xs text-zinc-300"
          >
            {@scim_base_url}
          </code>
          <.copy_button target={"#scim-url-#{@provider.id}"}>Copy</.copy_button>
        </div>
      </div>

      <%!-- The one-time token reveal — only for the provider whose token was
           just minted. Dismissing it (or any reload) drops it for good. --%>
      <div
        :if={@revealed_token}
        class="mt-3 rounded-lg bg-amber-500/10 p-3 ring-1 ring-amber-500/30"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0 flex-1">
            <p class="text-xs font-semibold text-amber-100">
              Copy this SCIM token now — it's shown only once.
            </p>
            <div class="mt-2 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-2.5 ring-1 ring-zinc-800">
              <code
                id={"scim-token-#{@provider.id}"}
                class="flex-1 break-all font-mono text-xs text-zinc-100"
              >
                {@revealed_token}
              </code>
              <.copy_button
                target={"#scim-token-#{@provider.id}"}
                class="bg-amber-500/20 px-2 text-amber-100 hover:bg-amber-500/30 font-semibold"
              >
                Copy
              </.copy_button>
            </div>
            <p class="mt-2 text-xs text-amber-100/70">
              Didn't copy it? Use <span class="font-semibold">Rotate token</span>
              above to mint a fresh one — the old token stops working.
            </p>
          </div>
          <button
            type="button"
            phx-click="dismiss_scim_token"
            class="rounded-lg p-1 text-amber-200/80 hover:bg-amber-500/10 hover:text-amber-100"
            aria-label="Dismiss"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
        </div>
      </div>

      <%!-- IdP-side SCIM setup — collapsed once enabled so a working connection
           doesn't dump its setup steps every visit; auto-opens right after the
           token's minted (you're mid-setup then). The base URL + bearer are
           above; this is how to wire them in, plus the externalId↔subject note. --%>
      <details
        :if={@provider.scim_enabled}
        class="mt-3 rounded-lg border border-zinc-800 bg-zinc-900/40"
        {if(@revealed_token, do: %{open: ""}, else: %{})}
      >
        <summary class="flex cursor-pointer items-center justify-between gap-3 p-4 text-sm font-medium text-zinc-200 hover:bg-zinc-900/60">
          <span>Point your IdP at this connection</span>
          <span class="text-xs font-normal text-zinc-500">setup steps</span>
        </summary>
        <div class="border-t border-zinc-900 px-4 pb-4 pt-3">
          <ol class="space-y-2.5 text-xs leading-relaxed text-zinc-400">
            <li>
              <span class="font-semibold text-zinc-300">1.</span>
              Enable SCIM provisioning {scim_location_hint(@provider.kind)}.
            </li>
            <li>
              <span class="font-semibold text-zinc-300">2.</span>
              Set the <span class="text-zinc-300">base URL</span>
              above as the connector's SCIM endpoint and paste the
              <span class="text-zinc-300">bearer token</span>
              into its <span class="text-zinc-300">API token</span>
              field (rotate above if you didn't copy it) — it's sent in the
              <code class="rounded bg-zinc-900 px-1 py-0.5">Authorization</code>
              header.
            </li>
            <li>
              <span class="font-semibold text-zinc-300">3.</span>
              Map the SCIM <span class="text-zinc-300">externalId</span>
              to the same value your OIDC
              <code class="rounded bg-zinc-900 px-1 py-0.5">{@provider.identifier_claim}</code>
              claim carries — so a member's SSO login and their synced record are one identity.
            </li>
          </ol>
          <p :if={@provider.kind == :okta} class="mt-3 text-[11px] leading-relaxed text-zinc-500">
            The SCIM app is a second Okta integration, separate from your sign-in app — its own
            SSO doesn't need to be functional. Okta defaults both the OIDC
            <code class="rounded bg-zinc-900 px-1 py-0.5">sub</code>
            and the SCIM <code class="rounded bg-zinc-900 px-1 py-0.5">externalId</code>
            to the Okta user id, so step 3 usually needs no change.
          </p>
        </div>
      </details>

      <%!-- Group → role mapping — only when directory sync is on. Maps an IdP
           group (by its SCIM externalId) to the role a member in it lands at;
           sync recomputes a member's role as the HIGHEST mapped role over their
           groups. Owner is never offered (decision 7). --%>
      <.group_mapping_section
        :if={@provider.scim_enabled}
        provider={@provider}
        mappings={@mappings}
        synced_groups={@synced_groups}
        mapping_form={@mapping_form}
        mapping_role_options={@mapping_role_options}
        editing_mapping_id={@editing_mapping_id}
        mapping_edit_form={@mapping_edit_form}
        typed={@typed}
      />
    </div>
    """
  end

  attr :provider, :map, required: true
  attr :mappings, :list, required: true
  attr :mapping_form, Phoenix.HTML.Form, default: nil
  attr :mapping_role_options, :list, required: true
  attr :editing_mapping_id, :string, default: nil
  attr :mapping_edit_form, Phoenix.HTML.Form, default: nil
  attr :typed, :string, default: ""
  attr :synced_groups, :list, default: []

  # The group→role mapping list + create form for one SCIM-enabled connection.
  # Each row maps a directory group (externalId + display) to an emisar role,
  # with an inline edit and a confirm-to-delete. role_label renders the data
  # role value (rendering a label is fine; never branch authz on it).
  defp group_mapping_section(assigns) do
    ~H"""
    <div class="mt-4 border-t border-zinc-800 pt-4">
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
          Group → role mapping
        </span>
        <.chip>{length(@mappings)}</.chip>
      </div>
      <p class="mt-1 max-w-prose text-xs text-zinc-500">
        Map an IdP group to the role its members land at. A member in several mapped groups
        gets the highest one. Owner is never assignable through directory sync.
      </p>

      <ul :if={@mappings != []} class="mt-3 space-y-2">
        <li
          :for={mapping <- @mappings}
          class="rounded-lg border border-zinc-800 bg-zinc-950/40 px-3 py-2.5"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="min-w-0">
              <span class="truncate font-mono text-xs text-zinc-300">
                {mapping.external_group_display || mapping.external_group_id}
              </span>
              <span :if={mapping.external_group_display} class="ml-1 text-[11px] text-zinc-600">
                {mapping.external_group_id}
              </span>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.chip>{role_label(mapping.role)}</.chip>
              <.button
                :if={@editing_mapping_id != mapping.id}
                variant="ghost"
                size="sm"
                phx-click="start_edit_mapping"
                phx-value-id={mapping.id}
              >
                Edit
              </.button>
              <%!-- Reversible config (re-addable; members keep their role until
                   the next sync) — a native confirm fits the tier, not a
                   typed-confirm. `delete_mapping` stays server-authz-gated. --%>
              <.button
                variant="ghost"
                tone="danger"
                size="sm"
                type="button"
                phx-click="delete_mapping"
                phx-value-id={mapping.id}
                data-confirm="Delete this group mapping? Members keep their current role until the next sync recomputes it from their remaining mapped groups."
              >
                Delete
              </.button>
            </div>
          </div>

          <%!-- Inline edit — display + role (the group's externalId is the
               immutable key). Reuses the page's mapping changeset; the owner
               error surfaces inline here too. --%>
          <div
            :if={@editing_mapping_id == mapping.id and @mapping_edit_form}
            class="mt-3 rounded-lg border border-zinc-800 bg-zinc-900/40 p-3"
          >
            <.simple_form
              for={@mapping_edit_form}
              id={"edit-mapping-#{mapping.id}"}
              phx-change="validate_edit_mapping"
              phx-submit="update_mapping"
            >
              <input type="hidden" name="mapping_id" value={mapping.id} />
              <.input
                field={@mapping_edit_form[:external_group_display]}
                type="text"
                label="Display name"
                placeholder="Admins"
              />
              <.input
                field={@mapping_edit_form[:role]}
                type="select"
                label="Role"
                options={@mapping_role_options}
              />
              <:actions>
                <.button phx-disable-with="Saving...">Save</.button>
                <.button variant="ghost" type="button" phx-click="cancel_edit_mapping">
                  Cancel
                </.button>
              </:actions>
            </.simple_form>
          </div>
        </li>
      </ul>

      <%!-- Create form. account_id/provider_id are server-side; the operator
           supplies the group externalId, an optional display, and the role
           (owner excluded). --%>
      <div class="mt-3 rounded-lg border border-dashed border-zinc-800 p-3">
        <.simple_form
          :if={@mapping_form}
          for={@mapping_form}
          id={"create-mapping-#{@provider.id}"}
          phx-change="validate_mapping"
          phx-submit="create_mapping"
        >
          <input type="hidden" name="provider_id" value={@provider.id} />
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <%!-- Map-after-first-sync: pick from the groups the IdP has actually
                 synced; fall back to a free-text id only before the first sync. --%>
            <.input
              :if={@synced_groups != []}
              field={@mapping_form[:external_group_id]}
              type="select"
              label="IdP group"
              options={@synced_groups}
              prompt="Pick a synced group"
            />
            <.input
              :if={@synced_groups == []}
              field={@mapping_form[:external_group_id]}
              type="text"
              label="IdP group ID"
              placeholder="syncs first, then pick…"
              class="font-mono"
            />
            <.input
              field={@mapping_form[:external_group_display]}
              type="text"
              label="Display (optional)"
              placeholder="Admins"
            />
            <.input
              field={@mapping_form[:role]}
              type="select"
              label="Role"
              options={@mapping_role_options}
              prompt="Select a role"
            />
          </div>
          <:actions>
            <.button phx-disable-with="Adding...">Add mapping</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  defp approve_confirm(%{matched_user_id: nil}) do
    "Approve access for this user? They'll be able to sign in at the connection's default role."
  end

  defp approve_confirm(%{email: email}) do
    "Link this connection to the existing #{email} account? That IdP identity will then sign in as this existing user."
  end

  defp role_label(role), do: role |> Atom.to_string() |> String.capitalize()

  defp provisioner_label(:jit), do: "Auto-provision"
  defp provisioner_label(:manual), do: "Manual approval"

  defp request_label(request),
    do: request.full_name || request.email || request.provider_identifier
end
