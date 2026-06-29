defmodule EmisarWeb.TeamLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Mailers, Runners, SSO}
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions}
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
     |> ConfirmDialog.init()
     |> assign_form(invite_changeset())}
  end

  def handle_params(params, _uri, socket) do
    # Gate load/2's reads behind connected? — they run once on the live mount,
    # not also on the dead render (IL-18). The dead render shows <.loading_state>.
    if connected?(socket) do
      {:noreply, socket |> assign(:loading?, false) |> load(params)}
    else
      {:noreply, assign(socket, :loading?, true)}
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
    {:noreply, assign(socket, :scope_editing_id, id)}
  end

  def handle_event("cancel_scope_edit", _params, socket) do
    {:noreply, assign(socket, :scope_editing_id, nil)}
  end

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
             |> assign(:require_sso_available?, true)
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
      groups = (params["groups"] || []) |> List.wrap()
      runner_ids = (params["runners"] || []) |> List.wrap()

      new_scopes =
        Enum.map(groups, &{"group", &1}) ++ Enum.map(runner_ids, &{"runner", &1})

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

  def handle_event("resend_invitation", %{"membership_id" => id}, socket) do
    case find_membership(socket, id) do
      nil -> {:noreply, socket}
      %Accounts.Membership{} = membership -> do_resend_invitation(socket, membership)
    end
  end

  def handle_event("change_role", %{"membership_id" => id, "role" => role}, socket) do
    with true <- role in @roles,
         %Accounts.Membership{} = membership <- find_membership(socket, id) do
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

  defp error_message(%Ecto.Changeset{}),
    do: "That change wasn't valid. Refresh to see the member's current state, then try again."

  defp error_message(_),
    do: "That change didn't apply. Refresh to see the member's current state, then try again."

  # One-line capability summary per role for the invite form. Kept in sync with
  # the authorizers: owner manages billing + adds owners; admin manages members/
  # runners/policies and approves runs but only *views* billing; operator
  # dispatches + approves but manages nothing; viewer is read-only.
  defp role_description("owner"), do: "Full control, including billing and adding owners."

  defp role_description("admin"),
    do: "Manage members, runners, and policies; approve runs; view-only billing."

  defp role_description("operator"),
    do: "Dispatch runs and approve actions — no team or billing management."

  defp role_description("viewer"), do: "Read-only access to runs, runners, approvals, and audit."

  defp role_description(_), do: nil

  defp do_invite(socket, email, role) do
    account = socket.assigns.current_account
    inviter = socket.assigns.current_user

    case Accounts.invite_user_to_account(email, role, socket.assigns.current_subject) do
      {:ok, %{user: user, invitation_token: token}} ->
        delivery = Mailers.UserNotifier.deliver_account_invitation(user, inviter, account, token)

        {:noreply,
         socket
         |> flash_invite_outcome(email, delivery)
         |> assign_form(invite_changeset())
         |> reload()}

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
  # flash reflects whether we could actually reach the address. A suppressed
  # recipient (hard-bounced or spam-flagged, recorded from the Postmark
  # webhook) silently skips the send — tell the inviter so they relay the link
  # another way instead of leaving the new member stuck "unconfirmed, never
  # signed in" with no hint why.
  defp flash_invite_outcome(socket, email, {:ok, %{suppressed: true}}) do
    put_flash(
      socket,
      :error,
      "Invited #{email}, but we can't email that address (it bounced or was marked spam) — send them the join link another way."
    )
  end

  defp flash_invite_outcome(socket, email, _delivery),
    do: put_flash(socket, :info, "Invited #{email}.")

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

        {:ok, runners, _} =
          Emisar.Runners.list_runners_for_account(socket.assigns.current_subject)

        runners_by_id = Map.new(runners, &{&1.id, &1})
        runner_groups = runners |> Enum.map(& &1.group) |> Enum.uniq() |> Enum.sort()

        socket
        |> assign(:memberships, memberships)
        |> assign(:metadata, meta)
        |> assign(
          :mfa_stats,
          mfa_stats(socket.assigns.current_account, socket.assigns.current_subject)
        )
        |> assign(:filter_params, params)
        |> assign(:scopes_by_membership, scopes_by_membership)
        |> assign(:runners_by_id, runners_by_id)
        |> assign(:runner_groups, runner_groups)
        |> assign(:current_role, current_role(memberships, socket.assigns.current_user.id))
        |> assign(
          :suppressed_emails,
          suppressed_emails(socket.assigns.current_account, socket.assigns.current_subject)
        )
        |> assign(
          :require_sso_available?,
          SSO.list_enabled_providers_for_account(socket.assigns.current_account.id) != []
        )
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
        |> assign(:runners_by_id, %{})
        |> assign(:runner_groups, [])
        |> assign(:current_role, nil)
        |> assign(:suppressed_emails, MapSet.new())
        |> assign(:require_sso_available?, false)
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
  defp scope_label(%{scope_type: :group, scope_value: v}, _groups, _runners),
    do: v

  defp scope_label(%{scope_type: :runner, scope_value: id}, _groups, runners_by_id) do
    case Map.get(runners_by_id, id) do
      %{name: name} -> name
      _ -> String.slice(id, 0, 8) <> "…"
    end
  end

  defp scope_selected?(membership_id, scopes_by_membership, type, value) do
    scopes_by_membership
    |> Map.get(membership_id, [])
    |> Enum.any?(fn scope -> scope.scope_type == type and scope.scope_value == value end)
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
      <:title>Team</:title>
      <:actions :if={not @loading? and can_manage?(assigns)}>
        <.button phx-click={show_invite()} size="md">
          Invite member
        </.button>
      </:actions>

      <.page_intro>
        Members, roles, and invitations for this workspace — who can dispatch, approve,
        and configure. <.doc_link href="/docs/teams-and-access">Team &amp; access docs</.doc_link>
      </.page_intro>

      <.loading_state :if={@loading?} />

      <%!-- Single-column list. Each row is a member: avatar, name +
           email, role pill, joined, "..." menu. Inline edit form
           opens directly under the row instead of in a bolted-on
           extra table column. --%>
      <div :if={not @loading?} class="space-y-6">
        <%!-- Security card — account-wide MFA toggle (owner-only) +
             at-a-glance per-member MFA status. Lives at the top because
             this is the highest-leverage account setting on the page;
             everything below is per-member admin. --%>
        <.panel title="Two-factor authentication">
          <:subtitle>
            When enforced, members without 2FA are funneled to their profile to set it up
            before they can use the rest of the app. You can't enable this until you've
            enrolled yourself — prevents lock-outs.
          </:subtitle>
          <:actions>
            <%= cond do %>
              <% Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                <button
                  type="button"
                  phx-click="toggle_require_mfa"
                  role="switch"
                  aria-checked={to_string(@current_account.settings.require_mfa)}
                  aria-label="Enforce 2FA account-wide"
                  data-confirm={
                    if @current_account.settings.require_mfa,
                      do: "Stop enforcing 2FA account-wide?",
                      else:
                        "Enforce 2FA for everyone on this account? #{@mfa_stats.total - @mfa_stats.enrolled} of #{@mfa_stats.total} members aren't enrolled yet — they'll be required to set it up before they can use the account again."
                  }
                  class={[
                    "shrink-0 rounded-lg px-3 py-1.5 text-xs font-semibold",
                    if(@current_account.settings.require_mfa,
                      do: "border border-rose-500/40 text-rose-200 hover:bg-rose-500/10",
                      else: "bg-brand-500 text-zinc-950 hover:bg-brand-400"
                    )
                  ]}
                >
                  {if @current_account.settings.require_mfa,
                    do: "Stop enforcing 2FA",
                    else: "Enforce 2FA"}
                </button>
              <% true -> %>
                <span class="shrink-0 text-[11px] text-zinc-600">Owner/admin only</span>
            <% end %>
          </:actions>

          <%!-- Member status row — shows who's enrolled / not. When
               require_mfa is on, the un-enrolled count gets a loud
               amber chip so the owner sees follow-up at a glance. --%>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <span class="text-zinc-400">
              2FA enrolled: <strong class="text-zinc-100">{@mfa_stats.enrolled}</strong>
              of <strong class="text-zinc-100">{@mfa_stats.total}</strong>
            </span>
            <%= if (n = @mfa_stats.total - @mfa_stats.enrolled) > 0 do %>
              <.chip tone={if @current_account.settings.require_mfa, do: :amber, else: :neutral}>
                {n} without 2FA
              </.chip>
            <% else %>
              <.chip tone={:brand}>All members enrolled</.chip>
            <% end %>
            <%= if @current_account.settings.require_mfa do %>
              <.chip tone={:brand}>Enforced</.chip>
            <% end %>
          </div>
        </.panel>

        <%!-- SSO-enforcement card — owner-only. Can't be turned on without an
             enabled SSO connection (that would lock everyone out), so it links
             to set one up first. --%>
        <.panel title="Single sign-on">
          <:subtitle>
            When required, members sign in through this account's identity provider —
            magic-link sign-ins are bounced to SSO. Needs an SSO connection.
          </:subtitle>
          <:actions>
            <%= cond do %>
              <% not Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                <span class="shrink-0 text-[11px] text-zinc-600">Owner/admin only</span>
              <% not @require_sso_available? and not @current_account.settings.require_sso -> %>
                <.link
                  navigate={~p"/app/#{@current_account}/settings/sso"}
                  class="shrink-0 text-xs font-medium text-brand-400 hover:text-brand-300"
                >
                  Set up SSO first →
                </.link>
              <% true -> %>
                <button
                  type="button"
                  phx-click="toggle_require_sso"
                  role="switch"
                  aria-checked={to_string(@current_account.settings.require_sso)}
                  aria-label="Require single sign-on account-wide"
                  data-confirm={
                    if @current_account.settings.require_sso do
                      "Stop requiring single sign-on? Members will be able to sign in with a magic link again."
                    else
                      "Require single sign-on for everyone? Members without a linked SSO identity are signed out and must sign in through your provider — if it's misconfigured, they're locked out. Confirm SSO works first."
                    end
                  }
                  class={[
                    "shrink-0 rounded-lg px-3 py-1.5 text-xs font-semibold",
                    if(@current_account.settings.require_sso,
                      do: "border border-rose-500/40 text-rose-200 hover:bg-rose-500/10",
                      else: "bg-brand-500 text-zinc-950 hover:bg-brand-400"
                    )
                  ]}
                >
                  {if @current_account.settings.require_sso,
                    do: "Stop requiring SSO",
                    else: "Require SSO"}
                </button>
            <% end %>
          </:actions>

          <%!-- Current state — always shown so the card is never a header over
               empty space (the 2FA panel always has its enrollment row). The
               brand "Required" chip only when enforced; otherwise a quiet note,
               not an "Optional" label. --%>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <%= if @current_account.settings.require_sso do %>
              <.chip tone={:brand}>Required</.chip>
            <% else %>
              <span class="text-zinc-500">Members can sign in with a magic link.</span>
            <% end %>
          </div>
        </.panel>

        <%!-- Invite panel — collapsed by default; revealed by header
             button. Avoids a permanent "fill out this form" sidebar
             dominating the page when no invite is in flight. --%>
        <.panel
          :if={can_manage?(assigns)}
          id="invite-panel"
          class="hidden"
          padding="p-6"
          title="Invite a member"
        >
          <:subtitle>
            We'll email a join link for <span class="font-medium text-zinc-300">{@current_account.name}</span>.
          </:subtitle>
          <:actions>
            <.icon_button icon="hero-x-mark" label="Close invite panel" phx-click={hide_invite()} />
          </:actions>

          <.simple_form
            for={@form}
            id="invite_form"
            phx-change="validate"
            phx-submit="invite"
            class="grid grid-cols-1 gap-3 sm:grid-cols-[1fr_auto_auto] sm:items-end"
          >
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              placeholder="name@company.com"
              required
            />
            <.input
              field={@form[:role]}
              type="select"
              label="Role"
              options={Enum.map(@roles, &{String.capitalize(&1), &1})}
            />
            <:actions>
              <.button phx-disable-with="Sending...">Send invite</.button>
            </:actions>
          </.simple_form>

          <%!-- Assigning a role is a privilege grant — spell out what each of
               the assignable roles can do instead of a bare name. --%>
          <dl class="mt-4 space-y-1 border-t border-zinc-900 pt-3 text-xs text-zinc-500">
            <div :for={role <- @roles} :if={role_description(role)} class="flex gap-2">
              <dt class="w-16 flex-none font-medium text-zinc-400">{String.capitalize(role)}</dt>
              <dd>{role_description(role)}</dd>
            </div>
          </dl>
        </.panel>

        <%!-- Member list — uses LiveTable :cards with overflow={:visible}
             so the per-row `<details>` action dropdown can escape the
             rounded card boundary instead of being clipped. Inline edit
             and scope-edit forms render INSIDE the :item slot below the
             top-line content, keeping the natural flow per row. --%>
        <header class="mb-3 flex items-center gap-2">
          <h2 class="font-display text-sm font-semibold tracking-[-0.01em] text-zinc-100">
            Members
          </h2>
          <.count_badge count={@metadata.count} tone={:neutral} />
        </header>

        <LiveTable.live_table
          layout={:cards}
          id="members"
          path={~p"/app/#{@current_account}/settings/team"}
          rows={@memberships}
          metadata={@metadata}
          filter_params={@filter_params}
          overflow={:visible}
        >
          <:item :let={membership}>
            <li class="px-5 py-4">
              <%!-- On a phone the role/Actions controls stack BELOW the
                   name+email instead of cramming the row (which truncated
                   "Sam Patel" to "Sa…"); they sit on the right at sm+. --%>
              <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:gap-4">
                <div class="flex min-w-0 flex-1 items-start gap-4">
                  <%!-- Avatar: initial in a colored disc — same shape as
                       the sidebar avatar, so the visual rhymes. --%>
                  <span class="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-zinc-800 text-sm font-semibold uppercase text-zinc-300">
                    {String.first(
                      (membership.user && (membership.user.full_name || membership.user.email)) || "?"
                    )}
                  </span>

                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
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
                      <.chip :if={membership.user_id == @current_user.id} tone={:neutral}>
                        You
                      </.chip>
                    </div>
                    <%!-- Both timestamps render through <.local_time> (viewer-local,
                       hoverable, live); {" "} guards the space the formatter would
                       otherwise let HEEx trim before each component tag. --%>
                    <div class="truncate text-xs text-zinc-500">
                      {membership.user && membership.user.email} · joined{" "}<.local_time
                        value={membership.inserted_at}
                        mode={:relative}
                      /> ·{" "}<.sign_in_status user={membership.user} />
                    </div>
                    <%!-- Per-user runner ACLs (#238): show what runners
                       this member can reach. Empty = all (default).
                       Group/runner scopes appear as inline chips. --%>
                    <div class="mt-1 flex flex-wrap items-center gap-1">
                      <%= case Map.get(@scopes_by_membership, membership.id, []) do %>
                        <% [] -> %>
                          <span class="text-[10px] text-zinc-400">
                            access: all runners
                          </span>
                        <% scopes -> %>
                          <span class="text-[10px] uppercase tracking-wider text-zinc-400">
                            scope:
                          </span>
                          <.chip :for={scope <- scopes} tone={:neutral}>
                            {scope_type_label(scope.scope_type)}: {scope_label(
                              scope,
                              @runner_groups,
                              @runners_by_id
                            )}
                          </.chip>
                      <% end %>
                    </div>
                  </div>
                </div>

                <div class="flex shrink-0 items-center gap-2 pl-14 sm:pl-0">
                  <%= if can_manage?(assigns) and not self_owner?(membership, @current_user.id) and not Accounts.Membership.disabled?(membership) do %>
                    <%!-- A role change is a privilege grant — a dropdown (same skin as
                       the Actions menu beside it) whose items each carry their own
                       confirm, so the dialog fires only when you pick a DIFFERENT
                       role, never just on opening the control. The handler still
                       authorizes (IL-15). --%>
                    <.dropdown
                      class="inline-block shrink-0 text-left"
                      summary_class="rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900"
                      panel_class="z-10 mt-2 w-40 p-1 text-xs shadow-xl"
                    >
                      <:trigger>
                        {String.capitalize(to_string(membership.role))}
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
                        {String.capitalize(role)}
                      </.menu_item>
                    </.dropdown>
                  <% else %>
                    <.chip class="shrink-0">
                      {String.capitalize(to_string(membership.role))}
                    </.chip>
                  <% end %>

                  <.member_actions
                    membership={membership}
                    current_user_id={@current_user.id}
                    can_manage?={can_manage?(assigns)}
                    current_account={@current_account}
                    typed={@typed}
                  />
                </div>
              </div>

              <%!-- Edit form appears inline under the row. No bolted-
                   on table column; just normal flow. --%>
              <div
                :if={@editing_id == membership.id and @edit_form}
                class="mt-4 rounded-lg border border-zinc-800 bg-zinc-900/40 p-4"
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
                  <%!-- Cancel sits next to Save (not pushed right by simple_form's
                       <:actions> justify-between), matching the scope editor below. --%>
                  <div class="flex items-center gap-3 pt-2">
                    <.button phx-disable-with="Saving...">Save</.button>
                    <.button variant="ghost" type="button" phx-click="cancel_edit">
                      Cancel
                    </.button>
                  </div>
                </.simple_form>
              </div>

              <%!-- Inline scope editor — appears under the row when
                   "Set runner scope" is clicked. Two HTML multi-selects
                   (groups + individual runners). Empty selection on
                   both = "all runners" default. --%>
              <div
                :if={@scope_editing_id == membership.id}
                class="mt-4 rounded-lg border border-zinc-800 bg-zinc-900/40 p-4"
              >
                <form phx-submit="save_scopes" class="space-y-4">
                  <input type="hidden" name="membership_id" value={membership.id} />
                  <p class="text-xs text-zinc-400">
                    Restrict this member to specific runner groups or individual runners. Leaving
                    both empty grants access to <strong>all runners</strong> in the account.
                  </p>

                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <label class="block">
                      <span class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
                        Groups
                      </span>
                      <.multi_select
                        name="groups[]"
                        options={
                          Enum.map(@runner_groups, fn g ->
                            %{
                              value: g,
                              label: g,
                              disabled: false,
                              selected:
                                scope_selected?(membership.id, @scopes_by_membership, :group, g)
                            }
                          end)
                        }
                      />
                    </label>

                    <label class="block">
                      <span class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
                        Individual runners
                      </span>
                      <.multi_select
                        name="runners[]"
                        options={
                          Enum.map(@runners_by_id, fn {id, r} ->
                            %{
                              value: id,
                              label: if(r.group, do: "#{r.name} (#{r.group})", else: r.name),
                              disabled: false,
                              selected:
                                scope_selected?(membership.id, @scopes_by_membership, :runner, id)
                            }
                          end)
                        }
                      />
                    </label>
                  </div>

                  <div class="flex items-center gap-3">
                    <.button phx-disable-with="Saving...">Save scope</.button>
                    <.button variant="ghost" type="button" phx-click="cancel_scope_edit">
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
              Use the
              <.chip>Invite</.chip>
              form above to send a magic-link to a new member.
            </.empty_state>
          </:empty>
        </LiveTable.live_table>

        <p :if={not can_manage?(assigns)} class="text-xs text-zinc-500">
          Only owners and admins can invite or manage members. Your role: {@current_role || "—"}.
        </p>
      </div>
    </.dashboard_shell>
    """
  end

  defp show_invite do
    JS.show(
      to: "#invite-panel",
      transition: {"transition-opacity ease-out duration-150", "opacity-0", "opacity-100"}
    )
  end

  defp hide_invite do
    JS.hide(
      to: "#invite-panel",
      transition: {"transition-opacity ease-in duration-100", "opacity-100", "opacity-0"}
    )
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

  defp mfa_badge(assigns) do
    ~H"""
    <.chip title="No two-factor authentication enrolled.">No 2FA</.chip>
    """
  end

  # own row (use Profile) and short-circuited for non-managers.
  attr :membership, :map, required: true
  attr :current_user_id, :string, required: true
  attr :can_manage?, :boolean, required: true
  attr :current_account, :map, required: true
  attr :typed, :string, required: true

  defp member_actions(assigns) do
    ~H"""
    <%= cond do %>
      <% @membership.user_id == @current_user_id -> %>
        <div class="flex shrink-0 items-center gap-2">
          <button
            :if={@membership.user && is_nil(@membership.user.confirmed_at)}
            phx-click="resend_confirmation"
            class="rounded px-2 py-1 text-xs font-medium text-brand-300 ring-1 ring-brand-500/30 hover:bg-brand-500/10"
          >
            Resend confirmation
          </button>
          <span class="text-xs text-zinc-500">you</span>
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
          <.menu_item phx-click="start_edit" phx-value-membership_id={@membership.id}>
            Edit name
          </.menu_item>
          <.menu_item phx-click="start_scope_edit" phx-value-membership_id={@membership.id}>
            Set runner scope
          </.menu_item>
          <.menu_item
            :if={Emisar.Accounts.Membership.disabled?(@membership)}
            tone="success"
            phx-click="reinstate"
            phx-value-membership_id={@membership.id}
          >
            Restore access
          </.menu_item>
          <.menu_item
            :if={not Emisar.Accounts.Membership.disabled?(@membership)}
            tone="caution"
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
            tone="caution"
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
          <div class="my-1 border-t border-zinc-800"></div>
          <%!-- IRREVERSIBLE — typed-confirm modal instead of native
               data-confirm. The button only OPENS the dialog; `remove`
               still fires from Confirm and stays server-authz-gated. --%>
          <.menu_item tone="danger" phx-click={show_confirm_dialog("remove-member-#{@membership.id}")}>
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
    do: "Change #{name}'s role to #{String.capitalize(role)}?"

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
