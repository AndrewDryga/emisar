defmodule EmisarWeb.SSOSettingsLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, SSO}
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
                  &{Emisar.Auth.Role.label(&1), Atom.to_string(&1)}
                )

  @mapping_role_options @role_options

  # The synced-users list re-roles a real membership, so its select offers ALL
  # roles (incl. owner) — unlike the JIT/mapping selects. update_membership_role
  # still enforces the owner / last-owner / self guards server-side.
  @member_role_options Enum.map(
                         Emisar.Auth.Role.all(),
                         &{Emisar.Auth.Role.label(&1), Atom.to_string(&1)}
                       )

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
      |> assign(:member_role_options, @member_role_options)
      |> assign(:provisioner_options, @provisioner_options)
      # Suspend/re-role a synced member acts on the Accounts membership, which
      # needs manage_team (distinct from the page's manage_sso view gate).
      |> assign(
        :can_manage_team?,
        Accounts.subject_can_manage_team?(socket.assigns.current_subject)
      )
      # The provider's synced users (identity + membership), loaded on :show.
      |> assign(:synced_members, [])
      |> assign(:edit_form, nil)
      # Pending manual-link requests across the account — loaded on :index, where
      # the overview triages them (the detail page is config-only).
      |> assign(:pending_requests, [])
      # Connection(s) in scope: ALL on :index (a list), the one on :show (detail).
      # Set per-action in handle_params.
      |> assign(:providers, [])
      # Per-connection {users, groups} tallies for the :index health line.
      |> assign(:sync_stats, %{})
      # Group→role mapping state: the per-provider lists + create forms, and the
      # single open inline edit (id + form). Keyed by provider id so each
      # provider's directory-sync panel owns its own mappings + form.
      |> assign(:group_mappings, %{})
      |> assign(:synced_groups, %{})
      |> assign(:mapping_forms, %{})
      |> assign(:editing_mapping_id, nil)
      |> assign(:mapping_edit_form, nil)
      # The add-mapping form is behind an "Add mapping" button, not always open.
      |> assign(:adding_mapping, false)
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
      # The "Test connection" capstone's last result on /new: nil, {:ok, summary},
      # or {:error, reason}. Cleared whenever the form changes so it never lies.
      |> assign(:test_result, nil)
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
        :edit -> load_edit(socket, params["id"])
        :new -> socket |> assign_form(SSO.change_provider()) |> assign(:test_result, nil)
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
    |> assign(:sync_stats, sync_stats(socket))
    |> assign(:pending_requests, list_pending_requests(socket))
  end

  # Per-connection {users, groups} tallies for the overview health line; an
  # unauthorized read (shouldn't happen on this page) degrades to empty counts.
  defp sync_stats(socket) do
    case SSO.provider_sync_stats(socket.assigns.current_subject) do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  # Detail: ONE connection (account-scoped — a cross-account or unknown id is
  # not_found → back to the overview) + its group→role mappings / synced groups.
  defp load_show(socket, id) do
    case SSO.fetch_provider_by_id(id, socket.assigns.current_subject) do
      {:ok, provider} ->
        socket
        |> assign(:loaded?, true)
        |> assign(:providers, [provider])
        |> assign(:adding_mapping, false)
        |> load_group_mappings([provider])
        |> load_synced_members(provider)
        |> assign_form(SSO.change_provider())

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Connection not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/sso")
    end
  end

  # The users provisioned through this connection, each paired with its account
  # membership (nil if the person was fully removed but the identity lingers) — so
  # the "Synced users" card can show state and act on the membership. Two reads
  # (SSO identities + Accounts memberships), zipped by user id; either failing
  # (e.g. a viewer without manage_sso) degrades to an empty list.
  defp load_synced_members(socket, provider) do
    subject = socket.assigns.current_subject

    members =
      with {:ok, identities} <- SSO.list_synced_users(provider, subject),
           user_ids = Enum.map(identities, & &1.user_id),
           {:ok, memberships} <-
             Accounts.list_memberships_for_users(
               socket.assigns.current_account,
               user_ids,
               subject
             ) do
        membership_by_user = Map.new(memberships, &{&1.user_id, &1})

        Enum.map(
          identities,
          &%{identity: &1, membership: Map.get(membership_by_user, &1.user_id)}
        )
      else
        _ -> []
      end

    assign(socket, :synced_members, members)
  end

  # Edit: its own page (like /new) so the form gets the full width — one
  # connection, pre-filled. A cross-account or unknown id falls back to the
  # overview, same as :show.
  defp load_edit(socket, id) do
    case SSO.fetch_provider_by_id(id, socket.assigns.current_subject) do
      {:ok, provider} ->
        socket
        |> assign(:loaded?, true)
        |> assign(:providers, [provider])
        |> assign(:edit_form, edit_form(provider))

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

    # The groups the IdP has actually synced (id + member count), each annotated
    # with its role mapping — powers the "Synced groups" readout, and (projected
    # to ids) the map-after-first-sync picker.
    synced =
      Map.new(scim_providers, fn provider ->
        {provider.id,
         annotate_synced_groups(list_synced_groups(socket, provider), mappings[provider.id])}
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

  # Attach each synced group's role mapping (nil when unmapped) so the readout
  # shows the role its members resolve to next to the member count.
  defp annotate_synced_groups(groups, mappings) do
    by_group = Map.new(mappings, &{&1.external_group_id, &1})
    Enum.map(groups, &Map.put(&1, :mapping, Map.get(by_group, &1.external_group_id)))
  end

  defp list_mappings(socket, provider) do
    case SSO.list_group_mappings(provider, socket.assigns.current_subject) do
      {:ok, mappings, _meta} -> mappings
      {:error, _} -> []
    end
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    params = prefill_fixed_issuer(params)

    changeset =
      SSO.change_provider(%SSO.IdentityProvider{}, params) |> Map.put(:action, :validate)

    {:noreply, socket |> assign_form(changeset) |> assign(:test_result, nil)}
  end

  def handle_event("create", %{"provider" => params}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_create(&1, params))
  end

  # The setup capstone: run a real OIDC discovery against the issuer the operator
  # has typed (read from the live form), so a working connection is proven before
  # it's saved. The context SSRF-validates the issuer and writes no row.
  def handle_event("test_connection", _params, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_test_connection/1)
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

  def handle_event("add_mapping_form", _params, socket),
    do: {:noreply, assign(socket, :adding_mapping, true)}

  # Close the add form and reset it, so a re-open starts blank (not with the last
  # partial input). do_create_mapping already resets the form on a successful add.
  def handle_event("cancel_add_mapping", _params, socket) do
    socket =
      case socket.assigns.providers do
        [provider | _] -> put_mapping_form(socket, provider.id, mapping_form(provider))
        _ -> socket
      end

    {:noreply, assign(socket, :adding_mapping, false)}
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

  # -- Synced users — member lifecycle (acts on the Accounts membership) ---
  # These mutate a real membership, so they gate on manage_team, not the page's
  # manage_sso view gate; Accounts enforces the owner / last-owner / self guards.

  def handle_event("change_member_role", %{"membership_id" => id, "role" => role}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_manage_team?,
      &do_change_member_role(&1, id, role)
    )
  end

  def handle_event("suspend_member", %{"membership_id" => id}, socket) do
    Permissions.gated(socket, socket.assigns.can_manage_team?, &do_suspend_member(&1, id))
  end

  def handle_event("reinstate_member", %{"membership_id" => id}, socket) do
    Permissions.gated(socket, socket.assigns.can_manage_team?, &do_reinstate_member(&1, id))
  end

  # No-op for the on_mount badge/fleet hooks' broadcasts (approvals, packs,
  # runner presence). Those nav cues are owned by the hooks; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp do_create(socket, params) do
    case SSO.configure_provider(strip_blank_secret(params), socket.assigns.current_subject) do
      {:ok, provider} ->
        # Land on the new connection's detail, not the overview — it's where the
        # next steps live (test a sign-in, enable directory sync, map groups).
        {:noreply,
         socket
         |> put_flash(:info, "Connection \"#{provider.name}\" added — finish setup below.")
         |> push_navigate(
           to: ~p"/app/#{socket.assigns.current_account}/settings/sso/#{provider.id}"
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Read the issuer the operator has typed (the form is kept current by validate)
  # and probe its OIDC discovery. The whole {:ok, …}/{:error, …} result is stashed
  # for the inline banner — no flash (the result is the point of the surface).
  defp do_test_connection(socket) do
    issuer = Ecto.Changeset.get_field(socket.assigns.form.source, :issuer)

    {:noreply,
     assign(socket, :test_result, SSO.test_provider(issuer, socket.assigns.current_subject))}
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
             |> push_navigate(
               to: ~p"/app/#{socket.assigns.current_account}/settings/sso/#{provider.id}"
             )}

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

  defp do_change_member_role(socket, membership_id, role) do
    with_synced_membership(socket, membership_id, fn membership ->
      # Directory sync owns a synced member's role (recomputed each sync), and the
      # DOMAIN refuses a manual change off the membership's own `directory_managed`
      # flag — the UI read-only lock is a courtesy, not the guard. An OIDC-only
      # member (no sync) isn't flagged, so the editable path still works.
      case Accounts.update_membership_role(membership, role, socket.assigns.current_subject) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Role updated.") |> reload()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, member_error(reason))}
      end
    end)
  end

  defp do_suspend_member(socket, membership_id) do
    with_synced_membership(socket, membership_id, fn membership ->
      case Accounts.suspend_membership(membership, socket.assigns.current_subject) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Member suspended.") |> reload()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, member_error(reason))}
      end
    end)
  end

  defp do_reinstate_member(socket, membership_id) do
    with_synced_membership(socket, membership_id, fn membership ->
      # A member the IdP deactivated can't be reactivated here — the DOMAIN refuses
      # off the membership's own `directory_suspended` flag (reactivate them in the
      # IdP, whose active:true re-syncs). The button hides for them too, but the
      # guard is domain-owned, not UI-trusted.
      case Accounts.reinstate_membership(membership, socket.assigns.current_subject) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Member reactivated.") |> reload()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, member_error(reason))}
      end
    end)
  end

  defp with_synced_membership(socket, membership_id, fun) do
    case find_synced_membership(socket, membership_id) do
      nil -> {:noreply, socket}
      membership -> fun.(membership)
    end
  end

  defp find_synced_membership(socket, membership_id) do
    socket.assigns.synced_members
    |> Enum.map(& &1.membership)
    |> Enum.find(&(&1 && &1.id == membership_id))
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

  # Member-lifecycle errors from Accounts (change role / suspend / reinstate) —
  # kept separate from the SSO-config error_message/1 so each reads for its surface.
  defp member_error(:unauthorized), do: "Only owners and admins can manage members."

  defp member_error(:insufficient_privileges),
    do: "You can't manage a member whose role is equal to or above yours."

  defp member_error(:last_owner) do
    "This is the account's last owner — promote someone else before demoting or suspending them."
  end

  defp member_error(reason) when reason in [:cannot_self_promote, :cannot_modify_self],
    do: "You can't change your own membership here — use Profile."

  defp member_error(:not_found), do: "That member no longer exists."

  defp member_error(:role_managed_by_directory) do
    "Roles for directory-synced members are set by your identity provider — use the group → role mappings."
  end

  defp member_error(:deactivated_in_idp) do
    "This member is deactivated in your identity provider — reactivate them there first."
  end

  defp member_error(%Ecto.Changeset{}),
    do: "That change wasn't valid. Refresh to see the member's current state, then try again."

  defp member_error(_),
    do: "That didn't complete. Refresh to see the member's current state, then try again."

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
      <:title>
        <%!-- The detail view titles itself with the connection, like every
             other detail page (detail_header family); the list keeps the
             section name. --%>
        <%= case {@live_action, @providers} do %>
          <% {:show, [provider | _]} -> %>
            <.detail_header
              back="Single sign-on"
              navigate={~p"/app/#{@current_account}/settings/sso"}
              title={provider.name}
            />
          <% _ -> %>
            Single sign-on
        <% end %>
      </:title>
      <:actions :if={@can_configure? and @live_action == :index}>
        <.button navigate={~p"/app/#{@current_account}/settings/sso/new"} size={:md} icon="hero-plus">
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

        <%!-- Adding a connection is its own view (/settings/sso/new): a bare
             sub-header over sibling field islands (Provider · OIDC · …), never
             one giant card. --%>
        <div :if={@live_action == :new} class="space-y-5">
          <div>
            <.link
              navigate={~p"/app/#{@current_account}/settings/sso"}
              class="inline-flex items-center gap-1 text-sm text-zinc-400 hover:text-zinc-200"
            >
              <.icon name="hero-arrow-left" class="h-4 w-4" /> Connections
            </.link>
            <h2 class="mt-3 text-lg font-semibold text-zinc-100">Add an identity provider</h2>
            <p class="mt-1 max-w-prose text-sm leading-relaxed text-zinc-500">
              We'll use the issuer's OIDC discovery document. Follow the steps in each section to
              create an OAuth/OIDC app at your provider, then paste its client ID and secret.
            </p>
          </div>

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
            <.test_result :if={@test_result} result={@test_result} />
            <:actions>
              <.button phx-disable-with="Saving...">Add connection</.button>
              <%!-- The capstone: prove the issuer is reachable before saving.
                   type="button" so it probes (phx-click) instead of submitting. --%>
              <.button
                type="button"
                variant={:secondary}
                phx-click="test_connection"
                phx-disable-with="Testing…"
              >
                Test connection
              </.button>
            </:actions>
          </.simple_form>
        </div>

        <%!-- Editing is its own view (/settings/sso/:id/edit), like /new — a bare
             sub-header over the same sibling field islands, never an inline
             collapsed block and never one giant card. --%>
        <div :if={@live_action == :edit} class="space-y-5">
          <div :for={provider <- @providers} class="space-y-5">
            <div>
              <.link
                navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
                class="inline-flex items-center gap-1 text-sm text-zinc-400 hover:text-zinc-200"
              >
                <.icon name="hero-arrow-left" class="h-4 w-4" /> {provider.name}
              </.link>
              <h2 class="mt-3 text-lg font-semibold text-zinc-100">Edit connection</h2>
              <p class="mt-1 max-w-prose text-sm leading-relaxed text-zinc-500">
                Update this connection's OIDC settings. Leave the client secret blank to keep the
                stored one.
              </p>
            </div>

            <.simple_form
              :if={@edit_form}
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
                <.button
                  navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
                  variant={:ghost}
                >
                  Cancel
                </.button>
              </:actions>
            </.simple_form>
          </div>

          <div :if={not @loaded?} class="text-sm text-zinc-500">Loading…</div>
        </div>

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
                    variant={:secondary}
                    size={:sm}
                    phx-click="approve_request"
                    phx-value-id={request.id}
                    data-confirm={approve_confirm(request)}
                  >
                    Approve
                  </.button>
                  <.button
                    variant={:ghost}
                    tone={:rose}
                    size={:sm}
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
                    <.icon name="hero-identification" class="h-4 w-4" />
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
                    <.sync_meta
                      provider={provider}
                      stats={Map.get(@sync_stats, provider.id, %{users: 0, groups: 0})}
                    />
                  </div>
                  <.icon name="hero-chevron-right" class="h-4 w-4 shrink-0 text-zinc-600" />
                </.link>
              </li>
            </ul>
          </.card>

          <.empty_state
            :if={@loaded? and @providers == []}
            icon="hero-identification"
            title="No connections yet"
          >
            Connect your identity provider to let your team sign in through it. You'll need an
            OAuth/OIDC app at your provider with its client ID and secret.
            <:cta navigate={~p"/app/#{@current_account}/settings/sso/new"}>Add connection</:cta>
          </.empty_state>
        </section>

        <%!-- The branded sign-in link to hand to the team — a quiet utility, so it
             sits at the bottom and lets the needs-attention block lead. Always
             useful (email sign-in works without SSO), so it's not gated on providers. --%>
        <.card :if={@live_action == :index} padding="p-5">
          <p class="text-sm font-medium text-zinc-200">Your team's sign-in link</p>
          <p class="mt-1 text-xs leading-relaxed text-zinc-500">
            Share this with your members — it opens this team's sign-in page with your SSO
            connections (and email sign-in as a fallback).
          </p>
          <.code_line id="sso-sign-in-link" value={@sign_in_url} class="mt-3" />
        </.card>

        <%!-- ── Connection detail (/settings/sso/:id) ───────────────────────
             One connection: identity + status + config (edit, directory sync,
             group→role). @providers holds exactly the one handle_params loaded. --%>
        <%!-- Back crumb + entity name live in the shell header (detail_header),
             like every other detail page. --%>
        <div :if={@live_action == :show} class="space-y-6">
          <div :for={provider <- @providers} class="space-y-5">
            <%!-- Connection island — identity + the config readout. Editing is
                 its own page (/edit), so this card is a clean read view. The
                 shell title already carries the name; this row is the status. --%>
            <.card padding="p-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="flex min-w-0 flex-wrap items-center gap-2">
                  <.chip>{kind_label(provider.kind)}</.chip>
                  <.chip :if={provider.enabled} tone={:brand}>Enabled</.chip>
                  <.chip :if={not provider.enabled} tone={:amber}>Disabled</.chip>
                </div>
                <%!-- Delete lives in a danger zone at the bottom, not up here beside
                     a routine Edit — a destructive action shouldn't sit one slip
                     away from the safe one. --%>
                <.button
                  navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}/edit"}
                  variant={:secondary}
                  size={:sm}
                  class="shrink-0"
                >
                  Edit
                </.button>
              </div>

              <div class="mt-5 space-y-4 border-t border-zinc-800/70 pt-4">
                <.meta_field label="Issuer" wrap>
                  <span class="font-mono text-zinc-300">{provider.issuer}</span>
                </.meta_field>
                <div class="grid grid-cols-2 gap-x-6 gap-y-4">
                  <.meta_field label="New users">
                    <span class="text-zinc-300">{provisioner_label(provider.provisioner)}</span>
                  </.meta_field>
                  <.meta_field label="Default role">
                    <span class="text-zinc-300">{role_label(provider.default_role)}</span>
                  </.meta_field>
                  <.meta_field label="Identifier claim">
                    <span class="font-mono text-zinc-300">{provider.identifier_claim}</span>
                  </.meta_field>
                  <.meta_field :if={provider.allowed_email_domain} label="Email domain">
                    <span class="text-zinc-300">@{provider.allowed_email_domain}</span>
                  </.meta_field>
                  <.meta_field label="2FA requirement">
                    <span :if={provider.satisfies_mfa} class="text-zinc-300">
                      Satisfied by this provider
                    </span>
                    <span :if={not provider.satisfies_mfa} class="text-zinc-500">Not satisfied</span>
                  </.meta_field>
                </div>
              </div>
            </.card>

            <.scim_panel
              :if={@can_configure_directory_sync?}
              provider={provider}
              scim_base_url={@scim_base_url}
              scim_token={@scim_token}
            />

            <.group_mapping_section
              :if={@can_configure_directory_sync? and provider.scim_enabled}
              provider={provider}
              mappings={Map.get(@group_mappings, provider.id, [])}
              synced_groups={Map.get(@synced_groups, provider.id, [])}
              mapping_form={Map.get(@mapping_forms, provider.id)}
              mapping_role_options={@mapping_role_options}
              editing_mapping_id={@editing_mapping_id}
              mapping_edit_form={@mapping_edit_form}
              adding_mapping={@adding_mapping}
            />

            <.synced_groups_card
              :if={@can_configure_directory_sync? and provider.scim_enabled}
              synced_groups={Map.get(@synced_groups, provider.id, [])}
            />

            <.synced_users_card
              members={@synced_members}
              member_role_options={@member_role_options}
              can_manage_team?={@can_manage_team?}
              current_user_id={@current_user.id}
              scim_enabled={provider.scim_enabled}
            />

            <.card :if={!@can_configure_directory_sync?} padding="p-5">
              <p class="text-sm leading-relaxed text-zinc-400">
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
              </p>
            </.card>

            <%!-- Danger zone at the bottom — the destructive action lives apart
                 from the routine config above and still runs the typed confirm. --%>
            <.confirm_zone
              title="Delete this connection"
              phx-click={show_confirm_dialog("delete-provider-#{provider.id}")}
              type="button"
            >
              <:body>
                Removes the connection and stops new sign-ins through it. Members who sign in only
                through it lose access until it's re-added; existing sessions aren't ended. This
                can't be undone.
              </:body>
              Delete connection
            </.confirm_zone>

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

  # The "Test connection" capstone's outcome. Dispatch on the result shape:
  # discovery succeeded (the endpoints prove a real OIDC IdP) vs. a reason.
  attr :result, :any, required: true

  defp test_result(%{result: {:ok, summary}} = assigns) do
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div class="rounded-lg border border-brand-500/30 bg-brand-500/10 p-3.5 text-sm text-brand-100">
      <div class="flex items-center gap-2 font-medium">
        <.icon name="hero-check-circle" class="h-4 w-4 text-brand-400" />
        Discovery succeeded — this issuer serves a valid OIDC configuration.
      </div>
      <dl class="mt-2 space-y-1 text-xs text-brand-200/80">
        <div :if={@summary.authorization_endpoint} class="flex gap-2">
          <dt class="w-32 shrink-0 text-brand-200/60">Authorization</dt>
          <dd class="truncate font-mono">{@summary.authorization_endpoint}</dd>
        </div>
        <div :if={@summary.token_endpoint} class="flex gap-2">
          <dt class="w-32 shrink-0 text-brand-200/60">Token</dt>
          <dd class="truncate font-mono">{@summary.token_endpoint}</dd>
        </div>
        <div :if={@summary.jwks_uri} class="flex gap-2">
          <dt class="w-32 shrink-0 text-brand-200/60">JWKS</dt>
          <dd class="truncate font-mono">{@summary.jwks_uri}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp test_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, test_error_message(reason))

    ~H"""
    <div class="flex items-start gap-2 rounded-lg border border-rose-500/30 bg-rose-500/10 p-3.5 text-sm text-rose-200">
      <.icon name="hero-exclamation-triangle" class="mt-0.5 h-4 w-4 shrink-0 text-rose-400" />
      <span>{@message}</span>
    </div>
    """
  end

  defp test_error_message(:invalid_issuer), do: "Enter the issuer's https URL first, then test."

  defp test_error_message(:blocked_issuer),
    do: "The issuer can't be a private, loopback, or metadata address."

  defp test_error_message(_reason) do
    "Couldn't load the issuer's OIDC discovery document. Check the issuer URL and that the IdP is reachable from the internet."
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :kind_options, :list, required: true
  attr :role_options, :list, required: true
  attr :provisioner_options, :list, required: true
  attr :guide_id, :string, required: true
  attr :callback_url, :string, required: true
  attr :editing?, :boolean, default: false

  # The connection form's fields, grouped into sibling islands (Provider · OIDC
  # connection · User provisioning · Security) so /new and /edit read like the
  # rest of the console — never one giant card. Shared by both actions; the outer
  # <.simple_form> spaces the islands and renders the submit footer.
  defp provider_fields(assigns) do
    assigns = assign(assigns, :kind, form_kind(assigns.form, assigns.kind_options))

    ~H"""
    <div class="space-y-5">
      <.panel title="Provider">
        <:subtitle>Which identity provider this is, and what to call it here.</:subtitle>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <%!-- Provider type is create-only: Changeset.update/2 never casts :kind
               (it's the IdP preset + half of the (account, kind) uniqueness). So on
               edit it's read-only — a select here would silently drop the change.
               Change the provider by adding a new connection. --%>
          <.input
            :if={not @editing?}
            field={@form[:kind]}
            type="select"
            label="Provider type"
            options={@kind_options}
          />
          <div :if={@editing?}>
            <.label>Provider type</.label>
            <div class="mt-2 flex items-center gap-2 rounded-lg bg-zinc-950/50 px-3 py-2.5 text-sm text-zinc-400 ring-1 ring-inset ring-zinc-800">
              <.icon name="hero-lock-closed" class="h-3.5 w-3.5 shrink-0 text-zinc-500" />
              {selected_kind_label(@form, @kind_options)}
            </div>
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
              Set when the connection was created. Add a new connection to use a different provider.
            </p>
          </div>
          <.input
            field={@form[:name]}
            type="text"
            label="Display name"
            placeholder={name_placeholder(@kind)}
          />
        </div>
      </.panel>

      <.panel title="OIDC connection">
        <:subtitle>
          The issuer we fetch discovery from, and the OAuth client we authenticate as.
        </:subtitle>
        <%!-- Setup steps for the SELECTED provider — what to create at the IdP and
             what to paste back here. --%>
        <.provider_setup_guide
          id={@guide_id}
          kind={form_kind(@form, @kind_options)}
          callback_url={@callback_url}
        />
        <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="sm:col-span-2">
            <.input
              field={@form[:issuer]}
              type="url"
              label="Issuer URL"
              placeholder={issuer_hint(@kind)}
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
          <%!-- Which claim identifies the user is an OIDC-connection concern, so it
               lives here beside the issuer/client — not down in provisioning. --%>
          <div class="sm:col-span-2">
            <.input
              field={@form[:identifier_claim]}
              type="select"
              label="Identifier claim"
              options={[{"sub — OIDC standard", "sub"}, {"oid — Microsoft Entra", "oid"}]}
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
              The stable, provider-issued claim that identifies a user — restricted to immutable
              subject identifiers (a mutable claim like email would allow account takeover). Leave
              as <code>sub</code>
              unless your provider (e.g. Microsoft Entra) requires <code>oid</code>.
            </p>
          </div>
        </div>
      </.panel>

      <.panel title="User provisioning">
        <:subtitle>How members map in when they sign in through this connection.</:subtitle>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
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
          <div class="sm:col-span-2">
            <.label>Default role for new users</.label>
            <%!-- Radio cards, not a bare select — the role a new member lands at is
                 a privilege choice, so each option shows what it grants (matches the
                 team-invite picker). --%>
            <.choice_cards
              name="provider[default_role]"
              value={@form[:default_role].value}
              columns={2}
              class="mt-2"
            >
              <:card
                :for={{label, value} <- @role_options}
                value={value}
                title={label}
              >
                {Emisar.Auth.Role.description(value)}
              </:card>
            </.choice_cards>
          </div>
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
        </div>
      </.panel>

      <.panel title="Security & activation">
        <:subtitle>
          Whether this provider satisfies 2FA, and whether members can use it yet.
        </:subtitle>
        <div class="space-y-3">
          <div>
            <.input
              field={@form[:satisfies_mfa]}
              type="checkbox"
              label="Sign-in through this provider satisfies the account's 2FA requirement"
            />
            <%!-- The caption tracks the box: OFF (the default) it's a calm fact
                 about what turning it on means; ON it's the amber consequence,
                 because that's the state that can actually weaken 2FA. A warning
                 shown at the safe default would just argue with itself. --%>
            <p
              :if={not checkbox_on?(@form[:satisfies_mfa])}
              class="mt-1 text-[11px] leading-relaxed text-zinc-500"
            >
              Turn on only if this provider enforces MFA itself — then a sign-in here counts as
              the account's second factor.
            </p>
            <p
              :if={checkbox_on?(@form[:satisfies_mfa])}
              class="mt-1 text-[11px] leading-relaxed text-amber-300/80"
            >
              This provider must enforce MFA itself — otherwise members who sign in through it
              bypass your 2FA requirement.
            </p>
          </div>
          <.input
            field={@form[:enabled]}
            type="checkbox"
            label="Enabled (members can sign in through this connection)"
          />
        </div>
      </.panel>
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
    <div class="rounded-lg bg-zinc-900/50 p-4 ring-1 ring-white/5">
      <p class="text-sm font-medium text-zinc-200">Setting up {setup_kind_label(@kind)}</p>
      <.steps class="mt-3">
        <:step>
          Create an OAuth / OIDC <span class="text-zinc-300">web app</span> {oidc_app_hint(@kind)}.
        </:step>
        <:step>
          Register this <span class="text-zinc-300">redirect URI</span>
          on the app: <.code_line id={"sso-callback-#{@id}"} value={@callback_url} class="mt-1.5" />
        </:step>
        <:step>
          Set the <span class="text-zinc-300">Issuer URL</span>
          below to <span class="font-mono text-zinc-300">{issuer_hint(@kind)}</span>.
          <span class="text-zinc-500">{issuer_where_hint(@kind)}</span>
        </:step>
        <:step>
          Paste the app's <span class="text-zinc-300">Client ID</span>
          and <span class="text-zinc-300">Client secret</span>
          into the fields below.
        </:step>
      </.steps>
      <%!-- Only providers whose OAuth app exposes a DPoP toggle get this note —
           Google and JumpCloud have no such setting, so it would only confuse. --%>
      <p :if={dpop_relevant?(@kind)} class="mt-3 text-xs leading-relaxed text-zinc-500">
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

  # The display-name placeholder — a plausible name for the picked provider, so
  # the example never contradicts the selected kind (no "Acme Okta" under Google).
  defp name_placeholder("google_workspace"), do: "Acme Google Workspace"
  defp name_placeholder("okta"), do: "Acme Okta"
  defp name_placeholder("jumpcloud"), do: "Acme JumpCloud"
  defp name_placeholder("keycloak"), do: "Acme Keycloak"
  defp name_placeholder(_), do: "Company SSO"

  # The "leave DPoP off" note applies only where the OAuth app exposes a DPoP
  # toggle (Okta, Keycloak, a generic OIDC app) — Google and JumpCloud don't.
  defp dpop_relevant?("google_workspace"), do: false
  defp dpop_relevant?("jumpcloud"), do: false
  defp dpop_relevant?(_), do: true

  # Whether a form checkbox field currently reads as on (params post "true";
  # the loaded struct carries a boolean).
  defp checkbox_on?(field), do: field.value in [true, "true"]

  # Google Workspace and JumpCloud have a single, fixed OIDC issuer — prefill it
  # when that provider is picked and the operator hasn't typed one, so they don't
  # hunt for a value that's always the same. Switching to a non-fixed provider
  # clears an issuer we'd prefilled (never one they typed).
  defp prefill_fixed_issuer(%{"kind" => kind} = params) do
    fixed = %{
      "google_workspace" => "https://accounts.google.com",
      "jumpcloud" => "https://oauth.id.jumpcloud.com/"
    }

    current = Map.get(params, "issuer", "")

    case Map.get(fixed, kind) do
      nil -> if current in Map.values(fixed), do: Map.put(params, "issuer", ""), else: params
      issuer -> if current in ["", nil], do: Map.put(params, "issuer", issuer), else: params
    end
  end

  defp prefill_fixed_issuer(params), do: params

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

  # The directory synced within the last day — setup is done, so the "point your IdP
  # at this connection" instructions are hidden until sync goes stale again.
  defp recently_synced?(%{scim_last_seen_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) < 24 * 60 * 60

  defp recently_synced?(_), do: false

  # The kind currently selected in the form (string), for the live setup guide;
  # defaults to the first option — what the select shows before any change.
  defp form_kind(form, kind_options) do
    case form[:kind].value do
      blank when blank in [nil, ""] -> elem(hd(kind_options), 1)
      value -> to_string(value)
    end
  end

  # The humanized label for the form's current kind — for the read-only display on
  # the edit form, where provider type is create-only.
  defp selected_kind_label(form, kind_options) do
    value = form_kind(form, kind_options)
    Enum.find_value(kind_options, value, fn {label, v} -> v == value && label end)
  end

  attr :provider, :map, required: true
  attr :scim_base_url, :string, required: true
  attr :scim_token, :map, default: nil

  # Directory sync (SCIM) — a sibling island on the connection detail: header +
  # intent, the live sync-status signal, the base URL, the once-shown bearer, and
  # the IdP setup steps. The bearer is write-only (shown once on enable/rotate).
  # Group→role is its own island card, not nested here.
  defp scim_panel(assigns) do
    provider_id = assigns.provider.id

    revealed_token =
      case assigns.scim_token do
        %{provider_id: ^provider_id, token: token} -> token
        _ -> nil
      end

    assigns = assign(assigns, :revealed_token, revealed_token)

    ~H"""
    <.card padding="p-5">
      <.section_header title="Directory sync (SCIM)">
        <:actions>
          <.chip :if={@provider.scim_enabled} tone={:brand}>Enabled</.chip>
          <.chip :if={not @provider.scim_enabled}>Disabled</.chip>
          <div class="ml-auto flex items-center gap-2">
            <.button
              :if={not @provider.scim_enabled}
              variant={:secondary}
              size={:sm}
              phx-click="enable_scim"
              phx-value-id={@provider.id}
            >
              Enable
            </.button>
            <.button
              :if={@provider.scim_enabled}
              variant={:secondary}
              size={:sm}
              phx-click="rotate_scim"
              phx-value-id={@provider.id}
              data-confirm="Rotate the SCIM token? Your IdP will lose access until you paste the new one."
            >
              Rotate token
            </.button>
            <.button
              :if={@provider.scim_enabled}
              variant={:ghost}
              tone={:rose}
              size={:sm}
              phx-click="disable_scim"
              phx-value-id={@provider.id}
              data-confirm="Disable directory sync? Your IdP can no longer provision or deprovision members through it."
            >
              Disable
            </.button>
          </div>
        </:actions>
      </.section_header>

      <p class="max-w-prose text-sm leading-6 text-zinc-400">
        Your IdP provisions members and offboards removed ones automatically.
        <.doc_link href="/docs/sso">Directory sync docs</.doc_link>
      </p>

      <div :if={@provider.scim_enabled} class="mt-4 space-y-4">
        <%!-- A healthy sync is a quiet freshness line — no boxed "all good"
             (silence is the confirmation). The waiting state is the one that
             earns a boxed amber note: it's telling you to go connect the IdP. --%>
        <p
          :if={@provider.scim_last_seen_at}
          class="flex items-center gap-2 text-sm text-zinc-400"
        >
          <.status_dot tone={:brand} size={:sm} /> Last sync
          <.local_time value={@provider.scim_last_seen_at} mode={:relative} />
        </p>
        <div
          :if={is_nil(@provider.scim_last_seen_at)}
          class="flex items-center gap-2.5 rounded-lg bg-amber-500/5 px-3 py-2.5 ring-1 ring-amber-500/20"
        >
          <.status_dot tone={:amber} size={:md} />
          <p class="text-sm text-zinc-400">No syncs yet — waiting for your IdP to connect.</p>
        </div>

        <div>
          <p class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
            SCIM base URL
          </p>
          <.code_line id={"scim-url-#{@provider.id}"} value={@scim_base_url} class="mt-1.5" />
        </div>

        <%!-- The one-time token reveal — only for the provider whose token was
             just minted. Dismissing it (or any reload) drops it for good. --%>
        <.secret_reveal
          :if={@revealed_token}
          id={"scim-token-#{@provider.id}"}
          variant={:card}
          title="Copy this SCIM token now — it's shown only once."
          secret={@revealed_token}
          on_dismiss="dismiss_scim_token"
        >
          If you lose it, <span class="font-semibold">Rotate token</span>
          above mints a fresh one — the old token stops working.
        </.secret_reveal>

        <%!-- IdP-side SCIM setup — a light disclosure (no heavy box); auto-opens
             right after the token's minted (mid-setup). Hidden once the directory has
             synced within the last day (setup's done) — unless a token was just revealed,
             since you need these steps to re-point the IdP at the new bearer. --%>
        <details
          :if={@revealed_token || not recently_synced?(@provider)}
          class="group"
          {if(@revealed_token, do: %{open: ""}, else: %{})}
        >
          <summary class="flex cursor-pointer list-none items-center gap-1.5 text-sm font-medium text-zinc-300 hover:text-zinc-100">
            <.icon
              name="hero-chevron-right"
              class="h-4 w-4 text-zinc-500 transition-transform group-open:rotate-90"
            /> Point your IdP at this connection
          </summary>
          <.steps class="mt-3 pl-5">
            <:step>
              Enable SCIM provisioning {scim_location_hint(@provider.kind)}.
            </:step>
            <:step>
              Set the <span class="text-zinc-300">base URL</span>
              above as the connector's SCIM endpoint and paste the
              <span class="text-zinc-300">bearer token</span>
              into its <span class="text-zinc-300">API token</span>
              field (rotate above if you didn't copy it) — it's sent in the
              <code class="rounded bg-zinc-900 px-1 py-0.5">Authorization</code>
              header.
            </:step>
            <:step>
              Map the SCIM <span class="text-zinc-300">externalId</span>
              to the same value your OIDC
              <code class="rounded bg-zinc-900 px-1 py-0.5">{@provider.identifier_claim}</code>
              claim carries — so a member's SSO login and their synced record are one identity.
            </:step>
          </.steps>
          <p :if={@provider.kind == :okta} class="mt-3 pl-5 text-[11px] leading-relaxed text-zinc-500">
            The SCIM app is a second Okta integration, separate from your sign-in app — its own
            SSO doesn't need to be functional. Okta defaults both the OIDC
            <code class="rounded bg-zinc-900 px-1 py-0.5">sub</code>
            and the SCIM <code class="rounded bg-zinc-900 px-1 py-0.5">externalId</code>
            to the Okta user id, so step 3 usually needs no change.
          </p>
        </details>
      </div>
    </.card>
    """
  end

  attr :provider, :map, required: true
  attr :mappings, :list, required: true
  attr :mapping_form, Phoenix.HTML.Form, default: nil
  attr :mapping_role_options, :list, required: true
  attr :editing_mapping_id, :string, default: nil
  attr :mapping_edit_form, Phoenix.HTML.Form, default: nil
  attr :synced_groups, :list, default: []
  attr :adding_mapping, :boolean, default: false

  # The group→role mapping island for one SCIM-enabled connection: intent line,
  # the current mappings (each a directory group → role, with inline edit and a
  # confirm-to-delete), an empty hint when there are none, then the add form.
  # role_label renders the data role value (rendering a label is fine; never
  # branch authz on it).
  defp group_mapping_section(assigns) do
    ~H"""
    <.card padding="p-5">
      <.section_header title="Group → role mapping" count={length(@mappings)} count_tone={:neutral}>
        <:actions>
          <.button
            :if={not @adding_mapping}
            variant={:secondary}
            size={:sm}
            phx-click="add_mapping_form"
            icon="hero-plus"
          >
            Add mapping
          </.button>
        </:actions>
      </.section_header>
      <p class="max-w-prose text-sm leading-6 text-zinc-400">
        Map an IdP group to the role its members land at — a member in several mapped groups
        gets the highest. Owner is never assignable through sync.
        <.doc_link href="/docs/teams-and-access">Roles docs</.doc_link>
      </p>

      <ul :if={@mappings != []} class="mt-4 divide-y divide-zinc-800/70">
        <li :for={mapping <- @mappings} class="py-3 first:pt-0 last:pb-0">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex min-w-0 items-center gap-2.5">
              <.icon name="hero-user-group" class="h-4 w-4 shrink-0 text-zinc-500" />
              <div class="min-w-0">
                <p class="truncate text-sm text-zinc-200">
                  {mapping.external_group_display || mapping.external_group_id}
                </p>
                <p
                  :if={mapping.external_group_display}
                  class="truncate font-mono text-[11px] text-zinc-500"
                >
                  {mapping.external_group_id}
                </p>
              </div>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.chip>{role_label(mapping.role)}</.chip>
              <.button
                :if={@editing_mapping_id != mapping.id}
                variant={:ghost}
                size={:sm}
                phx-click="start_edit_mapping"
                phx-value-id={mapping.id}
              >
                Edit
              </.button>
              <%!-- Reversible config (re-addable; members keep their role until
                   the next sync) — a native confirm fits the tier, not a
                   typed-confirm. `delete_mapping` stays server-authz-gated. --%>
              <.button
                variant={:ghost}
                tone={:rose}
                size={:sm}
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
          <div :if={@editing_mapping_id == mapping.id and @mapping_edit_form} class="mt-3">
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
                <.button variant={:ghost} type="button" phx-click="cancel_edit_mapping">
                  Cancel
                </.button>
              </:actions>
            </.simple_form>
          </div>
        </li>
      </ul>

      <.empty_state :if={@mappings == []} variant={:hint} class="mt-4">
        No group mappings yet. New members land at the connection's default role until you map a
        directory group to a higher one.
      </.empty_state>

      <%!-- Add a mapping — revealed by the "Add mapping" button (not always open);
           a divided region within the card (not a nested box). account_id/provider_id
           are server-side. Pick from synced groups once they exist; free-text before
           the first sync. --%>
      <div :if={@adding_mapping and @mapping_form} class="mt-5 border-t border-zinc-800/70 pt-5">
        <p class="text-sm font-medium text-zinc-300">Add a mapping</p>
        <.simple_form
          for={@mapping_form}
          id={"create-mapping-#{@provider.id}"}
          phx-change="validate_mapping"
          phx-submit="create_mapping"
          class="mt-3"
        >
          <input type="hidden" name="provider_id" value={@provider.id} />
          <%!-- One balanced row: group + optional display + role read left-to-right
               (role rightmost, mirroring the list rows above). Three even columns
               avoid the orphaned third field a 2-col grid leaves. --%>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <.input
              :if={@synced_groups != []}
              field={@mapping_form[:external_group_id]}
              type="select"
              label="IdP group"
              options={Enum.map(@synced_groups, & &1.external_group_id)}
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
            <.button variant={:ghost} type="button" phx-click="cancel_add_mapping">
              Cancel
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </.card>
    """
  end

  attr :synced_groups, :list, required: true

  # The groups the IdP actually pushes over SCIM (id + distinct member count),
  # each annotated with its role mapping — the directory-state companion to the
  # group→role mapping config above. It surfaces groups that sync but aren't
  # mapped (their members stay at the connection's default role), which the
  # mapping list can't show.
  defp synced_groups_card(assigns) do
    ~H"""
    <.card padding="p-5">
      <.section_header title="Synced groups" count={length(@synced_groups)} count_tone={:neutral} />
      <p class="max-w-prose text-sm leading-6 text-zinc-400">
        The groups your IdP pushes over SCIM, with how many synced users are in each. A group with
        no role mapping leaves its members at the connection's default role.
      </p>

      <ul :if={@synced_groups != []} class="mt-4 divide-y divide-zinc-800/70">
        <li
          :for={group <- @synced_groups}
          class="flex flex-wrap items-center justify-between gap-2 py-3 first:pt-0 last:pb-0"
        >
          <div class="flex min-w-0 items-center gap-2.5">
            <.icon name="hero-user-group" class="h-4 w-4 shrink-0 text-zinc-500" />
            <div class="min-w-0">
              <p class="truncate text-sm text-zinc-200">
                {(group.mapping && group.mapping.external_group_display) || group.external_group_id}
              </p>
              <p
                :if={group.mapping && group.mapping.external_group_display}
                class="truncate font-mono text-[11px] text-zinc-500"
              >
                {group.external_group_id}
              </p>
            </div>
          </div>
          <div class="flex shrink-0 items-center gap-3">
            <span class="text-xs tabular-nums text-zinc-400">
              {members_label(group.member_count)}
            </span>
            <.chip :if={group.mapping}>{role_label(group.mapping.role)}</.chip>
            <span :if={!group.mapping} class="text-xs text-zinc-500">No role mapping</span>
          </div>
        </li>
      </ul>

      <.empty_state :if={@synced_groups == []} variant={:hint} class="mt-4">
        No groups synced yet. Once your IdP pushes group memberships over SCIM, they'll appear here
        with their member counts.
      </.empty_state>
    </.card>
    """
  end

  defp members_label(1), do: "1 member"
  defp members_label(count), do: "#{count} members"

  attr :members, :list, required: true
  attr :member_role_options, :list, required: true
  attr :can_manage_team?, :boolean, required: true
  attr :current_user_id, :string, required: true
  attr :scim_enabled, :boolean, required: true

  # The users provisioned through this connection (SCIM sync / SSO first-login /
  # approved link), with portal-based lifecycle actions per row — re-role or
  # suspend/reactivate. The controls act on the Accounts membership (manage_team,
  # which enforces owner / last-owner / self); someone removed from the account
  # whose identity lingers shows "Removed" with no actions.
  defp synced_users_card(assigns) do
    ~H"""
    <.card padding="p-5">
      <.section_header title="Synced users" count={length(@members)} count_tone={:neutral} />
      <p class="max-w-prose text-sm leading-6 text-zinc-400">
        People provisioned through this connection — by directory sync, an SSO first sign-in, or an
        approved link request.
        <span :if={@scim_enabled}>
          Suspend a member here and it holds until you lift it. Roles follow your group → role
          mappings, and directory sync offboards a member automatically when your IdP does.
        </span>
        <span :if={not @scim_enabled}>Re-role or suspend a member here.</span>
      </p>

      <ul :if={@members != []} class="mt-4 divide-y divide-zinc-800/70">
        <li
          :for={member <- @members}
          class="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="truncate text-sm text-zinc-200">
                {member.identity.user.full_name || member.identity.user.email}
              </span>
              <.chip :if={is_nil(member.membership)} tone={:rose}>Removed</.chip>
              <.chip
                :if={member.membership && Accounts.Membership.disabled?(member.membership)}
                tone={:amber}
              >
                Suspended
              </.chip>
              <.chip :if={not member.identity.scim_active}>Deactivated in IdP</.chip>
              <.chip>{provisioned_via_label(member.identity.provisioned_via)}</.chip>
            </div>
            <div class="mt-0.5 truncate text-xs text-zinc-500">
              <span class="font-mono">{synced_external_id(member.identity)}</span>
              <span :if={member.identity.last_seen_at}>
                · last synced <.local_time value={member.identity.last_seen_at} mode={:relative} />
              </span>
            </div>
          </div>

          <div :if={@can_manage_team? and member.membership} class="flex shrink-0 items-center gap-2">
            <%= if member.membership.user_id == @current_user_id do %>
              <span class="text-xs text-zinc-500">you</span>
            <% else %>
              <%!-- On a directory-synced provider the role is the IdP's: a group→role
                 mapping (or the provider default) recomputes it on every sync, so a
                 manual change here silently reverts. Read-only — set it via the
                 group → role mappings above. An OIDC-only provider (no directory sync)
                 keeps the editable select; those roles aren't recomputed. --%>
              <.tooltip
                :if={@scim_enabled}
                text="Role is managed by directory sync — set it with the group → role mappings above"
              >
                <.chip icon="hero-lock-closed-mini">
                  {Emisar.Auth.Role.label(member.membership.role)}
                </.chip>
              </.tooltip>
              <form
                :if={not @scim_enabled}
                id={"synced-role-#{member.membership.id}"}
                phx-change="change_member_role"
              >
                <input type="hidden" name="membership_id" value={member.membership.id} />
                <select
                  name="role"
                  class="rounded-lg border-0 bg-zinc-900 py-1 pl-2 pr-7 text-xs text-zinc-200 ring-1 ring-inset ring-zinc-800 focus:ring-2 focus:ring-inset focus:ring-brand-500"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    @member_role_options,
                    to_string(member.membership.role)
                  )}
                </select>
              </form>
              <%!-- Suspend is reversible (Reactivate undoes it), so it stays a
                   neutral ghost — rose is reserved for the irreversible Delete. --%>
              <.button
                :if={not Accounts.Membership.disabled?(member.membership)}
                variant={:ghost}
                size={:sm}
                phx-click="suspend_member"
                phx-value-membership_id={member.membership.id}
                data-confirm="Suspend this member? They're signed out and blocked until reactivated — and directory sync may reactivate them if your IdP still lists them."
              >
                Suspend
              </.button>
              <.button
                :if={Accounts.Membership.disabled?(member.membership) and member.identity.scim_active}
                variant={:ghost}
                tone={:brand}
                size={:sm}
                phx-click="reinstate_member"
                phx-value-membership_id={member.membership.id}
              >
                Reactivate
              </.button>
              <%!-- The IdP deactivated them — emisar keeps them suspended; reactivation
                 is the IdP's to make (its active:true re-syncs), so no Reactivate here. --%>
              <span
                :if={
                  Accounts.Membership.disabled?(member.membership) and not member.identity.scim_active
                }
                class="text-xs text-zinc-500"
              >
                Reactivate in your IdP
              </span>
            <% end %>
          </div>
        </li>
      </ul>

      <.empty_state :if={@members == []} variant={:hint} class="mt-4">
        No one has been provisioned through this connection yet. Users appear here after they sign in
        through it, or after directory sync provisions them.
      </.empty_state>
    </.card>
    """
  end

  # The identity's directory id — the SCIM externalId if synced, else the OIDC sub.
  defp synced_external_id(identity),
    do: identity.scim_external_id || identity.provider_identifier

  defp provisioned_via_label(:scim), do: "SCIM"
  defp provisioned_via_label(:oidc_jit), do: "SSO"
  defp provisioned_via_label(:manual), do: "Linked"
  defp provisioned_via_label(_), do: "Synced"

  defp approve_confirm(%{matched_user_id: nil}) do
    "Approve access for this user? They'll be able to sign in at the connection's default role."
  end

  defp approve_confirm(%{email: email}) do
    "Link this connection to the existing #{email} account? That IdP identity will then sign in as this existing user."
  end

  defp role_label(role), do: Emisar.Auth.Role.label(role)

  defp provisioner_label(:jit), do: "Auto-provision"
  defp provisioner_label(:manual), do: "Manual approval"

  attr :provider, :map, required: true
  attr :stats, :map, required: true

  # The overview health line for one connection: how many users + distinct groups
  # the directory has actually synced through it, and — for a SCIM connection — how
  # fresh the last sync is (green when synced, amber "never synced" while it waits
  # on the IdP).
  defp sync_meta(assigns) do
    ~H"""
    <div class="mt-1 flex flex-wrap items-center gap-x-1.5 text-[11px] text-zinc-500">
      <span class="tabular-nums">{count_label(@stats.users, "user")}</span>
      <span class="tabular-nums">· {count_label(@stats.groups, "group")}</span>
      <span :if={@provider.scim_enabled and @provider.scim_last_seen_at} class="text-brand-300/90">
        · synced <.local_time value={@provider.scim_last_seen_at} mode={:relative} />
      </span>
      <span
        :if={@provider.scim_enabled and is_nil(@provider.scim_last_seen_at)}
        class="text-amber-300/90"
      >
        · never synced
      </span>
    </div>
    """
  end

  defp count_label(count, singular),
    do: "#{count} #{singular}#{if count == 1, do: "", else: "s"}"

  defp request_label(request),
    do: request.full_name || request.email || request.provider_identifier
end
