defmodule EmisarWeb.TeamLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Mailers, Runners}
  alias EmisarWeb.LiveTable
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
     |> assign_form(invite_changeset())}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
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
    value = not socket.assigns.current_account.require_mfa

    cond do
      not Accounts.subject_can_manage_account_security?(socket.assigns.current_subject) ->
        {:noreply, put_flash(socket, :error, "Only the account owner can change this setting.")}

      # Prevent owners from locking themselves out — if they don't have
      # MFA enabled, they can't enforce it (since the enforcement gate
      # would funnel them too).
      value and is_nil(socket.assigns.current_user.mfa_enabled_at) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Enable MFA on your own profile first — otherwise you'd lock yourself out."
         )}

      true ->
        case Accounts.update_account(
               socket.assigns.current_account,
               %{require_mfa: value},
               socket.assigns.current_subject
             ) do
          {:ok, account} ->
            {:noreply,
             socket
             |> assign(:current_account, account)
             |> put_flash(
               :info,
               if(value,
                 do:
                   "Account-wide MFA enforced. Members without MFA will be prompted on next sign-in.",
                 else: "Account-wide MFA requirement turned off."
               )
             )}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, "Only the account owner can change this setting.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update MFA setting.")}
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

  def handle_event("force_password_reset", %{"membership_id" => id}, socket) do
    with_membership(socket, id, fn membership ->
      case Accounts.force_password_reset(membership, socket.assigns.current_subject) do
        :ok -> {:ok, "Password-reset email sent and sessions ended."}
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
  defp error_message(%Ecto.Changeset{}), do: "Could not apply change."
  defp error_message(_), do: "Could not apply change."

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

      # A clean reload can fail too (e.g. a tightened list permission) —
      # degrade to an empty page rather than recursing forever.
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
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:team}
    >
      <:title>Team</:title>
      <:actions :if={can_manage?(assigns)}>
        <.button phx-click={show_invite()} size="md">
          Invite member
        </.button>
      </:actions>

      <%!-- Single-column list. Each row is a member: avatar, name +
           email, role pill, joined, "..." menu. Inline edit form
           opens directly under the row instead of in a bolted-on
           extra table column. --%>
      <.page_container max="4xl">
        <%!-- Security card — account-wide MFA toggle (owner-only) +
             at-a-glance per-member MFA status. Lives at the top because
             this is the highest-leverage account setting on the page;
             everything below is per-member admin. --%>
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h2 class="text-sm font-semibold text-zinc-100">Security</h2>
              <p class="mt-1 text-xs text-zinc-500 leading-relaxed">
                When enforced, members without 2FA are funneled to their profile to set it up
                before they can use the rest of the app. Owners can't enable this until they've
                enrolled themselves — prevents lock-outs.
              </p>
            </div>

            <%= cond do %>
              <% Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                <button
                  type="button"
                  phx-click="toggle_require_mfa"
                  data-confirm={
                    if @current_account.require_mfa,
                      do: "Stop enforcing 2FA account-wide?",
                      else: "Enforce 2FA for everyone on this account?"
                  }
                  class={[
                    "shrink-0 rounded-lg px-3 py-1.5 text-xs font-semibold",
                    if(@current_account.require_mfa,
                      do: "border border-rose-500/40 text-rose-200 hover:bg-rose-500/10",
                      else: "bg-indigo-500 text-zinc-950 hover:bg-indigo-400"
                    )
                  ]}
                >
                  {if @current_account.require_mfa, do: "Stop enforcing 2FA", else: "Enforce 2FA"}
                </button>
              <% true -> %>
                <span class="shrink-0 text-[11px] text-zinc-600">Owner-only</span>
            <% end %>
          </div>

          <%!-- Member status row — shows who's enrolled / not. When
               require_mfa is on, the un-enrolled count gets a loud
               amber chip so the owner sees follow-up at a glance. --%>
          <div class="mt-4 flex flex-wrap items-center gap-2 text-xs">
            <span class="text-zinc-400">
              2FA enrolled: <strong class="text-zinc-100">{@mfa_stats.enrolled}</strong>
              of <strong class="text-zinc-100">{@mfa_stats.total}</strong>
            </span>
            <%= if (n = @mfa_stats.total - @mfa_stats.enrolled) > 0 do %>
              <.chip tone={if @current_account.require_mfa, do: :amber, else: :default}>
                {n} without 2FA
              </.chip>
            <% else %>
              <.chip tone={:emerald}>All members enrolled</.chip>
            <% end %>
            <%= if @current_account.require_mfa do %>
              <.chip tone={:indigo}>Enforced</.chip>
            <% end %>
          </div>
        </section>

        <%!-- Invite panel — collapsed by default; revealed by header
             button. Avoids a permanent "fill out this form" sidebar
             dominating the page when no invite is in flight. --%>
        <div
          :if={can_manage?(assigns)}
          id="invite-panel"
          class="hidden rounded-xl border border-zinc-900 bg-zinc-950/60 p-6"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-base font-semibold text-zinc-100">Invite a teammate</h2>
              <p class="mt-1 text-sm text-zinc-500">
                We'll email a join link for <span class="font-medium text-zinc-300">{@current_account.name}</span>.
              </p>
            </div>
            <button
              type="button"
              phx-click={hide_invite()}
              class="rounded-md p-1 text-zinc-500 hover:bg-zinc-900 hover:text-zinc-200"
              aria-label="Close invite panel"
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
            </button>
          </div>

          <.simple_form
            for={@form}
            id="invite_form"
            phx-change="validate"
            phx-submit="invite"
            class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-[1fr_auto_auto] sm:items-end"
          >
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              placeholder="teammate@company.com"
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
        </div>

        <%!-- Member list — uses LiveTable :cards with overflow={:visible}
             so the per-row `<details>` action dropdown can escape the
             rounded card boundary instead of being clipped. Inline edit
             and scope-edit forms render INSIDE the :item slot below the
             top-line content, keeping the natural flow per row. --%>
        <header class="mb-3 flex items-baseline gap-2">
          <h2 class="text-sm font-semibold text-zinc-100">
            {@metadata.count} {if @metadata.count == 1, do: "member", else: "members"}
          </h2>
        </header>

        <LiveTable.live_table
          layout={:cards}
          id="members"
          path={~p"/app/settings/team"}
          rows={@memberships}
          metadata={@metadata}
          filter_params={@filter_params}
          overflow={:visible}
        >
          <:item :let={membership}>
            <li class="px-5 py-4">
              <div class="flex items-center gap-4">
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
                    <span
                      :if={Accounts.Membership.disabled?(membership)}
                      class="rounded bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-medium text-amber-200 ring-1 ring-amber-500/30"
                    >
                      Suspended
                    </span>
                    <%!-- Unconfirmed = signed up but never clicked the
                         email confirmation link. Useful signal when an
                         admin is wondering why a member can't sign in. --%>
                    <span
                      :if={membership.user && is_nil(membership.user.confirmed_at)}
                      class="rounded bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-medium text-amber-200 ring-1 ring-amber-500/30"
                      title="This user signed up but hasn't confirmed their email."
                    >
                      Unconfirmed
                    </span>
                    <%!-- MFA status. Three states worth distinguishing:
                         (1) enrolled — quiet emerald check, the happy
                         default; (2) not enrolled, account doesn't
                         enforce — neutral grey "No 2FA" hint; (3) not
                         enrolled AND the account requires MFA — LOUD
                         rose, because that user can't sign in right
                         now and an admin should chase them. --%>
                    <.mfa_badge user={membership.user} require_mfa?={@current_account.require_mfa} />
                    <span
                      :if={membership.user_id == @current_user.id}
                      class="rounded bg-indigo-500/15 px-1.5 py-0.5 text-[10px] font-medium text-indigo-200 ring-1 ring-indigo-500/30"
                    >
                      You
                    </span>
                  </div>
                  <div class="truncate text-xs text-zinc-500">
                    {membership.user && membership.user.email} · joined {relative_time(
                      membership.inserted_at
                    )} · {sign_in_label(membership.user)}
                  </div>
                  <%!-- Per-user runner ACLs (#238): show what runners
                       this member can reach. Empty = all (default).
                       Group/runner scopes appear as inline chips. --%>
                  <div class="mt-1 flex flex-wrap items-center gap-1">
                    <%= case Map.get(@scopes_by_membership, membership.id, []) do %>
                      <% [] -> %>
                        <span class="text-[10px] text-zinc-600">
                          access: all runners
                        </span>
                      <% scopes -> %>
                        <span class="text-[10px] uppercase tracking-wider text-zinc-600">
                          scope:
                        </span>
                        <.chip :for={scope <- scopes} tone={:indigo}>
                          {scope.scope_type}: {scope_label(scope, @runner_groups, @runners_by_id)}
                        </.chip>
                    <% end %>
                  </div>
                </div>

                <%= if can_manage?(assigns) and not self_owner?(membership, @current_user.id) and not Accounts.Membership.disabled?(membership) do %>
                  <%!-- A role change is a privilege grant — confirm it like every
                       other team action (suspend/remove/…), which this select alone
                       lacked. The handler still authorizes (IL-15); this only stops
                       an accidental one-click escalation. The option `selected` binds
                       to the true role, so a cancelled change self-heals to server
                       truth on the next render. --%>
                  <form
                    phx-change="change_role"
                    class="shrink-0"
                    data-confirm={"Change #{(membership.user && (membership.user.full_name || membership.user.email)) || "this member"}'s role? Admins and owners can manage members and runners; only owners manage billing."}
                  >
                    <input type="hidden" name="membership_id" value={membership.id} />
                    <select
                      name="role"
                      class="rounded-lg border-0 bg-zinc-900 px-2 py-1 text-xs text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
                    >
                      <option :for={r <- @roles} value={r} selected={to_string(membership.role) == r}>
                        {String.capitalize(r)}
                      </option>
                    </select>
                  </form>
                <% else %>
                  <span class="shrink-0 rounded-md bg-zinc-900 px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800">
                    {String.capitalize(to_string(membership.role))}
                  </span>
                <% end %>

                <.member_actions
                  membership={membership}
                  current_user_id={@current_user.id}
                  can_manage?={can_manage?(assigns)}
                />
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
                    update their own sign-in email (with a current-
                    password check) on their Profile page.
                  </p>
                  <:actions>
                    <.button phx-disable-with="Saving...">Save</.button>
                    <.button variant="ghost" type="button" phx-click="cancel_edit">
                      Cancel
                    </.button>
                  </:actions>
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
                      <span class="text-xs font-medium uppercase tracking-wider text-zinc-400">
                        Groups
                      </span>
                      <select
                        name="groups[]"
                        multiple
                        size={min(max(length(@runner_groups), 3), 6)}
                        class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-2 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
                      >
                        <option
                          :for={g <- @runner_groups}
                          value={g}
                          selected={scope_selected?(membership.id, @scopes_by_membership, :group, g)}
                        >
                          {g}
                        </option>
                      </select>
                      <p class="mt-1 text-[10px] text-zinc-500">
                        Cmd/Ctrl-click to select multiple.
                      </p>
                    </label>

                    <label class="block">
                      <span class="text-xs font-medium uppercase tracking-wider text-zinc-400">
                        Individual runners
                      </span>
                      <select
                        name="runners[]"
                        multiple
                        size={min(max(map_size(@runners_by_id), 3), 6)}
                        class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-2 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
                      >
                        <option
                          :for={{id, r} <- @runners_by_id}
                          value={id}
                          selected={
                            scope_selected?(membership.id, @scopes_by_membership, :runner, id)
                          }
                        >
                          {r.name} <span :if={r.group}>({r.group})</span>
                        </option>
                      </select>
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
            <%!-- This branch is technically defensive — the current user is
                 always a member of the account they're viewing, so an
                 entirely empty list shouldn't happen. Keep meaningful
                 copy anyway so it can never accidentally land as a
                 mystery blank panel. --%>
            <div class="mx-auto max-w-md">
              <.icon name="hero-users" class="mx-auto h-8 w-8 text-zinc-700" />
              <p class="mt-3 text-zinc-300">No team members yet.</p>
              <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                Use the
                <span class="rounded bg-zinc-900 px-1.5 py-0.5 text-[11px] font-medium text-zinc-300">
                  Invite
                </span>
                form above to send a magic-link to a teammate.
              </p>
            </div>
          </:empty>
        </LiveTable.live_table>

        <p :if={not can_manage?(assigns)} class="text-xs text-zinc-500">
          Only owners and admins can invite or manage members. Your role: {@current_role || "—"}.
        </p>
      </.page_container>
    </.dashboard_shell>
    """
  end

  defp show_invite,
    do:
      JS.show(
        to: "#invite-panel",
        transition: {"transition-all ease-out duration-150", "opacity-0", "opacity-100"}
      )

  defp hide_invite,
    do:
      JS.hide(
        to: "#invite-panel",
        transition: {"transition-all ease-in duration-100", "opacity-100", "opacity-0"}
      )

  # Inline action menu for a single member row. Hidden for the actor's
  attr :user, :map, default: nil
  attr :require_mfa?, :boolean, required: true

  defp mfa_badge(%{user: %{mfa_enabled_at: %DateTime{}}} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 rounded bg-emerald-500/15 px-1.5 py-0.5 text-[10px] font-medium text-emerald-200 ring-1 ring-emerald-500/30"
      title="Two-factor authentication is enrolled."
    >
      <.icon name="hero-shield-check" class="h-3 w-3" /> 2FA
    </span>
    """
  end

  defp mfa_badge(%{require_mfa?: true} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 rounded bg-rose-500/15 px-1.5 py-0.5 text-[10px] font-semibold text-rose-200 ring-1 ring-rose-500/40"
      title="Account requires 2FA but this user hasn't enrolled. They can't sign in until they do."
    >
      <.icon name="hero-shield-exclamation" class="h-3 w-3" /> 2FA required
    </span>
    """
  end

  defp mfa_badge(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] font-medium text-zinc-400 ring-1 ring-zinc-700"
      title="No two-factor authentication enrolled."
    >
      No 2FA
    </span>
    """
  end

  # own row (use Profile) and short-circuited for non-managers.
  attr :membership, :map, required: true
  attr :current_user_id, :string, required: true
  attr :can_manage?, :boolean, required: true

  defp member_actions(assigns) do
    ~H"""
    <%= cond do %>
      <% @membership.user_id == @current_user_id -> %>
        <div class="flex shrink-0 items-center gap-2">
          <button
            :if={@membership.user && is_nil(@membership.user.confirmed_at)}
            phx-click="resend_confirmation"
            class="rounded px-2 py-1 text-xs font-medium text-indigo-300 ring-1 ring-indigo-500/30 hover:bg-indigo-500/10"
          >
            Resend confirmation
          </button>
          <span class="text-xs text-zinc-500">you</span>
        </div>
      <% not @can_manage? -> %>
        <span></span>
      <% true -> %>
        <details class="group relative inline-block text-left">
          <summary class="cursor-pointer list-none rounded px-2 py-1 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800 hover:bg-zinc-900 [&::-webkit-details-marker]:hidden [&::marker]:hidden">
            Actions
            <span class="text-zinc-500 group-open:hidden">▾</span><span class="hidden text-zinc-500 group-open:inline">▴</span>
          </summary>
          <div class="absolute right-0 z-10 mt-2 w-56 rounded-lg border border-zinc-800 bg-zinc-950 p-1 text-xs shadow-xl">
            <button
              phx-click="start_edit"
              phx-value-membership_id={@membership.id}
              class="block w-full rounded px-3 py-2 text-left text-zinc-300 hover:bg-zinc-900"
            >
              Edit name
            </button>
            <button
              phx-click="start_scope_edit"
              phx-value-membership_id={@membership.id}
              class="block w-full rounded px-3 py-2 text-left text-zinc-300 hover:bg-zinc-900"
            >
              Set runner scope
            </button>
            <%= if Emisar.Accounts.Membership.disabled?(@membership) do %>
              <button
                phx-click="reinstate"
                phx-value-membership_id={@membership.id}
                class="block w-full rounded px-3 py-2 text-left text-emerald-300 hover:bg-emerald-500/10"
              >
                Restore access
              </button>
            <% else %>
              <button
                phx-click="suspend"
                phx-value-membership_id={@membership.id}
                data-confirm="Suspend this member? They will be signed out and can't sign back in until restored."
                class="block w-full rounded px-3 py-2 text-left text-amber-300 hover:bg-amber-500/10"
              >
                Suspend access
              </button>
            <% end %>
            <button
              phx-click="force_password_reset"
              phx-value-membership_id={@membership.id}
              data-confirm="Email them a password-reset link and sign out every session?"
              class="block w-full rounded px-3 py-2 text-left text-zinc-300 hover:bg-zinc-900"
            >
              Force password reset
            </button>
            <button
              phx-click="end_sessions"
              phx-value-membership_id={@membership.id}
              data-confirm="End every active session for this member?"
              class="block w-full rounded px-3 py-2 text-left text-zinc-300 hover:bg-zinc-900"
            >
              End all sessions
            </button>
            <div class="my-1 border-t border-zinc-800"></div>
            <button
              phx-click="remove"
              phx-value-membership_id={@membership.id}
              data-confirm={"Remove #{(@membership.user && @membership.user.email) || "this member"} from the team? This is permanent: they lose access immediately, their role and runner scopes are deleted, and they'd need a fresh invite to return. (Suspend instead to keep their access reversible.)"}
              class="block w-full rounded px-3 py-2 text-left text-rose-300 hover:bg-rose-500/10"
            >
              Remove from team
            </button>
          </div>
        </details>
    <% end %>
    """
  end

  defp self_owner?(%Accounts.Membership{user_id: uid, role: :owner}, user_id) when uid == user_id,
    do: true

  defp self_owner?(_, _), do: false

  # Two cases worth surfacing to admins: "active in the last 90 days"
  # is a no-op (don't clutter the row), "never signed in" hints at a
  # pending invite, and a stale last-sign-in flags a candidate for
  # cleanup. Long-form so it reads in the row's secondary line.
  defp sign_in_label(%{last_sign_in_at: nil}), do: "never signed in"

  defp sign_in_label(%{last_sign_in_at: %DateTime{} = ts}),
    do: "last sign-in #{relative_time(ts)}"

  defp sign_in_label(_), do: "—"
end
