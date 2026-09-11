defmodule EmisarWeb.SSOSettingsLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Runners, SSO}
  alias EmisarWeb.{ConfirmDialog, DirectoryGroups, GroupAccessForm, LiveForm, LiveTable}
  alias EmisarWeb.{MailTo, MemberErrors, OIDCStepUp, Permissions, RoleCopy, RunnerScope}
  alias Phoenix.LiveView.JS

  @group_access_prefix "group_access_"
  @synced_member_prefix "synced_members_"
  @refresh_ms 15_000

  # The role composer searches beyond the current directory page.
  @group_picker_scopes ~w(role)

  # Named the connection's own action: the shared step-up cannot know that this
  # page is proving a real provider sign-in rather than linking a profile.
  @sign_in_verification_start_error "Couldn't start sign-in verification."

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

  # Both the default-role select and group→role menu OMIT :owner — neither JIT nor
  # directory sync may assign owner (the changeset rejects it too; owner is a
  # deliberate human grant). Don't offer what can't be chosen.
  @role_options Enum.map(
                  Emisar.Auth.roles() -- [:owner],
                  &{Emisar.Auth.role_label(&1), Atom.to_string(&1)}
                )

  # New member provisioning modes for the form's select. JIT adds the membership on
  # first sign-in; manual parks first sign-ins as pending requests an admin
  # approves. Bespoke prose labels, so a literal list (not capitalized atoms).
  @provisioner_options [
    {"Add on first sign-in", "jit"},
    {"Require approval", "manual"}
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
      |> assign(:member_role_options, member_role_options(socket.assigns.current_subject))
      |> assign(:directory_refresh, nil)
      |> DirectoryGroups.init()
      |> assign(:directory_group_picker, nil)
      |> assign(:provider_load_error?, false)
      |> assign(:namespace_locked?, true)
      |> assign(:provisioner_options, @provisioner_options)
      # The connection's synced members (identity + membership), loaded on :show —
      # one page of them, since a directory is what makes this list long.
      |> assign(:synced_members, [])
      |> assign(:synced_member_metadata, empty_metadata())
      |> assign(:synced_members_load_error?, false)
      |> assign(:edit_form, nil)
      # The :new/:show create form. Only those actions assign it, but test_connection
      # reads it and is reachable over the socket from any route (IL-15), so default
      # it here — a nil default makes the crafted event a no-op, not a KeyError.
      |> assign(:form, nil)
      # The connection in scope: the one :show and :edit load, nil everywhere
      # else. Set per-action in handle_params.
      |> assign(:provider, nil)
      |> reset_mapping_panels()
      # The role composer's picker. A directory can push thousands of
      # groups, so the picker holds the operator's term and the bounded matches
      # the server answered with — never the directory.
      |> assign(:group_pickers, Map.new(@group_picker_scopes, &{&1, new_group_picker()}))
      # The add-mapping form is behind an "Add mapping" button, not always open.
      |> assign(:adding_mapping, false)
      |> assign(:expanded_scopes, MapSet.new())
      |> assign(:runners, [])
      |> assign(:runner_load_error?, false)
      |> assign(:pack_load_error?, false)
      |> assign(:pack_advertisements, %{})
      |> assign(:mapping_filter_params, %{})
      |> assign(:scim_base_url, "#{Emisar.PublicUrl.base()}/scim/v2")
      # The fixed OIDC redirect URI the operator registers in their IdP — shown
      # in the per-provider setup guide so they paste the exact value.
      |> assign(:callback_url, "#{Emisar.PublicUrl.base()}/sign_in/sso/callback")
      # The freshly-minted SCIM token, shown ONCE: `%{provider_id, token}` or
      # nil. Never re-rendered from a stored value — write-only, like every
      # emisar secret.
      |> assign(:scim_token, nil)
      # The issuer discovery check's last result on /new: nil, {:ok, summary},
      # or {:error, reason}. Cleared whenever the form changes so it never lies.
      |> assign(:test_result, nil)
      |> assign(:sign_in_verification, nil)
      |> OIDCStepUp.reset()
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
    {:noreply, socket |> cancel_directory_refresh() |> push_navigate(to: destination)}
  end

  def handle_params(params, _uri, socket) do
    socket =
      socket |> cancel_directory_refresh() |> DirectoryGroups.init() |> load_for_action(params)

    {:noreply, schedule_directory_refresh(socket)}
  end

  defp load_for_action(%{assigns: %{has_sso_permission?: false}} = socket, _params), do: socket

  # Expiry makes an existing connection dormant, but a permission holder can
  # still inspect and remove its stored trust. Adding and editing are paid
  # operations, and those views load nothing without the entitlement.
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
  # not_found → back to the overview) + its directory groups and access mappings.
  defp load_show(socket, params) do
    id = params["id"]

    case SSO.fetch_provider_by_id(id, socket.assigns.current_subject) do
      {:ok, provider} ->
        socket
        |> assign(:loaded?, true)
        |> assign(:provider, provider)
        |> assign(:provider_load_error?, false)
        |> assign(:scim_token, current_scim_token(socket.assigns.scim_token, provider))
        |> assign(:mapping_filter_params, Map.drop(params, ["id"]))
        |> assign(:adding_mapping, false)
        |> assign(:adding_runner_access_mapping, false)
        |> load_group_mappings(provider, params)
        |> load_synced_members(provider, params)
        |> load_runners()
        |> load_sign_in_verification(provider)
        |> assign_form(SSO.change_provider(socket.assigns.current_subject))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Connection not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")
    end
  end

  defp load_sign_in_verification(socket, provider) do
    case SSO.provider_sign_in_verification_facts(provider, socket.assigns.current_subject) do
      {:ok, facts} -> assign(socket, :sign_in_verification, facts)
      {:error, _reason} -> assign(socket, :sign_in_verification, nil)
    end
  end

  # The users provisioned through this connection, each paired with its account
  # membership (nil if the person was fully removed but the identity lingers) — so
  # the "Synced members" card can show state and act on the membership. Two reads
  # (SSO identities + Accounts memberships), zipped by user id; either failing
  # keeps uncertainty explicit instead of asserting that nobody was provisioned.
  defp load_synced_members(socket, provider, params) do
    subject = socket.assigns.current_subject

    opts =
      LiveTable.params_to_opts(params, SSO.directory_member_filters(),
        prefix: @synced_member_prefix
      )

    group_id = params["#{@synced_member_prefix}directory_group_id"]

    opts =
      if group_id in [nil, ""], do: opts, else: Keyword.put(opts, :directory_group_id, group_id)

    socket = DirectoryGroups.load_filter(socket, group_id, provider_id: provider.id)

    with {:ok, identities, metadata} <- SSO.list_synced_users(provider, subject, opts),
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
          fn identity ->
            membership = Map.get(membership_by_user, identity.user_id)

            %{
              identity: identity,
              membership: membership,
              manageable?: membership && Accounts.subject_can_manage_member?(membership, subject)
            }
          end
        )

      socket
      |> assign(:synced_members, members)
      |> assign(:synced_member_metadata, metadata)
      |> assign(:synced_members_load_error?, false)
      |> DirectoryGroups.load_summaries(user_ids, provider_id: provider.id)
    else
      _ ->
        socket
        |> assign(:synced_members, [])
        |> assign(:synced_member_metadata, empty_metadata())
        |> assign(:synced_members_load_error?, true)
        |> DirectoryGroups.init()
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
        |> assign(:provider, provider)
        |> assign_namespace_lock(provider)
        |> load_runners()
        |> assign_edit_form(provider)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Connection not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")
    end
  end

  defp assign_namespace_lock(socket, provider) do
    case SSO.provider_identity_namespace_locked?(provider, socket.assigns.current_subject) do
      {:ok, locked?} -> assign(socket, :namespace_locked?, locked?)
      {:error, _reason} -> assign(socket, :namespace_locked?, true)
    end
  end

  defp member_role_options(subject) do
    Emisar.Auth.roles()
    |> Enum.filter(&Accounts.subject_can_assign_member_role?(&1, subject))
    |> Enum.map(&{Emisar.Auth.role_label(&1), Atom.to_string(&1)})
  end

  defp cancel_directory_refresh(socket) do
    case socket.assigns.directory_refresh do
      {_attempt, _provider_id, timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    assign(socket, :directory_refresh, nil)
  end

  defp schedule_directory_refresh(%{assigns: %{live_action: :show, provider: %{id: id}}} = socket) do
    socket = cancel_directory_refresh(socket)

    if connected?(socket) do
      attempt = make_ref()
      timer = Process.send_after(self(), {:refresh_directory, attempt, id}, @refresh_ms)
      assign(socket, :directory_refresh, {attempt, id, timer})
    else
      socket
    end
  end

  defp schedule_directory_refresh(socket), do: socket

  # Only read projections refresh. Drafts, selected groups and one-time secrets
  # belong to the operator's interaction and are never reseeded by this timer.
  defp refresh_directory(socket) do
    subject = socket.assigns.current_subject

    case SSO.fetch_provider_by_id(socket.assigns.provider.id, subject) do
      {:ok, provider} ->
        socket =
          socket
          |> assign(:scim_token, current_scim_token(socket.assigns.scim_token, provider))
          |> assign(:provider, provider)
          |> assign(:provider_load_error?, false)
          |> assign(:can_configure?, SSO.subject_can_configure_sso?(subject))
          |> assign(
            :can_configure_directory_sync?,
            SSO.subject_can_configure_directory_sync?(subject)
          )
          |> load_sign_in_verification(provider)
          |> load_synced_members(provider, socket.assigns.mapping_filter_params)

        if provider.scim_enabled and socket.assigns.can_configure_directory_sync? do
          socket
          |> ensure_mapping_forms(provider)
          |> reload_mappings(provider)
        else
          reset_mapping_panels(socket)
        end

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        socket
        |> cancel_directory_refresh()
        |> assign(:provider, nil)
        |> assign(:scim_token, nil)
        |> put_flash(:error, "This connection is no longer available.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")

      {:error, _reason} ->
        assign(socket, :provider_load_error?, true)
    end
  end

  defp ensure_mapping_forms(socket, provider) do
    if is_nil(socket.assigns.mapping_form),
      do: assign(socket, :mapping_form, mapping_form(provider)),
      else: socket
  end

  defp load_runners(socket) do
    {advertisements, pack_load_error?} =
      RunnerScope.account_pack_advertisements(socket.assigns.current_subject)

    socket =
      socket
      |> assign(:pack_advertisements, advertisements)
      |> assign(:pack_load_error?, pack_load_error?)

    case Runners.list_runners_in_action_scope(socket.assigns.current_subject) do
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

  # Directory mappings require a SCIM-enabled connection. Load one group page
  # and seed the role composer. Reads answer `{rows, metadata, read_failed?}`:
  # the rows render the list, and the flag keeps a failed read from rendering as
  # that section's "no mappings / no groups" — which on this page reads as a
  # claim that the directory grants nobody a role or extra runner reach.
  defp load_group_mappings(
         socket,
         %SSO.IdentityProvider{scim_enabled: true} = provider,
         params
       ) do
    opts =
      LiveTable.params_to_opts(params, SSO.directory_group_filters(),
        prefix: @group_access_prefix
      )

    {groups, metadata, failed?} = list_access_groups(socket, provider, opts)

    socket
    |> assign(:access_groups, groups)
    |> assign(:role_mapping_errors, %{})
    |> assign(:group_mapping_metadata, metadata)
    |> assign(:group_mappings_load_error?, failed?)
    |> assign(:mapping_form, mapping_form(provider))
    |> assign(:group_access_editor, nil)
  end

  defp load_group_mappings(socket, %SSO.IdentityProvider{}, _params),
    do: reset_mapping_panels(socket)

  defp reset_mapping_panels(socket) do
    socket
    |> assign(:access_groups, [])
    |> assign(:role_mapping_errors, %{})
    |> assign(:group_mapping_metadata, empty_metadata())
    |> assign(:group_mappings_load_error?, false)
    |> assign(:mapping_form, nil)
    |> assign(:group_access_editor, nil)
  end

  defp list_access_groups(socket, provider, opts) do
    case SSO.list_group_access(provider, socket.assigns.current_subject, opts) do
      {:ok, groups, metadata} -> {groups, metadata, false}
      {:error, _reason} -> {[], empty_metadata(), true}
    end
  end

  defp empty_metadata, do: %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0}

  def handle_event("search_filter_options", params, socket),
    do: {:noreply, DirectoryGroups.search_filter(socket, params)}

  def handle_event("page_filter_options", params, socket),
    do: {:noreply, DirectoryGroups.page_filter(socket, params)}

  def handle_event("toggle_member_groups", params, socket) do
    case socket.assigns.provider do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply, DirectoryGroups.toggle_member_groups(socket, params, provider_id: provider.id)}
    end
  end

  def handle_event("search_member_groups", params, socket),
    do: {:noreply, DirectoryGroups.search_member_groups(socket, params)}

  def handle_event("page_member_groups", params, socket),
    do: {:noreply, DirectoryGroups.page_member_groups(socket, params)}

  def handle_event("filter_groups", %{"group_access_search" => term}, socket)
      when is_binary(term) do
    if socket.assigns.provider do
      {:noreply,
       LiveTable.apply_filter(
         socket,
         ~p"/app/#{socket.assigns.current_account}/settings/sso/#{socket.assigns.provider.id}",
         %{"group_access_search" => String.slice(term, 0, 200)},
         SSO.directory_group_filters(),
         prefix: "group_access_",
         current_params: socket.assigns.mapping_filter_params
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter_groups", _params, socket), do: {:noreply, socket}

  def handle_event(
        "filter_directory_members",
        %{"synced_members_search" => term} = submitted,
        socket
      )
      when is_binary(term) do
    if socket.assigns.provider do
      params =
        submitted
        |> Map.put("synced_members_search", String.slice(term, 0, 200))

      {:noreply,
       LiveTable.apply_filter(
         socket,
         ~p"/app/#{socket.assigns.current_account}/settings/sso/#{socket.assigns.provider.id}",
         params,
         SSO.directory_member_filters(),
         prefix: "synced_members_",
         current_params: socket.assigns.mapping_filter_params
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter_directory_members", _params, socket), do: {:noreply, socket}

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
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &do_create(&1, params)
    )
  end

  # Probe only the discovery document for the issuer currently in the form. This
  # intentionally does not claim the client credentials or callback work; that
  # proof needs a saved provider and the real sign-in verification on its detail.
  def handle_event("test_connection", _params, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &do_test_connection/1
    )
  end

  def handle_event("start_provider_sign_in_verification", %{"provider_id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &start_provider_verification(&1, id)
    )
  end

  def handle_event("confirm_oidc_step_up", %{"oidc_step" => %{"code" => code}}, socket) do
    case socket.assigns.oidc_step do
      %{} = step ->
        case OIDCStepUp.confirm(step, code, socket.assigns.current_subject) do
          {:ok, proof} ->
            {:noreply, OIDCStepUp.handoff(socket, step, proof)}

          {:error, message} ->
            {:noreply,
             socket
             |> assign(:oidc_step_error, message)
             |> push_event("code:reset", %{id: "provider-oidc-step-code"})}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Start sign-in verification first.")}
    end
  end

  def handle_event("resend_oidc_step_up", _params, socket) do
    case socket.assigns.oidc_step do
      %{factor: :email} = step ->
        {:noreply, OIDCStepUp.resend(socket, step, "provider-oidc-step-code")}

      _other ->
        {:noreply, put_flash(socket, :error, "Start sign-in verification again.")}
    end
  end

  def handle_event("cancel_oidc_step_up", _params, socket),
    do: {:noreply, OIDCStepUp.reset(socket)}

  # Pure view: expand or collapse a mapping row's clipped pack chip list. Held
  # per mapping id so a re-render can't re-collapse a row opened to audit.
  def handle_event("toggle_scope_expand", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded_scopes, &RunnerScope.toggle_scope(&1, id))}
  end

  def handle_event("validate_edit", %{"provider_id" => id, "provider" => params} = event, socket) do
    case find_provider(socket, id) do
      nil -> {:noreply, socket}
      provider -> {:noreply, assign_edit_form(socket, provider, params, event)}
    end
  end

  def handle_event("update", %{"provider_id" => id, "provider" => params}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &do_update(&1, id, params)
    )
  end

  def handle_event("enable_verified_provider", %{"provider_id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &do_enable_verified_provider(&1, id)
    )
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_manage_sso?(socket.assigns.current_subject),
      &do_delete(&1, id)
    )
  end

  # -- Directory sync (SCIM) ------------------------------------------

  def handle_event("enable_scim", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_enable_scim(&1, id)
    )
  end

  def handle_event("rotate_scim", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_rotate_scim(&1, id)
    )
  end

  def handle_event("disable_scim", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_manage_sso?(socket.assigns.current_subject),
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
        changeset = SSO.change_group_mapping(provider, params) |> LiveForm.on_change(event)

        {:noreply,
         socket
         |> assign(:mapping_form, mapping_to_form(provider, changeset))
         |> search_group_picker("role", provider, event["group_search"])}
    end
  end

  def handle_event("create_mapping", %{"provider_id" => id, "mapping" => params}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_create_mapping(&1, id, params)
    )
  end

  def handle_event("add_mapping_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_mapping, true)
     |> open_group_picker("role")}
  end

  def handle_event("set_group_role", %{"group_id" => id, "role" => role}, socket)
      when is_binary(role) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_set_group_role(&1, id, role)
    )
  end

  def handle_event("set_group_role", _params, socket), do: {:noreply, socket}

  # Close the add form and reset it, so a re-open starts blank (not with the last
  # partial input). do_create_mapping already resets the form on a successful add.
  def handle_event("cancel_add_mapping", _params, socket) do
    socket =
      case socket.assigns.provider do
        nil -> socket
        provider -> assign(socket, :mapping_form, mapping_form(provider))
      end

    {:noreply,
     socket
     |> assign(:adding_mapping, false)
     |> reset_group_picker("role")}
  end

  def handle_event("delete_mapping", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_delete_mapping(&1, id)
    )
  end

  # -- Group access ---------------------------------------------------

  def handle_event("edit_group_access", %{"group_id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_edit_group_access(&1, id)
    )
  end

  def handle_event("cancel_group_access", _params, socket),
    do: {:noreply, assign(socket, :group_access_editor, nil)}

  def handle_event(
        "validate_group_access",
        %{"group_id" => id, "runner_access_mapping" => params} = event,
        socket
      )
      when is_map(params) do
    case socket.assigns.group_access_editor do
      %{group_id: ^id} = editor ->
        attrs = group_access_submission(socket, editor, params)

        case SSO.change_group_runner_access_mapping(
               editor.target,
               attrs,
               socket.assigns.current_subject
             ) do
          {:ok, changeset} ->
            editor = %{editor | errors: []}

            {:noreply,
             put_group_access_form(socket, editor, LiveForm.on_change(changeset, event))}

          {:error, _reason} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "save_group_access",
        %{"group_id" => id, "runner_access_mapping" => params},
        socket
      )
      when is_map(params) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_save_group_access(&1, id, params)
    )
  end

  def handle_event(event, _params, socket)
      when event in ["edit_group_access", "validate_group_access", "save_group_access"],
      do: {:noreply, socket}

  def handle_event("delete_runner_access_mapping", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_directory_sync?(socket.assigns.current_subject),
      &do_delete_runner_access_mapping(&1, id)
    )
  end

  # -- Role mapping group picker --------------------------------------

  def handle_event("select_group", %{"scope" => scope, "group_id" => id}, socket)
      when scope in @group_picker_scopes do
    picker = group_picker(socket, scope)

    # Only a group the server just answered with can be chosen. Mutations also
    # re-authorize the immutable group id.
    case Enum.find(picker.results, &(&1.id == id)) do
      nil -> {:noreply, socket}
      group -> {:noreply, put_group_picker(socket, scope, %{picker | chosen: group})}
    end
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
      Accounts.subject_can_manage_team?(socket.assigns.current_subject),
      &do_change_member_role(&1, id, role)
    )
  end

  def handle_event("suspend_member", %{"membership_id" => id}, socket) do
    Permissions.gated(
      socket,
      Accounts.subject_can_manage_team?(socket.assigns.current_subject),
      &do_suspend_member(&1, id)
    )
  end

  def handle_event("reinstate_member", %{"membership_id" => id}, socket) do
    Permissions.gated(
      socket,
      Accounts.subject_can_manage_team?(socket.assigns.current_subject),
      &do_reinstate_member(&1, id)
    )
  end

  # No-op for the on_mount badge/fleet hooks' broadcasts (approvals, packs,
  # runner presence). Those nav cues are owned by the hooks; this page ignores them.
  def handle_info(
        {:refresh_directory, attempt, id},
        %{
          assigns: %{
            live_action: :show,
            provider: %{id: id},
            directory_refresh: {attempt, id, _timer}
          }
        } = socket
      ) do
    {:noreply, socket |> refresh_directory() |> schedule_directory_refresh()}
  end

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
  # No create form in scope (an :edit/:index route, or a crafted off-route event) —
  # nothing to test, so no-op rather than KeyError on the absent form.
  defp do_test_connection(%{assigns: %{form: nil}} = socket), do: {:noreply, socket}

  defp do_test_connection(socket) do
    issuer = Ecto.Changeset.get_field(socket.assigns.form.source, :issuer)

    result =
      case {form_kind(socket.assigns.form), issuer} do
        {"jumpcloud", value} when value in [nil, ""] -> {:error, :missing_jumpcloud_region}
        _ -> SSO.test_provider(issuer, socket.assigns.current_subject)
      end

    {:noreply, assign(socket, :test_result, result)}
  end

  defp start_provider_verification(socket, id) do
    case find_provider(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That connection is no longer available.")}

      provider ->
        step = %{provider_id: provider.id, provider_name: provider.name}

        {:noreply,
         OIDCStepUp.begin(socket, step, :verify_provider, @sign_in_verification_start_error)}
    end
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

          {:error, :identity_namespace_locked} ->
            {:noreply,
             socket
             |> assign_namespace_lock(provider)
             |> put_flash(:error, error_message(:identity_namespace_locked))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_enable_verified_provider(socket, id) do
    with_provider(socket, id, fn provider ->
      case SSO.update_provider(provider, %{enabled: true}, socket.assigns.current_subject) do
        {:ok, _provider} ->
          {:noreply,
           socket
           |> put_flash(:info, "Connection enabled for members.")
           |> reload()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
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
     |> assign(:scim_token, %{
       provider_id: provider.id,
       token: raw,
       token_hash: provider.scim_token_hash
     })
     |> reload()}
  end

  defp current_scim_token(
         %{provider_id: id, token_hash: hash} = revealed,
         %{id: id, scim_enabled: true, scim_token_hash: hash}
       ),
       do: revealed

  defp current_scim_token(_revealed, _provider), do: nil

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
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Role updated.") |> reload()}

        {:error, reason} ->
          # reload() so the dropdown trigger reflects the STORED role after a
          # refusal, not the value the operator picked.
          {:noreply, socket |> put_flash(:error, MemberErrors.message(reason)) |> reload()}
      end
    end)
  end

  defp do_suspend_member(socket, membership_id) do
    with_synced_membership(socket, membership_id, fn membership ->
      case Accounts.suspend_membership(membership, socket.assigns.current_subject) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Member suspended.") |> reload()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, MemberErrors.message(reason))}
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
        {:error, reason} -> {:noreply, put_flash(socket, :error, MemberErrors.message(reason))}
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
        {:ok, mapping} ->
          {:noreply,
           socket
           |> clear_role_mapping_error(mapping.directory_group_id)
           |> put_flash(:info, "Role mapping added.")
           |> assign(:adding_mapping, false)
           |> assign(:mapping_form, mapping_form(provider))
           |> reset_group_picker("role")
           |> reload_mappings(provider)}

        {:error, %Ecto.Changeset{} = changeset} ->
          form = mapping_to_form(provider, Map.put(changeset, :action, :insert))
          {:noreply, assign(socket, :mapping_form, form)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end)
  end

  defp do_set_group_role(socket, group_id, role) do
    group = Enum.find(socket.assigns.access_groups, &(&1.id == group_id and not &1.retired?))

    cond do
      is_nil(group) ->
        {:noreply, socket}

      is_nil(group.mapping) and socket.assigns.adding_mapping ->
        {:noreply, socket}

      group.mapping && to_string(group.mapping.role) == role ->
        {:noreply, socket}

      true ->
        set_group_role(socket, group, role)
    end
  end

  defp set_group_role(socket, group, role) do
    provider = socket.assigns.provider
    subject = socket.assigns.current_subject

    result =
      if group.mapping do
        SSO.update_group_mapping(group.mapping, %{"role" => role}, subject)
      else
        params = %{"directory_group_id" => group.id, "role" => role}
        SSO.create_group_mapping(provider, params, subject)
      end

    case result do
      {:ok, _mapping} ->
        {:noreply,
         socket
         |> clear_role_mapping_error(group.id)
         |> put_flash(
           :info,
           if(group.mapping, do: "Role mapping updated.", else: "Role mapping added.")
         )
         |> reload_mappings(provider)}

      {:error, reason} ->
        errors =
          Map.put(socket.assigns.role_mapping_errors, group.id, role_mapping_errors(reason))

        {:noreply,
         socket
         |> reload_mappings(provider)
         |> assign(:role_mapping_errors, errors)}
    end
  end

  defp role_mapping_errors(%Ecto.Changeset{errors: errors}),
    do: Enum.map(errors, fn {_field, error} -> translate_error(error) end)

  defp role_mapping_errors(reason), do: [error_message(reason)]

  defp clear_role_mapping_error(socket, group_id) do
    assign(socket, :role_mapping_errors, Map.delete(socket.assigns.role_mapping_errors, group_id))
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
             |> clear_role_mapping_error(deleted.directory_group_id)
             |> put_flash(:info, "Role mapping removed.")
             |> reload_mappings_for_id(deleted.provider_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  defp do_edit_group_access(socket, id) do
    group = Enum.find(socket.assigns.access_groups, &(&1.id == id and not &1.retired?))

    case {socket.assigns.group_access_editor, group} do
      {%{group_id: ^id}, _} ->
        {:noreply, assign(socket, :group_access_editor, nil)}

      {nil, %{id: ^id} = group} ->
        # Pin create vs update when the editor opens. A concurrent create must
        # return a duplicate error, never silently become an update.
        target = group.runner_access_mapping || socket.assigns.provider

        editor = %{
          group_id: id,
          target: target,
          form: nil,
          errors: [],
          defaults: nil,
          display: %{}
        }

        params =
          if group.runner_access_mapping,
            do: %{},
            else: %{"runner_access_mode" => "none", "pack_access_mode" => "none"}

        case SSO.change_group_runner_access_mapping(
               target,
               group_access_params(editor, params),
               socket.assigns.current_subject
             ) do
          {:ok, changeset} ->
            {:noreply, put_group_access_form(socket, editor, changeset)}

          {:error, _reason} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp do_save_group_access(socket, id, params) do
    case socket.assigns.group_access_editor do
      %{group_id: ^id} = editor ->
        if Enum.any?(socket.assigns.access_groups, &(&1.id == id and not &1.retired?)) do
          save_group_access(socket, editor, group_access_submission(socket, editor, params))
        else
          editor = %{
            editor
            | errors: [
                "This group is no longer available. Cancel this edit and refresh the page."
              ]
          }

          {:noreply, assign(socket, :group_access_editor, editor)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp save_group_access(socket, editor, params) do
    subject = socket.assigns.current_subject

    result =
      case {SSO.empty_group_access?(params), editor.target} do
        {true, %SSO.GroupRunnerAccessMapping{} = mapping} ->
          SSO.delete_group_runner_access_mapping(mapping, subject)

        {true, %SSO.IdentityProvider{} = provider} ->
          # Matching the defaults needs no persisted, empty mapping.
          with {:ok, provider} <- SSO.fetch_provider_by_id(provider.id, subject),
               do: {:ok, %{provider_id: provider.id}}

        {false, %SSO.IdentityProvider{} = provider} ->
          SSO.create_group_runner_access_mapping(provider, params, subject)

        {false, %SSO.GroupRunnerAccessMapping{} = mapping} ->
          SSO.update_group_runner_access_mapping(mapping, params, subject)
      end

    case result do
      {:ok, mapping} ->
        {:noreply,
         socket
         |> assign(:group_access_editor, nil)
         |> put_flash(:info, "Group access saved.")
         |> reload_mappings_for_id(mapping.provider_id)}

      {:error, %Ecto.Changeset{} = changeset} ->
        action = if match?(%SSO.IdentityProvider{}, editor.target), do: :insert, else: :update
        editor = %{editor | errors: role_mapping_errors(changeset)}

        {:noreply, put_group_access_form(socket, editor, %{changeset | action: action})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :group_access_editor, %{editor | errors: [error_message(reason)]})}
    end
  end

  # The row owns the target. Never accept a provider, mapping or group id from
  # inside form attrs, including forged persisted scope arrays.
  defp group_access_params(editor, params) do
    params
    |> Map.take(~w(runner_access_mode scope pack_access_mode pack_scope))
    |> Map.put("directory_group_id", editor.group_id)
  end

  defp group_access_submission(socket, editor, params) do
    editor.defaults
    |> SSO.group_access_additions(params, editor.display, socket.assigns.runners)
    |> then(&group_access_params(editor, &1))
  end

  defp put_group_access_form(socket, editor, changeset) do
    defaults = SSO.group_access_defaults(socket.assigns.provider)

    form =
      to_form(changeset,
        as: "runner_access_mapping",
        id: "edit-group-access-#{editor.group_id}"
      )

    assign(socket, :group_access_editor, %{
      editor
      | form: form,
        defaults: defaults,
        display: GroupAccessForm.presentation(defaults, changeset)
    })
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
             |> clear_group_access_editor(deleted.directory_group_id)
             |> put_flash(:info, "Group access reset to defaults.")
             |> reload_mappings_for_id(deleted.provider_id)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end
    end
  end

  # A full reload after a provider mutation: re-fetch the one connection :show
  # is on (its row may have changed — SCIM toggled, edited) with its group→role
  # mappings and pending manual-link requests, so enabling directory sync
  # (re)seeds the panels and approving/dismissing a request drops it from the
  # list. If the connection vanished (deleted), load_show falls back to the
  # overview.
  defp reload(socket) do
    case socket.assigns.provider do
      nil ->
        socket

      provider ->
        params = Map.put(socket.assigns.mapping_filter_params, "id", provider.id)
        load_show(socket, params)
    end
  end

  # Refresh the connection's mapping list after a mapping CRUD, leaving the rest
  # of the page's loaded state untouched.
  defp reload_mappings(socket, provider) do
    opts =
      LiveTable.params_to_opts(
        socket.assigns.mapping_filter_params,
        SSO.directory_group_filters(),
        prefix: @group_access_prefix
      )

    {groups, metadata, failed?} = list_access_groups(socket, provider, opts)

    socket
    |> assign(:access_groups, groups)
    |> assign(:group_mapping_metadata, metadata)
    |> assign(:group_mappings_load_error?, failed?)
    |> reconcile_group_access_editor(groups, failed?)
  end

  # A successful refresh may retire a group or move it off this cursor page.
  # Never leave an invisible editor disabling every other row. A failed read
  # does not discard the draft; the next successful refresh can recover it.
  defp reconcile_group_access_editor(socket, groups, false) do
    case socket.assigns.group_access_editor do
      %{group_id: id} = editor ->
        if Enum.any?(groups, &(&1.id == id and not &1.retired?)) do
          put_group_access_form(socket, editor, editor.form.source)
        else
          socket
          |> assign(:group_access_editor, nil)
          |> put_flash(
            :info,
            "This group is no longer available on this page. Its unsaved access changes were discarded."
          )
        end

      nil ->
        socket
    end
  end

  defp reconcile_group_access_editor(socket, _groups, true), do: socket

  defp clear_group_access_editor(socket, group_id) do
    case socket.assigns.group_access_editor do
      %{group_id: ^group_id} -> assign(socket, :group_access_editor, nil)
      _ -> socket
    end
  end

  defp reload_mappings_for_id(socket, provider_id) do
    case find_provider(socket, provider_id) do
      nil -> socket
      provider -> reload_mappings(socket, provider)
    end
  end

  # The page holds ONE connection, so a crafted event naming any other id finds
  # nothing and the handler that asked no-ops.
  defp find_provider(%{assigns: %{provider: %SSO.IdentityProvider{id: id} = provider}}, id),
    do: provider

  defp find_provider(_socket, _id), do: nil

  defp find_mapping(socket, id) do
    Enum.find_value(socket.assigns.access_groups, fn group ->
      if group.mapping && group.mapping.id == id, do: group.mapping
    end)
  end

  defp find_runner_access_mapping(socket, id) do
    Enum.find_value(socket.assigns.access_groups, fn group ->
      if group.runner_access_mapping && group.runner_access_mapping.id == id,
        do: group.runner_access_mapping
    end)
  end

  # The create form is built over the context's changeset builder, so phx-change
  # validation (required fields + the owner-exclusion) matches the server create
  # path exactly; account_id / provider_id come from the provider whose panel
  # owns the form.
  defp mapping_form(provider),
    do: mapping_to_form(provider, SSO.change_group_mapping(provider, %{}))

  defp mapping_to_form(provider, %Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: "mapping", id: "create-mapping-#{provider.id}")

  # -- Group picker ---------------------------------------------------

  # The picker never holds the directory: `results` is the bounded set the last
  # server search answered with, `chosen` is the group the operator picked (it
  # rides the form as that group's id), and `load_error?` keeps an empty result
  # from reading as "no such group" when the read never ran.
  defp new_group_picker, do: %{term: "", results: [], chosen: nil, load_error?: false}

  defp group_picker(socket, scope), do: Map.fetch!(socket.assigns.group_pickers, scope)

  defp put_group_picker(socket, scope, picker),
    do: assign(socket, :group_pickers, Map.put(socket.assigns.group_pickers, scope, picker))

  defp reset_group_picker(socket, scope), do: put_group_picker(socket, scope, new_group_picker())

  # Starting a mapping loads the first groups straight away, so an
  # admin with a handful of them never has to type to find one.
  defp open_group_picker(socket, scope) do
    case socket.assigns.provider do
      nil -> reset_group_picker(socket, scope)
      provider -> put_group_picker(socket, scope, search_groups(socket, provider, ""))
    end
  end

  defp search_group_picker(socket, scope, provider, term) do
    picker = group_picker(socket, scope)
    term = term || ""

    # Searching for a replacement must not discard the saved field choice.
    # Other form changes keep the existing results without a directory read.
    if term == picker.term do
      socket
    else
      searched = %{search_groups(socket, provider, term) | chosen: picker.chosen}
      put_group_picker(socket, scope, searched)
    end
  end

  defp search_groups(socket, provider, term) do
    case SSO.search_synced_groups(provider, term, socket.assigns.current_subject) do
      {:ok, groups} -> %{new_group_picker() | term: term, results: groups}
      {:error, _reason} -> %{new_group_picker() | term: term, load_error?: true}
    end
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

  defp error_message(:sign_in_verification_required) do
    "Verify a real sign-in with the current connection settings before enabling it for members."
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

  defp error_message(_) do
    "That action didn't complete. Refresh to see the connection's current state, then try again."
  end

  # Member-lifecycle errors from Accounts (change role / suspend / reinstate) —
  # kept separate from the SSO-config error_message/1 so each reads for its surface.

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
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
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
        <%= case {@live_action, @provider} do %>
          <% {:show, %SSO.IdentityProvider{} = provider} -> %>
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
          <% {:edit, %SSO.IdentityProvider{} = provider} -> %>
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
      <:actions :if={not is_nil(@provider) and @can_configure? and @live_action == :show}>
        <%!-- These act on the connection record, so they live opposite its
             title like every other detail-page action. The status row below
             stays a facts-only read rather than becoming an action toolbar. --%>
        <.button
          id={"view-provider-activity-#{@provider.id}"}
          navigate={
            ~p"/app/#{@current_account}/audit?#{[target_kind: "identity_provider", target_id: @provider.id]}"
          }
          variant={:secondary}
          size={:md}
        >
          View activity
        </.button>
        <.button
          id={"edit-provider-#{@provider.id}"}
          navigate={~p"/app/#{@current_account}/settings/sso/#{@provider.id}/edit"}
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
          title="Single sign-on settings are restricted"
        >
          Only owners and admins can manage connections.
        </.empty_state>
        <.locked :if={@has_sso_permission?} current_account={@current_account} />
        <.plan_locked_connection
          :if={not is_nil(@provider) and @has_sso_permission? and @live_action == :show}
          provider={@provider}
          typed={@typed}
        />
      </div>

      <div :if={@can_configure?} class="space-y-6">
        <.event_block
          :if={@provider_load_error?}
          icon="state.warning"
          title="Couldn't refresh this connection"
          tone={:amber}
        >
          <:body>Showing the last loaded settings. Refresh the page to try again.</:body>
        </.event_block>
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
              Connect your identity provider so your team can sign in with SSO.
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
                <.button
                  id="create-provider"
                  phx-hook="PendingButton"
                  phx-disable-with="Saving..."
                >
                  Add connection
                </.button>
                <%!-- This only checks issuer discovery. type="button" keeps the
                     probe separate from saving the provider. --%>
                <.button
                  id="test-provider"
                  type="button"
                  variant={:secondary}
                  phx-hook="PendingButton"
                  phx-click="test_connection"
                  phx-disable-with="Testing…"
                >
                  Check issuer
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
              kind={form_kind(@form)}
              callback_url={@callback_url}
              new_connection?={true}
            />
          </aside>
        </div>

        <%!-- Editing is its own view (/settings/sso/:id/edit), like /new — a bare
             sub-header over the same sibling field islands, never an inline
             collapsed block and never one giant card. --%>
        <div :if={@live_action == :edit} class="max-w-3xl space-y-5">
          <div :if={@provider} class="space-y-5">
            <%!-- No second crumb or heading here: the shell header already reads
                 Team / Single sign-on / <provider> / Edit connection. --%>
            <p class="max-w-prose text-sm leading-relaxed text-zinc-400">
              Update this connection's OIDC settings. Leave the client secret blank to keep the
              stored one.
            </p>

            <.simple_form
              :if={@edit_form}
              for={@edit_form}
              id={"edit-provider-#{@provider.id}"}
              phx-change="validate_edit"
              phx-submit="update"
            >
              <input type="hidden" name="provider_id" value={@provider.id} />
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
                guide_id={@provider.id}
                callback_url={@callback_url}
                editing?
                namespace_locked?={@namespace_locked?}
                directory_sync?={@provider.scim_enabled}
              />
              <:actions>
                <%!-- Emerald once edited, quiet outlined while clean (house
                     pattern — the button is the unsaved-changes signal). --%>
                <.button
                  id={"save-provider-#{@provider.id}"}
                  variant={if @edit_form.source.changes == %{}, do: :secondary, else: :primary}
                  phx-hook="PendingButton"
                  phx-disable-with="Saving..."
                >
                  Save changes
                </.button>
                <.button
                  navigate={~p"/app/#{@current_account}/settings/sso/#{@provider.id}"}
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
             group→role). @provider is the one handle_params loaded. --%>
        <%!-- Back crumb + entity name live in the shell header (detail_header),
             like every other detail page. --%>
        <%!-- Help-bearing sections own their two-column row: the heading and its
             actions stay in the primary column, while content and help share the
             row below. The rail waits for xl — below that it stacks after the
             section content instead of crowding it. --%>
        <div
          :if={@live_action == :show}
          class="mt-4"
        >
          <%!-- Help-bearing sections share the same primary and rail tracks.
               Provisioning groups its related subsections on those tracks. --%>
          <div
            :if={@provider}
            class="grid grid-cols-1 gap-x-12 gap-y-12 xl:grid-cols-[minmax(0,1fr)_18rem] xl:items-start"
          >
            <%!-- Sign-in stays separate from provisioning and access grants. --%>
            <section
              id="connection-summary"
              class="grid grid-cols-1 gap-x-12 gap-y-8 xl:col-span-2 xl:grid-cols-[minmax(0,1fr)_18rem] xl:items-start"
            >
              <section
                id="connection-status"
                class="min-w-0 xl:col-start-1 xl:row-start-1"
              >
                <.section_header title="Sign-in status" />
                <div
                  id="sign-in-verification"
                  class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="flex min-w-0 flex-wrap items-start gap-x-8 gap-y-3">
                    <p
                      id="connection-enabled-status"
                      class="flex items-center gap-2 text-sm font-medium"
                    >
                      <.status_dot tone={if(@provider.enabled, do: :brand, else: :amber)} />
                      <span class={
                        if(@provider.enabled, do: "text-brand-300", else: "text-amber-300")
                      }>
                        {if(@provider.enabled, do: "Enabled", else: "Disabled")}
                      </span>
                    </p>
                    <div class="flex min-w-0 items-start gap-2.5">
                      <.status_dot
                        tone={sign_in_verification_tone(@sign_in_verification)}
                        class="mt-1.5"
                      />
                      <div class="min-w-0">
                        <p class="text-sm font-medium text-zinc-100">
                          {sign_in_verification_label(@sign_in_verification)}
                        </p>
                        <p class="mt-0.5 text-xs leading-relaxed text-zinc-400">
                          {sign_in_verification_copy(@sign_in_verification, @provider)}
                          <span :if={
                            @sign_in_verification &&
                              @sign_in_verification.status == :verified &&
                              @sign_in_verification.verified_at
                          }>
                            <.local_time
                              id={"provider-sign-in-verified-#{@provider.id}"}
                              value={@sign_in_verification.verified_at}
                              mode={:relative}
                            />.
                          </span>
                        </p>
                      </div>
                    </div>
                  </div>

                  <div class="flex shrink-0 flex-wrap gap-2 sm:justify-end">
                    <.confirm_button
                      :if={
                        (@sign_in_verification && @sign_in_verification.status == :verified) and
                          not @provider.enabled
                      }
                      id={"enable-verified-provider-#{@provider.id}"}
                      title={"Enable #{@provider.name} for members?"}
                      confirm_label="Enable connection"
                      pending_label="Enabling…"
                      size={:md}
                      on_confirm={
                        JS.push("enable_verified_provider", value: %{provider_id: @provider.id})
                      }
                    >
                      <:body>
                        Members can start signing in through this connection. Magic-link sign-in
                        remains available until you separately require SSO for the team.
                      </:body>
                      Enable for members
                    </.confirm_button>

                    <.button
                      id={"verify-provider-sign-in-#{@provider.id}"}
                      type="button"
                      variant={:secondary}
                      size={:md}
                      class="min-w-32"
                      phx-hook="PendingButton"
                      phx-click="start_provider_sign_in_verification"
                      phx-value-provider_id={@provider.id}
                      phx-disable-with="Verifying…"
                    >
                      {if(@sign_in_verification && @sign_in_verification.status == :verified,
                        do: "Verify again",
                        else: "Verify sign-in"
                      )}
                    </.button>
                  </div>
                </div>

                <.oidc_step_dialog
                  :if={@oidc_step && @oidc_step.provider_id == @provider.id}
                  id="provider-oidc-step"
                  form={@oidc_step_form}
                  step={@oidc_step}
                  purpose={:verify}
                  email={@current_user.email}
                  error={@oidc_step_error}
                  handoff={@oidc_handoff}
                  trigger_submit={@oidc_trigger_submit}
                  action={~p"/app/#{@current_account}/settings/sso/identity/link"}
                />
              </section>

              <section id="connection-settings" class="min-w-0 xl:col-start-1 xl:row-start-2">
                <.section_header title="Sign-in settings" />
                <dl class="divide-y divide-zinc-800/70 border-y border-zinc-800/70">
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Provider</dt>
                    <dd class="text-sm text-zinc-300">{kind_label(@provider.kind)}</dd>
                  </div>
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Issuer</dt>
                    <dd class="break-all font-mono text-sm text-zinc-300">{@provider.issuer}</dd>
                  </div>
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Identifier claim</dt>
                    <dd class="font-mono text-sm text-zinc-300">{@provider.identifier_claim}</dd>
                  </div>
                  <div
                    :if={@provider.allowed_email_domain}
                    class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4"
                  >
                    <dt class="text-xs font-medium text-zinc-400">Allowed email domain</dt>
                    <dd class="text-sm text-zinc-300">@{@provider.allowed_email_domain}</dd>
                  </div>
                  <div class="grid gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
                    <dt class="text-xs font-medium text-zinc-400">Multi-factor authentication</dt>
                    <dd class="text-sm text-zinc-300">
                      {if(@provider.satisfies_mfa,
                        do: "Satisfied by this provider",
                        else: "Not satisfied by this provider"
                      )}
                    </dd>
                  </div>
                </dl>
              </section>

              <aside
                id="connection-docs"
                class="text-sm leading-relaxed xl:col-start-2 xl:row-start-2 xl:pt-1"
              >
                <p class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">Docs</p>
                <ul class="mt-3 space-y-2">
                  <li>
                    <.doc_link href={docs_path_for_kind(to_string(@provider.kind))}>
                      Setting up {setup_kind_label(to_string(@provider.kind))}
                    </.doc_link>
                  </li>
                  <li :if={SSO.supports_scim?(@provider.kind)}>
                    <.doc_link href={~p"/docs/scim"}>Directory sync</.doc_link>
                  </li>
                  <li><.doc_link href={~p"/docs/teams-and-access"}>Roles &amp; access</.doc_link></li>
                </ul>
              </aside>
            </section>

            <section id="connection-provisioning" class="min-w-0 space-y-6 xl:col-span-2">
              <.section_with_note
                :if={not @can_configure_directory_sync? or not SSO.supports_scim?(@provider.kind)}
                id="connection-provisioning-policy"
              >
                <:header><.section_header title="User provisioning & directory sync" /></:header>
                <dl id="connection-provisioning-summary">
                  <dt class="text-sm font-medium text-zinc-100">New members</dt>
                  <dd class="mt-0.5 text-xs leading-relaxed text-zinc-400">
                    {provisioner_label(@provider.provisioner)}
                  </dd>
                </dl>
              </.section_with_note>

              <.provisioning_section
                :if={@can_configure_directory_sync? and SSO.supports_scim?(@provider.kind)}
                provider={@provider}
                scim_base_url={@scim_base_url}
                scim_token={@scim_token}
              />

              <%!-- Keep capability and plan limits with provisioning. Neither
                   changes the configured new-member policy above. --%>
              <div
                :if={not SSO.supports_scim?(@provider.kind) or not @can_configure_directory_sync?}
                class="grid grid-cols-1 gap-x-12 xl:grid-cols-[minmax(0,1fr)_18rem]"
              >
                <p
                  :if={not SSO.supports_scim?(@provider.kind)}
                  class="max-w-prose text-sm leading-relaxed text-zinc-400"
                >
                  Directory sync isn't available for {kind_label(@provider.kind)}.
                </p>
                <p
                  :if={!@can_configure_directory_sync? and SSO.supports_scim?(@provider.kind)}
                  class="max-w-prose text-sm leading-relaxed text-zinc-400"
                >
                  Sync members and groups from your identity provider with the Enterprise plan.
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
              </div>

              <.synced_members_section
                id={"synced-members-#{@provider.id}"}
                account={@current_account}
                path={~p"/app/#{@current_account}/settings/sso/#{@provider.id}"}
                members={@synced_members}
                metadata={@synced_member_metadata}
                filter_params={@mapping_filter_params}
                load_error?={@synced_members_load_error?}
                member_role_options={@member_role_options}
                can_configure_directory_sync?={@can_configure_directory_sync?}
                current_user_id={@current_user.id}
                scim_enabled={@provider.scim_enabled}
                group_summaries={@member_group_summaries}
                member_group_list={@member_group_list}
                groups_error?={@member_groups_error?}
                group_picker={@directory_group_picker}
              />
            </section>

            <.group_access_section
              provider={@provider}
              show_mappings?={@can_configure_directory_sync? and @provider.scim_enabled}
              path={~p"/app/#{@current_account}/settings/sso/#{@provider.id}"}
              groups={@access_groups}
              metadata={@group_mapping_metadata}
              filter_params={@mapping_filter_params}
              load_error?={@group_mappings_load_error?}
              group_picker={@group_pickers["role"]}
              mapping_form={@mapping_form}
              mapping_role_options={@role_options}
              role_mapping_errors={@role_mapping_errors}
              adding_mapping={@adding_mapping}
              access_editor={@group_access_editor}
              runners={@runners}
              runner_error={RunnerScope.runner_load_error(@runner_load_error?)}
              pack_error={RunnerScope.pack_load_error(@pack_load_error?)}
              pack_advertisements={@pack_advertisements}
              pack_access_restricted?={@pack_access_restricted?}
              expanded_scopes={@expanded_scopes}
            />

            <%!-- Danger zone at the bottom — the destructive action lives apart
                 from the routine config above (its own canvas section) and still
                 runs the typed confirm. The outer grid owns the rhythm. --%>
            <section id="connection-danger-zone" class="min-w-0 xl:col-start-1">
              <.section_header title="Danger zone" />
              <div class="divide-y divide-zinc-800/70">
                <.confirm_zone
                  title="Delete this connection"
                  phx-click={show_confirm_dialog("delete-provider-#{@provider.id}")}
                >
                  <:body>
                    Removes the connection and stops new sign-ins through it. Members who sign in
                    only through it lose access until it's re-added, and the sessions they signed
                    in with are ended.
                  </:body>
                  Delete connection
                </.confirm_zone>
              </div>
            </section>

            <.confirm_dialog
              id={"delete-provider-#{@provider.id}"}
              title="Delete connection"
              confirm_label="Delete connection"
              pending_label="Deleting…"
              confirm_token={@provider.name}
              typed={@typed}
              on_confirm={
                JS.push("delete", value: %{id: @provider.id})
                |> hide_confirm_dialog("delete-provider-#{@provider.id}")
              }
            >
              <:body>
                Permanently removes the
                <span class="font-medium text-rose-100">{@provider.name}</span>
                connection. Members who sign in only through it lose access until it's re-added.
                The sessions they signed in through it are ended.
              </:body>
            </.confirm_dialog>
          </div>

          <div :if={not @loaded?} class="text-sm text-zinc-400">Loading…</div>
        </div>
      </div>
    </.console_shell>
    """
  end

  # A dormant connection remains visible so an owner can retire configuration
  # and tokens without paying to regain the cleanup controls.
  attr :provider, :map, required: true
  attr :typed, :string, required: true

  defp plan_locked_connection(assigns) do
    ~H"""
    <section class="mt-8">
      <.section_header title={@provider.name} />
      <p class="mt-2 text-sm leading-relaxed text-zinc-400">
        This connection is dormant. Sign-ins and its directory token are refused until paid access
        returns. You can disable directory sync or remove the connection now — neither cleanup
        action needs a plan.
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
          pending_label="Disabling…"
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
        pending_label="Deleting…"
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
          signed in with are ended.
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

  # The issuer check's outcome: discovery succeeded vs. a bounded reason.
  attr :result, :any, required: true

  defp test_result(%{result: {:ok, summary}} = assigns) do
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <.event_block icon="state.success" tone={:brand} title="Issuer reached">
      <:body>
        We found a valid OIDC discovery document. This does not check the client ID, client secret,
        or a real sign-in.
      </:body>
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
      title="Issuer check failed"
    >
      <:body>{@message}</:body>
    </.event_block>
    """
  end

  defp test_error_message(:missing_jumpcloud_region), do: "Select a JumpCloud region first."

  defp test_error_message(:invalid_issuer), do: "Enter the issuer's HTTPS URL first."

  defp test_error_message(:blocked_issuer),
    do: "The issuer can't be a private, loopback, or metadata address."

  defp test_error_message(:rate_limited),
    do: "Too many connection tests. Wait a minute and try again."

  defp test_error_message(:no_supported_id_token_signing_alg) do
    "That issuer only signs ID tokens with algorithms emisar won't accept. Configure it to sign with RS256 (or another public-key algorithm) and test again."
  end

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
  attr :namespace_locked?, :boolean, default: false
  attr :directory_sync?, :boolean, default: false

  # The connection form's fields, grouped into NAKED sibling sections (Provider ·
  # OIDC connection · Member provisioning · Security) — §8.1: the fields are the
  # controls; a panel per group was an island per group. Shared by both actions;
  # the outer <.simple_form> spaces the sections and renders the submit footer.
  defp provider_fields(assigns) do
    assigns = assign(assigns, :kind, form_kind(assigns.form))

    ~H"""
    <div class="space-y-10">
      <section>
        <.section_header title="Provider" />
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
        <.section_header title="OIDC connection" />
        <p :if={@namespace_locked?} id="connection-identity-lock" class="text-xs text-zinc-400">
          <.icon name="state.locked" class="mr-1 h-3.5 w-3.5" />
          Issuer, client ID, and identifier claim are fixed after members connect.
          Add a connection to use different settings.
        </p>
        <%!-- Setup steps for the SELECTED provider — what to create at the IdP and
             what to paste back here. --%>
        <.provider_setup_guide
          :if={@inline_guide?}
          id={@guide_id}
          kind={form_kind(@form)}
          callback_url={@callback_url}
          new_connection?={not @editing?}
        />
        <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="sm:col-span-2">
            <%= cond do %>
              <% @kind == "jumpcloud" -> %>
                <.input
                  field={@form[:issuer]}
                  type="select"
                  label="JumpCloud region"
                  prompt="Select a region…"
                  options={SSO.provider_issuer_regions(@kind)}
                  disabled={@namespace_locked?}
                />
              <% fixed = SSO.provider_fixed_issuer(@kind) -> %>
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
              <% true -> %>
                <.input
                  field={@form[:issuer]}
                  type="url"
                  label="Issuer URL"
                  placeholder={issuer_hint(@kind)}
                  class="font-mono"
                  disabled={@namespace_locked?}
                />
                <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
                  The OIDC issuer — its discovery document is fetched from here. Must be HTTPS.
                </p>
            <% end %>
          </div>
          <%!-- autocomplete="off" on both halves of the OAuth client: a password
               manager offering a saved username here would overwrite the client id
               the operator pasted from their IdP. --%>
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            autocomplete="off"
            disabled={@namespace_locked?}
          />
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
              disabled={@namespace_locked?}
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
        <.section_header title="Member access" />
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="sm:col-span-2">
            <.input
              field={@form[:provisioner]}
              type="select"
              label="New members"
              options={@provisioner_options}
            />
          </div>
          <div class="sm:col-span-2">
            <.label>Default role</.label>
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
            <.label>Default access</.label>
            <%!-- The eyebrows below name the two decisions, so this line spends
                  itself on what they cannot: a group mapping can widen this. --%>
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
              <%= if @directory_sync? do %>
                These defaults also apply to existing directory-managed members.
              <% else %>
                New members start with this access.
              <% end %>
            </p>
            <.access_scope_fields
              runner_mode_name="provider[default_runner_access_mode]"
              runner_mode_value={@form[:default_runner_access_mode].value}
              runner_scope_name="provider[default_runner_scope][]"
              runner_scope_selected={List.wrap(@form[:default_runner_scope].value)}
              pack_mode_name="provider[default_pack_access_mode]"
              pack_mode_value={@form[:default_pack_access_mode].value}
              pack_scope_name="provider[default_pack_scope][]"
              pack_scope_selected={List.wrap(@form[:default_pack_scope].value)}
              runners={@runners}
              advertisements={@pack_advertisements}
              grant_limited?={@pack_access_restricted?}
              runner_load_error?={@runner_load_error?}
              pack_load_error?={@pack_load_error?}
              runner_submit_error_field={@form[:default_runner_access_mode]}
              pack_submit_error_field={@form[:default_pack_access_mode]}
            />
          </div>
          <div class="sm:col-span-2">
            <.input
              field={@form[:allowed_email_domain]}
              type="text"
              label="Allowed email domain (optional)"
              placeholder="acme.com"
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-400">
              Restricts sign-in to verified emails on this domain. Leave blank to accept any
              address the provider returns.
            </p>
          </div>
        </div>
      </section>

      <section>
        <.section_header title="Sign-in security">
          <:subtitle>
            <%= if @editing? do %>
              Whether this provider satisfies MFA, and whether members can use it yet.
            <% else %>
              New connections stay disabled until you save them and verify a real sign-in.
            <% end %>
          </:subtitle>
        </.section_header>
        <div class="space-y-3">
          <div>
            <.input
              field={@form[:satisfies_mfa]}
              type="checkbox"
              label="Sign-in through this provider satisfies the account's MFA requirement"
            />
            <%!-- The caption tracks the box: OFF (the default) it's a calm fact
                 about what turning it on means; ON it's the amber consequence,
                 because that's the state that can actually weaken MFA. A warning
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
              bypass your MFA requirement.
            </p>
          </div>
          <.input
            :if={@editing?}
            field={@form[:enabled]}
            type="checkbox"
            label="Allow members to sign in"
          />
        </div>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :callback_url, :string, required: true
  attr :new_connection?, :boolean, default: false

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
        <:step :if={@kind == "google_workspace"}>
          In Google Auth Platform, set <span class="text-zinc-300">Audience</span>
          to <span class="text-zinc-300">Internal</span>.
        </:step>
        <:step>
          Create an OAuth / OIDC <span class="text-zinc-300">web app</span> {oidc_app_hint(@kind)}.
        </:step>
        <:step>
          Register this <span class="text-zinc-300">redirect URI</span>
          on the app: <.code_line id={"sso-callback-#{@id}"} value={@callback_url} class="mt-1.5" />
        </:step>
        <:step :if={@kind == "jumpcloud"}>
          Select the <span class="text-zinc-300">JumpCloud region</span>
          your organization uses: United States, Europe, or India.
        </:step>
        <:step :if={@kind != "jumpcloud" and is_nil(SSO.provider_fixed_issuer(@kind))}>
          Set the <span class="text-zinc-300">Issuer URL</span>
          to <span class="font-mono text-zinc-300">{issuer_hint(@kind)}</span>.
          <span class="text-zinc-400">{issuer_where_hint(@kind)}</span>
        </:step>
        <:step>
          Paste the app's <span class="text-zinc-300">Client ID</span>
          and <span class="text-zinc-300">Client secret</span>
          into the fields.
        </:step>
        <:step :if={@new_connection?}>
          Select <span class="text-zinc-300">Add connection</span>, then <span class="text-zinc-300">Verify sign-in</span>. After verification, select <span class="text-zinc-300">Enable for members</span>.
        </:step>
      </.steps>
      <p class="mt-3 text-sm leading-relaxed text-zinc-400">
        {provider_directory_note(@kind)}
      </p>
      <%!-- Only show this for providers with a documented per-client DPoP switch. --%>
      <p :if={dpop_relevant?(@kind)} class="mt-3 text-sm leading-relaxed text-zinc-400">
        Leave the requirement for <span class="text-zinc-300">DPoP-bound tokens</span> off.
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

  # Directory setup differs by provider. First-sign-in behavior belongs to the
  # New members setting, not this provider-only guide.
  defp provider_directory_note("okta"),
    do: "Directory sync is a second Okta app — this one only signs people in."

  defp provider_directory_note("entra"),
    do: "This is the app registration; directory sync is a separate enterprise application."

  defp provider_directory_note("jumpcloud"),
    do: "One JumpCloud application covers both this and directory sync."

  defp provider_directory_note("keycloak"),
    do: "Directory sync requires a third-party Keycloak extension."

  defp provider_directory_note("google_workspace") do
    "Google Workspace doesn't support directory sync with emisar."
  end

  # Steps 1 and 3 already say "confidential client" and "discovery document", so
  # the generic line has to stay on the directory axis like the named ones do.
  defp provider_directory_note(_) do
    "Directory sync requires a provider that can send SCIM updates."
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
    "in Google Cloud Console → Google Auth Platform → Clients → Create client (Web application)"
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

  defp dpop_relevant?(kind), do: kind in ~w[okta keycloak]

  # Whether a form checkbox field currently reads as on (params post "true";
  # the loaded struct carries a boolean).
  defp checkbox_on?(field), do: field.value in [true, "true"]

  # Where to FIND the issuer — it's an org/realm-level value, not on the app
  # page, which is the usual point of confusion.
  defp issuer_where_hint("okta") do
    "Copy your org URL from the account menu in the Okta admin console. Use the org URL without -admin or an /oauth2/… path."
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
    "in a SEPARATE Okta app — Okta's OIDC login app can't do SCIM. Add the \"SCIM 2.0 Test App (Header Auth)\" from the OIN catalog (its Sign-On tab is unused — SCIM lives entirely on the Provisioning tab): Configure API Integration → Enable, configure the Base URL and API token as described in step 2, then enable Create / Update / Deactivate. Okta sends the token as a raw header with no `Bearer` scheme, which emisar accepts"
  end

  defp scim_location_hint(:jumpcloud) do
    "on a JumpCloud application's Provisioning tab — one custom app can carry both sign-in and provisioning, so tick \"Export users to this app\" alongside SSO (its SAML/OIDC sub-choice defaults to SAML). Configure the Base URL and Token as described in step 2, then Test Connection → Activate (their form discards the config if you press Save instead)"
  end

  # Keycloak has no outbound SCIM: its own SCIM support (26.6+) makes Keycloak a
  # SCIM *server* others provision INTO, which is the opposite direction. Saying
  # "look in your provider's SCIM settings" sends an admin hunting for a screen
  # that doesn't exist, so name the gap and the way around it.
  defp scim_location_hint(:entra) do
    "on a separate ENTERPRISE APPLICATION, not this app registration — Entra splits sign-in and provisioning across two objects. Create a non-gallery app, then Provisioning → Automatic, with the URL in step 2 as Tenant URL and the `ems-` token as Secret Token. Remap externalId to objectId, or the directory and this connection will disagree about who someone is"
  end

  defp scim_location_hint(:keycloak) do
    "from a SCIM plugin on your Keycloak — Keycloak ships no outbound provisioning of its own, so this needs a third-party extension, which you configure and support"
  end

  defp scim_location_hint(_), do: "in your provider's SCIM / user-provisioning settings"

  # The kind currently selected in the form (string), for the live setup guide;
  # defaults to the first option — what the select shows before any change.
  # Blank on a fresh /new form (nothing picked yet) — the guide/hints fall back
  # to generic and the issuer stays editable, rather than arbitrarily pre-picking
  # the first provider (and locking its issuer before the operator has chosen).
  defp form_kind(form) do
    case form[:kind].value do
      blank when blank in [nil, ""] -> ""
      value -> to_string(value)
    end
  end

  # The humanized label for the form's current kind — for the read-only display on
  # the edit form, where provider type is create-only.
  defp selected_kind_label(form, kind_options) do
    value = form_kind(form)
    Enum.find_value(kind_options, value, fn {label, v} -> v == value && label end)
  end

  attr :provider, :map, required: true
  attr :scim_base_url, :string, required: true
  attr :scim_token, :map, default: nil

  # Directory sync separates configuration state from authenticated request
  # history. The timestamp does not prove a completed sync or a live connection.
  # The bearer is write-only (shown once on enable/rotate).
  defp provisioning_section(assigns) do
    provider_id = assigns.provider.id

    revealed_token =
      case assigns.scim_token do
        %{provider_id: ^provider_id, token: token} -> token
        _ -> nil
      end

    assigns = assign(assigns, :revealed_token, revealed_token)

    ~H"""
    <.section_with_note id={"directory-sync-#{@provider.id}"}>
      <:header>
        <.section_header title="User provisioning & directory sync" />
      </:header>

      <div class="space-y-4">
        <div
          id={"scim-status-#{@provider.id}"}
          class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="flex min-w-0 flex-wrap items-start gap-x-8 gap-y-3">
            <dl id="connection-provisioning-summary" class="min-w-0">
              <dt class="text-sm font-medium text-zinc-100">New members</dt>
              <dd class="mt-0.5 text-xs leading-relaxed text-zinc-400">
                {provisioner_label(@provider.provisioner)}
              </dd>
            </dl>
            <div class="min-w-0">
              <p class="text-sm font-medium text-zinc-100">SCIM</p>
              <p
                id={"scim-enabled-status-#{@provider.id}"}
                class="mt-0.5 text-sm font-medium"
              >
                <span class={if(@provider.scim_enabled, do: "text-brand-300", else: "text-zinc-400")}>
                  {if @provider.scim_enabled, do: "Enabled", else: "Disabled"}
                </span>
                <span
                  :if={@provider.scim_enabled}
                  id={"scim-request-status-#{@provider.id}"}
                  class="font-normal text-zinc-400"
                >
                  <%= if @provider.scim_last_seen_at do %>
                    (last request
                    <.local_time
                      id={"scim-last-request-#{@provider.id}"}
                      value={@provider.scim_last_seen_at}
                      mode={:relative}
                      styled_tooltip
                    />)
                  <% else %>
                    (waiting for first request)
                  <% end %>
                </span>
              </p>
            </div>
          </div>

          <div
            id={"scim-actions-#{@provider.id}"}
            class="flex shrink-0 flex-wrap gap-2 sm:justify-end"
          >
            <.button
              :if={not @provider.scim_enabled}
              id={"enable-scim-#{@provider.id}"}
              variant={:secondary}
              size={:md}
              phx-hook="PendingButton"
              phx-click="enable_scim"
              phx-value-id={@provider.id}
              phx-disable-with="Enabling…"
            >
              Enable
            </.button>
            <.confirm_button
              :if={@provider.scim_enabled}
              id={"rotate-scim-#{@provider.id}"}
              title="Rotate the SCIM token?"
              confirm_label="Rotate token"
              pending_label="Rotating…"
              variant={:secondary}
              tone={:neutral}
              size={:md}
              on_confirm={JS.push("rotate_scim", value: %{id: @provider.id})}
            >
              <:body>
                The current token stops working immediately. Update it in your identity provider
                to resume directory sync.
              </:body>
              Rotate token
            </.confirm_button>
            <.confirm_button
              :if={@provider.scim_enabled}
              id={"disable-scim-#{@provider.id}"}
              title="Disable directory sync?"
              confirm_label="Disable sync"
              pending_label="Disabling…"
              variant={:secondary}
              tone={:rose}
              size={:md}
              on_confirm={JS.push("disable_scim", value: %{id: @provider.id})}
            >
              <:body>Your IdP can no longer provision or deprovision members through it.</:body>
              Disable
            </.confirm_button>
          </div>
        </div>

        <%!-- The one-time token reveal — only for the provider whose token was
             just minted. Dismissing it (or any reload) drops it for good. --%>
        <div :if={@provider.scim_enabled && @revealed_token} id={"scim-token-#{@provider.id}"}>
          <.event_block
            icon="identity.credential"
            tone={:amber}
            title="Copy your SCIM token"
          >
            <:body>
              This token is shown only once.
            </:body>

            <.code_panel
              id={"scim-token-#{@provider.id}-value"}
              label="SCIM bearer token"
              copy
              copy_label="Copy token"
              code={@revealed_token}
              class="mt-6"
            />

            <div class="mt-6">
              <.button phx-click="dismiss_scim_token" variant={:secondary}>Done</.button>
            </div>
          </.event_block>
        </div>

        <%!-- Setup stays available regardless of request age. Enable/rotate
             opens it for the newly revealed token; inactivity is not a reset. --%>
        <details
          :if={@provider.scim_enabled}
          id={"scim-setup-#{@provider.id}"}
          class="group"
          open={not is_nil(@revealed_token)}
        >
          <summary class="flex min-h-10 w-fit cursor-pointer list-none items-center gap-1.5 text-sm font-medium text-zinc-300 hover:text-zinc-100">
            <.icon
              name="action.disclose"
              class="h-4 w-4 -rotate-90 text-zinc-500 transition-transform group-open:rotate-0"
            /> Setup instructions
          </summary>
          <.steps class="mt-3 pl-5">
            <:step>
              Enable SCIM provisioning {scim_location_hint(@provider.kind)}.
            </:step>
            <:step>
              <p>Set the connector's SCIM endpoint to this base URL:</p>
              <div id={"scim-endpoint-#{@provider.id}"} class="mt-2 min-w-0 max-w-full">
                <.copyable_id
                  id={"scim-url-#{@provider.id}"}
                  value={@scim_base_url}
                  class="text-sm text-zinc-300"
                />
              </div>
              <p class="mt-3">
                Paste the <span class="text-zinc-300">bearer token</span>
                into its <span class="text-zinc-300">API token</span>
                field (rotate the token above if you didn't copy it). It's sent in the
                <.inline_code>Authorization</.inline_code>
                header.
              </p>
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
      <%!-- Provider capability does not imply that provisioning is enabled. --%>
      <:note>
        <%= if @provider.scim_enabled do %>
          Members and groups stay in sync with your identity provider. Remove someone there to
          remove their emisar access.
        <% else %>
          Enable directory sync to add and remove members from your identity provider.
        <% end %>
      </:note>
    </.section_with_note>
    """
  end

  attr :provider, :map, required: true
  attr :path, :any, required: true
  attr :groups, :list, required: true
  attr :metadata, :any, required: true
  attr :filter_params, :map, required: true
  attr :load_error?, :boolean, default: false
  attr :mapping_form, Phoenix.HTML.Form, default: nil
  attr :mapping_role_options, :list, required: true
  attr :role_mapping_errors, :map, default: %{}
  attr :group_picker, :map, required: true
  attr :adding_mapping, :boolean, default: false
  attr :show_mappings?, :boolean, required: true

  attr :access_editor, :map, default: nil
  attr :runners, :list, required: true
  attr :runner_error, :string, default: nil
  attr :pack_error, :string, default: nil
  attr :pack_advertisements, :map, required: true
  attr :pack_access_restricted?, :boolean, required: true
  attr :expanded_scopes, :any, required: true

  # Keep group roles and access together; show connection defaults while editing.
  # Mapping controls still require enabled SCIM and directory-sync permission.
  # role_label renders the data role value (rendering a label is fine; never
  # branch authz on it).
  defp group_access_section(assigns) do
    ~H"""
    <.section_with_note :if={@show_mappings?} id={"group-access-section-#{@provider.id}"} compact>
      <:header>
        <.section_header
          title="Groups & access"
          count={if @show_mappings? and not @load_error?, do: @metadata.count}
          count_tone={:neutral}
        >
          <:actions>
            <.button
              :if={@show_mappings? and not @adding_mapping}
              variant={:secondary}
              size={:sm}
              phx-click="add_mapping_form"
              icon="action.add"
            >
              Add mapping
            </.button>
          </:actions>
        </.section_header>
      </:header>
      <div :if={@groups != [] or @filter_params["group_access_search"] not in [nil, ""]} class="mb-4">
        <LiveTable.filter_form
          id="group-access-search"
          path={@path}
          filters={SSO.directory_group_filters()}
          params={@filter_params}
          prefix="group_access_"
          event="filter_groups"
        />
      </div>
      <ul :if={@groups != []} class="divide-y divide-zinc-800/70">
        <li
          :for={group <- @groups}
          id={"synced-group-#{group.id}"}
          class="py-4 first:pt-0 last:pb-0"
        >
          <div
            id={group.mapping && "role-mapping-#{group.mapping.id}"}
            class="flex flex-wrap items-center justify-between gap-2"
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
            <div
              id={"group-actions-#{group.id}"}
              class="flex min-w-0 flex-wrap items-center justify-end gap-3"
            >
              <span :if={group.retired?} class="text-xs text-zinc-400">No longer synced</span>
              <.link
                :if={not group.retired?}
                patch={LiveTable.filter_option_path(@path, Map.drop(@filter_params, ["synced_members_search"]), :directory_group_id, group.id, "synced_members_") <> "#synced-members-#{@provider.id}"}
                phx-click={
                  JS.focus(to: "#filter-synced_members_directory_group_id-choices > summary")
                }
                aria-label={"Show #{directory_group_name(group)} members"}
                class="text-xs tabular-nums text-zinc-400 hover:text-zinc-200"
              >
                {members_label(group.member_count)}
              </.link>
              <span :if={group.retired?} class="text-xs tabular-nums text-zinc-400">{members_label(
                group.member_count
              )}</span>
              <.tooltip
                :if={not group.retired? and is_nil(group.mapping) and @adding_mapping}
                id={"map-group-role-#{group.id}-hint"}
                text="Finish or cancel the open mapping first."
              >
                <.button
                  id={"map-group-role-#{group.id}"}
                  variant={:secondary}
                  size={:sm}
                  disabled
                >
                  Map role
                </.button>
              </.tooltip>
              <.dropdown
                :if={not is_nil(group.mapping) or (not group.retired? and not @adding_mapping)}
                id={"group-role-#{group.id}"}
                aria-label={"Role for #{directory_group_name(group)}"}
                class="inline-block text-left"
                summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                panel_class="z-10 mt-2 w-40 p-1 text-xs shadow-xl"
              >
                <:trigger>
                  {if group.mapping, do: role_label(group.mapping.role), else: "Map role"}
                  <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
                </:trigger>
                <.menu_item
                  :for={{label, role} <- @mapping_role_options}
                  :if={
                    not group.retired? and
                      (is_nil(group.mapping) or role != to_string(group.mapping.role))
                  }
                  phx-click={
                    JS.push("set_group_role")
                    |> JS.remove_attribute("open", to: "#group-role-#{group.id}")
                    |> JS.focus(to: "#group-role-#{group.id} > summary")
                  }
                  phx-value-group_id={group.id}
                  phx-value-role={role}
                  phx-disable-with="Saving…"
                >
                  {label}
                </.menu_item>
                <div
                  :if={group.mapping && not group.retired?}
                  role="separator"
                  class="my-1 border-t border-zinc-800/70"
                >
                </div>
                <.menu_item
                  :if={group.mapping}
                  id={"remove-role-mapping-#{group.mapping.id}"}
                  tone={:rose}
                  phx-click={
                    JS.remove_attribute("open", to: "#group-role-#{group.id}")
                    |> JS.focus(to: "#group-role-#{group.id} > summary")
                    |> open_confirm("delete-mapping-#{group.mapping.id}")
                  }
                >
                  Remove mapping
                </.menu_item>
              </.dropdown>
              <.tooltip
                :if={
                  not group.retired? and not is_nil(@access_editor) and
                    @access_editor.group_id != group.id
                }
                id={"edit-group-access-#{group.id}-hint"}
                text="Finish or cancel the open access edit first."
              >
                <.button variant={:secondary} size={:sm} disabled>Edit access</.button>
              </.tooltip>
              <.button
                :if={
                  not group.retired? and
                    (is_nil(@access_editor) or @access_editor.group_id == group.id)
                }
                id={"edit-group-access-#{group.id}-toggle"}
                variant={:secondary}
                size={:sm}
                phx-click="edit_group_access"
                phx-value-group_id={group.id}
                aria-expanded={if @access_editor, do: "true", else: "false"}
                aria-controls={"edit-group-access-#{group.id}"}
              >
                {if @access_editor, do: "Cancel edit", else: "Edit access"}
              </.button>
              <.reset_group_access_button
                :if={group.retired? and group.runner_access_mapping}
                group={group}
              />
            </div>
          </div>
          <div
            :if={is_nil(@access_editor) or @access_editor.group_id != group.id}
            class="mt-2 pl-6"
          >
            <.group_access_facts group={group} runners={@runners} expanded_scopes={@expanded_scopes} />
          </div>

          <div
            :if={@access_editor && @access_editor.group_id == group.id}
            class="mt-4 space-y-3"
          >
            <div :if={@access_editor.errors != []} id={"group-access-error-#{group.id}"} role="alert">
              <.error :for={message <- @access_editor.errors}>{message}</.error>
            </div>
            <.simple_form
              for={@access_editor.form}
              id={"edit-group-access-#{group.id}"}
              phx-change="validate_group_access"
              phx-submit="save_group_access"
              aria-label={"Edit access for #{directory_group_name(group)}"}
            >
              <input type="hidden" name="group_id" value={group.id} hidden />
              <input type="hidden" name="runner_access_mapping[_present]" value="true" hidden />
              <.runner_access_mapping_fields
                form={@access_editor.form}
                defaults={@access_editor.defaults}
                display={@access_editor.display}
                runners={@runners}
                runner_error={@runner_error}
                pack_error={@pack_error}
                pack_advertisements={@pack_advertisements}
                pack_access_restricted?={@pack_access_restricted?}
              />
              <:actions>
                <.button
                  size={:sm}
                  phx-hook="PendingButton"
                  id={"save-group-access-#{group.id}"}
                  phx-disable-with="Saving…"
                >
                  Save access
                </.button>
                <.button variant={:ghost} type="button" phx-click="cancel_group_access" size={:sm}>
                  Cancel
                </.button>
                <.reset_group_access_button :if={group.runner_access_mapping} group={group} />
              </:actions>
            </.simple_form>
          </div>

          <%!-- Keep the dialog outside the dropdown so closing the menu cannot hide it. --%>
          <.confirm_dialog
            :if={group.mapping}
            id={"delete-mapping-#{group.mapping.id}"}
            title="Remove this role mapping?"
            confirm_label="Remove mapping"
            pending_label="Removing…"
            tone={:rose}
            on_confirm={
              JS.push("delete_mapping", value: %{id: group.mapping.id})
              |> close_confirm("delete-mapping-#{group.mapping.id}")
            }
          >
            <:body>
              Members get the highest role from their remaining mapped groups, or the default role if none match. The directory group is kept.
            </:body>
          </.confirm_dialog>
          <div
            :if={Map.has_key?(@role_mapping_errors, group.id)}
            id={"group-role-error-#{group.id}"}
            role="alert"
            class="mt-2"
          >
            <.error :for={message <- @role_mapping_errors[group.id]}>{message}</.error>
          </div>
        </li>
      </ul>
      <div
        :if={
          @show_mappings? and
            (@groups != [] or LiveTable.stale_page?(0, @metadata, @filter_params, "group_access_"))
        }
        class="mt-4"
      >
        <LiveTable.paginator
          id={"group-access-#{@provider.id}"}
          path={@path}
          metadata={@metadata}
          filter_params={@filter_params}
          prefix="group_access_"
          page_count={length(@groups)}
        />
      </div>

      <%!-- Missing groups are distinct from a failed read or an empty cursor page. --%>
      <.empty_state
        :if={@show_mappings? and @load_error?}
        variant={:hint}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load groups"
        class="mt-4"
      >
        Refresh the page to try again.
      </.empty_state>
      <.empty_state
        :if={
          @show_mappings? and not @load_error? and @groups == [] and not @adding_mapping and
            not LiveTable.stale_page?(0, @metadata, @filter_params, "group_access_")
        }
        variant={:hint}
        title={
          if @filter_params["group_access_search"] in [nil, ""],
            do: "No synced groups yet",
            else: "No groups match your search"
        }
        class="mt-4"
      >
        <%= if @filter_params["group_access_search"] in [nil, ""] do %>
          Groups appear here when your identity provider sends them through directory sync.
        <% else %>
          Try another group name or ID.
        <% end %>
      </.empty_state>

      <%!-- Add a mapping — revealed by the "Add mapping" button (not always open);
           a divided region within the card (not a nested box). account_id/provider_id
           are server-side. The group must be an exact synced resource; there is
           deliberately no free-text identity fallback. --%>
      <div
        :if={@show_mappings? and @adding_mapping and @mapping_form}
        class={["mt-4 max-w-3xl", @groups != [] && "border-t border-zinc-800/70 pt-5"]}
      >
        <.simple_form
          for={@mapping_form}
          id={"create-mapping-#{@provider.id}"}
          phx-change="validate_mapping"
          phx-submit="create_mapping"
        >
          <input type="hidden" name="provider_id" value={@provider.id} hidden />
          <div class="grid grid-cols-1 items-start gap-4 sm:grid-cols-[minmax(0,2fr)_minmax(10rem,1fr)]">
            <.group_picker
              id={"role-group-picker-#{@provider.id}"}
              scope="role"
              field={@mapping_form[:directory_group_id]}
              picker={@group_picker}
            />
            <.input
              field={@mapping_form[:role]}
              id={"create-mapping-role-#{@provider.id}"}
              type="select"
              label="Role"
              options={@mapping_role_options}
              prompt="Select a role"
              size={:compact}
            />
          </div>
          <:actions>
            <.button
              id={"create-mapping-#{@provider.id}-submit"}
              size={:md}
              disabled={is_nil(@group_picker.chosen) or @mapping_form[:role].value in [nil, ""]}
              phx-hook="PendingButton"
              phx-disable-with="Adding..."
            >
              Add mapping
            </.button>
            <.button variant={:ghost} size={:md} type="button" phx-click="cancel_add_mapping">
              Cancel
            </.button>
          </:actions>
        </.simple_form>
      </div>
      <:note>
        <p>
          Members get the highest role from their mapped groups, or the default
          <.chip id="connection-default-role-note" class="mr-1">
            {role_label(@provider.default_role)}
          </.chip>
          {" "}role if none match. Directory sync never grants Owner.
        </p>
        <p id="connection-default-access-note" class="mt-3">
          By default, groups use this connection's runner and pack access. Edit access adds
          a grant for one group; Reset to defaults removes that grant. Other group grants still apply.
        </p>
      </:note>
    </.section_with_note>
    """
  end

  attr :group, :map, required: true
  attr :runners, :list, required: true
  attr :expanded_scopes, :any, required: true

  defp group_access_facts(assigns) do
    assigns = assign(assigns, :runners_by_id, Map.new(assigns.runners, &{&1.id, &1}))

    ~H"""
    <div class="flex min-w-0 items-start gap-3">
      <dl
        id={"group-access-facts-#{@group.id}"}
        class="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-baseline gap-x-2 gap-y-1"
      >
        <dt class="text-[10px] uppercase tracking-wider text-zinc-400">Runners:</dt>
        <dd class="min-w-0 text-xs text-zinc-400">
          <.chip_overflow
            id={"group-runners-#{@group.id}"}
            items={access_scope_tag_items(@group.access)}
            expanded?={MapSet.member?(@expanded_scopes, "runners:#{@group.id}")}
            toggle="toggle_scope_expand"
            toggle_value={"runners:#{@group.id}"}
            label="runner scopes"
          >
            <:lead :if={mapping_runner_reach_phrase(@group.access.mode)}>
              {mapping_runner_reach_phrase(@group.access.mode)}
            </:lead>
            <:item :let={scope}>
              <%= case scope do %>
                <% {:group, name} -> %>
                  <.identity_tag category="group" value={name} />
                <% {:runner, id} -> %>
                  <.identity_tag category="runner">
                    {case Map.get(@runners_by_id, id) do
                      nil -> "Runner unavailable"
                      runner -> runner.name
                    end}
                  </.identity_tag>
              <% end %>
            </:item>
          </.chip_overflow>
        </dd>
        <dt class="text-[10px] uppercase tracking-wider text-zinc-400">Packs:</dt>
        <dd class="min-w-0 text-xs text-zinc-400">
          <.chip_overflow
            id={"group-packs-#{@group.id}"}
            items={@group.access.pack_ids}
            expanded?={MapSet.member?(@expanded_scopes, "packs:#{@group.id}")}
            toggle="toggle_scope_expand"
            toggle_value={"packs:#{@group.id}"}
            label="packs"
          >
            <:lead :if={
              @group.access.mode == :none or
                (@group.access.pack_mode == :restricted and @group.access.pack_ids == [])
            }>
              None
            </:lead>
            <:lead :if={@group.access.mode != :none and @group.access.pack_mode == :all}>All</:lead>
            <:item :let={id}>
              <.chip mono>{id}</.chip>
            </:item>
          </.chip_overflow>
        </dd>
      </dl>
    </div>
    """
  end

  attr :group, :map, required: true

  defp reset_group_access_button(assigns) do
    ~H"""
    <.confirm_button
      id={"delete-runner-access-mapping-#{@group.runner_access_mapping.id}"}
      title={
        if @group.retired?, do: "Remove this access mapping?", else: "Reset group access to defaults?"
      }
      confirm_label={if @group.retired?, do: "Remove mapping", else: "Reset to defaults"}
      pending_label="Removing…"
      variant={:secondary}
      tone={:rose}
      size={:sm}
      on_confirm={
        JS.push("delete_runner_access_mapping", value: %{id: @group.runner_access_mapping.id})
      }
    >
      <:body>
        Removes this group's added runner and pack access. Connection defaults, other group
        grants, and the role mapping stay unchanged.
      </:body>
      {if @group.retired?, do: "Remove access mapping", else: "Reset to defaults"}
    </.confirm_button>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :defaults, :map, required: true
  attr :display, :map, required: true
  attr :runners, :list, required: true
  attr :runner_error, :string, default: nil
  attr :pack_error, :string, default: nil
  attr :pack_advertisements, :map, required: true
  attr :pack_access_restricted?, :boolean, required: true

  defp runner_access_mapping_fields(assigns) do
    runner_mode = assigns.display["runner_access_mode"]

    runner_ids =
      RunnerScope.selected_runner_ids(assigns.runners, runner_mode, assigns.display["scope"])

    assigns =
      assigns
      |> assign(:runner_mode, runner_mode)
      |> assign(:default_pack_mode, GroupAccessForm.pack_mode(assigns.defaults))
      |> assign(:locked_runners, GroupAccessForm.runner_values(assigns.defaults))
      |> assign(:locked_packs, GroupAccessForm.pack_values(assigns.defaults))
      |> assign(
        :packs,
        RunnerScope.packs_in_scope(
          assigns.pack_advertisements,
          runner_ids,
          assigns.display["pack_scope"]
        )
      )

    ~H"""
    <div class="space-y-4">
      <p class="text-xs leading-relaxed text-zinc-400">
        Locked selections are included by connection defaults. You can add access, but not remove those defaults.
      </p>
      <div class="grid grid-cols-1 items-start gap-4 sm:grid-cols-2">
        <div>
          <.label variant={:eyebrow}>Runners</.label>
          <div class="mt-2">
            <.choice_cards
              name={@form[:runner_access_mode].name}
              value={@display["runner_access_mode"]}
              attached_value="restricted"
            >
              <:card
                value="none"
                title="No runners"
                disabled={@defaults.mode != :none}
                disabled_reason={
                  if @defaults.mode != :none, do: "Connection defaults already grant runner access."
                }
              >
                No runner action permissions through this group.
              </:card>
              <:card
                value="all"
                title="All runners"
                disabled={@defaults.mode == :all}
                disabled_reason={
                  if @defaults.mode == :all, do: "All runners are included by connection defaults."
                }
              >
                Includes every current and future runner in this workspace.
              </:card>
              <:card
                value="restricted"
                title="Selected runners"
                disabled={@defaults.mode == :all}
                disabled_reason={
                  if @defaults.mode == :all, do: "Connection defaults include all runners."
                }
              >
                Limit access to named runner groups or individual runners.
              </:card>
            </.choice_cards>

            <.runner_scope_select
              :if={@display["runner_access_mode"] == "restricted"}
              name={"#{@form.name}[scope][]"}
              variant={:attached}
              runners={@runners}
              selected={@display["scope"]}
              locked={@locked_runners}
              load_error={@runner_error}
              submit_error_field={@form[:runner_access_mode]}
              submit_error_message="Choose all runners or at least one selected runner scope."
            />
          </div>
        </div>

        <div>
          <.label variant={:eyebrow}>Packs</.label>
          <p :if={@pack_access_restricted?} class="mt-1 text-xs text-zinc-400">
            You can grant only packs within your own access.
          </p>
          <p
            :if={@runner_mode == "none" and @display["pack_access_mode"] != "none"}
            class="mt-1 text-xs text-zinc-400"
          >
            This pack access can combine with runner access from other groups.
          </p>
          <div class="mt-2">
            <.choice_cards
              name={@form[:pack_access_mode].name}
              value={@display["pack_access_mode"]}
              attached_value="restricted"
            >
              <:card
                value="none"
                title="No packs"
                disabled={@default_pack_mode != "none"}
                disabled_reason={
                  if @default_pack_mode != "none",
                    do: "Connection defaults already grant pack access."
                }
              >
                No actions from packs through this group.
              </:card>
              <:card
                value="all"
                title="All packs"
                disabled={@default_pack_mode == "all" or @runner_mode == "none"}
                disabled_reason={
                  cond do
                    @default_pack_mode == "all" -> "All packs are included by connection defaults."
                    @runner_mode == "none" -> "Choose runners before granting pack access."
                    true -> nil
                  end
                }
              >
                Every pack on those runners, including ones installed later.
              </:card>
              <:card
                value="restricted"
                title="Selected packs"
                disabled={@default_pack_mode == "all" or @runner_mode == "none"}
                disabled_reason={
                  cond do
                    @default_pack_mode == "all" -> "Connection defaults include all packs."
                    @runner_mode == "none" -> "Choose runners before granting pack access."
                    true -> nil
                  end
                }
              >
                Only actions from the packs you name.
              </:card>
            </.choice_cards>
            <RunnerScope.pack_scope_select
              :if={@display["pack_access_mode"] == "restricted"}
              name={"#{@form.name}[pack_scope][]"}
              variant={:attached}
              packs={@packs}
              selected={@display["pack_scope"]}
              locked={@locked_packs}
              load_error={@pack_error}
              submit_error_field={@form[:pack_access_mode]}
              submit_error_message="Choose a pack, or choose No packs."
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :scope, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :picker, :map, required: true

  # A directory pushes as many groups as it likes, so this picker asks the
  # SERVER: the operator types, the server answers with a bounded set of
  # matches, and the group they pick rides the form as its id. The shared
  # dropdown owns the overlay; the finite-catalog searchable_select would hide
  # groups beyond the server's bounded first result set.
  defp group_picker(assigns) do
    errors =
      if assigns.field.form.source.action in [:insert, :update] or
           Phoenix.Component.used_input?(assigns.field),
         do: Enum.map(assigns.field.errors, &translate_error/1),
         else: []

    assigns = assign(assigns, :errors, errors)

    ~H"""
    <div class="min-w-0">
      <.label id={"#{@id}-label"}>Directory group</.label>
      <input type="hidden" name={@field.name} value={@picker.chosen && @picker.chosen.id} />

      <.dropdown
        id={@id}
        aria-labelledby={"#{@id}-label"}
        phx-mounted={JS.ignore_attributes("open")}
        align={:left}
        class="mt-1 w-full"
        summary_class="flex items-center justify-between gap-2 rounded-lg bg-zinc-900 px-2 py-1.5 text-sm leading-5 text-zinc-100 ring-1 ring-inset ring-zinc-800"
        panel_class="z-30 mt-1 w-full p-2"
      >
        <:trigger>
          <span class="sr-only">Directory group:</span>
          <span :if={@picker.chosen} class="min-w-0 flex-1 truncate">
            {directory_group_name(@picker.chosen)}
          </span>
          <span :if={is_nil(@picker.chosen)} class="min-w-0 flex-1 truncate text-zinc-500">
            Select a directory group
          </span>
          <.icon name="action.disclose" class="h-4 w-4 shrink-0 text-zinc-500" />
        </:trigger>
        <.input
          id={"#{@id}-search"}
          type="text"
          size={:compact}
          name="group_search"
          value={@picker.term}
          placeholder="Search by name or ID"
          aria-label="Search directory groups"
          autocomplete="off"
          phx-debounce="300"
          data-dropdown-search
        />

        <p class="mt-2 hidden text-xs text-zinc-400 phx-change-loading:block">Searching…</p>

        <div class="scrollbar-control mt-2 max-h-64 overflow-y-auto">
          <ul :if={@picker.results != []}>
            <li :for={group <- @picker.results}>
              <button
                type="button"
                phx-click={
                  JS.push("select_group", value: %{scope: @scope, group_id: group.id})
                  |> JS.remove_attribute("open", to: "##{@id}")
                  |> JS.focus(to: "##{@id} > summary")
                }
                class="block w-full rounded-md px-2 py-2 text-left transition-colors hover:bg-white/[0.06] focus-visible:bg-white/[0.06]"
              >
                <span class="block truncate text-sm text-zinc-200">
                  {directory_group_name(group)}
                </span>
                <span class="block truncate font-mono text-[11px] text-zinc-400">
                  {directory_group_reference(group)}
                </span>
              </button>
            </li>
          </ul>

          <%!-- A failed read is distinct from an empty search result. --%>
          <.empty_state
            :if={@picker.load_error?}
            variant={:bare}
            tone={:danger}
            icon="state.warning"
            class="px-2 py-4"
          >
            Couldn't search synced groups. Refresh the page to try again.
          </.empty_state>
          <.empty_state
            :if={not @picker.load_error? and @picker.results == [] and @picker.term == ""}
            variant={:bare}
            class="px-2 py-4"
          >
            No groups synced yet. Map one once your IdP pushes it over SCIM.
          </.empty_state>
          <.empty_state
            :if={not @picker.load_error? and @picker.results == [] and @picker.term != ""}
            variant={:bare}
            class="px-2 py-4"
          >
            No group matches that name or ID.
          </.empty_state>
        </div>
      </.dropdown>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp directory_group_name(%{display: display}) when is_binary(display) and display != "",
    do: display

  defp directory_group_name(%{external_group_display: display})
       when is_binary(display) and display != "",
       do: display

  defp directory_group_name(_group), do: "Unnamed group"

  defp directory_group_reference(%{external_group_id: external_group_id})
       when is_binary(external_group_id) and external_group_id != "",
       do: external_group_id

  defp directory_group_reference(%{id: id}) when is_binary(id),
    do: "emisar group #{id}"

  defp directory_group_reference(%{directory_group_id: id}) when is_binary(id),
    do: "emisar group #{id}"

  attr :id, :string, required: true
  attr :path, :any, required: true
  attr :members, :list, required: true
  attr :metadata, :any, required: true
  attr :filter_params, :map, required: true
  attr :load_error?, :boolean, required: true
  attr :member_role_options, :list, required: true
  attr :can_configure_directory_sync?, :boolean, required: true
  attr :current_user_id, :string, required: true
  attr :scim_enabled, :boolean, required: true
  attr :account, :any, required: true

  # The members provisioned through this connection (SCIM sync / SSO first-login /
  # approved link), with portal-based lifecycle actions per row — re-role or
  # suspend/reactivate. The controls act on the Accounts membership (manage_team,
  # which enforces owner / last-owner / self); someone removed from the account
  # whose identity lingers shows "Removed" with no actions. A failed read keeps
  # its count off the header — "0" would assert a roster size we don't know.
  attr :group_summaries, :map, required: true
  attr :member_group_list, :any, default: nil
  attr :groups_error?, :boolean, default: false
  attr :group_picker, :any, default: nil

  defp synced_members_section(assigns) do
    ~H"""
    <.section_with_note id={@id}>
      <:header>
        <%!-- The count is the directory's whole roster, from the page metadata —
             `length(@members)` would report one page as the roster size. --%>
        <.section_header
          title="Members"
          level={3}
          count={if @load_error?, do: nil, else: @metadata.count}
          count_tone={:neutral}
        />
      </:header>
      <div class="mb-4">
        <LiveTable.filter_form
          id="directory-members-search"
          path={@path}
          filters={DirectoryGroups.filters(SSO.directory_member_filters(), @group_picker)}
          option_pickers={%{directory_group_id: @group_picker}}
          params={@filter_params}
          prefix="synced_members_"
          event="filter_directory_members"
        />
      </div>
      <ul :if={@members != []} class="divide-y divide-zinc-800/70">
        <li
          :for={member <- @members}
          class="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="truncate text-sm text-zinc-200">
                {Accounts.member_display_name(member.membership, member.identity.user)}
              </span>
              <.chip :if={member.membership && member.membership.user_id == @current_user_id}>
                You
              </.chip>
              <.chip :if={is_nil(member.membership)} tone={:rose}>Removed</.chip>
              <.chip
                :if={member.membership && Accounts.membership_disabled?(member.membership)}
                tone={:amber}
              >
                Suspended
              </.chip>
              <.chip :if={not member.identity.scim_active}>Deactivated in IdP</.chip>
              <.tooltip
                id={"member-origin-#{member.identity.id}"}
                text={provisioned_via_tooltip(member.identity.provisioned_via)}
              >
                <.chip>{provisioned_via_label(member.identity.provisioned_via)}</.chip>
              </.tooltip>
            </div>
            <%!-- Keep the email and last-seen time readable at narrow widths. --%>
            <div class="mt-0.5 text-xs text-zinc-400">
              <span :if={email = Accounts.secondary_user_email(member.identity.user)}>{email}</span>
              <span :if={member.identity.last_seen_at}>
                · last seen
                <.local_time
                  id={"scim-member-synced-#{member.identity.id}"}
                  value={member.identity.last_seen_at}
                  mode={:relative}
                />
              </span>
            </div>
            <DirectoryGroups.member_groups
              id={"synced-member-groups-#{member.identity.id}"}
              user_id={member.identity.user_id}
              summary={Map.get(@group_summaries, member.identity.user_id)}
              list={@member_group_list}
              error?={@groups_error?}
              path={@path}
              filter_params={@filter_params}
              prefix="synced_members_"
              active_group={@group_picker && @group_picker.group}
            />
          </div>

          <div :if={member.membership} class="flex shrink-0 items-center gap-2">
            <%= if member.membership.user_id == @current_user_id do %>
              <.tooltip
                id={"self-role-lock-#{member.membership.id}"}
                text="You can't change your own role."
              >
                <.chip icon="role.restricted">
                  {Emisar.Auth.role_label(member.membership.role)}
                </.chip>
              </.tooltip>
              <.tooltip
                id={"self-suspend-lock-#{member.membership.id}"}
                text="You can't suspend your own access."
              >
                <.button variant={:secondary} size={:sm} disabled>
                  Suspend access
                </.button>
              </.tooltip>
            <% else %>
              <%!-- On a directory-synced provider the role is the IdP's: a group→role
                 mapping (or the provider default) recomputes it on every sync, so a
                 manual change here silently reverts — read-only. An OIDC-only provider
                 (no directory sync) keeps the editable select; those roles aren't
                 recomputed. The remedy must remain available after a plan downgrade,
                 when group role mappings are no longer editable. --%>
              <.tooltip
                :if={member.membership.directory_managed}
                id={"role-lock-#{member.membership.id}"}
                text={role_lock_tip(@can_configure_directory_sync?)}
              >
                <.chip icon="role.restricted">
                  {Emisar.Auth.role_label(member.membership.role)}
                </.chip>
              </.tooltip>
              <%!-- A role change is a privilege grant, so it goes through the same
                   styled confirm as the Team roster: a dropdown whose items OPEN a
                   per-role confirm modal, never a bare select that promotes on a
                   single change. The handler still authorizes and the DOMAIN owns
                   the owner / last-owner / self guards (IL-15). --%>
              <.chip :if={not member.manageable? and not member.membership.directory_managed}>
                {Emisar.Auth.role_label(member.membership.role)}
              </.chip>
              <div
                :if={member.manageable? and not member.membership.directory_managed}
                class="flex items-center"
              >
                <.dropdown
                  class="inline-block text-left"
                  summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                  panel_class="z-10 mt-2 w-40 p-1 text-xs shadow-xl"
                >
                  <:trigger>
                    {Emisar.Auth.role_label(member.membership.role)}
                    <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
                  </:trigger>
                  <.menu_item
                    :for={{label, role} <- @member_role_options}
                    :if={
                      member.membership.role != :owner and role != to_string(member.membership.role)
                    }
                    phx-click={open_confirm("synced-role-#{member.membership.id}-#{role}")}
                  >
                    {label}
                  </.menu_item>
                  <.menu_item
                    :for={{label, role} <- @member_role_options}
                    :if={
                      member.membership.role == :owner and
                        not member.membership.runner_access_directory_managed and role != "owner"
                    }
                    navigate={
                      ~p"/app/#{@account}/settings/team/#{member.membership.id}/change-role/#{role}"
                    }
                  >
                    {label}
                  </.menu_item>
                  <.menu_item
                    :if={
                      member.membership.role == :owner and
                        member.membership.runner_access_directory_managed
                    }
                    navigate={
                      ~p"/app/#{@account}/settings/team/#{member.membership.id}/change-role/directory"
                    }
                  >
                    Use directory role
                  </.menu_item>
                </.dropdown>
                <.confirm_dialog
                  :for={{label, role} <- @member_role_options}
                  :if={member.membership.role != :owner and role != to_string(member.membership.role)}
                  id={"synced-role-#{member.membership.id}-#{role}"}
                  tone={:amber}
                  title={
                    RoleCopy.change_title(
                      Accounts.member_display_name(member.membership, member.identity.user),
                      role
                    )
                  }
                  confirm_label={"Change to #{label}"}
                  on_confirm={
                    JS.push("change_member_role",
                      value: %{membership_id: member.membership.id, role: role}
                    )
                    |> close_confirm("synced-role-#{member.membership.id}-#{role}")
                  }
                >
                  <:body>
                    <p>{RoleCopy.change_body(role)}</p>
                    <p :if={RoleCopy.access_hint(role)} class="mt-3">
                      {RoleCopy.access_hint(role)}
                    </p>
                  </:body>
                </.confirm_dialog>
              </div>
              <%!-- Suspend is reversible (Reactivate undoes it), so it stays
                   NEUTRAL — rose is reserved for the irreversible Delete. The face
                   is bordered, like every visible action verb (§7.47); Reactivate
                   below is its twin and wears the same one. --%>
              <.confirm_button
                :if={member.manageable? and not Accounts.membership_disabled?(member.membership)}
                id={"suspend-scim-#{member.membership.id}"}
                title="Suspend this member?"
                confirm_label="Suspend access"
                pending_label="Suspending…"
                variant={:secondary}
                tone={:neutral}
                size={:sm}
                on_confirm={JS.push("suspend_member", value: %{membership_id: member.membership.id})}
              >
                <:body>
                  {RoleCopy.suspend_body()}
                </:body>
                Suspend access
              </.confirm_button>
              <.button
                :if={
                  member.manageable? and Accounts.membership_disabled?(member.membership) and
                    not member.membership.directory_suspended
                }
                id={"reactivate-scim-#{member.membership.id}"}
                variant={:secondary}
                tone={:neutral}
                size={:sm}
                class="min-w-28"
                phx-hook="PendingButton"
                phx-click="reinstate_member"
                phx-value-membership_id={member.membership.id}
                phx-disable-with="Restoring…"
              >
                Restore access
              </.button>
              <%!-- Keep the expected action in place, but disabled: the IdP owns
                   this state and its next active:true sync performs the change. --%>
              <.tooltip
                :if={
                  member.manageable? and Accounts.membership_disabled?(member.membership) and
                    member.membership.directory_suspended
                }
                id={"reactivate-in-idp-#{member.membership.id}"}
                text="This member was deactivated in your identity provider. Reactivate them there."
              >
                <.button variant={:secondary} tone={:neutral} size={:sm} disabled>
                  Restore access
                </.button>
              </.tooltip>
            <% end %>
          </div>
        </li>
      </ul>

      <div
        :if={@members != [] or LiveTable.stale_page?(0, @metadata, @filter_params, "synced_members_")}
        class="mt-4"
      >
        <LiveTable.paginator
          id={@id}
          path={@path}
          metadata={@metadata}
          filter_params={@filter_params}
          prefix="synced_members_"
          page_count={length(@members)}
        />
      </div>

      <.empty_state
        :if={@load_error?}
        variant={:hint}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load members"
        class="mt-4"
      >
        Refresh the page to try again.
      </.empty_state>
      <%!-- Never say "nobody yet" for a cursor that simply ran past the end —
           the pager owns that state and offers the way back. --%>
      <.empty_state
        :if={
          @members == [] and not @load_error? and
            not LiveTable.stale_page?(0, @metadata, @filter_params, "synced_members_")
        }
        variant={:hint}
        title={
          if @filter_params["synced_members_search"] in [nil, ""] and
               @filter_params["synced_members_directory_group_id"] in [nil, ""],
             do: "No members yet",
             else: "No members match these filters"
        }
        class="mt-4"
      >
        <%= if @filter_params["synced_members_search"] not in [nil, ""] or @filter_params["synced_members_directory_group_id"] not in [nil, ""] do %>
          Try another name or group, or clear the filters.
        <% else %>
          <%= if @scim_enabled do %>
            Members appear here after signing in through this connection or being added by directory sync.
          <% else %>
            Members appear here after signing in through this connection.
          <% end %>
        <% end %>
      </.empty_state>
      <:note>
        Members linked to this connection. Suspend access here for a temporary hold.
        <%= if @scim_enabled do %>
          To remove a member, deactivate them in your identity provider.
        <% else %>
          To remove a member, use the Team page.
        <% end %>
      </:note>
    </.section_with_note>
    """
  end

  # Group role mappings are editable only while directory-sync config is available.
  defp role_lock_tip(true), do: "Role is managed by directory sync — set it in Groups & access"

  defp role_lock_tip(false),
    do: "Role is managed by directory sync — change this member's groups in your IdP"

  defp role_label(role), do: Emisar.Auth.role_label(role)

  defp members_label(1), do: "1 member"
  defp members_label(count), do: "#{count} members"

  defp mapping_runner_reach_phrase(:none), do: "None"
  defp mapping_runner_reach_phrase(:all), do: "All"
  defp mapping_runner_reach_phrase(:restricted), do: nil

  # Groups lead — a group is the wider grant, so the visible tags start there.
  defp access_scope_tag_items(access) do
    Enum.map(access.groups, &{:group, &1}) ++
      Enum.map(access.runner_ids, &{:runner, &1})
  end

  defp provisioner_label(:jit), do: "Add on first sign-in"
  defp provisioner_label(:manual), do: "Require approval"

  defp sign_in_verification_tone(%{status: :verified}), do: :brand
  defp sign_in_verification_tone(_verification), do: :amber

  defp sign_in_verification_label(%{status: :verified}), do: "Sign-in verified"
  defp sign_in_verification_label(%{status: :stale}), do: "Verification needed"
  defp sign_in_verification_label(_verification), do: "Sign-in not verified"

  defp sign_in_verification_copy(%{status: :verified}, _provider),
    do: "A real provider sign-in passed "

  defp sign_in_verification_copy(%{status: :stale}, _provider),
    do: "Connection settings changed. Verify sign-in again."

  defp sign_in_verification_copy(_verification, _provider) do
    "Verify sign-in before enabling this connection."
  end
end
