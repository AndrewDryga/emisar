defmodule EmisarWeb.TeamLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Audit, Catalog, Runners, SSO}
  alias EmisarWeb.{ConfirmDialog, LiveForm, LiveTable, Permissions, RunnerScope}
  alias Phoenix.LiveView.JS

  # String forms of the canonical role enum — the invite/role forms work
  # in strings (HTTP params); membership.role itself is an atom.
  @roles Enum.map(Emisar.Auth.roles(), &Atom.to_string/1)
  @runner_scope_required "Choose at least one runner group or runner for selected access."
  @pack_scope_required "Choose at least one pack for selected pack access."

  # No mount gate, deliberately: every member may see who else is in the
  # workspace, so the roster read (`list_team_member_facts/3`) asks only for
  # `view_own_account`. Managing the team is gated where it acts — the render's
  # `@can_manage_team?` branches and `Permissions.gated/3` on every handler — which
  # is what leaves a billing manager a read-only Team page instead of a nav link
  # that flashes and bounces. Same shape as the Billing page.
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Accounts.subscribe_account_team(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:page_title, "Team")
     |> assign(
       :can_manage_team?,
       Accounts.subject_can_manage_team?(socket.assigns.current_subject)
     )
     |> assign(
       :pack_access_restricted?,
       socket.assigns.current_membership.pack_access_mode == :restricted
     )
     |> assign(:roles, @roles)
     |> assign(:editing_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:scope_editing_id, nil)
     |> assign(:scope_access_mode, "none")
     |> assign(:scope_draft, [])
     |> assign(:scope_error, nil)
     |> assign(:scope_pack_mode, "all")
     |> assign(:scope_pack_draft, [])
     |> assign(:scope_pack_error, nil)
     |> assign(:runners, [])
     |> assign(:runners_by_id, %{})
     |> assign(:runner_load_error?, false)
     |> assign(:current_role, socket.assigns.current_subject.role)
     |> assign(:filters, Accounts.team_member_filters())
     |> assign(:pack_advertisements, %{})
     |> assign(:pack_load_error?, false)
     |> assign(:approval_access_modes, %{})
     |> assign(:approval_scope_drafts, %{})
     |> assign(:approval_scope_errors, %{})
     |> assign(:approval_pack_modes, %{})
     |> assign(:approval_pack_drafts, %{})
     |> assign(:approval_pack_errors, %{})
     |> assign(:mfa_reset_target, nil)
     |> assign(:mfa_reset_mode, :totp)
     |> assign(:mfa_reset_error, nil)
     |> assign(:mfa_reset_recovery_form, to_form(%{"code" => ""}, as: :recovery))
     |> assign(:mfa_reset_sso_facts, nil)
     # The branded sign-in link is a per-account constant to hand to members.
     |> assign(
       :sign_in_url,
       Emisar.PublicUrl.base() <> ~p"/app/#{socket.assigns.current_account}/sign_in"
     )
     |> ConfirmDialog.init()
     |> assign_invite_form()}
  end

  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      # The invite page needs no member load — it renders from the subject alone,
      # so it skips the connected?/loading dance and shows the form immediately.
      :new ->
        socket = socket |> assign(:page_title, "Invite a member") |> reset_invite_form()

        if connected?(socket) do
          {:noreply, load_invite_runners(socket)}
        else
          {:noreply, assign(socket, :loading?, true)}
        end

      :reset_mfa ->
        if connected?(socket) do
          {:noreply, load_mfa_reset(socket, params)}
        else
          {:noreply,
           socket
           |> assign(:page_title, "Reset member 2FA")
           |> assign(:loading?, true)}
        end

      # Gate load/2's reads behind connected? — they run once on the live mount,
      # not also on the dead render (IL-18). The dead render shows <.loading_state>.
      :index ->
        if connected?(socket) do
          {:noreply, socket |> assign(:loading?, false) |> load(params)}
        else
          {:noreply, assign(socket, :loading?, true)}
        end
    end
  end

  def handle_info({:list_changed, :team, _event_type, _id}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(
        {:sso_link_requests_changed, account_id},
        %{assigns: %{current_account: %{id: account_id}, live_action: :index}} = socket
      ),
      do: {:noreply, assign_sso_state(socket)}

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/settings/team",
       params,
       socket.assigns.filters
     )}
  end

  def handle_event("start_edit", %{"membership_id" => id}, socket) do
    case find_member_membership(socket, id) do
      nil ->
        {:noreply, socket}

      %Accounts.Membership{user: user} when not is_nil(user) ->
        params = %{"full_name" => user.full_name || ""}

        # One inline editor at a time — the naked editors would otherwise
        # stack into one unreadable run under the same row.
        {:noreply,
         socket
         |> assign(:editing_id, id)
         |> assign(:edit_form, to_form(params, as: "user"))
         |> assign(:scope_editing_id, nil)
         |> assign(:scope_access_mode, "none")
         |> assign(:scope_draft, [])
         |> assign(:scope_error, nil)
         |> assign(:scope_pack_mode, "all")
         |> assign(:scope_pack_draft, [])
         |> assign(:scope_pack_error, nil)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}
  end

  # Re-reads the member rather than trusting the roster this page rendered: a
  # directory that claimed their runner access since mount has to CLOSE the
  # editor, and the socket's copy would still open it.
  def handle_event("start_scope_edit", %{"membership_id" => id}, socket) do
    case Accounts.fetch_team_member_facts(id, socket.assigns.current_subject) do
      {:ok, %{runner_access_editable?: false}} ->
        {:noreply, put_flash(socket, :error, error_message(:runner_access_managed_by_directory))}

      # Re-read: a role changed to one that reaches no runners since mount has to
      # close the editor here too — the hidden menu item is never the check.
      {:ok, %{membership: membership, runner_access: access}} ->
        if Emisar.Auth.role_carries_runner_access?(membership.role),
          do: {:noreply, open_scope_edit(socket, id, access)},
          else:
            {:noreply, put_flash(socket, :error, error_message(:role_carries_no_runner_access))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_scope_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:scope_editing_id, nil)
     |> assign(:scope_access_mode, "none")
     |> assign(:scope_draft, [])
     |> assign(:scope_error, nil)
     |> assign(:scope_pack_mode, "all")
     |> assign(:scope_pack_draft, [])
     |> assign(:scope_pack_error, nil)}
  end

  # Live-normalize the scope selection so the picker can disable a runner the
  # moment its group is selected (the group already covers it) — parse drops the
  # now-redundant runners and re-seeds the draft the select renders from.
  def handle_event("scope_changed", params, socket) do
    mode = Map.get(params, "runner_access_mode", socket.assigns.scope_access_mode)
    scope = List.wrap(params["scope"])

    # The pack list has no coverage rule to normalize — what is checked IS the
    # draft, including a pack the account no longer carries, which the picker
    # keeps ticked so the operator can see and remove it.
    pack_mode = Map.get(params, "pack_access_mode", "all")
    pack_scope = List.wrap(params["pack_scope"])

    # Same terms as the runner half: clearing a selection you had is a mistake
    # worth naming, but merely REVEALING an empty one is not — a form does not
    # accuse you of a blank you have not reached yet.
    pack_error =
      if pack_mode == "restricted" and pack_scope == [] and
           socket.assigns.scope_pack_draft != [],
         do: @pack_scope_required

    socket =
      socket
      |> assign(:scope_pack_mode, pack_mode)
      |> assign(:scope_pack_draft, pack_scope)
      |> assign(:scope_pack_error, pack_error)

    case Accounts.build_runner_access(mode, scope, socket.assigns.runners) do
      {:ok, %Accounts.RunnerAccess{} = access} ->
        {:noreply,
         socket
         |> assign(:scope_access_mode, to_string(access.mode))
         |> assign(:scope_draft, RunnerScope.to_values(access.groups, access.runner_ids))
         |> assign(:scope_error, nil)}

      {:error, :invalid_runner_access} ->
        error =
          if scope == [] and socket.assigns.scope_draft != [],
            do: @runner_scope_required

        draft = if scope == [], do: [], else: socket.assigns.scope_draft

        {:noreply,
         socket
         |> assign(:scope_access_mode, mode)
         |> assign(:scope_draft, draft)
         |> assign(:scope_error, error)}
    end
  end

  def handle_event("toggle_require_mfa", _params, socket) do
    enforcement = socket.assigns.security_facts.mfa_enforcement
    value = enforcement != :enforced

    cond do
      not Accounts.subject_can_manage_account_security?(socket.assigns.current_subject) ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      # Prevent owners from locking themselves out — if they don't have
      # MFA enabled, they can't enforce it (since the enforcement gate
      # would funnel them too). The domain refuses it under the write lock
      # regardless (`:mfa_enrollment_required`); this only saves the round trip.
      value and enforcement == :actor_not_enrolled ->
        {:noreply, put_flash(socket, :error, error_message(:mfa_enrollment_required))}

      true ->
        case Accounts.update_account(
               socket.assigns.current_account,
               %{settings: %{require_mfa: value}},
               socket.assigns.current_subject
             ) do
          {:ok, account} ->
            {:noreply,
             socket
             |> assign(:current_account, account)
             |> assign_security_facts()
             |> put_flash(
               :info,
               if value do
                 "Account-wide MFA enforced. Members without MFA will be prompted on next sign-in."
               else
                 "Account-wide MFA requirement turned off."
               end
             )}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, "Only owners and admins can change this setting.")}

          {:error, :mfa_enrollment_required} ->
            {:noreply, put_flash(socket, :error, error_message(:mfa_enrollment_required))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update 2FA setting.")}
        end
    end
  end

  def handle_event("toggle_require_sso", _params, socket) do
    account = socket.assigns.current_account
    value = not socket.assigns.security_facts.sso_required?

    if Accounts.subject_can_manage_account_security?(socket.assigns.current_subject) do
      case Accounts.update_account(
             account,
             %{settings: %{require_sso: value}},
             socket.assigns.current_subject
           ) do
        {:ok, account} ->
          {:noreply,
           socket
           |> assign(:current_account, account)
           |> assign_security_facts()
           |> assign_sso_state()
           |> put_flash(
             :info,
             if value do
               "Single sign-on now required. Members sign in through your identity provider."
             else
               "Single sign-on requirement turned off."
             end
           )}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

        {:error, :require_sso_without_provider} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Add an enabled SSO connection before requiring single sign-on — otherwise nobody, owners included, could sign in."
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not update SSO setting.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}
    end
  end

  def handle_event("toggle_monthly_report", _params, socket) do
    account = socket.assigns.current_account
    opt_out = not account.settings.monthly_report_opt_out

    # Not destructive, so a plain toggle — the domain re-authorizes (IL-15);
    # a non-manager who forges the event lands on the :unauthorized flash.
    case Accounts.update_account(
           account,
           %{settings: %{monthly_report_opt_out: opt_out}},
           socket.assigns.current_subject
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:current_account, account)
         |> put_flash(
           :info,
           if opt_out do
             "Monthly report turned off. Turn it back on here anytime."
           else
             "Monthly report turned back on — you'll get the next one."
           end
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update the monthly report setting.")}
    end
  end

  def handle_event("approval_access_changed", %{"_request_id" => id} = params, socket) do
    mode = params["runner_access_mode"]
    scope = List.wrap(params["scope"])
    pack_mode = Map.get(params, "pack_access_mode", "all")
    pack_scope = List.wrap(params["pack_scope"])
    previous_pack_draft = Map.get(socket.assigns.approval_pack_drafts, id, [])

    pack_errors =
      if pack_mode == "restricted" and pack_scope == [] and previous_pack_draft != [] do
        Map.put(socket.assigns.approval_pack_errors, id, @pack_scope_required)
      else
        Map.delete(socket.assigns.approval_pack_errors, id)
      end

    socket =
      socket
      |> assign(
        :approval_pack_modes,
        Map.put(socket.assigns.approval_pack_modes, id, pack_mode)
      )
      |> assign(
        :approval_pack_drafts,
        Map.put(socket.assigns.approval_pack_drafts, id, pack_scope)
      )
      |> assign(:approval_pack_errors, pack_errors)

    case Accounts.build_runner_access(mode, scope, socket.assigns.runners) do
      {:ok, access} ->
        {:noreply,
         socket
         |> assign(
           :approval_access_modes,
           Map.put(socket.assigns.approval_access_modes, id, to_string(access.mode))
         )
         |> assign(
           :approval_scope_drafts,
           Map.put(
             socket.assigns.approval_scope_drafts,
             id,
             RunnerScope.to_values(access.groups, access.runner_ids)
           )
         )
         |> assign(
           :approval_scope_errors,
           Map.delete(socket.assigns.approval_scope_errors, id)
         )}

      {:error, :invalid_runner_access} ->
        previous_draft = Map.get(socket.assigns.approval_scope_drafts, id, [])

        errors =
          if scope == [] and previous_draft != [] do
            Map.put(socket.assigns.approval_scope_errors, id, @runner_scope_required)
          else
            Map.delete(socket.assigns.approval_scope_errors, id)
          end

        drafts =
          if scope == [],
            do: Map.put(socket.assigns.approval_scope_drafts, id, []),
            else: socket.assigns.approval_scope_drafts

        {:noreply,
         socket
         |> assign(
           :approval_access_modes,
           Map.put(socket.assigns.approval_access_modes, id, mode)
         )
         |> assign(
           :approval_scope_drafts,
           drafts
         )
         |> assign(:approval_scope_errors, errors)}
    end
  end

  def handle_event("approve_request", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &do_approve_request(&1, id, approval_params(&1, id))
    )
  end

  def handle_event("dismiss_request", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      SSO.subject_can_configure_sso?(socket.assigns.current_subject),
      &do_dismiss_request(&1, id)
    )
  end

  def handle_event("save_scopes", %{"membership_id" => id} = params, socket) do
    access =
      Accounts.build_runner_access(
        params["runner_access_mode"],
        List.wrap(params["scope"]),
        access_allowlist(socket),
        Map.get(params, "pack_access_mode", "all"),
        List.wrap(params["pack_scope"])
      )

    save_built_access(socket, id, access)
  end

  # Keeps @edit_form current with what's typed, so a rejected save re-renders the
  # operator's text instead of reverting to the stored name.
  def handle_event("validate_edit", %{"user" => params}, socket) do
    {:noreply, assign(socket, :edit_form, to_form(params, as: "user"))}
  end

  def handle_event("save_edit", %{"membership_id" => id, "user" => params}, socket) do
    socket = assign(socket, :edit_form, to_form(params, as: "user"))

    with_membership(socket, id, fn membership ->
      case Accounts.update_user_as_admin(membership, params, socket.assigns.current_subject) do
        {:ok, _user} -> {:ok, "Member updated."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
    |> tap_clear_edit()
  end

  def handle_event("validate", %{"invite" => params} = event, socket) do
    case Accounts.change_invitation(params, socket.assigns.current_subject) do
      {:ok, changeset} -> {:noreply, assign_form(socket, LiveForm.on_change(changeset, event))}
      {:error, :unauthorized} -> {:noreply, socket}
    end
  end

  def handle_event("invite", %{"invite" => params}, socket), do: do_invite(socket, params)

  def handle_event("invite_another", _params, socket),
    do: {:noreply, reset_invite_form(socket)}

  def handle_event("resend_invitation", %{"membership_id" => id}, socket) do
    case find_member_membership(socket, id) do
      nil -> {:noreply, socket}
      %Accounts.Membership{} = membership -> do_resend_invitation(socket, membership)
    end
  end

  def handle_event("change_role", %{"membership_id" => id, "role" => role}, socket) do
    with true <- role in @roles,
         %Accounts.Membership{} = membership <- find_member_membership(socket, id) do
      # A directory-synced member's role is the IdP's — the DOMAIN refuses the
      # change (`:role_managed_by_directory`) off the membership's own
      # `directory_managed` flag, so the UI lock is a courtesy, not the guard (IL-15).
      case Accounts.update_membership_role(membership, role, socket.assigns.current_subject) do
        {:ok, _updated} ->
          {:noreply, socket |> put_flash(:info, "Role updated.") |> reload()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    else
      false -> {:noreply, put_flash(socket, :error, "Unknown role.")}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("remove", %{"membership_id" => id}, socket) do
    with_membership(socket, id, fn membership ->
      case Accounts.delete_membership(membership, socket.assigns.current_subject) do
        {:ok, _} -> {:ok, "Member removed."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
  end

  # Typed-confirm state for the "Remove from team" dialog (UX friction only —
  # `remove` above stays the server gate).
  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("suspend", %{"membership_id" => id}, socket) do
    with_membership(socket, id, fn membership ->
      case Accounts.suspend_membership(membership, socket.assigns.current_subject) do
        {:ok, _} -> {:ok, "Access suspended."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
  end

  def handle_event("reinstate", %{"membership_id" => id}, socket) do
    with_membership(socket, id, fn membership ->
      # A member the IdP deactivated can't be reinstated here — the DOMAIN refuses
      # off the membership's own `directory_suspended` flag (reactivate them in the
      # IdP). The menu also hides the action, but the guard is domain-owned.
      case Accounts.reinstate_membership(membership, socket.assigns.current_subject) do
        {:ok, _} -> {:ok, "Access restored."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
  end

  def handle_event("end_sessions", %{"membership_id" => id}, socket) do
    with_membership(socket, id, fn membership ->
      case Accounts.end_all_sessions_for(membership, socket.assigns.current_subject) do
        :ok -> {:ok, "All sessions ended for that user."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
  end

  def handle_event("verify_reset_totp", %{"otp" => otp}, socket) do
    verify_and_reset_member_mfa(socket, {:totp, otp})
  end

  def handle_event("verify_reset_recovery", %{"recovery" => %{"code" => code}}, socket) do
    verify_and_reset_member_mfa(socket, {:recovery_code, code})
  end

  def handle_event("use_reset_recovery", _params, socket) do
    {:noreply,
     socket
     |> assign(:mfa_reset_mode, :recovery)
     |> assign(:mfa_reset_error, nil)}
  end

  def handle_event("use_reset_totp", _params, socket) do
    {:noreply,
     socket
     |> assign(:mfa_reset_mode, :totp)
     |> assign(:mfa_reset_error, nil)}
  end

  # The per-row "Resend confirmation" button (current user, unconfirmed)
  # fires the `resend_confirmation` event, but it's handled globally by
  # the `:email_confirmation` on_mount hook (UserAuth) — the same hook
  # that powers the portal-wide verify-email banner — so there's no
  # per-LV handler here.

  defp find_member_facts(socket, id),
    do: Enum.find(socket.assigns.member_facts, &(&1.membership.id == id))

  defp find_member_membership(socket, id) do
    case find_member_facts(socket, id) do
      nil -> nil
      facts -> facts.membership
    end
  end

  defp tap_clear_scope_edit({:noreply, %{assigns: %{flash: %{"info" => _}}} = socket}),
    do: {:noreply, assign(socket, :scope_editing_id, nil)}

  defp tap_clear_scope_edit(other), do: other

  defp tap_clear_edit({:noreply, %{assigns: %{flash: %{"info" => _}}} = socket}),
    do: {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}

  defp tap_clear_edit(other), do: other

  defp save_built_access(socket, id, {:ok, access}) do
    with_membership(socket, id, fn membership ->
      case Accounts.update_membership_runner_access(
             membership,
             access,
             socket.assigns.current_subject
           ) do
        {:ok, _membership} -> {:ok, "Access updated."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
    |> tap_clear_scope_edit()
  end

  defp save_built_access(socket, id, {:error, :invalid_pack_access}),
    do: reject_scope_save(socket, id, :scope_pack_error, @pack_scope_required)

  defp save_built_access(socket, id, {:error, :invalid_runner_access}),
    do: reject_scope_save(socket, id, :scope_error, @runner_scope_required)

  # An empty selection is fixable by ticking a box, so it belongs AT the box — a
  # flash at the top of the page puts the message nowhere near the control, and
  # the auto-dismiss then eats it. Inline only for the editor actually on screen
  # though: a submission naming another member has no control to point at, and
  # the open row's picker would blame the wrong person.
  defp reject_scope_save(%{assigns: %{scope_editing_id: id}} = socket, id, key, message),
    do: {:noreply, assign(socket, key, message)}

  defp reject_scope_save(socket, _id, _key, message),
    do: {:noreply, put_flash(socket, :error, message)}

  # Repetitive plumbing: look up the membership, run `fun`, flash + reload.
  defp with_membership(socket, id, fun) do
    case find_member_membership(socket, id) do
      nil ->
        {:noreply, socket}

      %Accounts.Membership{} = membership ->
        case fun.(membership) do
          {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> reload()}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  defp error_message(reason), do: EmisarWeb.MemberErrors.message(reason)

  defp open_scope_edit(socket, id, access) do
    socket
    |> assign(:scope_editing_id, id)
    |> assign(:scope_access_mode, to_string(access.mode))
    |> assign(:scope_draft, RunnerScope.to_values(access.groups, access.runner_ids))
    |> assign(:scope_error, nil)
    |> assign(:scope_pack_mode, to_string(access.pack_mode))
    |> assign(:scope_pack_draft, RunnerScope.to_pack_values(access.pack_ids))
    |> assign(:scope_pack_error, nil)
    |> assign(:editing_id, nil)
    |> assign(:edit_form, nil)
  end

  defp do_invite(socket, params) do
    case Accounts.invite_user_to_account_and_deliver(
           params,
           socket.assigns.current_user,
           socket.assigns.current_subject
         ) do
      {:ok, %{membership: membership, user: user, delivery: delivery}} ->
        access = Accounts.runner_access_for_memberships([membership]) |> Map.fetch!(membership.id)

        # Success is a page STATE, not a flash-and-reload: the invite view swaps
        # to a confirmation with "Invite another" / "View members", so the
        # inviter isn't dumped back onto the roster wondering if it worked.
        {:noreply,
         socket
         |> assign(:invited_email, user.email)
         |> assign(:invited_membership, membership)
         |> assign(:invited_access, access)
         |> assign(:invite_delivery, delivery)}

      # The domain rebuilt the form's own validation against live runners, so a
      # bad address or a stale runner pick belongs back under its field.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can invite members.")}

      {:error, :already_member} ->
        email = params |> Map.get("email", "") |> String.trim()
        {:noreply, put_flash(socket, :error, "#{email} is already a member.")}

      {:error, :over_limit, "free", 1} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Free includes one user. Upgrade to Team before inviting another."
         )}

      {:error, :over_limit, _plan, limit} ->
        member = if limit == 1, do: "member", else: "members"

        {:noreply,
         put_flash(
           socket,
           :error,
           "This account's plan allows #{limit} #{member}. Increase its member limit before inviting another."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not send invitation.")}
    end
  end

  defp do_resend_invitation(socket, %Accounts.Membership{} = membership) do
    case Accounts.resend_account_invitation_and_deliver(
           membership,
           socket.assigns.current_user,
           socket.assigns.current_subject
         ) do
      {:ok, %{user: user, delivery: delivery}} ->
        {:noreply,
         socket
         |> flash_resend_invitation_outcome(user.email, delivery)
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, resend_invitation_error_message(reason))}
    end
  end

  # The invitation row + token are refreshed regardless of email delivery, so
  # the flash says which actually happened — otherwise the inviter waits on a
  # member who never got a link. We can't offer the token as a fallback: it
  # stays inside Accounts by design.
  defp flash_resend_invitation_outcome(socket, email, {:ok, :suppressed}) do
    put_flash(
      socket,
      :error,
      "Invite link refreshed for #{email}, but we can't email that address (it bounced or was marked spam). Contact support to clear it or invite a different address."
    )
  end

  defp flash_resend_invitation_outcome(socket, email, {:error, _reason}) do
    put_flash(
      socket,
      :error,
      "Invite link refreshed for #{email}, but the email didn't go out. Try resending in a moment."
    )
  end

  defp flash_resend_invitation_outcome(socket, email, {:ok, :sent}),
    do: put_flash(socket, :info, "Invitation resent to #{email}.")

  defp resend_invitation_error_message(:not_found),
    do: "That invitation is no longer pending. Refresh to see the member's current state."

  defp resend_invitation_error_message(:unauthorized),
    do: "Only owners and admins can invite members."

  defp resend_invitation_error_message(reason), do: error_message(reason)

  defp load_mfa_reset(socket, %{"membership_id" => membership_id}) do
    subject = socket.assigns.current_subject

    with true <- Accounts.subject_can_manage_team?(subject),
         result <- Accounts.fetch_team_member_facts(membership_id, subject) do
      case result do
        {:ok, %{reset_mfa?: true} = facts} ->
          sso_facts =
            case SSO.fetch_member_mfa_reset_reauthentication_facts(subject) do
              {:ok, facts} -> facts
              {:error, _reason} -> nil
            end

          socket
          |> assign(:page_title, "Reset member 2FA")
          |> assign(:loading?, false)
          |> assign(:mfa_reset_target, facts.membership)
          |> assign(:mfa_reset_sso_facts, sso_facts)
          |> assign(:mfa_reset_error, nil)

        {:ok, _facts} ->
          socket
          |> put_flash(:error, "That member no longer has 2FA to reset.")
          |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")

        {:error, _reason} ->
          raise EmisarWeb.NotFoundError
      end
    else
      false ->
        socket
        |> put_flash(:error, "Only owners and admins can reset a member's 2FA.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")
    end
  end

  defp load_mfa_reset(_socket, _params), do: raise(EmisarWeb.NotFoundError)

  defp verify_and_reset_member_mfa(%{assigns: %{mfa_reset_target: nil}} = socket, _factor),
    do: {:noreply, socket}

  defp verify_and_reset_member_mfa(socket, factor) do
    membership = socket.assigns.mfa_reset_target
    subject = socket.assigns.current_subject
    actor_session_token_digest = current_session_token_digest(socket)

    with {:ok, proof} <-
           Accounts.verify_member_mfa_reset(
             membership,
             factor,
             actor_session_token_digest,
             subject
           ),
         {:ok, _user} <-
           Accounts.reset_member_mfa(
             membership,
             proof,
             actor_session_token_digest,
             subject
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "2FA reset. They can set up a new authenticator after signing in.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")}
    else
      {:error, :rate_limited} ->
        {:noreply,
         assign(
           socket,
           :mfa_reset_error,
           "Too many attempts. Wait a few minutes, then try again."
         )}

      {:error, reason} when reason in [:invalid, :replay] ->
        {:noreply,
         assign(
           socket,
           :mfa_reset_error,
           if(socket.assigns.mfa_reset_mode == :totp,
             do: "That authenticator code didn't match. Check it and try again.",
             else: "That recovery code didn't match or has already been used."
           )
         )}

      {:error, reason}
      when reason in [
             :mfa_reset_proof_stale,
             :mfa_not_enabled,
             :invitation_pending,
             :not_found
           ] ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "The member or 2FA settings changed. Review the current team state."
         )
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")}

      {:error, reason} ->
        {:noreply, assign(socket, :mfa_reset_error, error_message(reason))}
    end
  end

  defp current_session_token_digest(%{
         assigns: %{current_auth: %Emisar.Auth.UserToken{token: token}}
       }),
       do: token

  defp current_session_token_digest(_socket), do: nil

  defp load(socket, params) do
    opts = LiveTable.params_to_opts(params, socket.assigns.filters)

    case Accounts.list_team_member_facts(
           socket.assigns.current_account,
           socket.assigns.current_subject,
           opts
         ) do
      {:ok, member_facts, meta} ->
        # Which of the visible members a connection provisioned (and whether it
        # still owns their directory profile), so the row can attribute + link
        # them. manage_sso-gated, so a non-SSO-admin viewing the team simply sees
        # no sync badge.
        directory_by_user_id =
          case SSO.member_directory_facts(
                 Enum.map(member_facts, & &1.membership.user_id),
                 socket.assigns.current_subject
               ) do
            {:ok, facts} -> facts
            {:error, _} -> %{}
          end

        # The COMPLETE scoped fleet, not a page: this list is the allowlist the
        # runner-scope editor validates a selection against (`build_runner_access/3`),
        # so a paged one made every runner past the first page ungrantable — the
        # member picker and the approval-request approver both silently refused
        # them. The pagination metadata was discarded here anyway.
        #
        # A role without view_runners (billing_manager) gets no runners rather
        # than a MatchError crash — mirror the directory load above. The failure
        # rides along: a scope editor that shows "No runners registered yet." on
        # a failed read invites an admin to widen a grant they can't see.
        {runners, runner_load_error?} =
          case Emisar.Runners.list_all_runners_for_account(socket.assigns.current_subject) do
            {:ok, runners} -> {runners, false}
            {:error, _} -> {[], Runners.subject_can_view_runners?(socket.assigns.current_subject)}
          end

        runners_by_id = Map.new(runners, &{&1.id, &1})
        {advertisements, pack_load_error?} = account_pack_advertisements(socket)

        socket
        |> assign(:member_facts, member_facts)
        |> assign(:metadata, meta)
        |> assign_security_facts()
        |> assign(:filter_params, params)
        |> assign(:directory_by_user_id, directory_by_user_id)
        |> assign(:runners, runners)
        |> assign(:runners_by_id, runners_by_id)
        |> assign(:runner_load_error?, runner_load_error?)
        |> assign(:pack_advertisements, advertisements)
        |> assign(:pack_load_error?, pack_load_error?)
        |> assign(
          :suppressed_emails,
          suppressed_emails(socket.assigns.current_account, socket.assigns.current_subject)
        )
        |> assign_sso_state()
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. a tightened list permission) — flag it
      # so the page says "couldn't load" instead of a silent empty team (you're
      # always a member of your own team, so [] means the read failed).
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:member_facts, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:security_facts, unavailable_security_facts())
        |> assign(:filter_params, params)
        |> assign(:directory_by_user_id, %{})
        |> assign(:runners, [])
        |> assign(:runners_by_id, %{})
        |> assign(:runner_load_error?, true)
        |> assign(:pack_advertisements, %{})
        |> assign(:pack_load_error?, true)
        |> assign(:suppressed_emails, MapSet.new())
        |> assign(:provider_facts, [])
        |> assign(:require_sso_available?, false)
        |> assign(:enabled_sso_provider_count, 0)
        |> assign(:sso_load_error?, true)
        |> assign(:pending_requests, [])
        |> assign(:pending_requests_error?, sso_admin?(socket))
        |> assign(:sync_stats, %{})
        |> assign(:sync_stats_error?, sso_admin?(socket))
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  defp load_invite_runners(socket) do
    {advertisements, pack_load_error?} = account_pack_advertisements(socket)

    case Runners.list_all_runners_for_account(socket.assigns.current_subject) do
      {:ok, runners} ->
        socket
        |> assign(:loading?, false)
        |> assign(:runners, runners)
        |> assign(:runners_by_id, Map.new(runners, &{&1.id, &1}))
        |> assign(:pack_advertisements, advertisements)
        |> assign(:pack_load_error?, pack_load_error?)
        |> assign(:runner_load_error?, false)

      {:error, _reason} ->
        socket
        |> assign(:loading?, false)
        |> assign(:runners, [])
        |> assign(:runners_by_id, %{})
        |> assign(:pack_advertisements, advertisements)
        |> assign(:pack_load_error?, pack_load_error?)
        |> assign(:runner_load_error?, true)
    end
  end

  # A role without view_catalog gets no pack choices rather than a crash — the
  # same shape as the runner and directory loads above. The second element says
  # whether the empty map is a real answer or a failed read, so a pack picker
  # cannot report "No packs on the selected runners" for packs it never read.
  defp account_pack_advertisements(socket) do
    subject = socket.assigns.current_subject

    case Catalog.list_pack_advertisements(subject) do
      {:ok, advertisements} -> {advertisements, false}
      {:error, _reason} -> {%{}, Catalog.subject_can_view_packs?(subject)}
    end
  end

  # Account-wide, not page-scoped: a security stat computed from one paginated
  # page reads "all enrolled" while page 2 has gaps. Accounts owns the counts,
  # the enforcement state, and the SSO requirement, all read fresh — the page
  # never recombines them from its own assigns.
  defp assign_security_facts(socket) do
    facts =
      case Accounts.fetch_team_security_facts(socket.assigns.current_subject) do
        {:ok, facts} -> facts
        {:error, _} -> unavailable_security_facts()
      end

    assign(socket, :security_facts, facts)
  end

  # A denied/failed read shows an empty, unenforced stance rather than a partial
  # one — the roster's own load error is what tells the operator it didn't load.
  defp unavailable_security_facts do
    %{
      mfa_total: 0,
      mfa_enrolled: 0,
      mfa_missing: 0,
      mfa_enforcement: :actor_not_enrolled,
      sso_required?: false
    }
  end

  # SSO state for the Single sign-on rail: the connections themselves (listed
  # right there — Subject-gated, so a non-SSO-admin sees the enforcement status
  # but not the connections), the enabled count (drives the status / lockout
  # guard), and whether requiring SSO is even possible (≥1 enabled connection).
  defp assign_sso_state(socket) do
    subject = socket.assigns.current_subject
    sso_admin? = sso_admin?(socket)

    {provider_facts, providers_failed?} =
      case SSO.list_provider_facts(subject) do
        {:ok, facts, _meta} -> {facts, false}
        _ -> {[], sso_admin?}
      end

    # Every human role can read the narrow posture even when it cannot inspect
    # connection details. That keeps the account's enforcement stance honest
    # without handing a viewer raw provider configuration.
    {count, posture_failed?} =
      case SSO.fetch_account_connection_facts(subject) do
        {:ok, %{enabled_count: count}} -> {count, false}
        {:error, _reason} -> {0, true}
      end

    # Manual-provisioning requests waiting on an admin, across every connection —
    # the SSO hub now lives on Team, so its needs-attention queue does too. Gated
    # (manage_sso + Team plan) inside the read, so a non-SSO-admin just gets [].
    # For an admin, a failed read hides people locked out waiting on them, so it
    # keeps the section and reports the failure.
    {pending_requests, pending_requests_error?} =
      case SSO.list_pending_link_request_facts(subject) do
        {:ok, facts, _meta} -> {facts, false}
        _ -> {[], sso_admin?}
      end

    # Per-connection directory-sync counts (users + distinct groups), so a synced
    # connection's row can show how much it's pulling in. Gated → {} for a
    # non-SSO-admin, and JIT connections simply have no entry.
    {sync_stats, sync_stats_error?} =
      case SSO.provider_sync_stats(subject) do
        {:ok, stats} -> {stats, false}
        _ -> {%{}, sso_admin?}
      end

    socket
    |> assign(:provider_facts, provider_facts)
    |> assign(:enabled_sso_provider_count, count)
    |> assign(:require_sso_available?, count > 0)
    |> assign(:sso_load_error?, providers_failed? or posture_failed?)
    |> assign(:pending_requests, pending_requests)
    |> assign(:pending_requests_error?, pending_requests_error?)
    |> assign_approval_access(pending_requests)
    |> assign(:sync_stats, sync_stats)
    |> assign(:sync_stats_error?, sync_stats_error?)
  end

  # The permission half of every manage_sso-gated read on this page. A member
  # who simply lacks the permission gets the quiet nothing they already got; a
  # failed read is only reported to someone the section is actually for.
  defp sso_admin?(socket), do: SSO.subject_can_manage_sso?(socket.assigns.current_subject)

  # Each request's form opens on the runner access its own connection currently
  # defaults to — SSO derives it, so the page never reads a provider's default
  # fields (or has to decide what a missing connection would mean).
  defp assign_approval_access(socket, request_facts) do
    {modes, drafts} =
      Enum.reduce(request_facts, {%{}, %{}}, fn facts, {modes, drafts} ->
        access = facts.default_runner_access
        id = facts.request.id

        {Map.put(modes, id, to_string(access.mode)),
         Map.put(drafts, id, RunnerScope.to_values(access.groups, access.runner_ids))}
      end)

    socket
    |> assign(:approval_access_modes, modes)
    |> assign(:approval_scope_drafts, drafts)
    |> assign(:approval_scope_errors, %{})
    |> assign(:approval_pack_modes, %{})
    |> assign(:approval_pack_drafts, %{})
    |> assign(:approval_pack_errors, %{})
  end

  # -- Pending SSO access requests (manual provisioning) ----------------
  # People blocked at sign-in until an admin approves. Gated on configure_sso;
  # each acts on a request from the loaded list, then refreshes the SSO state.

  # Runners AND every pack the account carries — deliberately wider than the
  # picker, which only offers the packs the CHOSEN runners advertise: a grant may
  # name a pack that is momentarily unadvertised (its host is offline) without
  # the save being rejected.
  defp access_allowlist(socket) do
    Accounts.runner_access_allowlist(
      socket.assigns.runners,
      Map.keys(socket.assigns.pack_advertisements)
    )
  end

  # The review dialog keeps its draft in the socket as each choice changes. The
  # final click carries only the request id; a caller cannot smuggle a different
  # access grant around the reviewed controls in the approval event itself.
  defp approval_params(socket, id) do
    case Enum.find(socket.assigns.pending_requests, &(&1.request.id == id)) do
      %{request: %{matched_user_id: matched_user_id}} when not is_nil(matched_user_id) ->
        %{
          "runner_access_mode" => "none",
          "scope" => [],
          "pack_access_mode" => "all",
          "pack_scope" => []
        }

      _new_or_missing_request ->
        %{
          "runner_access_mode" => Map.get(socket.assigns.approval_access_modes, id, "none"),
          "scope" => Map.get(socket.assigns.approval_scope_drafts, id, []),
          "pack_access_mode" => Map.get(socket.assigns.approval_pack_modes, id, "all"),
          "pack_scope" => Map.get(socket.assigns.approval_pack_drafts, id, [])
        }
    end
  end

  defp do_approve_request(socket, id, params) do
    case find_pending_request(socket, id) do
      nil ->
        {:noreply, socket}

      request ->
        mode = Map.get(params, "runner_access_mode", "none")

        scope = List.wrap(params["scope"])

        case Accounts.build_runner_access(
               mode,
               scope,
               access_allowlist(socket),
               Map.get(params, "pack_access_mode", "all"),
               List.wrap(params["pack_scope"])
             ) do
          {:ok, access} ->
            approve_request_with_access(socket, request, access)

          {:error, :invalid_pack_access} ->
            {:noreply,
             put_flash(socket, :error, "Choose which packs before approving this request.")}

          {:error, :invalid_runner_access} ->
            {:noreply,
             put_flash(socket, :error, "Choose runner access before approving this request.")}
        end
    end
  end

  defp approve_request_with_access(socket, request, access) do
    case SSO.approve_link_request(request, access, socket.assigns.current_subject) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, approval_success_message(request))
         |> assign_sso_state()}

      {:error, :scim_identity_unmatched} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "This sign-in does not match a directory member. Fix the provider identity mapping, then have the user sign in again."
         )
         |> assign_sso_state()}

      {:error, {:over_limit, "free", 1}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Free includes one user. Upgrade to Team before approving another member."
         )}

      {:error, {:over_limit, _plan, limit}} ->
        member = if limit == 1, do: "member", else: "members"

        {:noreply,
         put_flash(
           socket,
           :error,
           "This account's plan allows #{limit} #{member}. Increase its member limit before approving another."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't approve that request.")}
    end
  end

  defp do_dismiss_request(socket, id) do
    case find_pending_request(socket, id) do
      nil ->
        {:noreply, socket}

      request ->
        case SSO.dismiss_link_request(request, socket.assigns.current_subject) do
          {:ok, _request} ->
            {:noreply,
             socket |> put_flash(:info, "Access request dismissed.") |> assign_sso_state()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Couldn't dismiss that request.")}
        end
    end
  end

  defp find_pending_request(socket, id) do
    case Enum.find(socket.assigns.pending_requests, &(&1.request.id == id)) do
      nil -> nil
      facts -> facts.request
    end
  end

  defp sync_count(count, word), do: "#{count} #{word}#{if count == 1, do: "", else: "s"}"

  # What a member who can't flip these security/notification settings reads in
  # the control's place. Each states the setting's own state plainly — the OFF
  # state included, which none of the three used to render at all.
  defp mfa_enforcement_value_label(:enforced), do: "Enforced"
  defp mfa_enforcement_value_label(_), do: "Not enforced"

  defp sso_connections_value_label(0), do: "Not configured"
  defp sso_connections_value_label(_), do: "Configured"

  defp sso_required_value_label(true), do: "Required"
  defp sso_required_value_label(_), do: "Not required"

  defp monthly_report_value_label(true), do: "Off"
  defp monthly_report_value_label(_), do: "On"

  defp request_label(request),
    do: Accounts.user_display_name(request) || request.provider_identifier

  defp approval_title(%{request: %{matched_user_id: nil} = request}),
    do: "Approve access for #{request_label(request)}?"

  defp approval_title(%{request: %{matched_user_id: _id}}),
    do: "Link this identity to the existing member?"

  defp approval_action_label(%{request: %{matched_user_id: matched_user_id}})
       when not is_nil(matched_user_id),
       do: "Link account"

  defp approval_action_label(_request_facts), do: "Approve"

  defp approval_success_message(%{matched_user_id: matched_user_id} = request)
       when not is_nil(matched_user_id),
       do: "#{request_label(request)} linked — they can sign in now."

  defp approval_success_message(request),
    do: "#{request_label(request)} approved — they can sign in now."

  defp approval_confirm_label(%{request: %{matched_user_id: matched_user_id}})
       when not is_nil(matched_user_id),
       do: "Link identity"

  defp approval_confirm_label(_request_facts), do: "Approve access"

  defp unmatched_directory_request?(%{
         request: %{matched_user_id: nil},
         provider: %{directory_sync?: true}
       }),
       do: true

  defp unmatched_directory_request?(_request_facts), do: false

  defp unmatched_directory_request_help(request_facts) do
    "No directory member matches this sign-in. Fix the externalId to OIDC sub or Entra oid mapping in #{request_facts.provider.name}, then have the user sign in again."
  end

  defp approval_disabled?(%{request: %{matched_user_id: matched_user_id}}, _assigns)
       when not is_nil(matched_user_id),
       do: false

  defp approval_disabled?(%{request: %{id: request_id}}, assigns) do
    runner_scope_missing? =
      Map.get(assigns.approval_access_modes, request_id) == "restricted" and
        Map.get(assigns.approval_scope_drafts, request_id, []) == []

    pack_scope_missing? =
      Map.get(assigns.approval_pack_modes, request_id) == "restricted" and
        Map.get(assigns.approval_pack_drafts, request_id, []) == []

    runner_scope_missing? or pack_scope_missing?
  end

  # The set of member emails on the deliverability suppression list — drives
  # the "Email bouncing" badge. Degrades to empty (no badges) on a denied read.
  defp suppressed_emails(account, subject) do
    case Accounts.suppressed_member_emails(account, subject) do
      {:ok, emails} -> emails
      {:error, _} -> MapSet.new()
    end
  end

  # Each dimension states itself ONCE: as a phrase when there is nothing to
  # enumerate, and as its own tags when there is. "Selected runners" standing in
  # front of the tags that name those runners was the same fact twice.
  defp runner_reach_phrase(%Accounts.RunnerAccess{mode: :none}), do: "None"
  defp runner_reach_phrase(%Accounts.RunnerAccess{mode: :all}), do: "All"
  defp runner_reach_phrase(%Accounts.RunnerAccess{mode: :restricted}), do: nil

  # No reach at all has no pack half at all: the row itself is suppressed, which
  # is why this needs no `mode: :none` clause.
  defp pack_reach_phrase(%Accounts.RunnerAccess{pack_mode: :all}), do: "All"
  defp pack_reach_phrase(%Accounts.RunnerAccess{}), do: nil

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "invite"))
  end

  # Accounts owns the invite form's defaults, role/mode sets, and runner-scope
  # allowlist; the web only renders what it returns. A subject that can't invite
  # gets no form — the page shows the "you can't invite members" state instead.
  defp assign_invite_form(socket, params \\ %{}) do
    case Accounts.change_invitation(params, socket.assigns.current_subject) do
      {:ok, changeset} -> assign_form(socket, changeset)
      {:error, :unauthorized} -> assign(socket, :form, nil)
    end
  end

  # Fresh invite page: a clean form, back on the "compose" step (no success panel).
  defp reset_invite_form(socket) do
    socket
    |> assign(:loading?, false)
    |> assign(:invited_email, nil)
    |> assign(:invited_membership, nil)
    |> assign(:invited_access, nil)
    |> assign(:invite_delivery, nil)
    |> assign_invite_form()
  end

  def render(assigns) do
    ~H"""
    <.console_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_access_requests_count={@pending_access_requests_count}
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
        <%= case @live_action do %>
          <% :new -> %>
            <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
            Invite a member
          <% :reset_mfa -> %>
            <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
            Reset member 2FA
          <% _ -> %>
            Team
        <% end %>
      </:title>

      <%!-- ========= Invite a member — its own focused page (:new) =========
           Pulled off the roster so the role choice gets room to breathe: a
           readable radio-card per role (name + what it can do), and a real
           success step (Invite another / Back to members) instead of a flash.
           NAKED on the canvas (§8.1: forms are naked — the inputs and the
           role cards are the controls; the panel around them was an island). --%>
      <div :if={@live_action == :new} class="mt-4 max-w-2xl">
        <.empty_state
          :if={not @can_manage_team?}
          variant={:bare}
          tone={:danger}
          icon="state.locked"
          title="You can't invite members"
        >
          Only owners and admins can invite members. Ask an owner or admin to add someone.
        </.empty_state>

        <%!-- Sent is the settled destination of this focused flow, so it gets a
             calm receipt. Delivery problems still use the attention spine
             because the operator has to act. --%>
        <.invite_result
          :if={@can_manage_team? and @invited_email}
          email={@invited_email}
          membership={@invited_membership}
          access={@invited_access}
          runners_by_id={@runners_by_id}
          delivery={@invite_delivery}
        >
          <div class="mt-6 flex flex-wrap items-center gap-3">
            <.button phx-click="invite_another" icon="action.add">Invite another</.button>
            <.button navigate={~p"/app/#{@current_account}/settings/team"} variant={:secondary}>
              View members
            </.button>
          </div>
        </.invite_result>

        <div :if={@can_manage_team? and is_nil(@invited_email)}>
          <p class="text-sm leading-relaxed text-zinc-400">
            We'll email a join link for <span class="font-medium text-zinc-300">{@current_account.name}</span>. They'll sign in
            with a magic link or SSO — no password — and land in this workspace.
          </p>

          <.simple_form
            for={@form}
            id="invite_form"
            phx-change="validate"
            phx-submit="invite"
            class="mt-6 space-y-5"
          >
            <.input
              field={@form[:email]}
              type="email"
              label="Email address"
              placeholder="name@company.com"
              autocomplete="off"
              required
            />

            <fieldset>
              <legend class="text-sm font-medium text-zinc-300">Role</legend>
              <p class="mt-0.5 text-xs text-zinc-400">
                What this person can do once they join — you can change it later.
              </p>
              <.choice_cards
                name="invite[role]"
                value={@form[:role].value}
                class="mt-2.5"
              >
                <:card
                  :for={role <- @roles}
                  :if={Emisar.Auth.role_description(role)}
                  value={role}
                  title={Emisar.Auth.role_label(role)}
                >
                  {Emisar.Auth.role_description(role)}
                </:card>
              </.choice_cards>
            </fieldset>

            <%!-- A role that reaches no runners keeps the fieldset — the value is
                  still a fact of the invite — but states it as the locked chip the
                  roster uses for a value someone else decides. Leaving the pickers
                  up would offer a choice `InvitationInput` resets on the very next
                  change event, which reads as a broken control. --%>
            <fieldset :if={not Emisar.Auth.role_carries_runner_access?(@form[:role].value)}>
              <legend class="text-sm font-medium text-zinc-300">Access</legend>
              <p class="mt-0.5 text-xs text-zinc-400">
                {Emisar.Auth.role_label(@form[:role].value)} manages billing only.
              </p>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <.chip icon="role.restricted">No runners</.chip>
                <.chip icon="role.restricted">No packs</.chip>
              </div>
            </fieldset>

            <fieldset :if={Emisar.Auth.role_carries_runner_access?(@form[:role].value)}>
              <legend class="text-sm font-medium text-zinc-300">Access</legend>
              <%!-- The eyebrows below already say the two decisions, so this line
                    spends itself on the one thing they cannot: why the first card
                    is preselected. --%>
              <p class="mt-0.5 text-xs text-zinc-400">New members start with no access.</p>
              <div class="mt-3">
                <.label variant={:eyebrow}>Runners</.label>
              </div>
              <div class="mt-2">
                <.choice_cards
                  name="invite[runner_access_mode]"
                  value={@form[:runner_access_mode].value}
                  attached_value="restricted"
                >
                  <:card value="none" title="No runners">
                    They can join the workspace but cannot view or act on runners.
                  </:card>
                  <:card value="all" title="All runners">
                    Includes every current and future runner in this workspace.
                  </:card>
                  <:card value="restricted" title="Selected runners">
                    Limit access to named runner groups or individual runners.
                  </:card>
                </.choice_cards>

                <.runner_scope_select
                  :if={@form[:runner_access_mode].value == "restricted"}
                  name="invite[scope][]"
                  variant={:attached}
                  runners={@runners}
                  selected={List.wrap(@form[:scope].value)}
                  submit_error_field={@form[:runner_access_mode]}
                  submit_error_message="Choose at least one runner group or runner for selected access."
                  loading?={@loading?}
                  load_error={RunnerScope.runner_load_error(@runner_load_error?)}
                />
              </div>

              <div class="mt-4">
                <.pack_access_field
                  runner_mode={to_string(@form[:runner_access_mode].value)}
                  runner_scope={List.wrap(@form[:scope].value)}
                  runners={@runners}
                  advertisements={@pack_advertisements}
                  grant_limited?={@pack_access_restricted?}
                  load_error={RunnerScope.pack_load_error(@pack_load_error?)}
                  mode_name="invite[pack_access_mode]"
                  mode_value={@form[:pack_access_mode].value}
                  scope_name="invite[pack_scope][]"
                  selected={List.wrap(@form[:pack_scope].value)}
                  submit_error_field={@form[:pack_access_mode]}
                  submit_error_message="Choose at least one pack for selected pack access."
                  loading?={@loading?}
                />
              </div>
            </fieldset>

            <:actions>
              <.button phx-disable-with="Sending…">Send invite</.button>
              <.button navigate={~p"/app/#{@current_account}/settings/team"} variant={:ghost}>
                Cancel
              </.button>
            </:actions>
          </.simple_form>
        </div>
      </div>

      <div :if={@live_action == :reset_mfa} class="mt-4 max-w-xl">
        <.loading_state :if={@loading?} />

        <div :if={not @loading? and @mfa_reset_target}>
          <% target = @mfa_reset_target.user %>
          <.status_note
            icon="state.warning"
            tone={:amber}
            title="This removes their current factor"
            primary
          >
            The authenticator and recovery codes for
            <span class="font-medium text-zinc-200">
              {Accounts.user_display_name(target) || target.email || "this member"}
            </span>
            are wiped. Every session they hold is signed out. They can set up a new factor
            after signing in. Confirm the member asked for this reset before you continue.
          </.status_note>

          <div class="mt-7">
            <%= if @current_user.mfa_enabled_at do %>
              <%= if @mfa_reset_mode == :totp do %>
                <.simple_form for={%{}} id="member-mfa-reset-totp" phx-submit="verify_reset_totp">
                  <.code_input
                    id="member-mfa-reset-otp"
                    name="otp"
                    numeric
                    label="Your authenticator code"
                    error={@mfa_reset_error}
                  />
                  <:actions>
                    <.button variant={:secondary} tone={:rose} phx-disable-with="Verifying…">
                      Verify and reset 2FA
                    </.button>
                    <.button
                      :if={@mfa_reset_sso_facts}
                      href={
                        ~p"/app/#{@current_account}/settings/team/#{@mfa_reset_target.id}/reset_2fa/sso"
                      }
                      method="post"
                      variant={:secondary}
                      tone={:rose}
                    >
                      Verify with {@mfa_reset_sso_facts.provider_name} and reset 2FA
                    </.button>
                    <.button
                      navigate={~p"/app/#{@current_account}/settings/team"}
                      variant={:ghost}
                    >
                      Cancel
                    </.button>
                  </:actions>
                </.simple_form>

                <button
                  type="button"
                  phx-click="use_reset_recovery"
                  class="mt-5 text-sm font-medium text-brand-400 hover:text-brand-300"
                >
                  Use a recovery code instead
                </button>
              <% else %>
                <.simple_form
                  for={@mfa_reset_recovery_form}
                  id="member-mfa-reset-recovery"
                  phx-submit="verify_reset_recovery"
                >
                  <.input
                    field={@mfa_reset_recovery_form[:code]}
                    type="text"
                    label="Your recovery code"
                    autocomplete="one-time-code"
                    required
                  />
                  <.error :if={@mfa_reset_error}>{@mfa_reset_error}</.error>
                  <:actions>
                    <.button variant={:secondary} tone={:rose} phx-disable-with="Verifying…">
                      Verify and reset 2FA
                    </.button>
                    <.button
                      navigate={~p"/app/#{@current_account}/settings/team"}
                      variant={:ghost}
                    >
                      Cancel
                    </.button>
                  </:actions>
                </.simple_form>

                <button
                  type="button"
                  phx-click="use_reset_totp"
                  class="mt-5 text-sm font-medium text-brand-400 hover:text-brand-300"
                >
                  Use an authenticator code instead
                </button>
              <% end %>
            <% else %>
              <%= if @mfa_reset_sso_facts do %>
                <p class="text-sm leading-relaxed text-zinc-400">
                  Reauthenticate with your identity provider before this reset can continue.
                </p>
                <div class="mt-5 flex flex-wrap gap-3">
                  <.button
                    href={
                      ~p"/app/#{@current_account}/settings/team/#{@mfa_reset_target.id}/reset_2fa/sso"
                    }
                    method="post"
                    variant={:secondary}
                    tone={:rose}
                  >
                    Verify with {@mfa_reset_sso_facts.provider_name} and reset 2FA
                  </.button>
                  <.button
                    navigate={~p"/app/#{@current_account}/settings/team"}
                    variant={:ghost}
                  >
                    Cancel
                  </.button>
                </div>
              <% else %>
                <.empty_state
                  variant={:bare}
                  tone={:danger}
                  icon="state.locked"
                  title="A second factor is required"
                >
                  Set up 2FA in your profile, then return here to reset this member's factor.
                  <div class="mt-4">
                    <.button
                      navigate={~p"/app/#{@current_account}/settings/profile"}
                      variant={:secondary}
                    >
                      Open profile
                    </.button>
                  </div>
                </.empty_state>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- The role note opens the page instead of closing it: it explains why
           the roster's invite and role controls are missing, so it has to be
           read BEFORE them, not discovered under the last row. The docs link
           stays the paragraph's tail either way. --%>
      <.page_intro :if={@live_action == :index}>
        Members, roles, and invitations for this workspace — who can dispatch, approve,
        and configure.{" "}<span :if={not @can_manage_team? and @current_role}>Only owners and admins can invite or manage members. Your role: {Emisar.Auth.role_label(
          @current_role
        )}.{" "}</span><.doc_link href="/docs/teams-and-access">Team &amp; access docs</.doc_link>
      </.page_intro>

      <.loading_state :if={@live_action == :index and @loading?} />

      <%!-- Single-column list. Each row is a member: avatar, name +
           email, role pill, joined, "..." menu. Inline edit form
           opens directly under the row instead of in a bolted-on
           extra table column. --%>
      <%!-- Roster leads the main column; the Security stance rides the SIDE
           PANEL beside it (stacks below on a phone) — 2FA and SSO each own one
           boxed control. SSO enforcement is a subsection of its connection
           setup, not a competing card. --%>
      <div
        :if={@live_action == :index and not @loading?}
        class="grid grid-cols-1 gap-x-10 gap-y-8 lg:grid-cols-3 lg:items-start"
      >
        <div id="team-primary-column" class="space-y-8 lg:col-span-2">
          <%!-- The queue belongs to the roster column: these requests become
               members, while Security keeps its stable side rail. --%>
          <section :if={@pending_requests_error?} id="pending-access-requests">
            <.section_header title="Pending access requests" />
            <.empty_state
              variant={:hint}
              tone={:danger}
              icon="state.warning"
              title="Couldn't load access requests"
            >
              This is a load error, not an empty queue — someone may be locked out waiting on you.
              Refresh the page to try again.
            </.empty_state>
          </section>

          <section
            :if={not @pending_requests_error? and @pending_requests != []}
            id="pending-access-requests"
          >
            <.section_header
              title="Pending access requests"
              count={length(@pending_requests)}
              count_tone={:amber}
            />
            <ul class="divide-y divide-zinc-800/70">
              <.list_row
                :for={request_facts <- @pending_requests}
                id={"pending-access-request-#{request_facts.request.id}"}
                padding="py-3.5"
              >
                <:title>
                  <span class="truncate text-sm text-zinc-200">
                    {Accounts.user_display_name(request_facts.request) || "Unknown user"}
                  </span>
                </:title>
                <:chips>
                  <.chip :if={request_facts.request.matched_user_id} tone={:amber}>
                    Existing account
                  </.chip>
                </:chips>
                <:meta>
                  <span :if={email = Accounts.secondary_user_email(request_facts.request)}>
                    {email}
                  </span>
                  <span
                    :if={Accounts.secondary_user_email(request_facts.request)}
                    class="text-zinc-500"
                  >
                    ·
                  </span>
                  <span>{request_facts.provider.name}</span>
                </:meta>
                <:actions>
                  <.tooltip
                    :if={unmatched_directory_request?(request_facts)}
                    id={"unmatched-directory-request-#{request_facts.request.id}"}
                    text={unmatched_directory_request_help(request_facts)}
                  >
                    <.button
                      type="button"
                      variant={:secondary}
                      tone={:amber}
                      size={:sm}
                      disabled
                    >
                      Approve
                    </.button>
                  </.tooltip>
                  <.button
                    :if={not unmatched_directory_request?(request_facts)}
                    id={"review-access-request-#{request_facts.request.id}"}
                    type="button"
                    variant={:secondary}
                    tone={:amber}
                    size={:sm}
                    aria-haspopup="dialog"
                    aria-controls={"approve-request-dialog-#{request_facts.request.id}"}
                    phx-click={open_confirm("approve-request-dialog-#{request_facts.request.id}")}
                  >
                    {approval_action_label(request_facts)}
                  </.button>
                  <.confirm_button
                    id={"dismiss-request-#{request_facts.request.id}"}
                    title="Dismiss this request?"
                    confirm_label="Dismiss"
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    on_confirm={JS.push("dismiss_request", value: %{id: request_facts.request.id})}
                  >
                    <:body>They'll need to sign in again to re-request.</:body>
                    Dismiss
                  </.confirm_button>
                </:actions>
              </.list_row>
            </ul>

            <%= for request_facts <- @pending_requests do %>
              <% request = request_facts.request %>
              <% approval_dialog_id = "approve-request-dialog-#{request.id}" %>
              <.confirm_dialog
                :if={not unmatched_directory_request?(request_facts)}
                id={approval_dialog_id}
                title={approval_title(request_facts)}
                confirm_label={approval_confirm_label(request_facts)}
                tone={:amber}
                disabled={approval_disabled?(request_facts, assigns)}
                on_confirm={
                  JS.push("approve_request", value: %{id: request.id})
                  |> close_confirm(approval_dialog_id)
                }
              >
                <:fields>
                  <div class="space-y-5">
                    <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2.5 text-sm">
                      <dt class="text-zinc-400">Connection</dt>
                      <dd class="min-w-0 text-zinc-200">{request_facts.provider.name}</dd>
                      <dt class="text-zinc-400">Email</dt>
                      <dd class="min-w-0 break-words text-zinc-200">{request.email}</dd>
                      <dt class="text-zinc-400">Provider ID</dt>
                      <dd class="min-w-0 break-all font-mono text-xs text-zinc-300">
                        {request.provider_identifier}
                      </dd>
                      <dt class="text-zinc-400">Workspace role</dt>
                      <dd class="min-w-0 text-zinc-200">
                        {if request.matched_user_id,
                          do: "Current role unchanged",
                          else: Emisar.Auth.role_label(request_facts.default_role)}
                      </dd>
                    </dl>

                    <form
                      :if={is_nil(request.matched_user_id)}
                      id={"approve-request-#{request.id}"}
                      phx-change="approval_access_changed"
                      class="space-y-3 border-t border-zinc-800/70 pt-5"
                    >
                      <input type="hidden" name="_request_id" value={request.id} />
                      <.input
                        type="select"
                        name="runner_access_mode"
                        value={Map.get(@approval_access_modes, request.id, "none")}
                        label="Runner access"
                        size={:compact}
                        class="min-w-0"
                        options={[
                          {"No runners", "none"},
                          {"All runners", "all"},
                          {"Selected runners", "restricted"}
                        ]}
                      />
                      <.runner_scope_select
                        :if={Map.get(@approval_access_modes, request.id) == "restricted"}
                        name="scope[]"
                        label="Selected runners"
                        runners={@runners}
                        selected={Map.get(@approval_scope_drafts, request.id, [])}
                        validation_error={Map.get(@approval_scope_errors, request.id)}
                        load_error={RunnerScope.runner_load_error(@runner_load_error?)}
                      />
                      <.pack_access_field
                        runner_mode={Map.get(@approval_access_modes, request.id, "none")}
                        runner_scope={Map.get(@approval_scope_drafts, request.id, [])}
                        runners={@runners}
                        advertisements={@pack_advertisements}
                        grant_limited?={@pack_access_restricted?}
                        load_error={RunnerScope.pack_load_error(@pack_load_error?)}
                        variant={:select}
                        mode_name="pack_access_mode"
                        mode_value={Map.get(@approval_pack_modes, request.id, "all")}
                        scope_name="pack_scope[]"
                        selected={Map.get(@approval_pack_drafts, request.id, [])}
                        validation_error={Map.get(@approval_pack_errors, request.id)}
                      />
                    </form>
                  </div>
                </:fields>
                <:body>
                  <p class="text-sm leading-relaxed text-zinc-300">
                    <%= if request.matched_user_id do %>
                      This replaces the member's sign-in identifier while keeping their directory
                      lifecycle linked through the provider external ID. Their current role, runner
                      access, and pack access stay unchanged.
                    <% else %>
                      This creates a member with the {Emisar.Auth.role_label(
                        request_facts.default_role
                      )} role and the runner and pack access selected above.
                    <% end %>
                  </p>
                </:body>
              </.confirm_dialog>
            <% end %>
          </section>

          <section id="members-section">
            <%!-- Member list — naked hairline rows; the per-row `<details>`
             action dropdown floats freely (nothing clips on the canvas).
             Inline edit and scope-edit forms render INSIDE the :item slot
             below the top-line content, keeping the natural flow per row. --%>
            <%!-- Invite lives on the Members header — the action belongs to the
               roster it grows, not the page as a whole. --%>
            <.section_header title="Members">
              <:actions :if={@can_manage_team?}>
                <.button
                  navigate={~p"/app/#{@current_account}/settings/team/invite"}
                  size={:sm}
                  icon="action.add"
                >
                  Invite member
                </.button>
              </:actions>
            </.section_header>

            <LiveTable.live_table
              layout={:cards}
              id="members"
              path={~p"/app/#{@current_account}/settings/team"}
              rows={@member_facts}
              metadata={@metadata}
              filter_params={@filter_params}
              filters={@filters}
              wrapper_class="divide-y divide-zinc-800/70"
            >
              <%!-- CONTENT ON CANVAS: hairline member rows on the page rail. The
               avatar stays — it's the ONE identity disc, not decoration. --%>
              <:item :let={member}>
                <li class="py-4">
                  <% membership = member.membership %>
                  <% directory = Map.get(@directory_by_user_id, membership.user_id) %>
                  <% suspended_by_label = Map.get(member, :suspended_by_label) %>
                  <%!-- Until desktop width, identity owns the row and the
                   controls sit beneath it. Splitting sooner reserves a wide
                   empty track while the member's name and provenance wrap. --%>
                  <div
                    id={"member-row-#{membership.id}"}
                    class="flex flex-col gap-3 lg:flex-row lg:items-center lg:gap-4"
                  >
                    <div class="flex min-w-0 flex-1 items-start gap-4">
                      <.avatar name={Accounts.member_display_name(membership, membership.user) || "?"} />

                      <div class="min-w-0 flex-1">
                        <%!-- Keep the identity line about identity. Persistent
                         identity markers (2FA, directory source, self) may sit
                         beside the name; caution states stack below instead of
                         piling amber boxes around it (§7.62). --%>
                        <div class="mb-1.5 flex flex-wrap items-center gap-x-2 gap-y-1">
                          <span
                            id={"member-name-#{membership.id}"}
                            class="truncate font-medium text-zinc-100"
                          >
                            {Accounts.member_display_name(membership, membership.user) || "(unknown)"}
                          </span>
                          <%!-- Email on the deliverability suppression list (a hard
                         bounce or spam complaint) — invites and notifications
                         to this address are silently dropped, so it's the real
                         answer to "why didn't they get the invite?". We expose
                         no un-suppress control; clearing it is a support action
                         (per the product call), hence the tooltip copy. --%>
                          <.chip
                            :if={
                              membership.user &&
                                MapSet.member?(@suppressed_emails, membership.user.email)
                            }
                            tone={:rose}
                            title="This address bounced or filed a spam complaint, so emails to it are blocked. Contact support to clear it."
                          >
                            Email bouncing
                          </.chip>
                          <%!-- MFA status. Three states worth distinguishing:
                         (1) enrolled — quiet brand check, the happy
                         default; (2) not enrolled, account doesn't
                         enforce — neutral grey "No 2FA" hint; (3) not
                         enrolled AND the account requires MFA — LOUD
                         rose, because that user can't sign in right
                         now and an admin should chase them. --%>
                          <.mfa_badge
                            enrolled?={member.mfa_enrolled?}
                            require_mfa?={@security_facts.mfa_enforcement == :enforced}
                          />
                          <%!-- Provisioned by an SSO/SCIM connection? Attribute + link
                         it, so an admin can see where this member came from and
                         jump to the provider. Renders nothing for a manually-added
                         member (or when the viewer can't read SSO). --%>
                          <.sync_badge directory={directory} account={@current_account} />
                          <.chip :if={membership.user_id == @current_user.id} tone={:neutral}>
                            You
                          </.chip>
                        </div>
                        <%!-- Both timestamps render through <.local_time> (viewer-local,
                       hoverable, live); {" "} guards the space the formatter would
                       otherwise let HEEx trim before each component tag. --%>
                        <%!-- When and how recently a colleague signs in is an
                         ADMINISTRATIVE fact about them, so a viewer who can't
                         manage the team sees it only on their OWN row — that
                         one is their own record. Their identity still reads in
                         full. The shared meta line owns the middot, so dropping
                         the two activity segments can't strand a separator
                         after the email. --%>
                        <% show_activity? =
                          @can_manage_team? or membership.user_id == @current_user.id %>
                        <%!-- Exceptional account-access states get their own compact
                       amber lines beneath identity. A pending invitation is ordinary
                       lifecycle metadata below, not a warning (§7.62). --%>
                        <div
                          :if={
                            member.disabled? or
                              (member.confirmation_pending? and not member.pending_invitation?)
                          }
                          id={"member-statuses-#{membership.id}"}
                          class="mb-1 text-xs leading-5"
                        >
                          <div
                            :if={member.disabled?}
                            id={"member-status-suspended-#{membership.id}"}
                            class="min-w-0"
                          >
                            <p class="min-w-0 text-amber-300">
                              <span
                                id={"member-suspended-#{membership.id}"}
                                class="whitespace-nowrap font-medium"
                              >
                                access suspended
                              </span><span
                                :if={suspended_by_label}
                                id={"member-suspended-by-#{membership.id}"}
                                class="text-zinc-400"
                              >
                                {" "}by {suspended_by_label}
                              </span>
                            </p>
                          </div>
                          <div
                            :if={member.confirmation_pending? and not member.pending_invitation?}
                            id={"member-status-unconfirmed-#{membership.id}"}
                            class="flex min-w-0 items-start gap-1.5"
                          >
                            <.status_dot tone={:amber} class="mt-[0.4375rem]" />
                            <p
                              id={"member-unconfirmed-#{membership.id}"}
                              class="font-medium text-amber-300"
                            >
                              Email unconfirmed
                            </p>
                          </div>
                        </div>
                        <.meta_line
                          id={"member-metadata-#{membership.id}"}
                          class="text-xs text-zinc-400"
                        >
                          <:seg :if={email = Accounts.secondary_user_email(membership.user)}>
                            {email}
                          </:seg>
                          <:seg :if={member.pending_invitation?}>
                            invited{" "}<.local_time
                              id={"member-invited-#{membership.id}"}
                              value={membership.inserted_at}
                              mode={:relative}
                            />
                          </:seg>
                          <:seg :if={member.pending_invitation?}>
                            <span
                              id={"member-invitation-state-#{membership.id}"}
                              class="font-medium text-amber-300"
                            >
                              pending
                            </span>
                          </:seg>
                          <:seg :if={show_activity? and not member.pending_invitation?}>
                            joined{" "}<.local_time
                              id={"member-joined-#{membership.id}"}
                              value={membership.inserted_at}
                              mode={:relative}
                            />
                          </:seg>
                          <:seg :if={show_activity? and not member.pending_invitation?}>
                            <.activity_status membership={membership} />
                          </:seg>
                        </.meta_line>
                        <% access = member.runner_access %>
                        <%!-- One labelled row per dimension, on a shared label
                         track. A middot could not survive the wrap: once a long
                         run of tags breaks, nothing on the second line says
                         which dimension it belongs to. The label does, and it
                         also lets each tag drop the half the row already
                         states — a pack row saying "pack" on every pill is the
                         same word twice. Keep label and value on the same row at
                         every width; only the value column wraps when its tags
                         genuinely run out of room (§7.63). --%>
                        <dl
                          id={"member-access-#{membership.id}"}
                          class="mt-1 grid grid-cols-[auto_minmax(0,1fr)] items-baseline gap-x-2 gap-y-1"
                        >
                          <dt class="text-[10px] uppercase tracking-wider text-zinc-400">
                            runners:
                          </dt>
                          <dd class="flex min-w-0 flex-wrap items-center gap-1">
                            <span :if={runner_reach_phrase(access)} class="text-xs text-zinc-400">
                              {runner_reach_phrase(access)}
                            </span>
                            <.identity_tag
                              :for={group <- access.groups}
                              category="group"
                              value={group}
                            />
                            <%!-- The full runner id rides the tag's title; the value half
                             names the live runner, and falls back to the shared
                             removed-runner label when the id no longer resolves. --%>
                            <.identity_tag
                              :for={runner_id <- access.runner_ids}
                              category="runner"
                              title={runner_id}
                            >
                              <% runner = Map.get(@runners_by_id, runner_id) %>
                              <span :if={runner}>{runner.name}</span>
                              <.removed_runner :if={is_nil(runner)} runner_id={runner_id} />
                            </.identity_tag>
                          </dd>

                          <%!-- No reach means no pack half to state at all. --%>
                          <dt
                            :if={access.mode != :none}
                            class="text-[10px] uppercase tracking-wider text-zinc-400"
                          >
                            packs:
                          </dt>
                          <dd
                            :if={access.mode != :none}
                            class="flex min-w-0 flex-wrap items-center gap-1"
                          >
                            <span :if={pack_reach_phrase(access)} class="text-xs text-zinc-400">
                              {pack_reach_phrase(access)}
                            </span>
                            <.chip :for={pack_id <- access.pack_ids} mono>{pack_id}</.chip>
                          </dd>
                        </dl>
                        <%!-- No "managed by identity provider" note here: the sync badge
                         by the name already says the member is IdP-provisioned, and the
                         role lock says its settings are IdP-owned. Access has no inline
                         control in the roster to lock, so an FYI is pure repetition.
                         The edit flow still guards + explains the directory lock. --%>
                      </div>
                    </div>

                    <%!-- Role + actions are ONE right-anchored cluster: the GROUP
                     owns the fixed track, its members stay content-sized inside it
                     (§7.55). The track is what keeps the identity column identical
                     on every row — content-sized cells let a "Billing manager" row
                     and an "Admin" row truncate the last-active fact at different
                     words. Right-anchoring is what puts the role beside its button
                     with one tight gap, and pins the role to the column's right edge
                     on a row that has no button at all. The minimum fits the widest
                     regular role + Actions pair without donating another 2rem of the
                     identity line to empty track; a rare own row carrying two verbs
                     grows rather than overflowing. --%>
                    <div
                      id={"member-controls-#{membership.id}"}
                      class="flex shrink-0 items-center justify-start gap-1.5 pl-14 lg:min-w-[12.5rem] lg:justify-end lg:pl-0"
                    >
                      <%= cond do %>
                        <% @can_manage_team? and not member.self_owner? and not member.role_editable? -> %>
                          <%!-- Synced role: the IdP owns it (a role mapping, or the
                         provider default), so directory sync recomputes it and a manual
                         change here silently reverts. Read-only, pointing to where the
                         change actually sticks — the identity provider. --%>
                          <.tooltip
                            id={"role-lock-#{membership.id}"}
                            text={"Role is managed by #{directory_label(directory)} — change it in your identity provider"}
                          >
                            <.chip icon="role.restricted">
                              {Emisar.Auth.role_label(membership.role)}
                            </.chip>
                          </.tooltip>
                        <% @can_manage_team? and member.role_editable? -> %>
                          <%!-- A role change is a privilege grant — a dropdown (the exact
                         skin of the Actions menu beside it) whose items each OPEN their own
                         styled confirm modal (not a native data-confirm — we use our own
                         dialogs everywhere), so the modal fires only when you pick a
                         DIFFERENT role, never just on opening the control. The handler still
                         authorizes (IL-15). Suspension does NOT lock this — editability
                         tracks permission, not access-state. --%>
                          <.dropdown
                            class="inline-block text-left"
                            summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                            panel_class="z-10 mt-2 w-40 p-1 text-xs shadow-xl"
                          >
                            <:trigger>
                              {Emisar.Auth.role_label(membership.role)}
                              <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
                            </:trigger>
                            <.menu_item
                              :for={role <- @roles}
                              :if={role != to_string(membership.role)}
                              phx-click={open_confirm("change-role-#{membership.id}-#{role}")}
                            >
                              {Emisar.Auth.role_label(role)}
                            </.menu_item>
                          </.dropdown>
                        <% true -> %>
                          <%!-- A role nobody here can change is a VALUE, so the chip
                         is content-sized: stretched to a control's box it impersonated
                         the disabled twin of the dropdown above it. --%>
                          <.chip>
                            {Emisar.Auth.role_label(membership.role)}
                          </.chip>
                      <% end %>
                      <%!-- No wrapper: an empty cell would still be a flex item, so
                       the cluster's gap would push the role off the right edge on a
                       row with no verb. --%>
                      <.member_actions
                        member={member}
                        current_user_id={@current_user.id}
                        can_manage?={@can_manage_team?}
                        can_view_member_activity?={
                          not Audit.subject_sees_billing_audit_only?(@current_subject)
                        }
                        current_account={@current_account}
                        typed={@typed}
                        name_locked?={directory_managed?(directory)}
                      />
                    </div>
                  </div>

                  <%!-- Styled confirm modals for the role dropdown — our own dialog,
                   NOT a native data-confirm. One per assignable role, each pushing
                   change_role on Confirm; mirrors the dropdown's guard so no orphan
                   dialog renders when the picker isn't shown. --%>
                  <.confirm_dialog
                    :for={role <- @roles}
                    :if={
                      @can_manage_team? and member.role_editable? and
                        role != to_string(membership.role)
                    }
                    id={"change-role-#{membership.id}-#{role}"}
                    tone={:amber}
                    title={role_change_title(member_name(membership) || "this member", role)}
                    confirm_label={"Change to #{Emisar.Auth.role_label(role)}"}
                    on_confirm={
                      JS.push("change_role", value: %{membership_id: membership.id, role: role})
                      |> close_confirm("change-role-#{membership.id}-#{role}")
                    }
                  >
                    <:body>{role_change_body(role)}</:body>
                  </.confirm_dialog>

                  <%!-- Edit form appears inline under the row, NAKED (§8.1: forms
                   are naked — the fields are the controls) — indented to the
                   row's content column and bounded by the row's own hairline. --%>
                  <div
                    :if={@editing_id == membership.id and @edit_form}
                    class="mt-4 max-w-xl sm:pl-14"
                  >
                    <.simple_form
                      for={@edit_form}
                      id={"edit-form-#{membership.id}"}
                      phx-change="validate_edit"
                      phx-submit="save_edit"
                      class="space-y-3"
                    >
                      <input type="hidden" name="membership_id" value={membership.id} />
                      <.input
                        field={@edit_form[:full_name]}
                        type="text"
                        label="Full name"
                        autocomplete="name"
                      />
                      <p class="text-xs text-zinc-400">
                        Only display name can be changed from here. Members
                        update their own sign-in email on their Profile page.
                      </p>
                      <:actions>
                        <.button phx-disable-with="Saving...">Save</.button>
                        <.button variant={:ghost} type="button" phx-click="cancel_edit">
                          Cancel
                        </.button>
                      </:actions>
                    </.simple_form>
                  </div>

                  <div :if={@scope_editing_id == membership.id} class="mt-4 max-w-xl sm:pl-14">
                    <form
                      id={"member-scope-form-#{membership.id}"}
                      phx-change="scope_changed"
                      phx-submit="save_scopes"
                      class="space-y-4"
                    >
                      <input type="hidden" name="membership_id" value={membership.id} />
                      <p class="text-xs text-zinc-400">
                        Any API key they create reaches only what you allow here, so narrowing
                        this narrows their keys too.
                      </p>

                      <div>
                        <.label variant={:eyebrow}>Runners</.label>
                        <div class="mt-2">
                          <.choice_cards
                            name="runner_access_mode"
                            value={@scope_access_mode}
                            attached_value="restricted"
                          >
                            <:card value="none" title="No runners">
                              Keep the member in the workspace without runner reach.
                            </:card>
                            <:card value="all" title="All runners">
                              Grant every current and future runner in this workspace.
                            </:card>
                            <:card value="restricted" title="Selected runners">
                              Grant only selected runner groups or individual runners.
                            </:card>
                          </.choice_cards>

                          <.runner_scope_select
                            :if={@scope_access_mode == "restricted"}
                            name="scope[]"
                            variant={:attached}
                            runners={@runners}
                            selected={@scope_draft}
                            validation_error={@scope_error}
                            load_error={RunnerScope.runner_load_error(@runner_load_error?)}
                          />
                        </div>
                      </div>

                      <.pack_access_field
                        runner_mode={@scope_access_mode}
                        runner_scope={@scope_draft}
                        runners={@runners}
                        advertisements={@pack_advertisements}
                        grant_limited?={@pack_access_restricted?}
                        load_error={RunnerScope.pack_load_error(@pack_load_error?)}
                        mode_name="pack_access_mode"
                        mode_value={@scope_pack_mode}
                        scope_name="pack_scope[]"
                        selected={@scope_pack_draft}
                        validation_error={@scope_pack_error}
                      />

                      <div class="flex items-center gap-3">
                        <.button phx-disable-with="Saving...">Save scope</.button>
                        <.button variant={:ghost} type="button" phx-click="cancel_scope_edit">
                          Cancel
                        </.button>
                      </div>
                    </form>
                  </div>
                </li>
              </:item>
              <:empty>
                <.empty_state
                  :if={@load_error?}
                  tone={:danger}
                  icon="state.warning"
                  title="Couldn't load your team"
                >
                  This is a load error, not an empty team — you're always a member of your own.
                  Refresh the page; if it persists, your access to this account may have changed.
                </.empty_state>
                <.empty_state
                  :if={
                    not @load_error? and
                      LiveTable.has_active_filters?(@filter_params, @filters)
                  }
                  variant={:hint}
                  icon="action.search"
                  title="No members match these filters"
                >
                  Try another name, role, or status.
                </.empty_state>
                <%!-- The non-error, unfiltered empty is defensive — the current
                 user is always a member of the account they're viewing, so it
                 shouldn't happen. Keep meaningful copy anyway so it can never
                 accidentally land as a mystery blank panel. --%>
                <.empty_state
                  :if={
                    not @load_error? and
                      not LiveTable.has_active_filters?(@filter_params, @filters)
                  }
                  icon="product.team"
                  title="No team members yet."
                >
                  Invite a teammate to dispatch runs, approve actions, or watch the audit trail.
                  <:cta
                    :if={@can_manage_team?}
                    navigate={~p"/app/#{@current_account}/settings/team/invite"}
                  >
                    Invite member
                  </:cta>
                </.empty_state>
              </:empty>
            </LiveTable.live_table>
          </section>
        </div>

        <%!-- ===== Security side panel ===== 2FA and SSO are the two account
             security concerns; the SSO card contains its enforcement and
             sign-in-link subsections in operator order. --%>
        <aside class="space-y-4 lg:col-span-1">
          <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">Security</h3>

          <%!-- ── Two-factor authentication ── --%>
          <% unenrolled = @security_facts.mfa_missing %>
          <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — a self-contained security control, boxed per the screenshot --%>
          <div class="rounded-xl border border-zinc-800/80 p-4">
            <h4 class="text-sm font-medium text-zinc-100">Two-factor authentication</h4>
            <p class="mt-1 text-xs leading-relaxed text-zinc-400">
              When enforced, members without 2FA are funneled to their profile to set it up before
              they can use the rest of the app. You can't enable this until you've enrolled
              yourself — prevents lock-outs.
            </p>
            <p class="mt-3 flex flex-wrap items-center gap-2 text-xs">
              <span class="flex items-center gap-1.5">
                <.status_dot :if={unenrolled > 0} tone={:amber} size={:sm} />
                <span class="text-zinc-400">
                  2FA enrolled:
                  <span id="mfa-enrolled-count" class="font-medium tabular-nums text-zinc-200">
                    {@security_facts.mfa_enrolled}
                  </span>
                  of
                  <span class="font-medium tabular-nums text-zinc-200">
                    {@security_facts.mfa_total}
                  </span>
                </span>
              </span>
            </p>
            <%!-- No "Enforced" chip on the facts line above: the button's own verb
                 says it for a member who can change it, and the locked value says it
                 for one who can't — a chip as well would state it twice. --%>
            <.gated_setting
              id="require-mfa"
              can_change?={Accounts.subject_can_manage_account_security?(@current_subject)}
              value={mfa_enforcement_value_label(@security_facts.mfa_enforcement)}
              who_can_change="Only owners and admins can change this."
              class="mt-4"
            >
              <%= if @security_facts.mfa_enforcement == :actor_not_enrolled do %>
                <.tooltip
                  text="Enable 2FA on your own profile first — otherwise you'd lock yourself out."
                  placement={:bottom}
                  class="shrink-0"
                >
                  <.mfa_confirm_button
                    require_mfa={false}
                    total={@security_facts.mfa_total}
                    unenrolled={unenrolled}
                    disabled={true}
                  />
                </.tooltip>
              <% else %>
                <.mfa_confirm_button
                  require_mfa={@security_facts.mfa_enforcement == :enforced}
                  total={@security_facts.mfa_total}
                  unenrolled={unenrolled}
                  disabled={false}
                />
              <% end %>
            </.gated_setting>
          </div>

          <%!-- ── Single sign-on connections ── --%>
          <%!-- The id is a documented deep-link target: /settings/sso lands here
               via its anchored redirect, and /docs/sso points operators at it. --%>
          <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — a self-contained security control, boxed per the screenshot --%>
          <div id="single-sign-on" class="rounded-xl border border-zinc-800/80 p-4">
            <h4 class="text-sm font-medium text-zinc-100">Single sign-on</h4>
            <p class="mt-1 text-xs leading-relaxed text-zinc-400">
              Connect your organization's identity provider so members sign in through it. New
              users are provisioned on first sign-in; you choose the role they land with.
            </p>
            <%!-- The whole list fits: a connection is unique per provider kind
                 (one Okta, one Google, …), so there are at most a handful. --%>
            <ul :if={@provider_facts != []} class="mt-3 space-y-0.5">
              <li :for={provider <- @provider_facts}>
                <.link
                  id={"sso-provider-#{provider.id}"}
                  navigate={~p"/app/#{@current_account}/settings/sso/#{provider.id}"}
                  class="group -mx-2 flex items-center gap-2.5 rounded-md px-2 py-2 transition-colors hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <span class="flex items-center gap-2 text-sm leading-tight text-zinc-200">
                      <span class="truncate">{provider.name}</span>
                      <span :if={not provider.enabled?} class="shrink-0 text-[10px] text-zinc-400">
                        Disabled
                      </span>
                    </span>
                    <%!-- Directory-sync status, one quiet line pulled up snug under
                         the name: how much the sync has pulled in (users + distinct
                         groups) and how fresh it is. Only for a SCIM connection; JIT
                         provisions on sign-in and has nothing to show here. --%>
                    <span
                      :if={provider.directory_sync?}
                      class="mt-0.5 block text-[11px] leading-tight text-zinc-400"
                    >
                      <%!-- Zeroes from a failed stats read would report a live sync
                           as pulling nothing in. --%>
                      <span :if={@sync_stats_error?}>Sync counts unavailable</span>
                      <% stats = Map.get(@sync_stats, provider.id, %{users: 0, groups: 0}) %>
                      <span :if={not @sync_stats_error?}>
                        {sync_count(stats.users, "user")} · {sync_count(stats.groups, "group")}
                      </span>
                      <span :if={provider.last_synced_at} class="text-brand-300/90">
                        · synced
                        <.local_time
                          id={"provider-synced-#{provider.id}"}
                          value={provider.last_synced_at}
                          mode={:relative}
                        />
                      </span>
                      <span :if={is_nil(provider.last_synced_at)} class="text-amber-300/90">
                        · never synced
                      </span>
                    </span>
                  </div>
                  <.icon
                    name="breadcrumb.separator"
                    class="h-3.5 w-3.5 shrink-0 text-zinc-500 group-hover:text-zinc-400"
                  />
                </.link>
              </li>
            </ul>
            <%!-- "Not configured" is a claim about how this account signs in, so
                 it is never made from a read that failed. --%>
            <.empty_state
              :if={@sso_load_error?}
              variant={:hint}
              tone={:danger}
              icon="state.warning"
              title="Couldn't load single sign-on"
              class="mt-3"
            >
              This is a load error, not a sign-in posture — connections may well be configured
              and enforced. Refresh the page to try again.
            </.empty_state>
            <%!-- With no list to show, the card still has to say where SSO
                 STANDS — through the same shape as every other setting (§7.59).
                 An SSO admin only lands here when nothing is connected, so
                 their arm keeps the sign-in consequence; a member who can't
                 manage connections gets that state as the locked value, not a
                 sentence about who outranks them. --%>
            <.gated_setting
              :if={not @sso_load_error? and @provider_facts == []}
              id="sso-connections"
              can_change?={SSO.subject_can_manage_sso?(@current_subject)}
              value={sso_connections_value_label(@enabled_sso_provider_count)}
              who_can_change="Only owners and admins can change this."
              class="mt-3"
            >
              <p class="text-xs text-zinc-400">
                Not configured — members sign in with a magic link.
              </p>
            </.gated_setting>
            <div class="mt-4">
              <%= cond do %>
                <% SSO.subject_can_configure_sso?(@current_subject) -> %>
                  <.button
                    navigate={~p"/app/#{@current_account}/settings/sso/new"}
                    variant={:secondary}
                    size={:sm}
                    icon="action.add"
                  >
                    Add provider
                  </.button>
                <% Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                  <span class="text-[11px] text-zinc-400">
                    Available on the Team and Enterprise plans
                  </span>
                <% true -> %>
              <% end %>
            </div>
            <%!-- Enforcement qualifies the connections above, so it stays in
                 their card. Match the quiet sign-in-link subsection grammar;
                 keep the lockout consequence and confirm action intact. --%>
            <div
              data-role="require-sso-section"
              class="mt-4 border-t border-zinc-800/70 pt-3"
            >
              <p class="text-[11px] font-medium text-zinc-300">Require single sign-on</p>
              <p class="mt-0.5 text-[11px] leading-relaxed text-zinc-400">
                Members sign in through this account's identity provider. Magic-link sign-ins are
                redirected to SSO. Needs an enabled connection.
              </p>
              <%!-- The "Required" tag that rode the title line is gone: the button's
                   verb states it for a member who can change it, the locked value for
                   one who can't, and neither said it when SSO was NOT required. --%>
              <.gated_setting
                id="require-sso"
                can_change?={Accounts.subject_can_manage_account_security?(@current_subject)}
                value={sso_required_value_label(@security_facts.sso_required?)}
                who_can_change="Only owners and admins can change this."
                class="mt-3"
              >
                <%= cond do %>
                  <% @security_facts.sso_required? -> %>
                    <.confirm_button
                      id="require-sso"
                      variant={:secondary}
                      tone={:neutral}
                      size={:sm}
                      title="Stop requiring single sign-on?"
                      confirm_label="Stop requiring"
                      on_confirm={JS.push("toggle_require_sso")}
                    >
                      <:body>Members will be able to sign in with a magic link again.</:body>
                      Stop requiring SSO
                    </.confirm_button>
                  <% @require_sso_available? -> %>
                    <.confirm_button
                      id="require-sso"
                      variant={:secondary}
                      tone={:neutral}
                      size={:sm}
                      title="Require single sign-on for everyone?"
                      confirm_label="Require SSO"
                      on_confirm={JS.push("toggle_require_sso")}
                    >
                      <:body>
                        Members who signed in another way are stopped the next time they navigate and
                        have to sign in again through your provider — if it's misconfigured, they're
                        locked out. Confirm SSO works first.
                      </:body>
                      Require SSO
                    </.confirm_button>
                  <% true -> %>
                    <span class="text-[11px] text-zinc-400">Add an enabled connection first</span>
                <% end %>
              </.gated_setting>
            </div>
            <%!-- The branded sign-in link to hand to members — only once there's a
                 connection to sign in through. --%>
            <div
              :if={@provider_facts != []}
              data-role="team-sign-in-section"
              class="mt-4 border-t border-zinc-800/70 pt-3"
            >
              <p class="text-[11px] font-medium text-zinc-300">Team sign-in link</p>
              <p class="mt-0.5 text-[11px] leading-relaxed text-zinc-400">
                Share this — it opens this team's sign-in page with your SSO connections.
              </p>
              <.code_line id="team-sso-sign-in-link" value={@sign_in_url} class="mt-2" />
            </div>
          </div>

          <%!-- ===== Notifications ===== account-wide email preferences, distinct
               from the security knobs above (owner/admin, but not a security change). --%>
          <h3 class="pt-2 text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
            Notifications
          </h3>

          <%!-- ── Monthly report ── --%>
          <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — a self-contained account preference, boxed like the security cards --%>
          <div class="rounded-xl border border-zinc-800/80 p-4">
            <h4 class="text-sm font-medium text-zinc-100">Monthly report</h4>
            <p class="mt-1 text-xs leading-relaxed text-zinc-400">
              A once-a-month email to the account owner summarizing what emisar did — runs executed,
              approvals that gated risky work, current posture. Sign-in and approval emails are
              separate and keep working either way.
            </p>
            <.gated_setting
              id="monthly-report"
              can_change?={Accounts.subject_can_manage_account?(@current_subject)}
              value={monthly_report_value_label(@current_account.settings.monthly_report_opt_out)}
              who_can_change="Only owners and admins can change this."
              class="mt-4"
            >
              <.switch
                on={not @current_account.settings.monthly_report_opt_out}
                on_label="Turn off"
                off_label="Turn back on"
                aria-label="Monthly account-health report email"
                phx-click="toggle_monthly_report"
              />
            </.gated_setting>
          </div>
        </aside>
      </div>
    </.console_shell>
    """
  end

  attr :email, :string, required: true
  attr :membership, Accounts.Membership, required: true
  attr :access, Accounts.RunnerAccess, required: true
  attr :runners_by_id, :map, required: true
  attr :delivery, :any, required: true
  slot :inner_block, required: true

  # The invitation is persisted before the email goes out, so the success step
  # reports what actually happened to the message: brand only when the join
  # link left, amber when the invitation is pending with no email behind it.
  # We never offer to relay the link — the raw token stays inside Accounts.
  defp invite_result(%{delivery: {:ok, :sent}} = assigns) do
    ~H"""
    <div data-shot="invite-complete">
      <.status_note
        icon="action.send"
        tone={:brand}
        title="Invitation sent"
        primary
      >
        The join link is on its way. This person will appear as pending until they accept it.
      </.status_note>

      <.meta_strip cols={4} class="mt-6">
        <.meta_field label="Recipient" wrap>{@email}</.meta_field>
        <.meta_field label="Role">{Emisar.Auth.role_label(@membership.role)}</.meta_field>
        <.meta_field label="Runners" wrap>
          {invited_runner_access(@access, @runners_by_id)}
        </.meta_field>
        <.meta_field label="Packs" wrap>{invited_pack_access(@access)}</.meta_field>
      </.meta_strip>

      <div class="mt-7 border-t border-zinc-800/70 pt-5">
        <h2 class="text-sm font-medium text-zinc-200">What happens next</h2>
        <p class="mt-1 max-w-xl text-sm leading-relaxed text-zinc-400">
          They can join with the emailed link, then sign in with a magic link or your SSO provider.
          You can resend the invitation or change their access from the member list.
        </p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp invite_result(%{delivery: {:ok, :suppressed}} = assigns) do
    ~H"""
    <.event_block
      icon="state.warning"
      tone={:amber}
      title="Invitation saved, but we couldn't email it"
    >
      <:body>
        <span class="font-medium text-zinc-200">{@email}</span>
        bounced or was marked spam, so no join link was sent. The invitation stays pending — contact
        support to clear that address, or invite a different one.
      </:body>
      {render_slot(@inner_block)}
    </.event_block>
    """
  end

  defp invite_result(%{delivery: {:error, _reason}} = assigns) do
    ~H"""
    <.event_block
      icon="state.warning"
      tone={:amber}
      title="Invitation saved, but the email didn't go out"
    >
      <:body>
        The invitation for <span class="font-medium text-zinc-200">{@email}</span>
        is pending, but email delivery failed. Resend it from the member list.
      </:body>
      {render_slot(@inner_block)}
    </.event_block>
    """
  end

  defp invited_runner_access(%Accounts.RunnerAccess{mode: :none}, _runners_by_id), do: "None"

  defp invited_runner_access(%Accounts.RunnerAccess{mode: :all}, _runners_by_id),
    do: "All runners"

  defp invited_runner_access(%Accounts.RunnerAccess{mode: :restricted} = access, runners_by_id) do
    groups = Enum.map(access.groups, &"#{&1} group")

    runners =
      Enum.map(access.runner_ids, fn id ->
        case Map.get(runners_by_id, id) do
          %{name: name} when is_binary(name) and name != "" -> name
          _runner -> id
        end
      end)

    Enum.join(groups ++ runners, ", ")
  end

  defp invited_pack_access(%Accounts.RunnerAccess{mode: :none}), do: "None"
  defp invited_pack_access(%Accounts.RunnerAccess{pack_mode: :all}), do: "All packs"

  defp invited_pack_access(%Accounts.RunnerAccess{pack_mode: :restricted, pack_ids: pack_ids}),
    do: Enum.join(pack_ids, ", ")

  # Inline action menu for a single member row. Hidden for the actor's
  attr :enrolled?, :boolean, required: true
  attr :require_mfa?, :boolean, required: true

  defp mfa_badge(%{enrolled?: true} = assigns) do
    ~H"""
    <.chip
      tone={:brand}
      icon="identity.authentication"
      title="Two-factor authentication is enrolled."
    >
      2FA
    </.chip>
    """
  end

  defp mfa_badge(%{require_mfa?: true} = assigns) do
    ~H"""
    <.chip
      tone={:rose}
      icon="security.posture_warning"
      title="Account requires 2FA but this user hasn't enrolled. They can't sign in until they do."
    >
      2FA required
    </.chip>
    """
  end

  # Not enrolled and the account doesn't enforce: render NOTHING — the 2FA
  # card already aggregates the count, and a "No 2FA" chip on every row of an
  # unenforced account carries zero discrimination (default ≠ signal).
  defp mfa_badge(assigns), do: ~H""

  attr :directory, :any, default: nil
  attr :account, :map, required: true

  # A linked chip attributing a member to the SSO/SCIM connection that
  # provisioned them — SCIM directory sync, an SSO first-login (JIT), or an admin
  # approving a link request — and jumping to that provider. A manually-added
  # member (no directory facts) renders nothing.
  defp sync_badge(%{directory: nil} = assigns), do: ~H""

  defp sync_badge(assigns) do
    assigns = assign(assigns, :identity, assigns.directory.identity)

    ~H"""
    <.link
      navigate={~p"/app/#{@account}/settings/sso/#{@identity.provider_id}"}
      class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-md bg-zinc-800/70 px-1.5 py-0.5 text-[11px] font-medium text-zinc-300 ring-1 ring-inset ring-white/10 transition hover:bg-zinc-700/70 hover:text-zinc-100"
      title={"Provisioned via #{provisioned_via_label(@identity.provisioned_via)} — #{@identity.provider_name}"}
    >
      <%!-- A directory SOURCE is identity metadata, not a pass state — the sync
           glyph stays neutral zinc (brand green is reserved for healthy/pass),
           so a roster of synced members doesn't paint itself green. --%>
      <.icon name="identity.directory_sync" class="h-3 w-3 shrink-0 text-zinc-400" />
      <span class="truncate">{sync_badge_label(@identity)}</span>
    </.link>
    """
  end

  defp provisioned_via_label(:scim), do: "SCIM"
  defp provisioned_via_label(:oidc_jit), do: "SSO"
  defp provisioned_via_label(:manual), do: "Linked"
  defp provisioned_via_label(_), do: "Synced"

  defp sync_badge_label(%{provisioned_via: :scim, provider_name: provider_name}),
    do: provider_name

  defp sync_badge_label(identity),
    do: "#{provisioned_via_label(identity.provisioned_via)} · #{identity.provider_name}"

  # The roster row's action slot, in three shapes: your OWN row gets the audit
  # jump (plus the email remedy while yours is unconfirmed), a manager gets the
  # full Actions menu on everyone else's row, and a non-manager gets nothing on
  # a teammate's row.
  attr :member, :map, required: true
  attr :current_user_id, :string, required: true
  attr :can_manage?, :boolean, required: true
  # A reader who only sees the billing slice of the trail finds nothing under a
  # person-filtered view, so they get no jump into one — not even their own.
  attr :can_view_member_activity?, :boolean, required: true
  attr :current_account, :map, required: true
  attr :typed, :string, required: true
  attr :name_locked?, :boolean, required: true

  defp member_actions(assigns) do
    assigns = assign(assigns, :membership, assigns.member.membership)

    ~H"""
    <%= cond do %>
      <% @membership.user_id == @current_user_id -> %>
        <%!-- Your own row is the only one that offers a jump into a person's
             audit trail as a plain button: a teammate's trail is a MANAGER's
             affordance and lives in the Actions menu below, so the roster no
             longer hands every operator a one-click pivot into a colleague's
             activity. Both verbs wear the bordered face of this cluster's
             other occupants (§7.47), and the remedy verb keeps the exact
             wording of the portal-wide unconfirmed-email strip. --%>
        <.button
          :if={@can_view_member_activity?}
          navigate={
            ~p"/app/#{@current_account}/audit?#{[actor_kind: "user", actor_id: @membership.user_id]}"
          }
          variant={:secondary}
          size={:sm}
        >
          View activity
        </.button>
        <.button
          :if={@member.resend_confirmation?}
          variant={:secondary}
          tone={:neutral}
          size={:sm}
          phx-click="resend_confirmation"
        >
          Resend email
        </.button>
      <% @can_manage? -> %>
        <.dropdown
          class="inline-block text-left"
          summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
          panel_class="z-10 mt-2 w-56 p-1 text-xs shadow-xl"
        >
          <:trigger>
            Actions
            <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
          </:trigger>
          <.menu_item
            :if={@membership.user_id}
            navigate={
              ~p"/app/#{@current_account}/audit?#{[actor_kind: "user", actor_id: @membership.user_id]}"
            }
          >
            View activity
          </.menu_item>
          <%!-- A synced member's name is the IdP's (the domain refuses the save
               with :directory_managed_profile — this hide is the courtesy, IL-15). --%>
          <.menu_item
            :if={not @name_locked?}
            phx-click="start_edit"
            phx-value-membership_id={@membership.id}
          >
            Edit name
          </.menu_item>
          <%!-- A role that reaches no runners has nothing to set: the row above
           already states the cleared value, so the verb goes rather than
           opening an editor whose every save the domain refuses. --%>
          <.menu_item
            :if={
              @member.runner_access_editable? and
                Emisar.Auth.role_carries_runner_access?(@membership.role)
            }
            phx-click="start_scope_edit"
            phx-value-membership_id={@membership.id}
          >
            Set access
          </.menu_item>
          <.menu_item
            :if={@member.disabled?}
            tone={:brand}
            phx-click="reinstate"
            phx-value-membership_id={@membership.id}
          >
            Restore access
          </.menu_item>
          <.menu_item
            :if={not @member.disabled?}
            tone={:amber}
            phx-click={open_confirm("suspend-#{@membership.id}")}
          >
            Suspend access
          </.menu_item>
          <.menu_item
            :if={@member.resend_invitation?}
            phx-click="resend_invitation"
            phx-value-membership_id={@membership.id}
          >
            Resend invite
          </.menu_item>
          <%!-- Only offered when the member actually has 2FA enrolled —
               the recovery path for someone locked out of both their
               authenticator and their recovery codes. It's an
               MFA-BYPASS action (it lets them enroll a NEW factor), so
               the screen spells out the account-takeover risk if the
               admin is wrong about who's really asking. --%>
          <.menu_item
            :if={@member.reset_mfa?}
            tone={:amber}
            navigate={~p"/app/#{@current_account}/settings/team/#{@membership.id}/reset_2fa"}
          >
            Reset 2FA
          </.menu_item>
          <.menu_item phx-click={open_confirm("end-sessions-#{@membership.id}")}>
            End all sessions
          </.menu_item>
          <div class="my-1 border-t border-zinc-800/70"></div>
          <%!-- IRREVERSIBLE — typed-confirm modal instead of native
               data-confirm. The button only OPENS the dialog; `remove`
               still fires from Confirm and stays server-authz-gated. --%>
          <.menu_item tone={:rose} phx-click={show_confirm_dialog("remove-member-#{@membership.id}")}>
            Remove from team
          </.menu_item>
        </.dropdown>

        <%!-- Plain (no-typing) styled confirm modals for the dropdown's
             reversible destructive actions — the drop-in for a native
             data-confirm: the menu row's `phx-click` runs `open_confirm/1`,
             the Confirm here dispatches the event and closes. Same pattern as
             the typed Remove dialog below; each mirrors its trigger's `:if`
             so no orphan dialog renders when the action isn't offered. --%>
        <.confirm_dialog
          :if={not @member.disabled?}
          id={"suspend-#{@membership.id}"}
          title="Suspend this member?"
          confirm_label="Suspend member"
          on_confirm={
            JS.push("suspend", value: %{membership_id: @membership.id})
            |> close_confirm("suspend-#{@membership.id}")
          }
        >
          <:body>They're signed out and can't sign back in until you restore them.</:body>
        </.confirm_dialog>

        <.confirm_dialog
          id={"end-sessions-#{@membership.id}"}
          title="End all sessions for this member?"
          confirm_label="End sessions"
          on_confirm={
            JS.push("end_sessions", value: %{membership_id: @membership.id})
            |> close_confirm("end-sessions-#{@membership.id}")
          }
        >
          <:body>Signs them out of every device; they can sign back in right away.</:body>
        </.confirm_dialog>

        <.confirm_dialog
          id={"remove-member-#{@membership.id}"}
          title="Remove from team"
          confirm_label="Remove member"
          confirm_token={(@membership.user && @membership.user.email) || @membership.id}
          typed={@typed}
          on_confirm={
            JS.push("remove", value: %{membership_id: @membership.id})
            |> hide_confirm_dialog("remove-member-#{@membership.id}")
          }
        >
          <:body>
            Permanently removes
            <span class="font-medium text-rose-100">
              {(@membership.user && @membership.user.email) || "this member"}
            </span>
            from the team: they lose access immediately, their role and runner scopes are
            deleted, and they'd need a fresh invite to return. Suspend instead to keep their
            access reversible.
          </:body>
        </.confirm_dialog>
      <% true -> %>
    <% end %>
    """
  end

  defp mfa_confirm_button(assigns) do
    ~H"""
    <.confirm_button
      id="enforce-mfa"
      variant={:secondary}
      tone={:neutral}
      size={:sm}
      icon="state.locked"
      disabled={@disabled}
      title={
        if @require_mfa,
          do: "Stop enforcing 2FA account-wide?",
          else: "Enforce 2FA for everyone on this account?"
      }
      confirm_label={if @require_mfa, do: "Stop enforcing", else: "Enforce 2FA"}
      on_confirm={JS.push("toggle_require_mfa")}
    >
      <:body>
        <%= if @require_mfa do %>
          Members will be able to use the account without 2FA again.
        <% else %>
          {@unenrolled} of {@total} members aren't enrolled yet — they'll be funneled to set it up
          before they can use the account again. You can't enable this until you've enrolled
          yourself.
        <% end %>
      </:body>
      {if @require_mfa, do: "Stop enforcing 2FA", else: "Enforce 2FA"}
    </.confirm_button>
    """
  end

  # A member whose PROFILE is authoritatively the IdP's: they hold an identity on
  # a connection that currently runs directory sync, so a rename here would be
  # silently overwritten (the domain refuses it with `:directory_managed_profile`).
  # No directory facts (not synced) or an OIDC-only connection stays editable.
  defp directory_managed?(nil), do: false
  defp directory_managed?(directory), do: directory.directory_managed?

  # Names the connection a lock points at; a member the roster can see but whose
  # directory facts the viewer can't read still gets a sentence that makes sense.
  defp directory_label(nil), do: "your identity provider"
  defp directory_label(directory), do: directory.identity.provider_name

  # A member the directory (SCIM) has deactivated (`scim_active: false`) — the IdP
  # revoked their access, so emisar keeps them suspended and won't reinstate them here
  # (reactivate in the IdP instead). A nil identity (not synced) is never IdP-deactivated.

  # The member's display name for a confirm/flash — name, else email, else nil
  # (the user is always preloaded here). Callers supply the "this member" fallback.
  defp member_name(%Accounts.Membership{} = membership),
    do: Accounts.member_display_name(membership, membership.user)

  # Role-change confirm copy for our styled dialog — the title carries the
  # escalation question, the body the consequence. Promoting to a privileged role
  # grants real power (a new owner can act against you), so those spell it out.
  defp role_change_title(name, "owner"), do: "Make #{name} an owner?"
  defp role_change_title(name, "admin"), do: "Make #{name} an admin?"
  defp role_change_title(name, "billing_manager"), do: "Make #{name} a billing manager?"
  defp role_change_title(name, "operator"), do: "Make #{name} an operator?"
  defp role_change_title(name, role), do: "Change #{name} to #{Emisar.Auth.role_label(role)}?"

  defp role_change_body("owner") do
    "Owners have full control — billing, deleting the account, and managing other owners — and can remove or demote you."
  end

  defp role_change_body("admin") do
    "Admins manage runners, policy, members, approvals, and billing across the whole account — everything an owner can, except adding or removing owners."
  end

  defp role_change_body("operator"),
    do: "Operators can dispatch runs to your fleet and approve gated actions."

  # Every remaining role states its OWN contract, from the one description the
  # role pickers already render. The hardcoded fallback here used to hand a
  # billing manager the viewer sentence — "they can see runs, runners, and
  # audit" — which was the exact inverse of the seat, and any role added later
  # would have inherited the same wrong promise.
  defp role_change_body(role), do: Emisar.Auth.role_description(role)

  # Membership activity is account-specific. Until a membership has its first
  # console touch, the user's sign-in timestamp is the conservative fallback:
  # signing in proves activity, while a global later timestamp must never
  # overwrite another account's durable membership value.
  attr :membership, Accounts.Membership, required: true

  defp activity_status(%{membership: %{last_active_at: %DateTime{} = ts}} = assigns) do
    assigns = assign(assigns, :active_at, ts)

    ~H"""
    last active{" "}<.local_time id={"active-#{@membership.id}"} value={@active_at} mode={:relative} />
    """
  end

  defp activity_status(
         %{membership: %{last_active_at: nil, user: %{last_sign_in_at: %DateTime{} = ts}}} =
           assigns
       ) do
    assigns = assign(assigns, :active_at, ts)

    ~H"""
    last active{" "}<.local_time id={"active-#{@membership.id}"} value={@active_at} mode={:relative} />
    """
  end

  defp activity_status(assigns), do: ~H"never active"
end
