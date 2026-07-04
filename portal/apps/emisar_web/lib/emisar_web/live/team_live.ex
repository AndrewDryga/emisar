defmodule EmisarWeb.TeamLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Mailers, Runners, SSO}
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions, RunnerScope}
  alias Phoenix.LiveView.JS

  # String forms of the canonical role enum — the invite/role forms work
  # in strings (HTTP params); membership.role itself is an atom.
  @roles Enum.map(Emisar.Auth.Role.all(), &Atom.to_string/1)

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Accounts.subscribe_account_team(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:page_title, "Team")
     |> assign(:roles, @roles)
     |> assign(:editing_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:scope_editing_id, nil)
     |> assign(:scope_draft, [])
     |> ConfirmDialog.init()
     |> assign_form(invite_changeset())}
  end

  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      # The invite page needs no member load — it renders from the subject alone,
      # so it skips the connected?/loading dance and shows the form immediately.
      :new ->
        {:noreply, socket |> assign(:page_title, "Invite a member") |> reset_invite_form()}

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

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  def handle_event("start_edit", %{"membership_id" => id}, socket) do
    case find_membership(socket, id) do
      nil ->
        {:noreply, socket}

      %Accounts.Membership{user: user} when not is_nil(user) ->
        params = %{"full_name" => user.full_name || ""}

        {:noreply,
         socket
         |> assign(:editing_id, id)
         |> assign(:edit_form, to_form(params, as: "user"))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}
  end

  def handle_event("start_scope_edit", %{"membership_id" => id}, socket) do
    scopes = Map.get(socket.assigns.scopes_by_membership, id, [])
    groups = for %{scope_type: :group, scope_value: value} <- scopes, do: value
    runner_ids = for %{scope_type: :runner, scope_value: value} <- scopes, do: value

    {:noreply,
     socket
     |> assign(:scope_editing_id, id)
     |> assign(:scope_draft, RunnerScope.to_values(groups, runner_ids))}
  end

  def handle_event("cancel_scope_edit", _params, socket) do
    {:noreply, socket |> assign(:scope_editing_id, nil) |> assign(:scope_draft, [])}
  end

  # Live-normalize the scope selection so the picker can disable a runner the
  # moment its group is selected (the group already covers it) — parse drops the
  # now-redundant runners and re-seeds the draft the select renders from.
  def handle_event("scope_changed", %{"scope" => values}, socket) do
    %{groups: groups, runner_ids: runner_ids} = RunnerScope.parse(values, socket.assigns.runners)
    {:noreply, assign(socket, :scope_draft, RunnerScope.to_values(groups, runner_ids))}
  end

  def handle_event("scope_changed", _params, socket),
    do: {:noreply, assign(socket, :scope_draft, [])}

  def handle_event("toggle_require_mfa", _params, socket) do
    value = not socket.assigns.current_account.settings.require_mfa

    cond do
      not Accounts.subject_can_manage_account_security?(socket.assigns.current_subject) ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      # Prevent owners from locking themselves out — if they don't have
      # MFA enabled, they can't enforce it (since the enforcement gate
      # would funnel them too).
      value and is_nil(socket.assigns.current_user.mfa_enabled_at) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Enable 2FA on your own profile first — otherwise you'd lock yourself out."
         )}

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

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update 2FA setting.")}
        end
    end
  end

  def handle_event("toggle_require_sso", _params, socket) do
    account = socket.assigns.current_account
    value = not account.settings.require_sso

    cond do
      not Accounts.subject_can_manage_account_security?(socket.assigns.current_subject) ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      # Prevent a lockout — requiring SSO with no enabled connection would leave
      # everyone (owners included) with no way in.
      value and SSO.list_enabled_providers_for_account(account.id) == [] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Add an enabled SSO connection before requiring single sign-on."
         )}

      true ->
        case Accounts.update_account(
               account,
               %{settings: %{require_sso: value}},
               socket.assigns.current_subject
             ) do
          {:ok, account} ->
            {:noreply,
             socket
             |> assign(:current_account, account)
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
            {:noreply,
             put_flash(socket, :error, "Only owners and admins can change this setting.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update SSO setting.")}
        end
    end
  end

  def handle_event("save_scopes", %{"membership_id" => id} = params, socket) do
    with_membership(socket, id, fn membership ->
      %{groups: groups, runner_ids: runner_ids} =
        RunnerScope.parse(List.wrap(params["scope"]), socket.assigns.runners)

      new_scopes = Enum.map(groups, &{"group", &1}) ++ Enum.map(runner_ids, &{"runner", &1})

      case Runners.replace_runner_scopes(membership, new_scopes, socket.assigns.current_subject) do
        {:ok, :ok} -> {:ok, "Scope updated."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
    |> tap_clear_scope_edit()
  end

  def handle_event("save_edit", %{"membership_id" => id, "user" => params}, socket) do
    with_membership(socket, id, fn membership ->
      case Accounts.update_user_as_admin(membership, params, socket.assigns.current_subject) do
        {:ok, _user} -> {:ok, "Member updated."}
        {:error, reason} -> {:error, error_message(reason)}
      end
    end)
    |> tap_clear_edit()
  end

  def handle_event("validate", %{"invite" => params}, socket) do
    changeset = invite_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("invite", %{"invite" => params}, socket) do
    changeset = invite_changeset(params)

    cond do
      not can_manage?(socket) ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can invite members.")}

      not changeset.valid? ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      :else ->
        %{email: email, role: role} = Ecto.Changeset.apply_changes(changeset)
        do_invite(socket, email, role)
    end
  end

  def handle_event("invite_another", _params, socket),
    do: {:noreply, reset_invite_form(socket)}

  def handle_event("resend_invitation", %{"membership_id" => id}, socket) do
    case find_membership(socket, id) do
      nil -> {:noreply, socket}
      %Accounts.Membership{} = membership -> do_resend_invitation(socket, membership)
    end
  end

  def handle_event("change_role", %{"membership_id" => id, "role" => role}, socket) do
    with true <- role in @roles,
         %Accounts.Membership{} = membership <- find_membership(socket, id) do
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

  def handle_event("reset_mfa", %{"membership_id" => id}, socket) do
    Permissions.gated(
      socket,
      Accounts.subject_can_manage_team?(socket.assigns.current_subject),
      fn socket ->
        with_membership(socket, id, fn membership ->
          case Accounts.reset_member_mfa(membership, socket.assigns.current_subject) do
            {:ok, _user} ->
              {:ok, "2FA reset — they'll set up a new authenticator on next sign-in."}

            {:error, reason} ->
              {:error, error_message(reason)}
          end
        end)
      end
    )
  end

  # The per-row "Resend confirmation" button (current user, unconfirmed)
  # fires the `resend_confirmation` event, but it's handled globally by
  # the `:email_confirmation` on_mount hook (UserAuth) — the same hook
  # that powers the portal-wide verify-email banner — so there's no
  # per-LV handler here.

  defp find_membership(socket, id), do: Enum.find(socket.assigns.memberships, &(&1.id == id))

  defp tap_clear_scope_edit({:noreply, %{assigns: %{flash: %{"info" => _}}} = socket}),
    do: {:noreply, assign(socket, :scope_editing_id, nil)}

  defp tap_clear_scope_edit(other), do: other

  defp tap_clear_edit({:noreply, %{assigns: %{flash: %{"info" => _}}} = socket}),
    do: {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}

  defp tap_clear_edit(other), do: other

  # Repetitive plumbing: look up the membership, run `fun`, flash + reload.
  defp with_membership(socket, id, fun) do
    case find_membership(socket, id) do
      nil ->
        {:noreply, socket}

      %Accounts.Membership{} = membership ->
        case fun.(membership) do
          {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> reload()}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  defp error_message(:unauthorized), do: "Only owners and admins can manage memberships."

  defp error_message(:insufficient_privileges),
    do: "You can only assign or change roles whose permissions you already hold."

  defp error_message(:last_owner),
    do: "Can't remove or demote the last owner. Promote someone else first."

  defp error_message(:cannot_self_promote),
    do: "Promote someone else first — you can't promote yourself."

  defp error_message(:cannot_modify_self),
    do: "You can't change your own membership from here. Use Profile."

  defp error_message(:not_found), do: "User no longer exists."

  defp error_message(:directory_managed_profile),
    do: "This member's name is managed by your identity provider — change it there."

  defp error_message(:role_managed_by_directory),
    do: "That member's role is set by their identity provider."

  defp error_message(:deactivated_in_idp),
    do: "That member is deactivated in your identity provider — reactivate them there first."

  defp error_message(%Ecto.Changeset{}),
    do: "That change wasn't valid. Refresh to see the member's current state, then try again."

  defp error_message(_),
    do: "That change didn't apply. Refresh to see the member's current state, then try again."

  # One-line capability summary per role for the invite picker. Each says what the
  # role CAN do and where it stops, so the grant is a deliberate choice. Kept in
  # sync with the authorizers: owner manages billing + adds owners; admin manages
  # members/runners/policies and approves runs but only *views* billing;
  defp do_invite(socket, email, role) do
    account = socket.assigns.current_account
    inviter = socket.assigns.current_user

    case Accounts.invite_user_to_account(email, role, socket.assigns.current_subject) do
      {:ok, %{user: user, invitation_token: token}} ->
        delivery = Mailers.UserNotifier.deliver_account_invitation(user, inviter, account, token)

        # Success is a page STATE, not a flash-and-reload: the invite view swaps
        # to a confirmation with "Invite another" / "Back to members", so the
        # inviter isn't dumped back onto the roster wondering if it worked.
        {:noreply,
         socket
         |> assign(:invited_email, email)
         |> assign(:invite_suppressed?, suppressed_delivery?(delivery))}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, "#{email} is already a member.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not send invitation.")}
    end
  end

  defp do_resend_invitation(socket, %Accounts.Membership{} = membership) do
    account = socket.assigns.current_account
    inviter = socket.assigns.current_user

    case Accounts.resend_account_invitation(membership, socket.assigns.current_subject) do
      {:ok, %{user: user, invitation_token: token}} ->
        delivery = Mailers.UserNotifier.deliver_account_invitation(user, inviter, account, token)

        {:noreply,
         socket
         |> flash_resend_invitation_outcome(user.email, delivery)
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, resend_invitation_error_message(reason))}
    end
  end

  # The invitation row + token are created regardless of email delivery; the
  # success panel flags when we could NOT reach the address (a hard-bounced or
  # spam-flagged recipient, recorded from the Postmark webhook) so the inviter
  # relays the join link another way instead of leaving the new member stuck
  # "unconfirmed, never signed in" with no hint why.
  defp suppressed_delivery?({:ok, %{suppressed: true}}), do: true
  defp suppressed_delivery?(_), do: false

  defp flash_resend_invitation_outcome(socket, email, {:ok, %{suppressed: true}}) do
    put_flash(
      socket,
      :error,
      "Invite link refreshed for #{email}, but we can't email that address (it bounced or was marked spam). Contact support to clear it or invite a different address."
    )
  end

  defp flash_resend_invitation_outcome(socket, email, _delivery),
    do: put_flash(socket, :info, "Invitation resent to #{email}.")

  defp resend_invitation_error_message(:not_found),
    do: "That invitation is no longer pending. Refresh to see the member's current state."

  defp resend_invitation_error_message(:unauthorized),
    do: "Only owners and admins can invite members."

  defp resend_invitation_error_message(reason), do: error_message(reason)

  defp load(socket, params) do
    opts = LiveTable.params_to_opts(params)

    case Accounts.list_memberships_for_account(
           socket.assigns.current_account,
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:user])
         ) do
      {:ok, memberships, meta} ->
        scopes_by_membership =
          memberships
          |> Enum.map(& &1.id)
          |> Runners.runner_scopes_for_membership_ids()

        # Which of the visible members were provisioned by an SSO/SCIM connection
        # (and which one), so the row can attribute + link them. manage_sso-gated,
        # so a non-SSO-admin viewing the team simply sees no sync badge.
        identity_by_user_id =
          case SSO.list_identities_for_users(
                 Enum.map(memberships, & &1.user_id),
                 socket.assigns.current_subject
               ) do
            {:ok, identities} -> Map.new(identities, &{&1.user_id, &1})
            {:error, _} -> %{}
          end

        {:ok, runners, _} =
          Emisar.Runners.list_runners_for_account(socket.assigns.current_subject)

        runners_by_id = Map.new(runners, &{&1.id, &1})

        socket
        |> assign(:memberships, memberships)
        |> assign(:metadata, meta)
        |> assign(
          :mfa_stats,
          mfa_stats(socket.assigns.current_account, socket.assigns.current_subject)
        )
        |> assign(:filter_params, params)
        |> assign(:scopes_by_membership, scopes_by_membership)
        |> assign(:identity_by_user_id, identity_by_user_id)
        |> assign(:runners, runners)
        |> assign(:runners_by_id, runners_by_id)
        |> assign(:current_role, current_role(memberships, socket.assigns.current_user.id))
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
        |> assign(:memberships, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:mfa_stats, %{total: 0, enrolled: 0})
        |> assign(:filter_params, params)
        |> assign(:scopes_by_membership, %{})
        |> assign(:runners, [])
        |> assign(:runners_by_id, %{})
        |> assign(:current_role, nil)
        |> assign(:suppressed_emails, MapSet.new())
        |> assign(:require_sso_available?, false)
        |> assign(:enabled_sso_provider_count, 0)
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  # Account-wide, not page-scoped: a security stat computed from one
  # paginated page reads "all enrolled" while page 2 has gaps.
  defp mfa_stats(account, subject) do
    case Accounts.team_mfa_stats(account, subject) do
      {:ok, stats} -> stats
      {:error, _} -> %{total: 0, enrolled: 0}
    end
  end

  # SSO enforcement state for the Single sign-on panel: the number of enabled
  # identity providers (drives the count / "Not configured" status), and whether
  # requiring SSO is even possible (≥1 enabled provider — guards the lockout).
  defp assign_sso_state(socket) do
    count = length(SSO.list_enabled_providers_for_account(socket.assigns.current_account.id))

    socket
    |> assign(:enabled_sso_provider_count, count)
    |> assign(:require_sso_available?, count > 0)
  end

  defp sso_provider_label(1), do: "1 provider"
  defp sso_provider_label(count), do: "#{count} providers"

  # The set of member emails on the deliverability suppression list — drives
  # the "Email bouncing" badge. Degrades to empty (no badges) on a denied read.
  defp suppressed_emails(account, subject) do
    case Accounts.suppressed_member_emails(account, subject) do
      {:ok, emails} -> emails
      {:error, _} -> MapSet.new()
    end
  end

  # Operator-facing label for a scope's type — "Group" / "Runner", not the raw
  # lowercase atom.
  defp scope_type_label(:group), do: "Group"
  defp scope_type_label(:runner), do: "Runner"

  # Render a scope chip's value — humanizes runner-uuids into names.
  defp scope_label(%{scope_type: :group, scope_value: value}, _runners), do: value

  defp scope_label(%{scope_type: :runner, scope_value: id}, runners_by_id) do
    case Map.get(runners_by_id, id) do
      %{name: name} -> name
      _ -> String.slice(id, 0, 8) <> "…"
    end
  end

  defp current_role(memberships, user_id) do
    case Enum.find(memberships, &(&1.user_id == user_id)) do
      nil -> nil
      %Accounts.Membership{role: role} -> role
    end
  end

  # Mirrors the central Permissions module, but accepts the assigns map
  # directly so it can be called from inside HEEx templates without a
  # full socket.
  defp can_manage?(%{assigns: %{current_subject: subject}}),
    do: Accounts.subject_can_manage_team?(subject)

  defp can_manage?(%{current_subject: subject}),
    do: Accounts.subject_can_manage_team?(subject)

  defp pending_invitation?(%Accounts.Membership{
         invitation_accepted_at: nil,
         invitation_token_digest: token_digest
       })
       when is_binary(token_digest),
       do: true

  defp pending_invitation?(_membership), do: false

  # Schemaless validation changeset for the invite form. The invite itself
  # is created by `Accounts.invite_user_to_account/3`; this only drives
  # `phx-change` validation + inline field errors (email format, role) so
  # bad input lands under the input instead of in a flash banner.
  defp invite_changeset(params \\ %{}) do
    {%{role: "operator"}, %{email: :string, role: :string}}
    |> Ecto.Changeset.cast(params, [:email, :role])
    |> Ecto.Changeset.update_change(:email, &String.trim/1)
    |> Ecto.Changeset.validate_required([:email])
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> Ecto.Changeset.validate_inclusion(:role, @roles)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "invite"))
  end

  # Fresh invite page: a clean form, back on the "compose" step (no success panel).
  defp reset_invite_form(socket) do
    socket
    |> assign(:loading?, false)
    |> assign(:invited_email, nil)
    |> assign(:invite_suppressed?, false)
    |> assign_form(invite_changeset())
  end

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
      section={:team}
      width={:settings}
    >
      <:title>
        <%= if @live_action == :new do %>
          <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
          Invite a member
        <% else %>
          Team
        <% end %>
      </:title>
      <:actions :if={@live_action == :index and not @loading? and can_manage?(assigns)}>
        <.button
          navigate={~p"/app/#{@current_account}/settings/team/invite"}
          size={:md}
          icon="hero-plus"
        >
          Invite member
        </.button>
      </:actions>

      <%!-- ========= Invite a member — its own focused page (:new) =========
           Pulled off the roster so the role choice gets room to breathe: a
           readable radio-card per role (name + what it can do), and a real
           success step (Invite another / Back to members) instead of a flash. --%>
      <div :if={@live_action == :new} class="mx-auto max-w-2xl space-y-5">
        <.empty_state
          :if={not can_manage?(assigns)}
          variant={:bare}
          tone={:danger}
          icon="hero-lock-closed"
          title="You can't invite members"
        >
          Only owners and admins can invite members. Ask an owner or admin to add someone.
        </.empty_state>

        <%!-- Sent: confirm it, then the two next moves — no vanishing flash. --%>
        <.panel :if={can_manage?(assigns) and @invited_email}>
          <div class="flex flex-col items-center py-6 text-center">
            <span class="grid h-12 w-12 place-items-center rounded-full bg-brand-500/15 text-brand-300 ring-1 ring-brand-500/30">
              <.icon name="hero-paper-airplane" class="h-6 w-6" />
            </span>
            <h2 class="mt-4 font-display text-lg font-semibold tracking-[-0.01em] text-zinc-100">
              Invitation sent
            </h2>
            <p class="mt-1.5 max-w-sm text-pretty text-sm leading-relaxed text-zinc-400">
              We emailed a join link to <span class="font-medium text-zinc-200">{@invited_email}</span>. They'll show in the
              roster as pending until they accept.
            </p>

            <.callout :if={@invite_suppressed?} tone={:amber} class="mt-4 max-w-sm text-left">
              We couldn't email {@invited_email} — it bounced or was marked spam. Send them the
              join link another way, or invite a different address.
            </.callout>

            <div class="mt-6 flex flex-wrap items-center justify-center gap-3">
              <.button phx-click="invite_another" icon="hero-plus">Invite another</.button>
              <.button navigate={~p"/app/#{@current_account}/settings/team"} variant={:secondary}>
                Back to members
              </.button>
            </div>
          </div>
        </.panel>

        <%!-- No panel title — the shell title already says "Invite a member"
             (never a stacked near-synonym pair); the lead line carries intent. --%>
        <.panel :if={can_manage?(assigns) and is_nil(@invited_email)}>
          <p class="mb-5 text-sm leading-relaxed text-zinc-400">
            We'll email a join link for <span class="font-medium text-zinc-300">{@current_account.name}</span>. They'll sign in
            with a magic link or SSO — no password — and land in this workspace.
          </p>

          <.simple_form
            for={@form}
            id="invite_form"
            phx-change="validate"
            phx-submit="invite"
            class="space-y-5"
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
              <p class="mt-0.5 text-xs text-zinc-500">
                What this person can do once they join — you can change it later.
              </p>
              <.choice_cards
                name="invite[role]"
                value={@form[:role].value}
                class="mt-2.5"
              >
                <:card
                  :for={role <- @roles}
                  :if={Emisar.Auth.Role.description(role)}
                  value={role}
                  title={Emisar.Auth.Role.label(role)}
                >
                  {Emisar.Auth.Role.description(role)}
                </:card>
              </.choice_cards>
            </fieldset>

            <:actions>
              <.button phx-disable-with="Sending…">Send invite</.button>
              <.button navigate={~p"/app/#{@current_account}/settings/team"} variant={:ghost}>
                Cancel
              </.button>
            </:actions>
          </.simple_form>
        </.panel>
      </div>

      <.page_intro :if={@live_action == :index}>
        Members, roles, and invitations for this workspace — who can dispatch, approve,
        and configure. <.doc_link href="/docs/teams-and-access">Team &amp; access docs</.doc_link>
      </.page_intro>

      <.loading_state :if={@live_action == :index and @loading?} />

      <%!-- Single-column list. Each row is a member: avatar, name +
           email, role pill, joined, "..." menu. Inline edit form
           opens directly under the row instead of in a bolted-on
           extra table column. --%>
      <div :if={@live_action == :index and not @loading?} class="space-y-6">
        <%!-- Member list — uses LiveTable :cards with overflow={:visible}
             so the per-row `<details>` action dropdown can escape the
             rounded card boundary instead of being clipped. Inline edit
             and scope-edit forms render INSIDE the :item slot below the
             top-line content, keeping the natural flow per row. --%>
        <.section_header title="Members" />

        <LiveTable.live_table
          layout={:cards}
          id="members"
          path={~p"/app/#{@current_account}/settings/team"}
          rows={@memberships}
          metadata={@metadata}
          filter_params={@filter_params}
          overflow={:visible}
          wrapper_class="divide-y divide-zinc-800/70"
        >
          <%!-- CONTENT ON CANVAS: hairline member rows on the page rail. The
               avatar stays — it's the ONE identity disc, not decoration. --%>
          <:item :let={membership}>
            <li class="py-4">
              <%!-- On a phone the role/Actions controls stack BELOW the
                   name+email instead of cramming the row (which truncated
                   "Sam Patel" to "Sa…"); they sit on the right at sm+. --%>
              <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:gap-4">
                <div class={[
                  "flex min-w-0 flex-1 items-start gap-4",
                  Accounts.Membership.disabled?(membership) && "opacity-60"
                ]}>
                  <.avatar name={
                    (membership.user && (membership.user.full_name || membership.user.email)) ||
                      "?"
                  } />

                  <div class="min-w-0 flex-1">
                    <%!-- flex-wrap: the member's name is their identity — on a
                         phone the status chips wrap to the next line instead of
                         crushing the name to "Theo A…". --%>
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="truncate font-medium text-zinc-100">
                        {(membership.user && (membership.user.full_name || membership.user.email)) ||
                          "(unknown)"}
                      </span>
                      <.chip :if={Accounts.Membership.disabled?(membership)} tone={:amber}>
                        Suspended
                      </.chip>
                      <%!-- Unconfirmed = signed up but never clicked the
                         email confirmation link. Useful signal when an
                         admin is wondering why a member can't sign in. --%>
                      <.chip
                        :if={membership.user && is_nil(membership.user.confirmed_at)}
                        tone={:amber}
                        title="This user signed up but hasn't confirmed their email."
                      >
                        Unconfirmed
                      </.chip>
                      <%!-- Email on the deliverability suppression list (a hard
                         bounce or spam complaint) — invites and notifications
                         to this address are silently dropped, so it's the real
                         answer to "why didn't they get the invite?". We expose
                         no un-suppress control; clearing it is a support action
                         (per the product call), hence the tooltip copy. --%>
                      <.chip
                        :if={
                          membership.user && MapSet.member?(@suppressed_emails, membership.user.email)
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
                        user={membership.user}
                        require_mfa?={@current_account.settings.require_mfa}
                      />
                      <%!-- Provisioned by an SSO/SCIM connection? Attribute + link
                         it, so an admin can see where this member came from and
                         jump to the provider. Renders nothing for a manually-added
                         member (or when the viewer can't read SSO). --%>
                      <.sync_badge
                        identity={Map.get(@identity_by_user_id, membership.user_id)}
                        account={@current_account}
                      />
                      <.chip :if={membership.user_id == @current_user.id} tone={:neutral}>
                        You
                      </.chip>
                    </div>
                    <%!-- Both timestamps render through <.local_time> (viewer-local,
                       hoverable, live); {" "} guards the space the formatter would
                       otherwise let HEEx trim before each component tag. --%>
                    <%!-- Wraps below sm — single-line truncation ate the
                         sign-in-recency tail on every long email. --%>
                    <div class="text-xs text-zinc-500 sm:truncate">
                      {membership.user && membership.user.email} · joined{" "}<.local_time
                        value={membership.inserted_at}
                        mode={:relative}
                      /> ·{" "}<.sign_in_status user={membership.user} />
                    </div>
                    <%!-- Per-user runner ACLs (#238): show what runners
                       this member can reach. Empty = all (default).
                       Group/runner scopes appear as inline chips. --%>
                    <%!-- All-runners is the DEFAULT — render nothing (default ≠
                       signal); only a narrowed scope earns chips. --%>
                    <div
                      :if={Map.get(@scopes_by_membership, membership.id, []) != []}
                      class="mt-1 flex flex-wrap items-center gap-1"
                    >
                      <span class="text-[10px] uppercase tracking-wider text-zinc-400">
                        scope:
                      </span>
                      <.chip
                        :for={scope <- Map.get(@scopes_by_membership, membership.id, [])}
                        tone={:neutral}
                      >
                        {scope_type_label(scope.scope_type)}: {scope_label(scope, @runners_by_id)}
                      </.chip>
                    </div>
                  </div>
                </div>

                <div class="flex shrink-0 items-center gap-2 pl-14 sm:pl-0">
                  <% identity = Map.get(@identity_by_user_id, membership.user_id) %>
                  <%= cond do %>
                    <% can_manage?(assigns) and not self_owner?(membership, @current_user.id) and directory_managed?(identity) -> %>
                      <%!-- Synced role: the IdP owns it (a group→role mapping, or the
                         provider default), so directory sync recomputes it and a manual
                         change here silently reverts. Read-only, pointing to where the
                         change actually sticks — the identity provider. --%>
                      <.tooltip
                        class="shrink-0"
                        text={"Role is managed by #{identity.provider.name} — change it in your identity provider"}
                      >
                        <.chip icon="hero-lock-closed-mini">
                          {Emisar.Auth.Role.label(membership.role)}
                        </.chip>
                      </.tooltip>
                    <% can_manage?(assigns) and not self_owner?(membership, @current_user.id) -> %>
                      <%!-- A role change is a privilege grant — a dropdown (same skin as
                         the Actions menu beside it) whose items each carry their own
                         confirm, so the dialog fires only when you pick a DIFFERENT role,
                         never just on opening the control. The handler still authorizes
                         (IL-15). Suspension does NOT lock this — editability tracks
                         permission, not access-state. --%>
                      <.dropdown
                        class="inline-block shrink-0 text-left"
                        summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                        panel_class="z-10 mt-2 w-40 p-1 text-xs shadow-xl"
                      >
                        <:trigger>
                          {Emisar.Auth.Role.label(membership.role)}
                          <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
                        </:trigger>
                        <.menu_item
                          :for={role <- @roles}
                          :if={role != to_string(membership.role)}
                          phx-click="change_role"
                          phx-value-membership_id={membership.id}
                          phx-value-role={role}
                          data-confirm={
                            role_change_confirm(member_name(membership) || "this member", role)
                          }
                        >
                          {Emisar.Auth.Role.label(role)}
                        </.menu_item>
                      </.dropdown>
                    <% true -> %>
                      <.chip class="shrink-0">
                        {Emisar.Auth.Role.label(membership.role)}
                      </.chip>
                  <% end %>

                  <.member_actions
                    membership={membership}
                    current_user_id={@current_user.id}
                    can_manage?={can_manage?(assigns)}
                    current_account={@current_account}
                    typed={@typed}
                    name_locked?={directory_managed?(identity)}
                  />
                </div>
              </div>

              <%!-- Edit form appears inline under the row. No bolted-
                   on table column; just normal flow. --%>
              <div
                :if={@editing_id == membership.id and @edit_form}
                class="mt-4 rounded-lg bg-zinc-900/40 p-4 ring-1 ring-white/[0.08]"
              >
                <.simple_form
                  for={@edit_form}
                  id={"edit-form-#{membership.id}"}
                  phx-submit="save_edit"
                  class="space-y-3"
                >
                  <input type="hidden" name="membership_id" value={membership.id} />
                  <.input field={@edit_form[:full_name]} type="text" label="Full name" />
                  <p class="text-xs text-zinc-500">
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

              <%!-- Inline scope editor — appears under the row when "Set runner
                   scope" is clicked. ONE grouped multi-select (groups with their
                   runners nested beneath); selecting a group disables its runners
                   (already covered). Empty selection = "all runners" default. --%>
              <div
                :if={@scope_editing_id == membership.id}
                class="mt-4 rounded-lg bg-zinc-900/40 p-4 ring-1 ring-white/[0.08]"
              >
                <form phx-change="scope_changed" phx-submit="save_scopes" class="space-y-4">
                  <input type="hidden" name="membership_id" value={membership.id} />
                  <p class="text-xs text-zinc-400">
                    Restrict this member to specific runner groups or individual runners. Selecting a
                    group covers every runner in it. Leave everything unselected to grant access to
                    <strong>all runners</strong>
                    in the account.
                  </p>

                  <.runner_scope_select
                    name="scope[]"
                    label="Runner scope"
                    runners={@runners}
                    selected={@scope_draft}
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
              variant={:bare}
              tone={:danger}
              icon="hero-exclamation-triangle"
              title="Couldn't load your team"
            >
              This is a load error, not an empty team — you're always a member of your own.
              Refresh the page; if it persists, your access to this account may have changed.
            </.empty_state>
            <%!-- The non-error empty is defensive — the current user is always a
                 member of the account they're viewing, so an entirely empty list
                 shouldn't happen. Keep meaningful copy anyway so it can never
                 accidentally land as a mystery blank panel. --%>
            <.empty_state
              :if={not @load_error?}
              variant={:bare}
              icon="hero-users"
              title="No team members yet."
            >
              Invite a teammate to dispatch runs, approve actions, or watch the audit trail.
              <:cta
                :if={can_manage?(assigns)}
                navigate={~p"/app/#{@current_account}/settings/team/invite"}
              >
                Invite member
              </:cta>
            </.empty_state>
          </:empty>
        </LiveTable.live_table>

        <%!-- Security posture — one slim row per control (2FA + SSO):
             title · live fact · control on the right. BELOW the roster on
             purpose: the page's object is PEOPLE, and the daily job (who's
             in, roles, invites) must own the fold — account security is
             rare-touch config, so it reads as the page's footer concern.
             Explainer prose lives in each toggle's confirm dialog. --%>
        <section>
          <.section_header title="Security" />
          <ul class="divide-y divide-zinc-800/70 border-t border-zinc-800/70">
            <li class="flex flex-wrap items-center gap-x-4 gap-y-2 py-4">
              <div class="min-w-0 flex-1">
                <div class="text-sm font-medium text-zinc-100">Two-factor authentication</div>
                <%!-- ONE line, one severity: the count wears amber only while
                     someone is unenrolled (the dashboard pillar's grammar).
                     Full enrollment renders silence — no green "all good". --%>
                <% n = @mfa_stats.total - @mfa_stats.enrolled %>
                <div class="mt-1 flex flex-wrap items-center gap-2 text-xs">
                  <span class="flex items-center gap-1.5 tabular-nums">
                    <.status_dot :if={n > 0} tone={:amber} size={:sm} />
                    <span class={if n > 0, do: "text-amber-300", else: "text-zinc-400"}>
                      {@mfa_stats.enrolled} of {@mfa_stats.total} enrolled
                    </span>
                  </span>
                  <.chip :if={@current_account.settings.require_mfa} tone={:brand}>Enforced</.chip>
                </div>
              </div>
              <%= cond do %>
                <% Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                  <.switch
                    on={@current_account.settings.require_mfa}
                    on_label="Stop enforcing 2FA"
                    off_label="Enforce 2FA"
                    phx-click="toggle_require_mfa"
                    aria-label="Enforce 2FA account-wide"
                    data-confirm={
                      if @current_account.settings.require_mfa,
                        do: "Stop enforcing 2FA account-wide?",
                        else:
                          "Enforce 2FA for everyone on this account? #{@mfa_stats.total - @mfa_stats.enrolled} of #{@mfa_stats.total} members aren't enrolled yet — they'll be funneled to set it up before they can use the account again. You can't enable this until you've enrolled yourself."
                    }
                  />
                <% true -> %>
                  <span class="shrink-0 text-[11px] text-zinc-600">Owner/admin only</span>
              <% end %>
            </li>

            <%!-- SSO can't be required without an enabled connection (that would
                 lock everyone out), so the control becomes the set-up link. --%>
            <li class="flex flex-wrap items-center gap-x-4 gap-y-2 py-4">
              <div class="min-w-0 flex-1">
                <div class="text-sm font-medium text-zinc-100">Single sign-on</div>
                <div class="mt-1 flex flex-wrap items-center gap-2 text-xs">
                  <%= cond do %>
                    <% @current_account.settings.require_sso -> %>
                      <span class="text-zinc-400">
                        Members sign in through your identity provider
                      </span>
                      <.chip tone={:brand}>Required</.chip>
                    <% @enabled_sso_provider_count > 0 -> %>
                      <.chip>{sso_provider_label(@enabled_sso_provider_count)}</.chip>
                    <% true -> %>
                      <.chip>not configured</.chip>
                  <% end %>
                  <%!-- SSO's ONE console door — its nav item is gone (a
                       rare-touch, admin-only surface lives behind its owning
                       page, like runner keys behind Runners). With no provider
                       yet, the right-side "Set up SSO" control IS the door —
                       two links to the same place read as a glitch. --%>
                  <.link
                    :if={
                      @enabled_sso_provider_count > 0 and
                        Accounts.subject_can_manage_account_security?(@current_subject)
                    }
                    navigate={~p"/app/#{@current_account}/settings/sso"}
                    class="font-medium text-brand-400 hover:text-brand-300"
                  >
                    Manage providers →
                  </.link>
                </div>
              </div>
              <%= cond do %>
                <% not Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                  <span class="shrink-0 text-[11px] text-zinc-600">Owner/admin only</span>
                <% not @require_sso_available? and not @current_account.settings.require_sso -> %>
                  <.link
                    navigate={~p"/app/#{@current_account}/settings/sso"}
                    class="shrink-0 text-xs font-medium text-brand-400 hover:text-brand-300"
                  >
                    {if SSO.subject_can_configure_sso?(@current_subject),
                      do: "Set up SSO →",
                      else: "Set up SSO · Team →"}
                  </.link>
                <% true -> %>
                  <.switch
                    on={@current_account.settings.require_sso}
                    on_label="Stop requiring SSO"
                    off_label="Require SSO"
                    phx-click="toggle_require_sso"
                    aria-label="Require single sign-on account-wide"
                    data-confirm={
                      if @current_account.settings.require_sso do
                        "Stop requiring single sign-on? Members will be able to sign in with a magic link again."
                      else
                        "Require single sign-on for everyone? Members without a linked SSO identity are signed out and must sign in through your provider — if it's misconfigured, they're locked out. Confirm SSO works first."
                      end
                    }
                  />
              <% end %>
            </li>
          </ul>
        </section>

        <p :if={not can_manage?(assigns)} class="text-xs text-zinc-500">
          Only owners and admins can invite or manage members. Your role: {@current_role || "—"}.
        </p>
      </div>
    </.dashboard_shell>
    """
  end

  # Inline action menu for a single member row. Hidden for the actor's
  attr :user, :map, default: nil
  attr :require_mfa?, :boolean, required: true

  defp mfa_badge(%{user: %{mfa_enabled_at: %DateTime{}}} = assigns) do
    ~H"""
    <.chip
      tone={:brand}
      icon="hero-shield-check"
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
      icon="hero-shield-exclamation"
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

  attr :identity, :any, default: nil
  attr :account, :map, required: true

  # A linked chip attributing a member to the SSO/SCIM connection that
  # provisioned them — SCIM directory sync, an SSO first-login (JIT), or an admin
  # approving a link request — and jumping to that provider. A manually-added
  # member (nil identity) renders nothing.
  defp sync_badge(%{identity: nil} = assigns), do: ~H""

  defp sync_badge(assigns) do
    ~H"""
    <.link
      navigate={~p"/app/#{@account}/settings/sso/#{@identity.provider_id}"}
      class="inline-flex items-center gap-1 rounded-md bg-zinc-800/70 px-1.5 py-0.5 text-[11px] font-medium text-zinc-300 ring-1 ring-inset ring-white/10 transition hover:bg-zinc-700/70 hover:text-zinc-100"
      title={"Provisioned via #{provisioned_via_label(@identity.provisioned_via)} — #{@identity.provider.name}"}
    >
      <%!-- A directory SOURCE is identity metadata, not a pass state — the sync
           glyph stays neutral zinc (brand green is reserved for healthy/pass),
           so a roster of synced members doesn't paint itself green. --%>
      <.icon name="hero-arrow-path" class="h-3 w-3 text-zinc-400" />
      {provisioned_via_label(@identity.provisioned_via)} · {@identity.provider.name}
    </.link>
    """
  end

  defp provisioned_via_label(:scim), do: "SCIM"
  defp provisioned_via_label(:oidc_jit), do: "SSO"
  defp provisioned_via_label(:manual), do: "Linked"
  defp provisioned_via_label(_), do: "Synced"

  # own row (use Profile) and short-circuited for non-managers.
  attr :membership, :map, required: true
  attr :current_user_id, :string, required: true
  attr :can_manage?, :boolean, required: true
  attr :current_account, :map, required: true
  attr :typed, :string, required: true
  attr :name_locked?, :boolean, required: true

  defp member_actions(assigns) do
    ~H"""
    <%= cond do %>
      <% @membership.user_id == @current_user_id -> %>
        <div class="flex shrink-0 items-center gap-2">
          <.button
            :if={@membership.user && is_nil(@membership.user.confirmed_at)}
            variant={:ghost}
            tone={:brand}
            size={:sm}
            phx-click="resend_confirmation"
          >
            Resend confirmation
          </.button>
        </div>
      <% not @can_manage? -> %>
        <%!-- Viewers can't manage a member but can audit them — every role on
             this page holds view_audit. The link is subject-scoped by the audit
             page; it only pre-filters to this member as actor. --%>
        <.link
          :if={@membership.user_id}
          navigate={
            ~p"/app/#{@current_account}/audit?#{[actor_kind: "user", actor_id: @membership.user_id]}"
          }
          class="shrink-0 text-xs font-medium text-brand-400 hover:text-brand-300"
        >
          View activity →
        </.link>
      <% true -> %>
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
            icon="hero-clipboard-document-list"
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
          <.menu_item phx-click="start_scope_edit" phx-value-membership_id={@membership.id}>
            Set runner scope
          </.menu_item>
          <.menu_item
            :if={Emisar.Accounts.Membership.disabled?(@membership)}
            tone={:brand}
            phx-click="reinstate"
            phx-value-membership_id={@membership.id}
          >
            Restore access
          </.menu_item>
          <.menu_item
            :if={not Emisar.Accounts.Membership.disabled?(@membership)}
            tone={:amber}
            phx-click="suspend"
            phx-value-membership_id={@membership.id}
            data-confirm="Suspend this member? They will be signed out and can't sign back in until restored."
          >
            Suspend access
          </.menu_item>
          <.menu_item
            :if={
              pending_invitation?(@membership) and
                not Emisar.Accounts.Membership.disabled?(@membership)
            }
            phx-click="resend_invitation"
            phx-value-membership_id={@membership.id}
            icon="hero-paper-airplane"
          >
            Resend invite
          </.menu_item>
          <%!-- Only offered when the member actually has 2FA enrolled —
               the recovery path for someone locked out of both their
               authenticator and their recovery codes. It's an
               MFA-BYPASS action (it lets them enroll a NEW factor), so
               the confirm spells out the account-takeover risk if the
               admin is wrong about who's really asking. --%>
          <.menu_item
            :if={@membership.user && not is_nil(@membership.user.mfa_enabled_at)}
            tone={:amber}
            phx-click="reset_mfa"
            phx-value-membership_id={@membership.id}
            data-confirm={"Reset 2FA for #{@membership.user.email}? Their authenticator and recovery codes are wiped and they'll enroll a NEW factor on next sign-in. Only do this for someone you've confirmed is locked out — a new factor is an account-takeover vector if you're wrong about who's asking."}
          >
            Reset 2FA
          </.menu_item>
          <.menu_item
            phx-click="end_sessions"
            phx-value-membership_id={@membership.id}
            data-confirm="End every active session for this member?"
          >
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
    <% end %>
    """
  end

  defp self_owner?(%Accounts.Membership{user_id: uid, role: :owner}, user_id) when uid == user_id,
    do: true

  defp self_owner?(_, _), do: false

  # A member whose role is authoritatively the IdP's: they carry an identity for a
  # provider with directory sync (SCIM) enabled, so the sync recomputes their role
  # (group→role mapping, else the provider default) and any manual change here would
  # be silently overwritten. Role is read-only for them — in the roster AND in the
  # change_role handler. A nil identity (not synced) or an OIDC-only provider (no
  # directory sync) stays editable.
  defp directory_managed?(nil), do: false
  defp directory_managed?(identity), do: identity.provider.scim_enabled

  # A member the directory (SCIM) has deactivated (`scim_active: false`) — the IdP
  # revoked their access, so emisar keeps them suspended and won't reinstate them here
  # (reactivate in the IdP instead). A nil identity (not synced) is never IdP-deactivated.

  # The member's display name for a confirm/flash — name, else email, else nil
  # (the user is always preloaded here). Callers supply the "this member" fallback.
  defp member_name(%Accounts.Membership{} = membership),
    do: membership.user && (membership.user.full_name || membership.user.email)

  # Escalation/lock-out wording on a role change — promoting to a privileged role
  # grants real power (and a new owner can act against you), so the confirm spells
  # out the consequence; a lateral move or demotion keeps the plain prompt.
  defp role_change_confirm(name, "owner") do
    "Make #{name} an owner? Owners have full control — billing, deleting the account, and managing other owners — and can remove or demote you."
  end

  defp role_change_confirm(name, "admin") do
    "Make #{name} an admin? Admins manage runners, policy, members, and approvals across the whole account."
  end

  defp role_change_confirm(name, "operator") do
    "Make #{name} an operator? Operators can dispatch runs to your fleet and approve gated actions."
  end

  defp role_change_confirm(name, role),
    do: "Change #{name}'s role to #{Emisar.Auth.Role.label(role)}?"

  # Two cases worth surfacing to admins: "active in the last 90 days"
  # is a no-op (don't clutter the row), "never signed in" hints at a
  # pending invite, and a stale last-sign-in flags a candidate for
  # cleanup. Long-form so it reads in the row's secondary line. The
  # timestamp case renders through <.local_time> (viewer-local,
  # hoverable, live); {" "} keeps "last sign-in" off the <time> tag.
  attr :user, :map, default: nil

  defp sign_in_status(%{user: %{last_sign_in_at: %DateTime{} = ts}} = assigns) do
    assigns = assign(assigns, :signed_in_at, ts)

    ~H"""
    last sign-in{" "}<.local_time value={@signed_in_at} mode={:relative} />
    """
  end

  defp sign_in_status(%{user: %{last_sign_in_at: nil}} = assigns), do: ~H"never signed in"

  defp sign_in_status(assigns), do: ~H"—"
end
