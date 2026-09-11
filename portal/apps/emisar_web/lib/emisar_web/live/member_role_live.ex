defmodule EmisarWeb.MemberRoleLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Auth, Runners}
  alias EmisarWeb.{MemberErrors, RunnerScope}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Change owner role")
     |> assign(:loading?, true)
     |> assign(:target, nil)
     |> assign(:role, nil)
     |> assign(
       :form,
       to_form(%{"runner_access_mode" => "", "pack_access_mode" => "all"}, as: :access)
     )
     |> assign(:runners, [])
     |> assign(:advertisements, %{})
     |> assign(:runner_load_error?, false)
     |> assign(:pack_load_error?, false)
     |> assign(:error, nil)}
  end

  def handle_params(%{"membership_id" => id, "role" => role}, _uri, socket) do
    if connected?(socket) do
      subject = socket.assigns.current_subject

      with {:ok, %{membership: %{role: :owner} = target, role_editable?: true}} <-
             Accounts.fetch_team_member_facts(id, subject),
           true <- valid_destination?(role, target, subject) do
        {advertisements, pack_error?} =
          if role in ["directory", "billing_manager"],
            do: {%{}, false},
            else: RunnerScope.account_pack_advertisements(subject)

        {runners, runner_error?} =
          if role in ["directory", "billing_manager"],
            do: {[], false},
            else: load_runners(subject)

        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:target, target)
         |> assign(:role, role)
         |> assign(
           :form,
           to_form(%{"runner_access_mode" => "", "pack_access_mode" => "all"}, as: :access)
         )
         |> assign(:error, nil)
         |> assign(:runners, runners)
         |> assign(:advertisements, advertisements)
         |> assign(:runner_load_error?, runner_error?)
         |> assign(:pack_load_error?, pack_error?)}
      else
        _ ->
          {:noreply,
           socket
           |> put_flash(:error, "This owner's role can't be changed here.")
           |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"access" => params}, socket) when is_map(params) do
    if valid_params?(params) do
      {:noreply, socket |> assign(:form, to_form(params, as: :access)) |> assign(:error, nil)}
    else
      {:noreply, assign(socket, :error, "That access selection isn't valid.")}
    end
  end

  def handle_event(
        "save",
        %{"access" => params},
        %{assigns: %{target: %Accounts.Membership{} = target}} = socket
      )
      when is_map(params) do
    if valid_params?(params),
      do: save_role(socket, target, params),
      else: {:noreply, assign(socket, :error, "That access selection isn't valid.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save_role(socket, target, params) do
    socket = assign(socket, :form, to_form(params, as: :access))

    with {:ok, access} <- selected_access(socket, params),
         {:ok, _membership} <- change_role(socket, target, access) do
      {:noreply,
       socket
       |> put_flash(:info, "Role and access updated.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/team")}
    else
      {:error, reason} -> {:noreply, assign(socket, :error, access_error(reason))}
    end
  end

  defp valid_params?(params) do
    Enum.all?(["runner_access_mode", "pack_access_mode"], fn key ->
      is_nil(params[key]) or (is_binary(params[key]) and byte_size(params[key]) <= 32)
    end) and
      Enum.all?(["scope", "pack_scope"], fn key ->
        values = params[key] || []

        is_list(values) and length(values) <= 256 and
          Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 512))
      end)
  end

  defp valid_destination?("directory", %{runner_access_directory_managed: true}, _subject),
    do: true

  defp valid_destination?(_role, %{runner_access_directory_managed: true}, _subject), do: false

  defp valid_destination?(role, _target, subject) do
    role != "owner" and role in Enum.map(Auth.roles(), &Atom.to_string/1) and
      Accounts.subject_can_assign_member_role?(role, subject)
  end

  defp change_role(%{assigns: %{role: "directory"}} = socket, target, :directory),
    do: Accounts.return_owner_to_directory(target, socket.assigns.current_subject)

  defp change_role(socket, target, access) do
    Accounts.update_membership_role(target, socket.assigns.role, socket.assigns.current_subject,
      runner_access: access,
      expected_role: :owner
    )
  end

  defp selected_access(%{assigns: %{role: "directory"}}, %{"runner_access_mode" => "directory"}),
    do: {:ok, :directory}

  defp selected_access(%{assigns: %{role: "directory"}}, _params),
    do: {:error, :owner_demotion_requires_directory}

  defp selected_access(%{assigns: %{role: "billing_manager"}}, %{"runner_access_mode" => "none"}),
    do: Accounts.build_runner_access(:none, [], [])

  defp selected_access(socket, params) do
    allowlist =
      Accounts.runner_access_allowlist(
        socket.assigns.runners,
        Map.keys(socket.assigns.advertisements)
      )

    Accounts.build_runner_access(
      params["runner_access_mode"],
      List.wrap(params["scope"]),
      allowlist,
      params["pack_access_mode"] || "all",
      List.wrap(params["pack_scope"])
    )
  end

  defp access_error(:invalid_runner_access),
    do: "Choose their runner access. For selected access, choose at least one runner or group."

  defp access_error(:invalid_pack_access),
    do: "Choose at least one pack for selected pack access."

  defp access_error(reason), do: MemberErrors.message(reason)

  defp load_runners(subject) do
    case Runners.list_runners_in_action_scope(subject) do
      {:ok, runners} -> {runners, false}
      {:error, _reason} -> {[], true}
    end
  end

  defp change_title(target, "directory"),
    do: "Return #{Accounts.member_display_name(target, target.user)} to directory sync?"

  defp change_title(target, role),
    do: "Change #{Accounts.member_display_name(target, target.user)} to #{Auth.role_label(role)}?"

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
        <.back_link navigate={~p"/app/#{@current_account}/settings/team"}>Team</.back_link>
        Change owner role
      </:title>
      <.loading_state :if={@loading?} />
      <div :if={not @loading? and @target} class="mt-4 max-w-xl">
        <.status_note tone={:amber} icon="state.warning" title={change_title(@target, @role)}>
          They will lose Owner privileges. Their agent credentials and standing approvals will be revoked.
        </.status_note>
        <p :if={@role != "directory"} class="mt-4 text-sm leading-relaxed text-zinc-400">
          {Auth.role_description(@role)}
        </p>
        <.simple_form
          for={@form}
          id="owner-role-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-6 space-y-5"
        >
          <fieldset>
            <legend class="text-sm font-medium text-zinc-300">Access after the change</legend>
            <input type="hidden" name="access[runner_access_mode]" value="" />
            <.access_scope_fields
              runner_mode_name="access[runner_access_mode]"
              runner_mode_value={@form[:runner_access_mode].value}
              runner_scope_name="access[scope][]"
              runner_scope_selected={List.wrap(@form[:scope].value)}
              pack_mode_name="access[pack_access_mode]"
              pack_mode_value={@form[:pack_access_mode].value || "all"}
              pack_scope_name="access[pack_scope][]"
              pack_scope_selected={List.wrap(@form[:pack_scope].value)}
              runners={@runners}
              advertisements={@advertisements}
              runner_load_error?={@runner_load_error?}
              pack_load_error?={@pack_load_error?}
              pack_access?={
                @form[:runner_access_mode].value in ["all", "restricted"] and
                  @role not in ["billing_manager", "directory"]
              }
            >
              <:card
                :if={@role == "directory"}
                value="directory"
                title="Use directory role and access"
              >
                Directory sync will set their role and access. Until it completes, they will be a Viewer with no runner or pack access.
              </:card>
              <:card :if={@role != "directory"} value="none" title="No runners">
                No access to runners or packs.
              </:card>
              <:card
                :if={@role not in ["billing_manager", "directory"]}
                value="all"
                title="All runners"
              >
                Includes every current and future runner in this account.
              </:card>
              <:card
                :if={@role not in ["billing_manager", "directory"]}
                value="restricted"
                title="Selected runners"
              >
                Choose runner groups or individual runners.
              </:card>
            </.access_scope_fields>
          </fieldset>
          <.error :if={@error}>{@error}</.error>
          <:actions>
            <.button tone={:amber} variant={:secondary} phx-disable-with="Changing…">Change role</.button>
            <.button navigate={~p"/app/#{@current_account}/settings/team"} variant={:ghost}>Cancel</.button>
          </:actions>
        </.simple_form>
      </div>
    </.console_shell>
    """
  end
end
