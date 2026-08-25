defmodule EmisarWeb.SSOSettingsLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Catalog, Runners, SSO}
  alias EmisarWeb.{ConfirmDialog, LiveForm, LiveTable, MailTo, Permissions, RunnerScope}
  alias Phoenix.LiveView.JS

  @role_mapping_prefix "role_mappings_"
  @runner_access_mapping_prefix "runner_access_mappings_"

  # Humanized provider-kind labels for the select + the row badge — the enum's
  # atoms don't title-case cleanly ("openid_connect" → "OpenID Connect").
  @kind_labels %{
    google_workspace: "Google Workspace",
    okta: "Okta",
    entra: "Microsoft Entra",
    jumpcloud: "JumpCloud",
    keycloak: "Keycloak",
    openid_connect: "OpenID Connect"
  }

  # The provider-kind select. `{label, value}` pairs from the schema's enum;
  # the value stays the atom's string form.
  @kind_options Enum.map(
                  SSO.identity_provider_kinds(),
                  &{Map.fetch!(@kind_labels, &1), Atom.to_string(&1)}
                )

  # Both the default-role and group→role selects OMIT :owner — neither JIT nor
  # directory sync may assign owner (the changeset rejects it too; owner is a
  # deliberate human grant). Don't offer what can't be chosen.
  @role_options Enum.map(
                  Emisar.Auth.roles() -- [:owner],
                  &{Emisar.Auth.role_label(&1), Atom.to_string(&1)}
                )

  @mapping_role_options @role_options

  # The synced-members list re-roles a real membership, so its select offers ALL
  # roles (incl. owner) — unlike the JIT/mapping selects. update_membership_role
  # still enforces the owner / last-owner / self guards server-side.
  @member_role_options Enum.map(
                         Emisar.Auth.roles(),
                         &{Emisar.Auth.role_label(&1), Atom.to_string(&1)}
                       )

  # New member provisioning modes for the form's select. JIT adds the membership on
  # first sign-in; manual parks first sign-ins as pending requests an admin
  # approves. Bespoke prose labels, so a literal list (not capitalized atoms).
  @provisioner_options [
    {"Auto-provision new members on first sign-in", "jit"},
    {"Manual — an admin approves each new member", "manual"}
  ]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Single sign-on")
      |> assign(
        :pack_access_restricted?,
        socket.assigns.current_membership.pack_access_mode == :restricted
      )
      |> assign(:can_configure?, SSO.subject_can_configure_sso?(socket.assigns.current_subject))
      |> assign(:has_sso_permission?, SSO.subject_can_manage_sso?(socket.assigns.current_subject))
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
      # The connection's synced members (identity + membership), loaded on :show.
      |> assign(:synced_members, [])
      |> assign(:synced_members_load_error?, false)
      |> assign(:edit_form, nil)
      # Connection(s) in scope: ALL on :index (a list), the one on :show (detail).
      # Set per-action in handle_params.
      |> assign(:providers, [])
      # Role-mapping state: the per-provider lists + create forms, and the
      # single open inline edit (id + form). Keyed by provider id so each
      # provider's directory-sync panel owns its own mappings + form.
      |> assign(:group_mappings, %{})
      |> assign(:group_mapping_metadata, %{})
      |> assign(:group_mapping_errors, %{})
      |> assign(:synced_groups, %{})
      |> assign(:synced_group_errors, %{})
      |> assign(:mapping_forms, %{})
      |> assign(:editing_mapping_id, nil)
      |> assign(:mapping_edit_form, nil)
      # The add-mapping form is behind an "Add mapping" button, not always open.
      |> assign(:adding_mapping, false)
      |> assign(:runner_access_mappings, %{})
      |> assign(:runner_access_mapping_metadata, %{})
      |> assign(:runner_access_mapping_errors, %{})
      |> assign(:runner_access_mapping_forms, %{})
      |> assign(:editing_runner_access_mapping_id, nil)
      |> assign(:runner_access_mapping_edit_form, nil)
      |> assign(:adding_runner_access_mapping, false)
      |> assign(:runners, [])
      |> assign(:runner_load_error?, false)
      |> assign(:pack_load_error?, false)
      |> assign(:pack_advertisements, %{})
      |> assign(:mapping_filter_params, %{})
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
  # The SSO overview folded into the Team page — /settings/sso is gone; its
  # connections, pending requests, and sign-in link all live on Team now. The
  # per-connection detail (/settings/sso/:id) and Add (/new) stay.
  # Where single sign-on actually lives: the anchored card on the Team page. The
  # `:index` route redirects here, so crumbs must link THIS, not the route that
  # bounces to it.
  defp sso_card_path(account), do: ~p"/app/#{account}/settings/team" <> "#single-sign-on"

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    # The fragment lands the operator on Team's Single sign-on card (its DOM id)
    # instead of the top of a long page — docs and old bookmarks deep-link here.
    destination = sso_card_path(socket.assigns.current_account)
    {:noreply, push_navigate(socket, to: destination)}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load_for_action(socket, params)}
  end

  defp load_for_action(%{assigns: %{has_sso_permission?: false}} = socket, _params), do: socket

  # A downgrade does not stop an existing connection working, so a permission
  # holder can still open it and remove it. Adding and editing are what the plan
  # actually gates, and those views load nothing.
  defp load_for_action(
         %{assigns: %{can_configure?: false, live_action: action}} = socket,
         _params
       )
       when action != :show,
       do: socket

  defp load_for_action(socket, params) do
    if connected?(socket) do
      case socket.assigns.live_action do
        :show ->
          load_show(socket, params)

        :edit ->
          load_edit(socket, params["id"])

        :new ->
          socket
          |> load_runners()
          |> assign_form(SSO.change_provider(socket.assigns.current_subject))
          |> assign(:test_result, nil)
      end
    else
      # A blank form names no runners, so SSO resolves it without a read (IL-18)
      # and /new still renders on the dead pass.
      assign_form(socket, SSO.change_provider(socket.assigns.current_subject))
    end
  end

  # Detail: ONE connection (account-scoped — a cross-account or unknown id is
  # not_found → back to the overview) + its group→role mappings / synced groups.
  defp load_show(socket, params) do
    id = params["id"]

    case SSO.fetch_provider_by_id(id, socket.assigns.current_subject) do
      {:ok, provider} ->
        socket
        |> assign(:loaded?, true)
        |> assign(:providers, [provider])
        |> assign(:mapping_filter_params, Map.drop(params, ["id"]))
        |> assign(:adding_mapping, false)
        |> assign(:adding_runner_access_mapping, false)
        |> load_group_mappings([provider], params)
        |> load_synced_members(provider)
        |> load_runners()
        |> assign_form(SSO.change_provider(socket.assigns.current_subject))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Connection not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")
    end
  end

  # The users provisioned through this connection, each paired with its account
  # membership (nil if the person was fully removed but the identity lingers) — so
  # the "Synced members" card can show state and act on the membership. Two reads
  # (SSO identities + Accounts memberships), zipped by user id; either failing
  # keeps uncertainty explicit instead of asserting that nobody was provisioned.
  defp load_synced_members(socket, provider) do
    subject = socket.assigns.current_subject

    with {:ok, identities} <- SSO.list_synced_users(provider, subject),
         user_ids = Enum.map(identities, & &1.user_id),
         {:ok, memberships} <-
           Accounts.list_memberships_for_users(
             socket.assigns.current_account,
             user_ids,
             subject
           ) do
      membership_by_user = Map.new(memberships, &{&1.user_id, &1})

      members =
        Enum.map(
          identities,
          &%{identity: &1, membership: Map.get(membership_by_user, &1.user_id)}
        )

      socket
      |> assign(:synced_members, members)
      |> assign(:synced_members_load_error?, false)
    else
      _ ->
        socket
        |> assign(:synced_members, [])
        |> assign(:synced_members_load_error?, true)
    end
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
        |> load_runners()
        |> assign_edit_form(provider)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Connection not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")
    end
  end

  defp load_runners(socket) do
    {advertisements, pack_load_error?} = account_pack_advertisements(socket)

    socket =
      socket
      |> assign(:pack_advertisements, advertisements)
      |> assign(:pack_load_error?, pack_load_error?)

    case Runners.list_all_runners_for_account(socket.assigns.current_subject) do
      {:ok, runners} ->
        socket
        |> assign(:runners, runners)
        |> assign(:runner_load_error?, false)

      {:error, _reason} ->
        socket
        |> assign(:runners, [])
        |> assign(:runner_load_error?, true)
    end
  end

  # A role without view_catalog gets no pack choices rather than a crash — the
  # same shape as the runner load above. The flag says whether the empty map is
  # a real answer or a failed read, so a pack picker cannot report "No packs on
  # the selected runners" for packs it never read.
  defp account_pack_advertisements(socket) do
    subject = socket.assigns.current_subject

    case Catalog.list_pack_advertisements(subject) do
      {:ok, advertisements} -> {advertisements, false}
      {:error, _reason} -> {%{}, Catalog.subject_can_view_packs?(subject)}
    end
  end

  # Role mappings only exist for SCIM-enabled providers; load each one's
  # list + seed a fresh create form, both keyed by provider id.
  defp load_group_mappings(socket, providers, params) do
    scim_providers = Enum.filter(providers, & &1.scim_enabled)

    role_opts = LiveTable.params_to_opts(params, [], prefix: @role_mapping_prefix)

    runner_access_opts =
      LiveTable.params_to_opts(params, [], prefix: @runner_access_mapping_prefix)

    role_reads = Map.new(scim_providers, &{&1.id, list_mappings(socket, &1, role_opts)})

    runner_access_reads =
      Map.new(
        scim_providers,
        &{&1.id, list_runner_access_mappings(socket, &1, runner_access_opts)}
      )

    role_mappings = paged_rows(role_reads)
    runner_access_mappings = paged_rows(runner_access_reads)

    # The groups the IdP has actually synced (id + member count), each annotated
    # with its role mapping — powers the "Synced groups" readout, and (projected
    # to ids) the map-after-first-sync picker.
    synced_reads =
      Map.new(scim_providers, fn provider ->
        {groups, failed?} = list_synced_groups(socket, provider)

        {provider.id, {groups, failed?}}
      end)

    forms = Map.new(scim_providers, &{&1.id, mapping_form(&1)})
    runner_access_forms = runner_access_mapping_forms(socket, scim_providers)

    socket
    |> assign(:group_mappings, role_mappings)
    |> assign(:group_mapping_metadata, paged_metadata(role_reads))
    |> assign(:group_mapping_errors, paged_read_errors(role_reads))
    |> assign(:runner_access_mappings, runner_access_mappings)
    |> assign(:runner_access_mapping_metadata, paged_metadata(runner_access_reads))
    |> assign(:runner_access_mapping_errors, paged_read_errors(runner_access_reads))
    |> assign(:synced_groups, rows(synced_reads))
    |> assign(:synced_group_errors, read_errors(synced_reads))
    |> assign(:mapping_forms, forms)
    |> assign(:runner_access_mapping_forms, runner_access_forms)
  end

  # Each per-provider read is kept as `{rows, read_failed?}` and split here: the
  # rows render the list, the flag keeps a failed read from rendering as that
  # section's "no mappings / no groups" — which on this page reads as a claim
  # that the directory grants nobody a role or extra runner reach.
  defp rows(reads), do: Map.new(reads, fn {id, {rows, _failed?}} -> {id, rows} end)

  defp read_errors(reads), do: Map.new(reads, fn {id, {_rows, failed?}} -> {id, failed?} end)

  defp paged_rows(reads),
    do: Map.new(reads, fn {id, {rows, _metadata, _failed?}} -> {id, rows} end)

  defp paged_metadata(reads),
    do: Map.new(reads, fn {id, {_rows, metadata, _failed?}} -> {id, metadata} end)

  defp paged_read_errors(reads),
    do: Map.new(reads, fn {id, {_rows, _metadata, failed?}} -> {id, failed?} end)

  defp list_synced_groups(socket, provider) do
    case SSO.list_synced_groups(provider, socket.assigns.current_subject) do
      {:ok, groups} -> {groups, false}
      {:error, _} -> {[], true}
    end
  end

  defp list_mappings(socket, provider, opts) do
    case SSO.list_group_mappings(provider, socket.assigns.current_subject, opts) do
      {:ok, mappings, metadata} -> {mappings, metadata, false}
      {:error, _} -> {[], empty_metadata(), true}
    end
  end

  defp list_runner_access_mappings(socket, provider, opts) do
    case SSO.list_group_runner_access_mappings(
           provider,
           socket.assigns.current_subject,
           opts
         ) do
      {:ok, mappings, metadata} -> {mappings, metadata, false}
      {:error, _reason} -> {[], empty_metadata(), true}
    end
  end

  defp empty_metadata, do: %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0}

  def handle_event("validate", %{"provider" => params} = event, socket) do
    case SSO.change_provider(%SSO.IdentityProvider{}, params, socket.assigns.current_subject) do
      {:ok, changeset} ->
        changeset = LiveForm.on_change(changeset, event)
        {:noreply, socket |> assign_form(changeset) |> assign(:test_result, nil)}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
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

  def handle_event("validate_edit", %{"provider_id" => id, "provider" => params} = event, socket) do
    case find_provider(socket, id) do
      nil -> {:noreply, socket}
      provider -> {:noreply, assign_edit_form(socket, provider, params, event)}
    end
  end

  def handle_event("update", %{"provider_id" => id, "provider" => params}, socket) do
    Permissions.gated(socket, socket.assigns.can_configure?, &do_update(&1, id, params))
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Permissions.gated(socket, socket.assigns.has_sso_permission?, &do_delete(&1, id))
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
      socket.assigns.has_sso_permission?,
      &do_disable_scim(&1, id)
    )
  end

  def handle_event("dismiss_scim_token", _params, socket) do
    {:noreply, assign(socket, :scim_token, nil)}
  end

  # -- Role mapping -------------------------------------------

  def handle_event(
        "validate_mapping",
        %{"provider_id" => id, "mapping" => params} = event,
        socket
      ) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        changeset = mapping_changeset(provider, params) |> LiveForm.on_change(event)
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

  # -- Group -> runner access mapping ---------------------------------

  def handle_event(
        "validate_runner_access_mapping",
        %{"provider_id" => id, "runner_access_mapping" => params} = event,
        socket
      ) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, socket}

      provider ->
        case SSO.change_group_runner_access_mapping(
               provider,
               params,
               socket.assigns.current_subject
             ) do
          {:ok, changeset} ->
            form = runner_access_mapping_to_form(provider, LiveForm.on_change(changeset, event))
            {:noreply, put_runner_access_mapping_form(socket, id, form)}

          {:error, :unauthorized} ->
            {:noreply, socket}
        end
    end
  end

  def handle_event(
        "create_runner_access_mapping",
        %{"provider_id" => id, "runner_access_mapping" => params},
        socket
      ) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_create_runner_access_mapping(&1, id, params)
    )
  end

  def handle_event("add_runner_access_mapping_form", _params, socket),
    do: {:noreply, assign(socket, :adding_runner_access_mapping, true)}

  def handle_event("cancel_add_runner_access_mapping", _params, socket) do
    socket =
      case socket.assigns.providers do
        [provider | _] -> reset_runner_access_mapping_form(socket, provider)
        _ -> socket
      end

    {:noreply, assign(socket, :adding_runner_access_mapping, false)}
  end

  def handle_event("start_edit_runner_access_mapping", %{"id" => id}, socket) do
    case find_runner_access_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        {:noreply,
         socket
         |> assign(:editing_runner_access_mapping_id, id)
         |> assign_runner_access_mapping_edit_form(mapping)}
    end
  end

  def handle_event("cancel_edit_runner_access_mapping", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_runner_access_mapping_id, nil)
     |> assign(:runner_access_mapping_edit_form, nil)}
  end

  def handle_event(
        "validate_edit_runner_access_mapping",
        %{"runner_access_mapping_id" => id, "runner_access_mapping" => params} = event,
        socket
      ) do
    case find_runner_access_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        {:noreply, assign_runner_access_mapping_edit_form(socket, mapping, params, event)}
    end
  end

  def handle_event(
        "update_runner_access_mapping",
        %{"runner_access_mapping_id" => id, "runner_access_mapping" => params},
        socket
      ) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_update_runner_access_mapping(&1, id, params)
    )
  end

  def handle_event("delete_runner_access_mapping", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      socket.assigns.can_configure_directory_sync?,
      &do_delete_runner_access_mapping(&1, id)
    )
  end

  # Typed-confirm state for the "Delete connection" dialog (UX friction only —
  # `delete` above stays the server gate).
  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  # -- Synced members — member lifecycle (acts on the Accounts membership) ---
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
    case SSO.configure_provider(params, socket.assigns.current_subject) do
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
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

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
        # Pass the blank secret THROUGH. Whether a blank means "keep the stored
        # one" is a security decision — it does not, when the issuer or client id
        # is being repointed — and the domain owns it. Stripping here left the
        # domain unable to tell "not supplied" from "supplied unchanged".
        case SSO.update_provider(provider, params, socket.assigns.current_subject) do
          {:ok, _provider} ->
            {:noreply,
             socket
             |> put_flash(:info, "Connection updated.")
             |> push_navigate(
               to: ~p"/app/#{socket.assigns.current_account}/settings/sso/#{provider.id}"
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            # Render the changeset the WRITE returned. Rebuilding a fresh one
            # from the same params re-runs only the in-process validations, so
            # the database's verdict — a second connection claiming an allowed
            # email domain already taken — was dropped and the form came back
            # with no error at all.
            form = edit_form(provider, Map.put(changeset, :action, :update))
            {:noreply, assign(socket, :edit_form, form)}

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
             |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")}

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
           |> put_flash(:info, "Role mapping added.")
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
             |> put_flash(:info, "Role mapping updated.")
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
             |> put_flash(:info, "Role mapping deleted.")
             |> reload_mappings_for_id(deleted.provider_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_create_runner_access_mapping(socket, provider_id, params) do
    with_provider(socket, provider_id, fn provider ->
      case SSO.create_group_runner_access_mapping(
             provider,
             params,
             socket.assigns.current_subject
           ) do
        {:ok, _mapping} ->
          {:noreply,
           socket
           |> put_flash(:info, "Group runner access added.")
           |> reset_runner_access_mapping_form(provider)
           |> reload_runner_access_mappings(provider)}

        {:error, %Ecto.Changeset{} = changeset} ->
          form = runner_access_mapping_to_form(provider, Map.put(changeset, :action, :insert))
          {:noreply, put_runner_access_mapping_form(socket, provider_id, form)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp do_update_runner_access_mapping(socket, id, params) do
    case find_runner_access_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        case SSO.update_group_runner_access_mapping(
               mapping,
               params,
               socket.assigns.current_subject
             ) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Group runner access updated.")
             |> assign(:editing_runner_access_mapping_id, nil)
             |> assign(:runner_access_mapping_edit_form, nil)
             |> reload_runner_access_mappings_for_id(updated.provider_id)}

          {:error, %Ecto.Changeset{} = changeset} ->
            form =
              runner_access_mapping_edit_form(mapping, Map.put(changeset, :action, :update))

            {:noreply, assign(socket, :runner_access_mapping_edit_form, form)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_delete_runner_access_mapping(socket, id) do
    case find_runner_access_mapping(socket, id) do
      nil ->
        {:noreply, socket}

      mapping ->
        case SSO.delete_group_runner_access_mapping(mapping, socket.assigns.current_subject) do
          {:ok, deleted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Group runner access deleted.")
             |> reload_runner_access_mappings_for_id(deleted.provider_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  # A full reload after a provider mutation: refresh the connection list, the
  # group→role mappings, AND the pending manual-link requests — so enabling
  # directory sync (re)seeds a provider's panels, and approving/dismissing a
  # request drops it from the list.
  defp reload(socket) do
    reload_show(socket)
  end

  # Re-fetch the one connection :show is on (its row may have changed — SCIM
  # toggled, edited). If it vanished (deleted), load_show falls back to the overview.
  defp reload_show(socket) do
    case socket.assigns.providers do
      [provider | _] ->
        params = Map.put(socket.assigns.mapping_filter_params, "id", provider.id)
        load_show(socket, params)

      _ ->
        socket
    end
  end

  # Refresh just one provider's mapping list (after a mapping CRUD), leaving the
  # other providers' panels untouched.
  defp reload_mappings(socket, provider) do
    opts =
      LiveTable.params_to_opts(
        socket.assigns.mapping_filter_params,
        [],
        prefix: @role_mapping_prefix
      )

    {mappings, metadata, failed?} = list_mappings(socket, provider, opts)

    socket
    |> put_mappings(provider.id, mappings)
    |> put_mapping_metadata(:group_mapping_metadata, provider.id, metadata)
    |> put_read_error(:group_mapping_errors, provider.id, failed?)
    |> reload_synced_groups(provider)
  end

  # The synced-groups readout carries each group's mapping badge, so a mapping
  # CRUD has to re-annotate it too. Refreshing only the mapping LIST left the
  # readout showing a role badge for a mapping that had just been deleted. The
  # groups themselves have not changed — this re-derives their annotation from
  # the mapping lists now in the socket, with no extra read.
  defp reload_synced_groups(socket, provider) do
    {groups, failed?} = list_synced_groups(socket, provider)

    socket
    |> assign(:synced_groups, Map.put(socket.assigns.synced_groups, provider.id, groups))
    |> put_read_error(:synced_group_errors, provider.id, failed?)
  end

  defp reload_mappings_for_id(socket, provider_id) do
    case find_provider(socket, provider_id) do
      nil -> socket
      provider -> reload_mappings(socket, provider)
    end
  end

  defp reload_runner_access_mappings(socket, provider) do
    opts =
      LiveTable.params_to_opts(
        socket.assigns.mapping_filter_params,
        [],
        prefix: @runner_access_mapping_prefix
      )

    {mappings, metadata, failed?} = list_runner_access_mappings(socket, provider, opts)

    socket
    |> assign(
      :runner_access_mappings,
      Map.put(socket.assigns.runner_access_mappings, provider.id, mappings)
    )
    |> put_mapping_metadata(:runner_access_mapping_metadata, provider.id, metadata)
    |> put_read_error(:runner_access_mapping_errors, provider.id, failed?)
    |> reload_synced_groups(provider)
  end

  defp reload_runner_access_mappings_for_id(socket, provider_id) do
    case find_provider(socket, provider_id) do
      nil -> socket
      provider -> reload_runner_access_mappings(socket, provider)
    end
  end

  defp put_mappings(socket, provider_id, mappings) do
    assign(
      socket,
      :group_mappings,
      Map.put(socket.assigns.group_mappings, provider_id, mappings)
    )
  end

  defp put_read_error(socket, assign_name, provider_id, failed?) do
    errors = Map.put(socket.assigns[assign_name], provider_id, failed?)
    assign(socket, assign_name, errors)
  end

  defp put_mapping_metadata(socket, assign_name, provider_id, metadata) do
    values = Map.put(socket.assigns[assign_name], provider_id, metadata)
    assign(socket, assign_name, values)
  end

  defp put_mapping_form(socket, provider_id, form),
    do: assign(socket, :mapping_forms, Map.put(socket.assigns.mapping_forms, provider_id, form))

  defp put_runner_access_mapping_form(socket, provider_id, form) do
    forms = Map.put(socket.assigns.runner_access_mapping_forms, provider_id, form)
    assign(socket, :runner_access_mapping_forms, forms)
  end

  defp find_provider(socket, id), do: Enum.find(socket.assigns.providers, &(&1.id == id))

  defp find_mapping(socket, id) do
    socket.assigns.group_mappings
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == id))
  end

  defp find_runner_access_mapping(socket, id) do
    socket.assigns.runner_access_mappings
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == id))
  end

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
      |> LiveForm.on_change()

    to_form(changeset, as: "mapping", id: "edit-mapping-#{mapping.id}")
  end

  # SSO owns the runner-access mapping form — it resolves the raw picker values
  # against the account's live runners — so the web passes them through and
  # renders what comes back.
  defp runner_access_mapping_forms(socket, providers) do
    providers
    |> Enum.flat_map(fn provider ->
      case SSO.change_group_runner_access_mapping(provider, %{}, socket.assigns.current_subject) do
        {:ok, changeset} -> [{provider.id, runner_access_mapping_to_form(provider, changeset)}]
        {:error, :unauthorized} -> []
      end
    end)
    |> Map.new()
  end

  defp reset_runner_access_mapping_form(socket, provider) do
    case SSO.change_group_runner_access_mapping(provider, %{}, socket.assigns.current_subject) do
      {:ok, changeset} ->
        put_runner_access_mapping_form(
          socket,
          provider.id,
          runner_access_mapping_to_form(provider, changeset)
        )

      {:error, :unauthorized} ->
        socket
    end
  end

  defp runner_access_mapping_to_form(provider, %Ecto.Changeset{} = changeset) do
    to_form(changeset,
      as: "runner_access_mapping",
      id: "create-runner-access-mapping-#{provider.id}"
    )
  end

  # The inline edit form for one mapping. With no input it renders the stored
  # selection; with submitted params it renders exactly what was chosen, so a
  # rejected save comes back with the operator's picks still in the picker.
  defp assign_runner_access_mapping_edit_form(socket, mapping, params \\ %{}, event \\ %{}) do
    case SSO.change_group_runner_access_mapping(mapping, params, socket.assigns.current_subject) do
      {:ok, changeset} ->
        changeset = if params == %{}, do: changeset, else: LiveForm.on_change(changeset, event)

        assign(
          socket,
          :runner_access_mapping_edit_form,
          runner_access_mapping_edit_form(mapping, changeset)
        )

      {:error, :unauthorized} ->
        socket
    end
  end

  defp runner_access_mapping_edit_form(mapping, %Ecto.Changeset{} = changeset) do
    to_form(changeset,
      as: "runner_access_mapping",
      id: "edit-runner-access-mapping-#{mapping.id}"
    )
  end

  defp error_message(:sso_not_available), do: "Single sign-on requires a Team or Enterprise plan."
  defp error_message(:unauthorized), do: "You don't have permission to configure single sign-on."
  defp error_message(:not_found), do: "That no longer exists — it may have just been removed."

  defp error_message(:require_sso_last_provider) do
    "This is the only active SSO connection and the account requires single sign-on. Turn off the SSO requirement (Team → Single sign-on) before disabling or deleting it."
  end

  defp error_message(:client_secret_required) do
    "Changing the issuer or client ID needs the client secret again — emisar sends it to the endpoints that issuer publishes, so it can't carry the old one over to a new provider."
  end

  defp error_message(:identity_namespace_locked) do
    "This connection has already signed people in, so its issuer, client ID and identifier claim are fixed — changing them would repoint existing members' identities at whoever the new provider asserts. Rotate the client secret here; to move to a different provider, add a new connection."
  end

  defp error_message(:scim_not_supported) do
    "This provider can't push a directory to emisar, so there's no SCIM token to issue. Members provision on their first sign-in instead."
  end

  defp error_message(:blocked_discovery_endpoint) do
    "That issuer's discovery document points one of its endpoints at a private or non-HTTPS address, so emisar won't call it. Check the provider's configuration."
  end

  defp error_message(:role_exceeds_your_permissions) do
    "You can only hand out a role you hold yourself. Ask an owner to set this one."
  end

  defp error_message(:link_target_outranks_approver) do
    "That email belongs to a member whose role you can't manage, so linking an identity to them isn't something this role can approve. An owner can approve it."
  end

  defp error_message(:link_target_in_other_accounts) do
    "That email belongs to someone who is also a member of another workspace. Linking here would give this connection's sign-in their access there too, so it can't be approved from this workspace."
  end

  defp error_message(:email_taken) do
    "A user with that email already exists. Approving would create a duplicate, so this request can't be auto-approved."
  end

  defp error_message(_) do
    "That action didn't complete. Refresh to see the connection's current state, then try again."
  end

  # Member-lifecycle errors from Accounts (change role / suspend / reinstate) —
  # kept separate from the SSO-config error_message/1 so each reads for its surface.
  defp member_error(reason), do: EmisarWeb.MemberErrors.message(reason)

  # The create form and any open inline edit form coexist in the DOM, so each
  # gets its own `id` — otherwise their inputs collide on `provider_<field>`.
  # SSO owns the config form — it resolves the raw runner-scope selection
  # against the account — so a subject that may not manage single sign-on gets
  # no form and the page renders its permission state instead.
  defp assign_form(socket, {:ok, changeset}), do: assign_form(socket, changeset)
  defp assign_form(socket, {:error, :unauthorized}), do: socket

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "provider", id: "create-provider"))

  # The inline edit form. `change_provider` returns a presentation-safe
  # changeset — the stored, write-only client_secret is never in it — so leaving
  # the field blank keeps the stored secret, unless the edit repoints the issuer
  # or client id, which the domain refuses without one. With no input it seeds
  # the picker from the stored runner scope.
  defp assign_edit_form(socket, provider, params \\ %{}, event \\ %{}) do
    case SSO.change_provider(provider, params, socket.assigns.current_subject) do
      {:ok, changeset} ->
        changeset = if params == %{}, do: changeset, else: LiveForm.on_change(changeset, event)

        assign(socket, :edit_form, edit_form(provider, changeset))

      {:error, :unauthorized} ->
        socket
    end
  end

  defp edit_form(provider, %Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: "provider", id: "edit-provider-#{provider.id}")

  defp kind_label(kind), do: Map.fetch!(@kind_labels, kind)

  defp scim_sales_mailto(account, user) do
    context = MailTo.context(%{current_account: account, current_user: user})

    MailTo.sales(
      subject: "SCIM directory sync - #{account.name}",
      context: context
    )
  end

  def render(assigns) do
    ~H"""
    <.console_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      section={:team}
      width={:table}
    >
      <:title>
        <%!-- The detail view titles itself with the connection, like every
             other detail page (detail_header family); /new titles itself with
             its JOB (§7.1); the list carries the section name with a back link
             to Team, its owning page (SSO has no nav item of its own). --%>
        <%!-- SSO has no nav item of its own — it lives on the Team page — so every
             view here reads Team / Single sign-on / <this page>. The middle crumb
             points at Team's anchored SSO card, NOT /settings/sso: that route is a
             pure redirect to exactly this anchor, so linking it made the crumb
             bounce through a dead stop. --%>
        <%= case {@live_action, @providers} do %>
          <% {:show, [provider | _]} -> %>
            <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
            <.detail_header
              back="Single sign-on"
              navigate={sso_card_path(@current_account)}
              title={provider.name}
            />
          <% {:new, _} -> %>
            <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
            <.detail_header
              back="Single sign-on"
              navigate={sso_card_path(@current_account)}
              title="Add connection"
            />
          <% {:edit, [provider | _]} -> %>
            <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
            <.back_link navigate={sso_card_path(@current_account)}>Single sign-on</.back_link>
            <.detail_header
              back={provider.name}
              navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
              title="Edit connection"
            />
          <% _ -> %>
            <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
            Single sign-on
        <% end %>
      </:title>
      <:actions
        :for={provider <- @providers}
        :if={@can_configure? and @live_action == :show}
      >
        <%!-- These act on the connection record, so they live opposite its
             title like every other detail-page action. The status row below
             stays a facts-only read rather than becoming an action toolbar. --%>
        <.button
          id={"view-provider-activity-#{provider.id}"}
          navigate={
            ~p"/app/#{@current_account}/audit?#{[target_kind: "identity_provider", target_id: provider.id]}"
          }
          variant={:secondary}
          size={:md}
        >
          View activity
        </.button>
        <.button
          id={"edit-provider-#{provider.id}"}
          navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}/edit"}
          variant={:secondary}
          size={:md}
        >
          Edit
        </.button>
      </:actions>
      <div :if={not @can_configure?}>
        <%!-- Two different locks, two different messages (§4): a role gate is
             not an upsell, and pitching plans to an admin-less operator on an
             Enterprise account read as a billing bug. --%>
        <.empty_state
          :if={not @has_sso_permission?}
          icon="state.locked"
          title="Single sign-on needs an owner or admin role."
        >
          Providers, enforcement, and directory sync are configured by account
          owners and admins.
        </.empty_state>
        <.locked :if={@has_sso_permission?} current_account={@current_account} />
        <.plan_locked_connection
          :for={provider <- @providers}
          :if={@has_sso_permission? and @live_action == :show}
          provider={provider}
          typed={@typed}
        />
      </div>

      <div :if={@can_configure?} class="space-y-6">
        <%!-- Adding a connection is its own view (/settings/sso/new): a bare
             sub-header over sibling field islands (Provider · OIDC · …), never
             one giant card. --%>
        <%!-- The per-provider steps teach BESIDE the form rather than above it, so
             the fields stay one uninterrupted column. The rail waits for xl: at
             narrower widths a 20rem column would crowd a max-w-3xl form, so the
             guide stacks back on top instead. --%>
        <div
          :if={@live_action == :new}
          class="grid grid-cols-1 gap-x-12 gap-y-6 xl:grid-cols-[minmax(0,48rem)_20rem] xl:items-start"
        >
          <div class="order-2 space-y-5 xl:order-1">
            <%!-- The shell title carries the job + the ONE back affordance; no
               second in-body title. --%>
            <p class="max-w-prose text-sm leading-relaxed text-zinc-400">
              We'll use the issuer's OIDC discovery document. Follow the steps in each section to
              create an OAuth/OIDC app at your provider, then paste its client ID and secret.
            </p>

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
                runners={@runners}
                pack_advertisements={@pack_advertisements}
                pack_access_restricted?={@pack_access_restricted?}
                runner_load_error?={@runner_load_error?}
                pack_load_error?={@pack_load_error?}
                guide_id="new"
                callback_url={@callback_url}
                inline_guide?={false}
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

          <%!-- Naked rail, the install-wizard grammar: separated by air, never
               boxed. Sticky so the steps stay in view while the operator works
               down a long form. --%>
          <aside class="order-1 xl:order-2 xl:sticky xl:top-6">
            <.provider_setup_guide
              id="new-rail"
              kind={form_kind(@form, @kind_options)}
              callback_url={@callback_url}
            />
          </aside>
        </div>

        <%!-- Editing is its own view (/settings/sso/:id/edit), like /new — a bare
             sub-header over the same sibling field islands, never an inline
             collapsed block and never one giant card. --%>
        <div :if={@live_action == :edit} class="max-w-3xl space-y-5">
          <div :for={provider <- @providers} class="space-y-5">
            <%!-- No second crumb or heading here: the shell header already reads
                 Team / Single sign-on / <provider> / Edit connection. --%>
            <p class="max-w-prose text-sm leading-relaxed text-zinc-400">
              Update this connection's OIDC settings. Leave the client secret blank to keep the
              stored one.
            </p>

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
                runners={@runners}
                pack_advertisements={@pack_advertisements}
                pack_access_restricted?={@pack_access_restricted?}
                runner_load_error?={@runner_load_error?}
                pack_load_error?={@pack_load_error?}
                guide_id={provider.id}
                callback_url={@callback_url}
                editing?
              />
              <:actions>
                <%!-- Emerald once edited, quiet outlined while clean (house
                     pattern — the button is the unsaved-changes signal). --%>
                <.button
                  variant={if @edit_form.source.changes == %{}, do: :secondary, else: :primary}
                  phx-disable-with="Saving..."
                >
                  Save changes
                </.button>
                <.button
                  navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
                  variant={:ghost}
                >
                  Cancel
                </.button>
              </:actions>
            </.simple_form>
          </div>

          <div :if={not @loaded?} class="text-sm text-zinc-400">Loading…</div>
        </div>

        <%!-- ── Pending access requests (needs attention) ──────────────────
             People blocked waiting for an admin, across ALL connections. The
             time-sensitive job, so it leads the overview. --%>
        <%!-- ── Connections (overview) ──────────────────────────────────────
             A bounded set; each row is a SUMMARY that opens its own detail page.
             Config (edit, SCIM, group→role) lives on the detail, not here. --%>
        <%!-- The branded sign-in link to hand to the team — a quiet utility, so it
             sits at the bottom and lets the needs-attention block lead. Always
             useful (email sign-in works without SSO), so it's not gated on
             providers. NAKED — the code_line is the artifact. --%>
        <%!-- ── Connection detail (/settings/sso/:id) ───────────────────────
             One connection: identity + status + config (edit, directory sync,
             group→role). @providers holds exactly the one handle_params loaded. --%>
        <%!-- Back crumb + entity name live in the shell header (detail_header),
             like every other detail page. --%>
        <%!-- The help moved out of the sections into a rail beside them, so the
             data starts at its own heading. The rail waits for xl — below that a
             20rem column would crowd the lists — and stacks BELOW the connection
             rather than above it: this is a status page, so the record leads. --%>
        <div
          :if={@live_action == :show}
          class="mt-4"
        >
          <%!-- Each section and its note are SIBLING cells of one grid, so the
               note sits in that section's row — "Synced groups" explained beside
               Synced groups, not stacked with everything else at the top. Rows are
               implicit: emit section, note, section, note. A section with nothing
               to say emits a spacer, hidden below xl so it costs no row there. --%>
          <div
            :for={provider <- @providers}
            class="grid grid-cols-1 gap-x-12 gap-y-12 xl:grid-cols-[minmax(0,1fr)_18rem] xl:items-start"
          >
            <%!-- The title already names the connection. Its operational facts
                 follow the detail-page meta grammar used by approvals, then the
                 durable configuration reads as a compact definition table. --%>
            <section id="connection-summary">
              <dl class="grid min-w-0 grid-cols-2 gap-x-8 gap-y-4 sm:grid-cols-4">
                <div>
                  <dt class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                    Status
                  </dt>
                  <dd class="mt-1 flex items-center gap-2 text-sm font-medium">
                    <.status_dot tone={if(provider.enabled, do: :brand, else: :amber)} />
                    <span class={if(provider.enabled, do: "text-brand-300", else: "text-amber-300")}>
                      {if(provider.enabled, do: "Enabled", else: "Disabled")}
                    </span>
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                    Provider
                  </dt>
                  <dd class="mt-1 text-sm text-zinc-300">{kind_label(provider.kind)}</dd>
                </div>
                <div>
                  <dt class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                    New members
                  </dt>
                  <dd class="mt-1 text-sm text-zinc-300">
                    {provisioner_label(provider.provisioner)}
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                    Default role
                  </dt>
                  <dd class="mt-1 text-sm text-zinc-300">{role_label(provider.default_role)}</dd>
                </div>
              </dl>

              <div class="mt-8">
                <.section_header title="Connection settings" />
                <dl class="divide-y divide-zinc-800/70 border-y border-zinc-800/70">
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Issuer</dt>
                    <dd class="break-all font-mono text-sm text-zinc-300">{provider.issuer}</dd>
                  </div>
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Identifier claim</dt>
                    <dd class="font-mono text-sm text-zinc-300">{provider.identifier_claim}</dd>
                  </div>
                  <div
                    :if={provider.allowed_email_domain}
                    class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4"
                  >
                    <dt class="text-xs font-medium text-zinc-400">Email domain</dt>
                    <dd class="text-sm text-zinc-300">@{provider.allowed_email_domain}</dd>
                  </div>
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Runner access</dt>
                    <dd class="text-sm text-zinc-300">
                      {runner_access_mode_label(provider.default_runner_access_mode)}
                    </dd>
                  </div>
                  <div
                    :if={provider.default_runner_access_mode != :none}
                    class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4"
                  >
                    <dt class="text-xs font-medium text-zinc-400">Pack access</dt>
                    <dd class="text-sm text-zinc-300">
                      {pack_access_mode_label(provider.default_pack_access_mode)}
                    </dd>
                  </div>
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Two-factor authentication</dt>
                    <dd class="text-sm text-zinc-300">
                      {if(provider.satisfies_mfa,
                        do: "Satisfied by this provider",
                        else: "Not satisfied by this provider"
                      )}
                    </dd>
                  </div>
                </dl>
              </div>
            </section>

            <aside class="text-sm leading-relaxed xl:pt-1">
              <p class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">Docs</p>
              <ul class="mt-3 space-y-2">
                <li>
                  <.doc_link href={docs_path_for_kind(to_string(provider.kind))}>
                    Setting up {setup_kind_label(to_string(provider.kind))}
                  </.doc_link>
                </li>
                <li :if={SSO.supports_scim?(provider.kind)}>
                  <.doc_link href="/docs/scim">Directory sync</.doc_link>
                </li>
                <li><.doc_link href="/docs/teams-and-access">Roles &amp; access</.doc_link></li>
              </ul>
            </aside>

            <.scim_section
              :if={@can_configure_directory_sync? and SSO.supports_scim?(provider.kind)}
              provider={provider}
              scim_base_url={@scim_base_url}
              scim_token={@scim_token}
            />
            <%!-- The provider kind only says SCIM is supported; it does not mean
                 this connection has enabled provisioning. --%>
            <.section_note :if={@can_configure_directory_sync? and provider.scim_enabled}>
              Members and groups stay in sync with your identity provider. Remove someone there to
              remove their Emisar access.
            </.section_note>

            <%!-- This kind can't push SCIM (e.g. Google Workspace) — say so once
                 instead of dangling an enable panel or an Enterprise upsell for a
                 feature that could never connect. --%>
            <p
              :if={not SSO.supports_scim?(provider.kind)}
              class="max-w-prose text-sm leading-relaxed text-zinc-400"
            >
              <span class="font-medium text-zinc-200">Directory sync</span>
              isn't available for {kind_label(provider.kind)}. Members are added when they first
              sign in through this connection.
            </p>
            <.section_spacer :if={not SSO.supports_scim?(provider.kind)} />

            <.role_mapping_section
              :if={@can_configure_directory_sync? and provider.scim_enabled}
              provider={provider}
              path={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
              mappings={Map.get(@group_mappings, provider.id, [])}
              metadata={Map.get(@group_mapping_metadata, provider.id, empty_metadata())}
              filter_params={@mapping_filter_params}
              load_error?={Map.get(@group_mapping_errors, provider.id, false)}
              synced_groups={Map.get(@synced_groups, provider.id, [])}
              mapping_form={Map.get(@mapping_forms, provider.id)}
              mapping_role_options={@mapping_role_options}
              editing_mapping_id={@editing_mapping_id}
              mapping_edit_form={@mapping_edit_form}
              adding_mapping={@adding_mapping}
            />
            <.section_note :if={@can_configure_directory_sync? and provider.scim_enabled}>
              Choose the role for each synced group. If someone belongs to several mapped groups,
              the highest role wins. Sync never grants Owner.
            </.section_note>

            <.group_runner_access_mapping_section
              :if={@can_configure_directory_sync? and provider.scim_enabled}
              provider={provider}
              path={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
              mappings={Map.get(@runner_access_mappings, provider.id, [])}
              metadata={Map.get(@runner_access_mapping_metadata, provider.id, empty_metadata())}
              filter_params={@mapping_filter_params}
              load_error?={Map.get(@runner_access_mapping_errors, provider.id, false)}
              synced_groups={Map.get(@synced_groups, provider.id, [])}
              mapping_form={Map.get(@runner_access_mapping_forms, provider.id)}
              editing_mapping_id={@editing_runner_access_mapping_id}
              mapping_edit_form={@runner_access_mapping_edit_form}
              adding_mapping={@adding_runner_access_mapping}
              runners={@runners}
              pack_advertisements={@pack_advertisements}
              pack_access_restricted?={@pack_access_restricted?}
            />
            <.section_note :if={@can_configure_directory_sync? and provider.scim_enabled}>
              Each mapping adds runner and pack access to the connection defaults. Groups are
              matched by ID, not by name.
            </.section_note>

            <.synced_groups_section
              :if={@can_configure_directory_sync? and provider.scim_enabled}
              synced_groups={Map.get(@synced_groups, provider.id, [])}
              load_error?={Map.get(@synced_group_errors, provider.id, false)}
            />
            <.section_note :if={@can_configure_directory_sync? and provider.scim_enabled}>
              Groups received from your identity provider. An unmapped group leaves its members at
              the connection defaults.
            </.section_note>

            <.synced_members_section
              members={@synced_members}
              load_error?={@synced_members_load_error?}
              member_role_options={@member_role_options}
              can_manage_team?={@can_manage_team?}
              can_configure_directory_sync?={@can_configure_directory_sync?}
              current_user_id={@current_user.id}
              scim_enabled={provider.scim_enabled}
            />
            <.section_note :if={provider.scim_enabled}>
              Members received through this connection. Suspend someone here for a temporary hold.
              For offboarding, deactivate them in your identity provider.
            </.section_note>
            <.section_note :if={not provider.scim_enabled}>
              Members added when they first signed in through this connection. Remove their
              workspace access on the Team page.
            </.section_note>

            <%!-- A plan-posture fact, naked — not a boxed interruption. Only for
                 kinds that CAN do SCIM; the note above covers the ones that can't. --%>
            <p
              :if={!@can_configure_directory_sync? and SSO.supports_scim?(provider.kind)}
              class="max-w-prose text-sm leading-relaxed text-zinc-400"
            >
              <span class="font-medium text-zinc-200">SCIM directory sync</span>
              — automatic provisioning and offboarding from your IdP, plus group→role mapping —
              is available on the Enterprise plan.
              <.link
                navigate={~p"/pricing"}
                class="font-medium text-brand-400 underline decoration-zinc-700 underline-offset-4 hover:text-brand-300"
              >
                See plans
              </.link>
              or <a
                href={scim_sales_mailto(@current_account, @current_user)}
                class="font-medium text-brand-400 underline decoration-zinc-700 underline-offset-4 hover:text-brand-300"
              >talk to us</a>.
            </p>
            <.section_spacer :if={
              !@can_configure_directory_sync? and SSO.supports_scim?(provider.kind)
            } />

            <%!-- Danger zone at the bottom — the destructive action lives apart
                 from the routine config above (its own canvas section) and still
                 runs the typed confirm. The space-y-12 wrapper owns the rhythm. --%>
            <section id="connection-danger-zone" class="xl:col-span-2">
              <.section_header title="Danger zone" />
              <div class="divide-y divide-zinc-800/70">
                <.confirm_zone
                  title="Delete this connection"
                  phx-click={show_confirm_dialog("delete-provider-#{provider.id}")}
                >
                  <:body>
                    Removes the connection and stops new sign-ins through it. Members who sign in
                    only through it lose access until it's re-added, and the sessions they signed
                    in with are ended.
                    This can't be undone.
                  </:body>
                  Delete connection
                </.confirm_zone>
              </div>
            </section>

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
                The sessions they signed in through it are ended. This can't be undone.
              </:body>
            </.confirm_dialog>
          </div>

          <div :if={not @loaded?} class="text-sm text-zinc-400">Loading…</div>
        </div>
      </div>
    </.console_shell>
    """
  end

  # A connection that outlived the plan that bought it. It is still accepting
  # sign-ins, so hiding it behind the upsell left an owner unable to retire a
  # credential they no longer wanted — the one action offered here is removing it.
  attr :provider, :map, required: true
  attr :typed, :string, required: true

  defp plan_locked_connection(assigns) do
    ~H"""
    <section class="mt-8">
      <.section_header title={@provider.name} />
      <p class="mt-2 text-sm leading-relaxed text-zinc-400">
        This connection is still accepting sign-ins, and its directory token still works. Upgrade
        to configure it again, or shut either one down now — neither needs a plan.
      </p>
      <div class="mt-4 divide-y divide-zinc-800/70">
        <%!-- Containing a leaked directory token must not cost the operator their
             working sign-in. Offering only "delete the connection" made it. --%>
        <.confirm_zone
          :if={@provider.scim_enabled}
          title="Disable directory sync"
          phx-click={show_confirm_dialog("disable-scim-#{@provider.id}")}
        >
          <:body>
            Clears this connection's directory token, so your identity provider stops pushing
            members and the token stops authenticating. Sign-in through this connection is
            unaffected. Members keep the roles the directory last gave them.
          </:body>
          Disable directory sync
        </.confirm_zone>

        <.confirm_dialog
          :if={@provider.scim_enabled}
          id={"disable-scim-#{@provider.id}"}
          title="Disable directory sync"
          confirm_label="Disable sync"
          on_confirm={
            JS.push("disable_scim", value: %{id: @provider.id})
            |> hide_confirm_dialog("disable-scim-#{@provider.id}")
          }
        >
          <:body>
            The directory token stops working immediately. Members keep their current roles, and
            you take over managing them here.
          </:body>
        </.confirm_dialog>

        <.confirm_zone
          title="Delete this connection"
          phx-click={show_confirm_dialog("delete-provider-#{@provider.id}")}
        >
          <:body>
            Removes the connection and stops new sign-ins through it. Members who sign in only
            through it lose access, and the sessions they signed in with are ended. This can't be
            undone.
          </:body>
          Delete connection
        </.confirm_zone>
      </div>

      <.confirm_dialog
        id={"delete-provider-#{@provider.id}"}
        title="Delete connection"
        confirm_label="Delete connection"
        confirm_token={@provider.name}
        typed={@typed}
        on_confirm={
          JS.push("delete", value: %{id: @provider.id})
          |> hide_confirm_dialog("delete-provider-#{@provider.id}")
        }
      >
        <:body>
          Permanently removes the <span class="font-medium text-rose-100">{@provider.name}</span>
          connection. Members who sign in only through it lose access, and the sessions they
          signed in with are ended. This can't be undone.
        </:body>
      </.confirm_dialog>
    </section>
    """
  end

  # The Enterprise upsell shown to anyone who can't configure SSO — a member
  # without manage_sso, or any account below the Enterprise plan. Never crashes;
  # the gate is also re-checked in every handler.
  attr :current_account, :map, required: true

  defp locked(assigns) do
    ~H"""
    <.empty_state icon="state.locked" title="Single sign-on is a paid feature">
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
    <.event_block icon="state.success" tone={:brand} title="Discovery succeeded">
      <:body>This issuer serves a valid OIDC configuration.</:body>
      <%!-- An IdP's three endpoints share a long prefix and differ only in the
           trailing path segment, which is exactly where the truncation lands —
           so each value carries its full self as the hover escape. --%>
      <dl class="mt-3 space-y-1 text-xs text-zinc-400">
        <div :if={@summary.authorization_endpoint} class="flex gap-2">
          <dt class="w-32 shrink-0 text-zinc-400">Authorization</dt>
          <dd class="truncate font-mono text-zinc-300" title={@summary.authorization_endpoint}>
            {@summary.authorization_endpoint}
          </dd>
        </div>
        <div :if={@summary.token_endpoint} class="flex gap-2">
          <dt class="w-32 shrink-0 text-zinc-400">Token</dt>
          <dd class="truncate font-mono text-zinc-300" title={@summary.token_endpoint}>
            {@summary.token_endpoint}
          </dd>
        </div>
        <div :if={@summary.jwks_uri} class="flex gap-2">
          <dt class="w-32 shrink-0 text-zinc-400">JWKS</dt>
          <dd class="truncate font-mono text-zinc-300" title={@summary.jwks_uri}>
            {@summary.jwks_uri}
          </dd>
        </div>
      </dl>
    </.event_block>
    """
  end

  defp test_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, test_error_message(reason))

    ~H"""
    <.event_block
      icon="state.warning"
      tone={:rose}
      title="Connection test failed"
    >
      <:body>{@message}</:body>
    </.event_block>
    """
  end

  defp test_error_message(:invalid_issuer), do: "Enter the issuer's https URL first, then test."

  defp test_error_message(:blocked_issuer),
    do: "The issuer can't be a private, loopback, or metadata address."

  defp test_error_message(:rate_limited),
    do: "Too many connection tests. Wait a minute and try again."

  defp test_error_message(_reason) do
    "Couldn't load the issuer's OIDC discovery document. Check the issuer URL and that the IdP is reachable from the internet."
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :kind_options, :list, required: true
  attr :role_options, :list, required: true
  attr :provisioner_options, :list, required: true
  attr :runners, :list, required: true
  attr :pack_advertisements, :map, required: true
  attr :pack_access_restricted?, :boolean, required: true
  attr :runner_load_error?, :boolean, required: true
  attr :pack_load_error?, :boolean, default: false
  attr :guide_id, :string, required: true
  attr :callback_url, :string, required: true
  # The :new view renders the guide in its own rail, so it suppresses the inline
  # copy rather than showing the same steps twice.
  attr :inline_guide?, :boolean, default: true
  attr :editing?, :boolean, default: false

  # The connection form's fields, grouped into NAKED sibling sections (Provider ·
  # OIDC connection · Member provisioning · Security) — §8.1: the fields are the
  # controls; a panel per group was an island per group. Shared by both actions;
  # the outer <.simple_form> spaces the sections and renders the submit footer.
  defp provider_fields(assigns) do
    assigns = assign(assigns, :kind, form_kind(assigns.form, assigns.kind_options))

    ~H"""
    <div class="space-y-10">
      <section>
        <.section_header title="Provider">
          <:subtitle>Which identity provider this is, and what to call it here.</:subtitle>
        </.section_header>
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
            prompt="Select a provider…"
            options={@kind_options}
          />
          <div :if={@editing?}>
            <.label>Provider type</.label>
            <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — a control: the locked read-only field wears the input recipe --%>
            <div class="mt-2 flex items-center gap-2 rounded-lg bg-zinc-950/50 px-3 py-2.5 text-sm text-zinc-400 ring-1 ring-inset ring-zinc-800">
              <.icon name="state.locked" class="h-3.5 w-3.5 shrink-0 text-zinc-500" />
              {selected_kind_label(@form, @kind_options)}
            </div>
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
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
      </section>

      <section>
        <.section_header title="OIDC connection">
          <:subtitle>
            Your provider's issuer URL, and the OAuth app emisar signs in with.
          </:subtitle>
        </.section_header>
        <%!-- Setup steps for the SELECTED provider — what to create at the IdP and
             what to paste back here. --%>
        <.provider_setup_guide
          :if={@inline_guide?}
          id={@guide_id}
          kind={form_kind(@form, @kind_options)}
          callback_url={@callback_url}
        />
        <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="sm:col-span-2">
            <%= if fixed = SSO.provider_fixed_issuer(@kind) do %>
              <%!-- A constant for this provider — show it locked + prefilled, not
                   an input the operator must copy exactly. --%>
              <.label>Issuer URL</.label>
              <%!-- Hidden field carries the constant on submit (a disabled input
                   wouldn't), and keeps a provider[issuer] input in the form. --%>
              <input type="hidden" name={@form[:issuer].name} value={fixed} />
              <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — a control: the locked read-only field wears the input recipe --%>
              <div class="mt-2 flex items-center gap-2 rounded-lg bg-zinc-950/50 px-3 py-2.5 font-mono text-sm text-zinc-400 ring-1 ring-inset ring-zinc-800">
                <.icon name="state.locked" class="h-3.5 w-3.5 shrink-0 text-zinc-500" />
                {fixed}
              </div>
              <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
                Fixed for {setup_kind_label(@kind)} — the same for every org, so there's nothing to set.
              </p>
            <% else %>
              <.input
                field={@form[:issuer]}
                type="url"
                label="Issuer URL"
                placeholder={issuer_hint(@kind)}
                class="font-mono"
              />
              <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
                The OIDC issuer — its discovery document is fetched from here. Must be HTTPS.
              </p>
            <% end %>
          </div>
          <%!-- autocomplete="off" on both halves of the OAuth client: a password
               manager offering a saved username here would overwrite the client id
               the operator pasted from their IdP. --%>
          <.input field={@form[:client_id]} type="text" label="Client ID" autocomplete="off" />
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
              options={identifier_claim_options(@kind, @form[:identifier_claim].value)}
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
              How emisar recognises a returning member. Never their email — people change those. {identifier_claim_hint(
                @kind
              )}
            </p>
          </div>
        </div>
      </section>

      <section>
        <.section_header title="Member provisioning">
          <:subtitle>How members map in when they sign in through this connection.</:subtitle>
        </.section_header>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="sm:col-span-2">
            <.input
              field={@form[:provisioner]}
              type="select"
              label="New member provisioning"
              options={@provisioner_options}
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
              <span class="font-medium text-zinc-400">Auto-provision</span>
              adds a member on first sign-in. <span class="font-medium text-zinc-400">Manual</span>
              holds first-time sign-ins as pending requests for an admin to approve. Either way
              they land at the default role below.
            </p>
          </div>
          <div class="sm:col-span-2">
            <.label>Default role for new members</.label>
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
                {Emisar.Auth.role_description(value)}
              </:card>
            </.choice_cards>
          </div>
          <div class="sm:col-span-2">
            <.label>Default access for new members</.label>
            <%!-- The eyebrows below name the two decisions, so this line spends
                  itself on what they cannot: a group mapping can widen this. --%>
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
              Every member provisioned through this connection starts here; a group mapping below
              adds to it.
            </p>
            <div class="mt-2">
              <.label variant={:eyebrow}>Runners</.label>
            </div>
            <div class="mt-2">
              <.choice_cards
                name="provider[default_runner_access_mode]"
                value={@form[:default_runner_access_mode].value}
                attached_value="restricted"
              >
                <:card value="none" title="No runners">
                  New members join without runner visibility or dispatch reach.
                </:card>
                <:card value="all" title="All runners">
                  New members receive every current and future runner.
                </:card>
                <:card value="restricted" title="Selected runners">
                  New members receive only selected runner groups or runners.
                </:card>
              </.choice_cards>

              <.runner_scope_select
                :if={restricted_runner_access?(@form[:default_runner_access_mode].value)}
                name="provider[default_runner_scope][]"
                variant={:attached}
                runners={@runners}
                selected={List.wrap(@form[:default_runner_scope].value)}
                submit_error_field={@form[:default_runner_access_mode]}
                submit_error_message="Choose at least one runner group or runner for selected access."
                load_error={RunnerScope.runner_load_error(@runner_load_error?)}
              />
            </div>

            <div class="mt-4">
              <.pack_access_field
                runner_mode={to_string(@form[:default_runner_access_mode].value)}
                runner_scope={List.wrap(@form[:default_runner_scope].value)}
                runners={@runners}
                advertisements={@pack_advertisements}
                grant_limited?={@pack_access_restricted?}
                load_error={RunnerScope.pack_load_error(@pack_load_error?)}
                mode_name="provider[default_pack_access_mode]"
                mode_value={@form[:default_pack_access_mode].value}
                scope_name="provider[default_pack_scope][]"
                selected={List.wrap(@form[:default_pack_scope].value)}
                submit_error_field={@form[:default_pack_access_mode]}
                submit_error_message="Choose at least one pack for selected pack access."
              />
            </div>
          </div>
          <div class="sm:col-span-2">
            <.input
              field={@form[:allowed_email_domain]}
              type="text"
              label="Allowed email domain (optional)"
              placeholder="acme.com"
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
              Restricts sign-in to verified emails on this domain and routes that domain's
              sign-ins here. Leave blank to accept any address the provider returns.
            </p>
          </div>
        </div>
      </section>

      <section>
        <.section_header title="Security & activation">
          <:subtitle>
            Whether this provider satisfies 2FA, and whether members can use it yet.
          </:subtitle>
        </.section_header>
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
              class="mt-1 text-[11px] leading-relaxed text-zinc-400"
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
      </section>
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
    <%!-- NAKED supporting rail (the install-wizard rail grammar) — the reading
         column is separated by AIR, never boxed; the code_lines inside are the
         earned artifacts. --%>
    <div>
      <p class="text-sm font-medium text-zinc-200">Setting up {setup_kind_label(@kind)}</p>
      <.steps class="mt-3">
        <:step>
          Create an OAuth / OIDC <span class="text-zinc-300">web app</span> {oidc_app_hint(@kind)}.
        </:step>
        <:step>
          Register this <span class="text-zinc-300">redirect URI</span>
          on the app: <.code_line id={"sso-callback-#{@id}"} value={@callback_url} class="mt-1.5" />
        </:step>
        <%!-- Dropped for providers whose issuer is a constant — it's already
             locked + prefilled below, so there's no step to follow. --%>
        <:step :if={is_nil(SSO.provider_fixed_issuer(@kind))}>
          Set the <span class="text-zinc-300">Issuer URL</span>
          below to <span class="font-mono text-zinc-300">{issuer_hint(@kind)}</span>.
          <span class="text-zinc-400">{issuer_where_hint(@kind)}</span>
        </:step>
        <:step>
          Paste the app's <span class="text-zinc-300">Client ID</span>
          and <span class="text-zinc-300">Client secret</span>
          into the fields below.
        </:step>
      </.steps>
      <p class="mt-3 text-sm leading-relaxed text-zinc-400">
        {provider_directory_note(@kind)}
      </p>
      <%!-- Only providers whose OAuth app exposes a DPoP toggle get this note —
           Google and JumpCloud have no such setting, so it would only confuse. --%>
      <p :if={dpop_relevant?(@kind)} class="mt-3 text-sm leading-relaxed text-zinc-400">
        Leave <span class="text-zinc-300">DPoP</span>
        (sender-constrained tokens) OFF. emisar reads the ID token only and never presents the
        access token to an API, so turning it on would break the token request.
      </p>
      <%!-- The docs link closes the rail on its own line, the shape `docs_rail`
           uses on the list pages ("Runner docs"): `text-sm` on the HOST, since
           `doc_link` carries no `text-*` of its own. --%>
      <p class="mt-4 text-sm">
        <.doc_link href={docs_path_for_kind(@kind)}>{docs_link_label(@kind)}</.doc_link>
      </p>
    </div>
    """
  end

  # The steps above cover creating the sign-in app, which is the same shape
  # everywhere. What actually differs between providers — and what the operator
  # hits immediately after this — is how each one handles the DIRECTORY: Okta
  # wants a second app, Entra a separate enterprise application, JumpCloud does
  # both from one, and Keycloak and Google push nothing at all. Saying that here
  # sets the expectation while they are still deciding what to build over there.
  # The rail is already titled "Setting up <provider>", so this must not repeat
  # the provider's name or announce that a guide exists.
  defp provider_directory_note("okta"),
    do: "Directory sync is a second Okta app — this one only signs people in."

  defp provider_directory_note("entra"),
    do: "This is the app registration; directory sync is a separate enterprise application."

  defp provider_directory_note("jumpcloud"),
    do: "One JumpCloud application covers both this and directory sync."

  defp provider_directory_note("keycloak"),
    do: "Keycloak pushes no directory of its own, so members arrive on their first sign-in."

  defp provider_directory_note("google_workspace") do
    "Google Workspace can't push a directory to emisar, so members arrive on first sign-in."
  end

  # Steps 1 and 3 already say "confidential client" and "discovery document", so
  # the generic line has to stay on the directory axis like the named ones do.
  defp provider_directory_note(_) do
    "Directory sync needs a provider that pushes SCIM; otherwise members arrive on first sign-in."
  end

  # Deep-link to the provider's own guide rather than the top of the docs. The
  # label says what the page IS, the house shape ("Runner docs"); a label that
  # promised screenshots needed a per-provider honesty split, because only four
  # of the guides have full console coverage. Naming the page plainly removes
  # the claim, and with it the split.
  defp docs_link_label(kind) when kind in ~w[okta entra jumpcloud keycloak google_workspace],
    do: "Step-by-step guide"

  defp docs_link_label(_), do: "Single sign-on docs"

  # `oid` exists for exactly one provider. Offering it under Keycloak or Google
  # invites an admin to pick a claim their IdP never issues, which fails at the
  # first sign-in with a missing-identifier error rather than at save time.
  # One option per provider, because there is one right answer per provider. We
  # offered Entra a `sub` labelled "not recommended" — a wrong choice, presented
  # as a choice. Entra's `sub` is pairwise, so sign-in and directory sync land on
  # different identities and the person becomes two members.
  #
  # A connection ALREADY on the wrong claim still shows it, so the form tells the
  # truth about what is stored rather than rendering a value it does not hold.
  # It cannot be re-selected once dropped, and the identity-namespace freeze
  # stops it changing under anyone who has signed in through it.
  defp identifier_claim_options(kind, current) do
    options = identifier_claim_options(kind)

    if current in [nil, ""] or
         Enum.any?(options, fn {_label, value} -> value == to_string(current) end),
       do: options,
       else: options ++ [{"#{current} — stored on this connection", to_string(current)}]
  end

  # The claim itself is the domain's — this only words it.
  defp identifier_claim_options(kind) do
    case SSO.provider_identifier_claim(kind) do
      :oid -> [{"oid — Microsoft Entra", "oid"}]
      _sub_or_unknown -> [{"sub — OIDC standard", "sub"}]
    end
  end

  # Entra's `sub` differs per application, so `oid` is the only claim that joins
  # sign-in to the directory — which is why it is the only one offered. The
  # reasoning belongs in the Entra guide; here the operator needs the fact.
  defp identifier_claim_hint("entra") do
    "Entra gives every app a different `sub`, so emisar uses `oid` — the id directory sync sends."
  end

  # One option, nothing to decide: justifying why the list is short is our
  # bookkeeping, not the operator's.
  defp identifier_claim_hint(_), do: ""

  defp docs_path_for_kind("google_workspace"), do: ~p"/docs/integrations/google-workspace"
  defp docs_path_for_kind("okta"), do: ~p"/docs/integrations/okta"
  defp docs_path_for_kind("entra"), do: ~p"/docs/integrations/entra"
  defp docs_path_for_kind("jumpcloud"), do: ~p"/docs/integrations/jumpcloud"
  defp docs_path_for_kind("keycloak"), do: ~p"/docs/integrations/keycloak"
  defp docs_path_for_kind(_), do: ~p"/docs/sso#generic-oidc"

  defp setup_kind_label("google_workspace"), do: "Google Workspace"
  defp setup_kind_label("okta"), do: "Okta"
  defp setup_kind_label("entra"), do: "Microsoft Entra"
  defp setup_kind_label("jumpcloud"), do: "JumpCloud"
  defp setup_kind_label("keycloak"), do: "Keycloak"
  defp setup_kind_label(_), do: "a generic OIDC provider"

  defp oidc_app_hint("google_workspace") do
    "in Google Cloud Console → APIs & Services → Credentials → Create OAuth client ID (Web application)"
  end

  defp oidc_app_hint("entra") do
    "in the Microsoft Entra admin center → App registrations → New registration, with a Web redirect URI"
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
  defp issuer_hint("entra"), do: "https://login.microsoftonline.com/YOUR-TENANT-ID/v2.0"
  defp issuer_hint("jumpcloud"), do: "https://oauth.id.jumpcloud.com/"
  defp issuer_hint("keycloak"), do: "https://YOUR-HOST/realms/YOUR-REALM"
  defp issuer_hint(_), do: "your provider's OIDC issuer URL (the discovery base)"

  # The display-name placeholder — a plausible name for the picked provider, so
  # the example never contradicts the selected kind (no "Acme Okta" under Google).
  defp name_placeholder("entra"), do: "Acme Entra"
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

  # Where to FIND the issuer — it's an org/realm-level value, not on the app
  # page, which is the usual point of confusion.
  defp issuer_where_hint("okta") do
    "It's your Okta org URL — the domain you use for the admin console, not a per-app field. Use the org authorization server (Security → API → Authorization Servers, the org row's Issuer URI), not a custom one."
  end

  defp issuer_where_hint("jumpcloud") do
    "Always this exact value for JumpCloud — including the trailing slash. Nothing to look up."
  end

  defp issuer_where_hint("google_workspace"),
    do: "Always this exact value for Google — nothing to look up."

  defp issuer_where_hint("entra") do
    "Build it from your Directory (tenant) ID, on the app registration's Overview. The trailing `/v2.0` selects Entra's v2.0 endpoint — without it you get v1.0 tokens."
  end

  defp issuer_where_hint("keycloak") do
    "Your realm's base URL; Realm settings → Endpoints → OpenID Endpoint Configuration confirms the exact value."
  end

  defp issuer_where_hint(assigns) do
    ~H"""
    Whatever URL serves its OIDC discovery document at <code>/.well-known/openid-configuration</code>
    — emisar fetches it from there.
    """
  end

  defp scim_location_hint(:okta) do
    "in a SEPARATE Okta app — Okta's OIDC login app can't do SCIM. Add the \"SCIM 2.0 Test App (Header Auth)\" from the OIN catalog (its Sign-On tab is unused — SCIM lives entirely on the Provisioning tab): Configure API Integration → Enable, set the Base URL to the value above and paste the `ems-` token as the API token, then enable Create / Update / Deactivate. Okta sends the token as a raw header with no `Bearer` scheme, which emisar accepts"
  end

  defp scim_location_hint(:jumpcloud) do
    "on a JumpCloud application's Provisioning tab — one custom app can carry both sign-in and provisioning, so tick \"Export users to this app\" alongside SSO (its SAML/OIDC sub-choice defaults to SAML). Set the Base URL to the value above and paste the `ems-` token as the Token, then Test Connection → Activate (their form discards the config if you press Save instead)"
  end

  # Keycloak has no outbound SCIM: its own SCIM support (26.6+) makes Keycloak a
  # SCIM *server* others provision INTO, which is the opposite direction. Saying
  # "look in your provider's SCIM settings" sends an admin hunting for a screen
  # that doesn't exist, so name the gap and the way around it.
  defp scim_location_hint(:entra) do
    "on a separate ENTERPRISE APPLICATION, not this app registration — Entra splits sign-in and provisioning across two objects. Create a non-gallery app, then Provisioning → Automatic, with the Base URL above as Tenant URL and the `ems-` token as Secret Token. Remap externalId to objectId, or the directory and this connection will disagree about who someone is"
  end

  defp scim_location_hint(:keycloak) do
    "from a SCIM plugin on your Keycloak — Keycloak ships no outbound provisioning of its own, so this needs a third-party extension, which you configure and support. Point it at the Base URL above with the `ems-` token as its bearer credential"
  end

  defp scim_location_hint(_), do: "in your provider's SCIM / user-provisioning settings"

  # The kind currently selected in the form (string), for the live setup guide;
  # defaults to the first option — what the select shows before any change.
  # Blank on a fresh /new form (nothing picked yet) — the guide/hints fall back
  # to generic and the issuer stays editable, rather than arbitrarily pre-picking
  # the first provider (and locking its issuer before the operator has chosen).
  defp form_kind(form, _kind_options) do
    case form[:kind].value do
      blank when blank in [nil, ""] -> ""
      value -> to_string(value)
    end
  end

  # The humanized label for the form's current kind — for the read-only display on
  # the edit form, where provider type is create-only.
  defp selected_kind_label(form, kind_options) do
    value = form_kind(form, kind_options)
    Enum.find_value(kind_options, value, fn {label, v} -> v == value && label end)
  end

  slot :inner_block, required: true

  # A section's explanation, living in the grid's second column so it lands in
  # that section's ROW. It carries no title of its own: the section heading is
  # directly to its left, and repeating it was what made the old single rail read
  # as a list of headings ("Synced groups & users" above a docs list).
  defp section_note(assigns) do
    ~H"""
    <aside class="max-w-prose text-sm leading-relaxed text-zinc-400 xl:pt-1">
      {render_slot(@inner_block)}
    </aside>
    """
  end

  # Holds the second column open for a section with nothing to explain, so the
  # next section starts a fresh row instead of sliding into this one. Hidden
  # below xl, where the grid is a single column and an empty cell would only add
  # a gap.
  defp section_spacer(assigns) do
    ~H"""
    <div class="hidden xl:block" aria-hidden="true"></div>
    """
  end

  attr :provider, :map, required: true
  attr :scim_base_url, :string, required: true
  attr :scim_token, :map, default: nil

  # Directory sync (SCIM) — a sibling island on the connection detail: header +
  # intent, the live sync-status signal, the base URL, the once-shown bearer, and
  # the IdP setup steps. The bearer is write-only (shown once on enable/rotate).
  # Role mapping is its own island card, not nested here.
  defp scim_section(assigns) do
    provider_id = assigns.provider.id

    revealed_token =
      case assigns.scim_token do
        %{provider_id: ^provider_id, token: token} -> token
        _ -> nil
      end

    assigns = assign(assigns, :revealed_token, revealed_token)

    ~H"""
    <section id={"directory-sync-#{@provider.id}"}>
      <.section_header title="Directory sync (SCIM)">
        <:actions>
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
            <.confirm_button
              :if={@provider.scim_enabled}
              id={"rotate-scim-#{@provider.id}"}
              title="Rotate the SCIM token?"
              confirm_label="Rotate token"
              variant={:secondary}
              tone={:neutral}
              size={:sm}
              on_confirm={JS.push("rotate_scim", value: %{id: @provider.id})}
            >
              <:body>Your IdP will lose access until you paste the new one.</:body>
              Rotate token
            </.confirm_button>
            <.confirm_button
              :if={@provider.scim_enabled}
              id={"disable-scim-#{@provider.id}"}
              title="Disable directory sync?"
              confirm_label="Disable sync"
              variant={:secondary}
              tone={:rose}
              size={:sm}
              on_confirm={JS.push("disable_scim", value: %{id: @provider.id})}
            >
              <:body>Your IdP can no longer provision or deprovision members through it.</:body>
              Disable
            </.confirm_button>
          </div>
        </:actions>
      </.section_header>

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
          class="flex items-center gap-2.5"
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
          :if={@revealed_token || not SSO.provider_sync_recent?(@provider)}
          class="group"
          {if(@revealed_token, do: %{open: ""}, else: %{})}
        >
          <summary class="flex cursor-pointer list-none items-center gap-1.5 text-sm font-medium text-zinc-300 hover:text-zinc-100">
            <.icon
              name="action.disclose"
              class="h-4 w-4 -rotate-90 text-zinc-500 transition-transform group-open:rotate-0"
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
              <.inline_code>Authorization</.inline_code>
              header.
            </:step>
            <:step>
              Map the SCIM <span class="text-zinc-300">externalId</span>
              to the same value your OIDC
              <.inline_code>{@provider.identifier_claim}</.inline_code>
              claim carries — so a member's SSO login and their synced record are one identity.
            </:step>
          </.steps>
          <p :if={@provider.kind == :okta} class="mt-3 pl-5 text-[11px] leading-relaxed text-zinc-400">
            The SCIM app is a second Okta integration, separate from your sign-in app — its own
            SSO doesn't need to be functional. Okta defaults both the OIDC
            <.inline_code>sub</.inline_code>
            and the SCIM
            <.inline_code>externalId</.inline_code>
            to the Okta user id, so step 3 usually needs no change.
          </p>
        </details>
      </div>
    </section>
    """
  end

  attr :provider, :map, required: true
  attr :path, :any, required: true
  attr :mappings, :list, required: true
  attr :metadata, :any, required: true
  attr :filter_params, :map, required: true
  attr :load_error?, :boolean, default: false
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
  defp role_mapping_section(assigns) do
    ~H"""
    <section>
      <.section_header title="Role mapping" count={@metadata.count} count_tone={:neutral}>
        <:actions>
          <.button
            :if={not @adding_mapping}
            variant={:secondary}
            size={:sm}
            phx-click="add_mapping_form"
            icon="action.add"
          >
            Add mapping
          </.button>
        </:actions>
      </.section_header>
      <ul :if={@mappings != []} class="mt-4 divide-y divide-zinc-800/70">
        <li :for={mapping <- @mappings} class="py-3 first:pt-0 last:pb-0">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex min-w-0 items-center gap-2.5">
              <.icon name="identity.group" class="h-4 w-4 shrink-0 text-zinc-500" />
              <div class="min-w-0">
                <p class="truncate text-sm text-zinc-200">
                  {directory_group_name(mapping)}
                </p>
                <p class="truncate font-mono text-[11px] text-zinc-400">
                  {directory_group_reference(mapping)}
                </p>
              </div>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.chip>{role_label(mapping.role)}</.chip>
              <.button
                :if={@editing_mapping_id != mapping.id}
                variant={:secondary}
                size={:sm}
                phx-click="start_edit_mapping"
                phx-value-id={mapping.id}
              >
                Edit
              </.button>
              <%!-- Reversible config (re-addable) — a plain confirm fits the
                   tier, not a typed-confirm. `delete_mapping` stays
                   server-authz-gated. --%>
              <.confirm_button
                id={"delete-mapping-#{mapping.id}"}
                title="Delete this role mapping?"
                confirm_label="Delete mapping"
                variant={:secondary}
                tone={:rose}
                size={:sm}
                on_confirm={JS.push("delete_mapping", value: %{id: mapping.id})}
              >
                <:body>
                  Members of this group have their role recomputed straight away from whichever mapped groups they are still in.
                </:body>
                Delete
              </.confirm_button>
            </div>
          </div>

          <%!-- The immutable group resource is fixed; inline edit changes only
               the role. The owner error surfaces inline here too. --%>
          <div :if={@editing_mapping_id == mapping.id and @mapping_edit_form} class="mt-3">
            <.simple_form
              for={@mapping_edit_form}
              id={"edit-mapping-#{mapping.id}"}
              phx-change="validate_edit_mapping"
              phx-submit="update_mapping"
            >
              <input type="hidden" name="mapping_id" value={mapping.id} />
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
      <div class="mt-4">
        <LiveTable.paginator
          id={"role-mappings-#{@provider.id}"}
          path={@path}
          metadata={@metadata}
          filter_params={@filter_params}
          prefix="role_mappings_"
          page_count={length(@mappings)}
        />
      </div>

      <%!-- "No role mappings yet" is a statement about what this directory grants,
           so it is never made from a read that failed. --%>
      <.empty_state
        :if={@load_error?}
        variant={:hint}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load role mappings"
        class="mt-4"
      >
        This is a load error, not an empty list — mapped groups may well be granting roles.
        Refresh the page to try again.
      </.empty_state>
      <.empty_state
        :if={
          not @load_error? and @mappings == [] and
            not LiveTable.stale_page?(
              0,
              @metadata,
              @filter_params,
              "role_mappings_"
            )
        }
        variant={:hint}
        class="mt-4"
      >
        No role mappings yet. New members land at the connection's default role until you map a
        directory group to a higher one.
      </.empty_state>

      <%!-- Add a mapping — revealed by the "Add mapping" button (not always open);
           a divided region within the card (not a nested box). account_id/provider_id
           are server-side. The group must be an exact synced resource; there is
           deliberately no free-text identity fallback. --%>
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
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <.input
              field={@mapping_form[:directory_group_id]}
              type="select"
              label="IdP group"
              options={Enum.map(@synced_groups, &directory_group_option/1)}
              prompt={if @synced_groups == [], do: "Sync a group first", else: "Pick a synced group"}
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
    </section>
    """
  end

  attr :provider, :map, required: true
  attr :path, :any, required: true
  attr :mappings, :list, required: true
  attr :metadata, :any, required: true
  attr :filter_params, :map, required: true
  attr :load_error?, :boolean, default: false
  attr :mapping_form, Phoenix.HTML.Form, default: nil
  attr :editing_mapping_id, :string, default: nil
  attr :mapping_edit_form, Phoenix.HTML.Form, default: nil
  attr :synced_groups, :list, default: []
  attr :adding_mapping, :boolean, default: false
  attr :runners, :list, required: true
  attr :pack_advertisements, :map, required: true
  attr :pack_access_restricted?, :boolean, required: true

  defp group_runner_access_mapping_section(assigns) do
    assigns = assign(assigns, :runners_by_id, Map.new(assigns.runners, &{&1.id, &1}))

    ~H"""
    <section>
      <.section_header
        title="Runner access mapping"
        count={@metadata.count}
        count_tone={:neutral}
      >
        <:actions>
          <.button
            :if={not @adding_mapping}
            variant={:secondary}
            size={:sm}
            phx-click="add_runner_access_mapping_form"
            icon="action.add"
          >
            Add runner access
          </.button>
        </:actions>
      </.section_header>
      <ul :if={@mappings != []} class="mt-4 divide-y divide-zinc-800/70">
        <li :for={mapping <- @mappings} class="py-3 first:pt-0 last:pb-0">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate text-sm text-zinc-200">
                {directory_group_name(mapping)}
              </p>
              <p class="font-mono text-[11px] text-zinc-400">
                {directory_group_reference(mapping)}
              </p>
              <dl
                id={"runner-access-mapping-facts-#{mapping.id}"}
                class="mt-1 grid grid-cols-[auto_minmax(0,1fr)] items-baseline gap-x-2 gap-y-1"
              >
                <dt class="text-[10px] uppercase tracking-wider text-zinc-400">runners:</dt>
                <dd class="flex min-w-0 flex-wrap items-center gap-1">
                  <span
                    :if={mapping_runner_reach_phrase(mapping.runner_access_mode)}
                    class="text-xs text-zinc-400"
                  >
                    {mapping_runner_reach_phrase(mapping.runner_access_mode)}
                  </span>
                  <.identity_tag
                    :for={group <- mapping.runner_scope_groups}
                    category="group"
                    value={group}
                  />
                  <%!-- The full runner id rides the tag's title; the value half names the
                       live runner, and falls back to the shared removed-runner label when
                       the id no longer resolves. --%>
                  <.identity_tag
                    :for={runner_id <- mapping.runner_scope_runner_ids}
                    category="runner"
                    title={runner_id}
                  >
                    <% runner = Map.get(@runners_by_id, runner_id) %>
                    <span :if={runner}>{runner.name}</span>
                    <.removed_runner :if={is_nil(runner)} runner_id={runner_id} />
                  </.identity_tag>
                </dd>
                <dt
                  :if={mapping.runner_access_mode != :none}
                  class="text-[10px] uppercase tracking-wider text-zinc-400"
                >
                  packs:
                </dt>
                <dd
                  :if={mapping.runner_access_mode != :none}
                  class="flex min-w-0 flex-wrap items-center gap-1"
                >
                  <span
                    :if={mapping_pack_reach_phrase(mapping.pack_access_mode)}
                    class="text-xs text-zinc-400"
                  >
                    {mapping_pack_reach_phrase(mapping.pack_access_mode)}
                  </span>
                  <.chip :for={pack_id <- mapping.pack_scope_pack_ids} mono>{pack_id}</.chip>
                </dd>
              </dl>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.button
                :if={@editing_mapping_id != mapping.id}
                variant={:secondary}
                size={:sm}
                phx-click="start_edit_runner_access_mapping"
                phx-value-id={mapping.id}
              >
                Edit
              </.button>
              <.confirm_button
                id={"delete-runner-access-mapping-#{mapping.id}"}
                title="Delete this runner-access mapping?"
                confirm_label="Delete mapping"
                variant={:secondary}
                tone={:rose}
                size={:sm}
                on_confirm={JS.push("delete_runner_access_mapping", value: %{id: mapping.id})}
              >
                <:body>
                  Current members of this IdP group immediately lose this grant. Their connection
                  default and other mapped-group grants remain.
                </:body>
                Delete
              </.confirm_button>
            </div>
          </div>

          <div :if={@editing_mapping_id == mapping.id and @mapping_edit_form} class="mt-4">
            <.simple_form
              for={@mapping_edit_form}
              id={"edit-runner-access-mapping-#{mapping.id}"}
              phx-change="validate_edit_runner_access_mapping"
              phx-submit="update_runner_access_mapping"
            >
              <input type="hidden" name="runner_access_mapping_id" value={mapping.id} />
              <.runner_access_mapping_fields
                form={@mapping_edit_form}
                synced_groups={@synced_groups}
                runners={@runners}
                pack_advertisements={@pack_advertisements}
                pack_access_restricted?={@pack_access_restricted?}
                editing?
              />
              <:actions>
                <.button phx-disable-with="Saving...">Save</.button>
                <.button
                  variant={:ghost}
                  type="button"
                  phx-click="cancel_edit_runner_access_mapping"
                >
                  Cancel
                </.button>
              </:actions>
            </.simple_form>
          </div>
        </li>
      </ul>
      <div class="mt-4">
        <LiveTable.paginator
          id={"runner-access-mappings-#{@provider.id}"}
          path={@path}
          metadata={@metadata}
          filter_params={@filter_params}
          prefix="runner_access_mappings_"
          page_count={length(@mappings)}
        />
      </div>

      <%!-- Claiming no group widens runner reach is a security statement — never
           make it from a read that failed. --%>
      <.empty_state
        :if={@load_error?}
        variant={:hint}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load runner access mappings"
        class="mt-4"
      >
        This is a load error, not an empty list — IdP groups may well be granting extra runner
        reach. Refresh the page to try again.
      </.empty_state>
      <.empty_state
        :if={
          not @load_error? and @mappings == [] and
            not LiveTable.stale_page?(
              0,
              @metadata,
              @filter_params,
              "runner_access_mappings_"
            )
        }
        variant={:hint}
        class="mt-4"
      >
        No IdP groups grant additional runner access. Synced members use the connection default.
      </.empty_state>

      <div :if={@adding_mapping and @mapping_form} class="mt-5 border-t border-zinc-800/70 pt-5">
        <p class="text-sm font-medium text-zinc-300">Add group runner access</p>
        <.simple_form
          for={@mapping_form}
          id={"create-runner-access-mapping-#{@provider.id}"}
          phx-change="validate_runner_access_mapping"
          phx-submit="create_runner_access_mapping"
          class="mt-3"
        >
          <input type="hidden" name="provider_id" value={@provider.id} />
          <.runner_access_mapping_fields
            form={@mapping_form}
            synced_groups={@synced_groups}
            runners={@runners}
            pack_advertisements={@pack_advertisements}
            pack_access_restricted?={@pack_access_restricted?}
          />
          <:actions>
            <.button phx-disable-with="Adding...">Add runner access</.button>
            <.button
              variant={:ghost}
              type="button"
              phx-click="cancel_add_runner_access_mapping"
            >
              Cancel
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </section>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :synced_groups, :list, required: true
  attr :runners, :list, required: true
  attr :pack_advertisements, :map, required: true
  attr :pack_access_restricted?, :boolean, required: true
  attr :editing?, :boolean, default: false

  defp runner_access_mapping_fields(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.input
          :if={not @editing?}
          field={@form[:directory_group_id]}
          type="select"
          label="IdP group"
          options={Enum.map(@synced_groups, &directory_group_option/1)}
          prompt={if @synced_groups == [], do: "Sync a group first", else: "Pick a synced group"}
        />
      </div>

      <div>
        <.label>Access this group grants</.label>
        <div class="mt-2">
          <.label variant={:eyebrow}>Runners</.label>
        </div>
        <div class="mt-2">
          <.choice_cards
            name={@form[:runner_access_mode].name}
            value={@form[:runner_access_mode].value}
            attached_value="restricted"
          >
            <:card value="all" title="All runners">
              Grant every current and future runner.
            </:card>
            <:card value="restricted" title="Selected runners">
              Grant selected runner groups or individual runners.
            </:card>
          </.choice_cards>

          <.runner_scope_select
            :if={restricted_runner_access?(@form[:runner_access_mode].value)}
            name={"#{@form.name}[scope][]"}
            variant={:attached}
            runners={@runners}
            selected={List.wrap(@form[:scope].value)}
            submit_error_field={@form[:runner_access_mode]}
            submit_error_message="Choose all runners or at least one selected runner scope."
          />
        </div>

        <div class="mt-4">
          <.pack_access_field
            runner_mode={to_string(@form[:runner_access_mode].value)}
            runner_scope={List.wrap(@form[:scope].value)}
            runners={@runners}
            advertisements={@pack_advertisements}
            grant_limited?={@pack_access_restricted?}
            mode_name={@form[:pack_access_mode].name}
            mode_value={@form[:pack_access_mode].value}
            scope_name={"#{@form.name}[pack_scope][]"}
            selected={List.wrap(@form[:pack_scope].value)}
            submit_error_field={@form[:pack_access_mode]}
            submit_error_message="Choose at least one pack for selected pack access."
          />
        </div>
      </div>
    </div>
    """
  end

  attr :synced_groups, :list, required: true
  attr :load_error?, :boolean, default: false

  # The groups the IdP actually pushes over SCIM (id + distinct member count),
  # each annotated with its role mapping — the directory-state companion to the
  # group→role mapping config above. It surfaces groups that sync but aren't
  # mapped (their members stay at the connection's default role), which the
  # mapping list can't show.
  defp synced_groups_section(assigns) do
    ~H"""
    <section>
      <.section_header title="Synced groups" count={length(@synced_groups)} count_tone={:neutral} />
      <ul :if={@synced_groups != []} class="mt-4 divide-y divide-zinc-800/70">
        <li
          :for={group <- @synced_groups}
          class="flex flex-wrap items-center justify-between gap-2 py-3 first:pt-0 last:pb-0"
        >
          <div class="flex min-w-0 items-center gap-2.5">
            <.icon name="identity.group" class="h-4 w-4 shrink-0 text-zinc-500" />
            <div class="min-w-0">
              <p class="truncate text-sm text-zinc-200">
                {directory_group_name(group)}
              </p>
              <p class="truncate font-mono text-[11px] text-zinc-400">
                {directory_group_reference(group)}
              </p>
            </div>
          </div>
          <div class="flex shrink-0 items-center gap-3">
            <span class="text-xs tabular-nums text-zinc-400">
              {members_label(group.member_count)}
            </span>
            <.chip :if={group.mapping}>{role_label(group.mapping.role)}</.chip>
            <span :if={!group.mapping} class="text-xs text-zinc-400">No role mapping</span>
          </div>
        </li>
      </ul>

      <.empty_state
        :if={@load_error?}
        variant={:hint}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load synced groups"
        class="mt-4"
      >
        This is a load error, not an empty directory — your IdP may well be pushing groups.
        Refresh the page to try again.
      </.empty_state>
      <.empty_state :if={not @load_error? and @synced_groups == []} variant={:hint} class="mt-4">
        No groups synced yet. Once your IdP pushes group memberships over SCIM, they'll appear here
        with their member counts.
      </.empty_state>
    </section>
    """
  end

  defp members_label(1), do: "1 member"
  defp members_label(count), do: "#{count} members"

  defp directory_group_option(group),
    do: {"#{directory_group_name(group)} · #{directory_group_reference(group)}", group.id}

  defp directory_group_name(%{display: display}) when is_binary(display) and display != "",
    do: display

  defp directory_group_name(%{external_group_display: display})
       when is_binary(display) and display != "",
       do: display

  defp directory_group_name(group), do: directory_group_reference(group)

  defp directory_group_reference(%{external_group_id: external_group_id})
       when is_binary(external_group_id) and external_group_id != "",
       do: external_group_id

  defp directory_group_reference(%{id: id}) when is_binary(id),
    do: "Emisar group #{String.slice(id, 0, 8)}"

  defp directory_group_reference(%{directory_group_id: id}) when is_binary(id),
    do: "Emisar group #{String.slice(id, 0, 8)}"

  attr :members, :list, required: true
  attr :load_error?, :boolean, required: true
  attr :member_role_options, :list, required: true
  attr :can_manage_team?, :boolean, required: true
  attr :can_configure_directory_sync?, :boolean, required: true
  attr :current_user_id, :string, required: true
  attr :scim_enabled, :boolean, required: true

  # The members provisioned through this connection (SCIM sync / SSO first-login /
  # approved link), with portal-based lifecycle actions per row — re-role or
  # suspend/reactivate. The controls act on the Accounts membership (manage_team,
  # which enforces owner / last-owner / self); someone removed from the account
  # whose identity lingers shows "Removed" with no actions. A failed read keeps
  # its count off the header — "0" would assert a roster size we don't know.
  defp synced_members_section(assigns) do
    ~H"""
    <section>
      <.section_header
        title="Synced members"
        count={if @load_error?, do: nil, else: length(@members)}
        count_tone={:neutral}
      />
      <ul :if={@members != []} class="mt-4 divide-y divide-zinc-800/70">
        <li
          :for={member <- @members}
          class="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="truncate text-sm text-zinc-200">
                {Accounts.member_display_name(member.membership, member.identity.user)}
              </span>
              <.chip :if={is_nil(member.membership)} tone={:rose}>Removed</.chip>
              <.chip
                :if={member.membership && Accounts.membership_disabled?(member.membership)}
                tone={:amber}
              >
                Suspended
              </.chip>
              <.chip :if={not member.identity.scim_active}>Deactivated in IdP</.chip>
              <.chip>{provisioned_via_label(member.identity.provisioned_via)}</.chip>
            </div>
            <%!-- No truncate: a long directory id (a UUID `sub`) wraps so its
                 "· last synced" tail stays visible rather than clipping to "last s…". --%>
            <div class="mt-0.5 text-xs text-zinc-400">
              <span class="break-all font-mono">{synced_external_id(member.identity)}</span>
              <span :if={member.identity.last_seen_at}>
                · last synced
                <.local_time
                  id={"scim-member-synced-#{member.identity.id}"}
                  value={member.identity.last_seen_at}
                  mode={:relative}
                />
              </span>
            </div>
          </div>

          <div :if={@can_manage_team? and member.membership} class="flex shrink-0 items-center gap-2">
            <%= if member.membership.user_id == @current_user_id do %>
              <span class="text-xs text-zinc-400">you</span>
            <% else %>
              <%!-- On a directory-synced provider the role is the IdP's: a group→role
                 mapping (or the provider default) recomputes it on every sync, so a
                 manual change here silently reverts — read-only. An OIDC-only provider
                 (no directory sync) keeps the editable select; those roles aren't
                 recomputed. The remedy must remain available after a plan downgrade,
                 when Role mapping is no longer rendered. --%>
              <.tooltip
                :if={@scim_enabled}
                id={"role-lock-#{member.membership.id}"}
                text={role_lock_tip(@can_configure_directory_sync?)}
              >
                <.chip icon="role.restricted">
                  {Emisar.Auth.role_label(member.membership.role)}
                </.chip>
              </.tooltip>
              <form
                :if={not @scim_enabled}
                id={"synced-role-#{member.membership.id}"}
                phx-change="change_member_role"
                class="w-36"
              >
                <input type="hidden" name="membership_id" value={member.membership.id} />
                <.select
                  id={"synced-role-select-#{member.membership.id}"}
                  name="role"
                  size={:compact}
                  class="text-xs"
                  options={role_select_options(@member_role_options, member.membership.role)}
                />
              </form>
              <%!-- Suspend is reversible (Reactivate undoes it), so it stays
                   NEUTRAL — rose is reserved for the irreversible Delete. The face
                   is bordered, like every visible action verb (§7.47); Reactivate
                   below is its twin and wears the same one. --%>
              <.confirm_button
                :if={not Accounts.membership_disabled?(member.membership)}
                id={"suspend-scim-#{member.membership.id}"}
                title="Suspend this member?"
                confirm_label="Suspend member"
                variant={:secondary}
                tone={:neutral}
                size={:sm}
                on_confirm={JS.push("suspend_member", value: %{membership_id: member.membership.id})}
              >
                <:body>
                  They're signed out and blocked until reactivated — and directory sync may reactivate them if your IdP still lists them.
                </:body>
                Suspend
              </.confirm_button>
              <.button
                :if={Accounts.membership_disabled?(member.membership) and member.identity.scim_active}
                variant={:secondary}
                tone={:neutral}
                size={:sm}
                phx-click="reinstate_member"
                phx-value-membership_id={member.membership.id}
              >
                Reactivate
              </.button>
              <%!-- Keep the expected action in place, but disabled: the IdP owns
                   this state and its next active:true sync performs the change. --%>
              <.tooltip
                :if={
                  Accounts.membership_disabled?(member.membership) and not member.identity.scim_active
                }
                id={"reactivate-in-idp-#{member.membership.id}"}
                text="This member was deactivated in your identity provider. Reactivate them there."
              >
                <.button variant={:secondary} tone={:neutral} size={:sm} disabled>
                  Reactivate
                </.button>
              </.tooltip>
            <% end %>
          </div>
        </li>
      </ul>

      <.empty_state
        :if={@load_error?}
        variant={:hint}
        tone={:danger}
        icon="state.warning"
        title="Synced members couldn't be loaded"
        class="mt-4"
      >
        Refresh the page to try again. This connection may still have provisioned members.
      </.empty_state>
      <.empty_state :if={@members == [] and not @load_error?} variant={:hint} class="mt-4">
        No one has been provisioned through this connection yet. Members appear here after they sign in
        through it, or after directory sync provisions them.
      </.empty_state>
    </section>
    """
  end

  # "Role mapping above" only exists while the plan renders directory-sync config.
  defp role_lock_tip(true), do: "Role is managed by directory sync — set it in Role mapping above"

  defp role_lock_tip(false),
    do: "Role is managed by directory sync — change this member's groups in your IdP"

  # `{label, value}` role pairs as the shared select's option maps.
  defp role_select_options(role_options, current_role) do
    Enum.map(role_options, fn {label, value} ->
      %{value: value, label: label, disabled: false, selected: to_string(current_role) == value}
    end)
  end

  # The identity's directory id — the SCIM externalId if synced, else the OIDC sub.
  defp synced_external_id(identity),
    do: identity.scim_external_id || identity.provider_identifier

  defp provisioned_via_label(:scim), do: "SCIM"
  defp provisioned_via_label(:oidc_jit), do: "SSO"
  defp provisioned_via_label(:manual), do: "Linked"
  defp provisioned_via_label(_), do: "Synced"

  defp role_label(role), do: Emisar.Auth.role_label(role)

  defp runner_access_mode_label(:none), do: "No runners"
  defp runner_access_mode_label(:all), do: "All runners"
  defp runner_access_mode_label(:restricted), do: "Selected runners"

  defp mapping_runner_reach_phrase(:none), do: "None"
  defp mapping_runner_reach_phrase(:all), do: "All"
  defp mapping_runner_reach_phrase(:restricted), do: nil

  defp mapping_pack_reach_phrase(:all), do: "All"
  defp mapping_pack_reach_phrase(:restricted), do: nil

  defp pack_access_mode_label(:all), do: "All packs"
  defp pack_access_mode_label(:restricted), do: "Selected packs"

  defp restricted_runner_access?(mode), do: mode in [:restricted, "restricted"]

  defp provisioner_label(:jit), do: "Auto-provision"
  defp provisioner_label(:manual), do: "Manual approval"
end
