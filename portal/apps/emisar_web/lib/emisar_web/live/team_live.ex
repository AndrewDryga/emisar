defmodule EmisarWeb.TeamLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Mailers}
  alias Emisar.Accounts.Membership
  alias EmisarWeb.Permissions

  @roles ~w(owner admin operator viewer)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Team")
     |> assign(:roles, @roles)
     |> assign_form(default_params())
     |> load()}
  end

  def handle_event("validate", %{"invite" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("invite", %{"invite" => params}, socket) do
    if can_manage?(socket) do
      email = String.trim(params["email"] || "")
      role = params["role"] || "operator"

      cond do
        email == "" ->
          {:noreply, put_flash(socket, :error, "Email is required.")}

        role not in @roles ->
          {:noreply, put_flash(socket, :error, "Unknown role.")}

        true ->
          do_invite(socket, email, role)
      end
    else
      {:noreply, put_flash(socket, :error, "Only owners and admins can invite members.")}
    end
  end

  def handle_event("change_role", %{"membership_id" => id, "role" => role}, socket) do
    cond do
      role not in @roles ->
        {:noreply, put_flash(socket, :error, "Unknown role.")}

      true ->
        case Enum.find(socket.assigns.memberships, &(&1.id == id)) do
          nil ->
            {:noreply, socket}

          %Membership{} = m ->
            case Accounts.update_membership_role(m, role, socket.assigns.current_user.id) do
              {:ok, _updated} ->
                {:noreply, socket |> put_flash(:info, "Role updated.") |> load()}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, role_error_message(reason))}
            end
        end
    end
  end

  def handle_event("remove", %{"membership_id" => id}, socket) do
    case Enum.find(socket.assigns.memberships, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %Membership{} = m ->
        case Accounts.delete_membership(m, socket.assigns.current_user.id) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Member removed.") |> load()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, role_error_message(reason))}

          %Membership{} = _stale ->
            {:noreply, socket |> put_flash(:info, "Member removed.") |> load()}
        end
    end
  end

  defp role_error_message(:unauthorized), do: "Only owners and admins can change membership."
  defp role_error_message(:owner_required), do: "Only an existing owner can grant or revoke owner."
  defp role_error_message(:last_owner), do: "Can't remove or demote the last owner. Promote someone else first."
  defp role_error_message(:cannot_self_promote), do: "Promote someone else first — you can't promote yourself."
  defp role_error_message(%Ecto.Changeset{}), do: "Could not update role."
  defp role_error_message(_), do: "Could not update role."

  defp do_invite(socket, email, role) do
    account = socket.assigns.current_account
    inviter = socket.assigns.current_user

    case Accounts.invite_user_to_account(account.id, email, role, inviter.id) do
      {:ok, %{user: user, invitation_token: token}} ->
        _ = Mailers.UserNotifier.deliver_account_invitation(user, inviter, account, token)

        {:noreply,
         socket
         |> put_flash(:info, "Invited #{email}.")
         |> assign_form(default_params())
         |> load()}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, "#{email} is already a member.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not send invitation.")}
    end
  end

  defp load(socket) do
    memberships = Accounts.list_memberships_for_account(socket.assigns.current_account.id)

    socket
    |> assign(:memberships, memberships)
    |> assign(:current_role, current_role(memberships, socket.assigns.current_user.id))
  end

  defp current_role(memberships, user_id) do
    case Enum.find(memberships, &(&1.user_id == user_id)) do
      nil -> nil
      %Membership{role: role} -> role
    end
  end

  # Mirrors the central Permissions module, but accepts the assigns map
  # directly so it can be called from inside HEEx templates without a
  # full socket.
  defp can_manage?(socket_or_assigns), do: Permissions.can?(socket_or_assigns, :manage_team)

  defp default_params, do: %{"email" => "", "role" => "operator"}

  defp assign_form(socket, params) do
    assign(socket, :form, to_form(params, as: "invite"))
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:team}
    >
      <:title>Team</:title>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card class="lg:col-span-1">
          <.section_header title="Invite a teammate" />
          <p class="mt-1 text-xs text-zinc-500">
            They will receive an email with a link to join <span class="font-semibold">{@current_account.name}</span>.
          </p>

          <%= if can_manage?(assigns) do %>
            <.simple_form for={@form} id="invite_form" phx-change="validate" phx-submit="invite">
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
                <.button phx-disable-with="Sending..." class="w-full">
                  Send invitation
                </.button>
              </:actions>
            </.simple_form>
          <% else %>
            <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
              Only owners and admins can invite new members. Your current role: {@current_role || "—"}.
            </p>
          <% end %>
        </.card>

        <.card class="lg:col-span-2">
          <.section_header title="Members" />

          <div class="mt-4">
            <.list_table id="memberships" rows={@memberships}>
              <:col :let={m} label="Member">
                <div class="font-medium text-zinc-200">
                  {(m.user && (m.user.full_name || m.user.email)) || "—"}
                </div>
                <div class="text-xs text-zinc-500">{m.user && m.user.email}</div>
              </:col>
              <:col :let={m} label="Role">
                <%= if can_manage?(assigns) and not self_owner?(m, @current_user.id) do %>
                  <form phx-change="change_role" class="inline-flex">
                    <input type="hidden" name="membership_id" value={m.id} />
                    <select
                      name="role"
                      class="rounded-lg border-0 bg-zinc-900 px-2 py-1 text-xs text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
                    >
                      <option :for={r <- @roles} value={r} selected={m.role == r}>{String.capitalize(r)}</option>
                    </select>
                  </form>
                <% else %>
                  <span class="rounded bg-zinc-900 px-2 py-0.5 text-xs font-medium text-zinc-300 ring-1 ring-zinc-800">
                    {String.capitalize(m.role)}
                  </span>
                <% end %>
              </:col>
              <:col :let={m} label="Joined">
                <span class="text-xs text-zinc-400">{relative_time(m.inserted_at)}</span>
              </:col>
              <:action :let={m}>
                <%= cond do %>
                  <% m.user_id == @current_user.id and m.role == "owner" -> %>
                    <span class="text-xs text-zinc-500">you</span>
                  <% can_manage?(assigns) -> %>
                    <button
                      phx-click="remove"
                      phx-value-membership_id={m.id}
                      data-confirm={"Remove #{(m.user && m.user.email) || "this member"} from the team?"}
                      class="rounded px-2 py-1 text-xs font-medium text-rose-300 ring-1 ring-rose-500/30 hover:bg-rose-500/10"
                    >
                      Remove
                    </button>
                  <% true -> %>
                    <span></span>
                <% end %>
              </:action>
            </.list_table>
          </div>
        </.card>
      </div>
    </.dashboard_shell>
    """
  end

  defp self_owner?(%Membership{user_id: uid, role: "owner"}, user_id) when uid == user_id, do: true
  defp self_owner?(_, _), do: false

end
