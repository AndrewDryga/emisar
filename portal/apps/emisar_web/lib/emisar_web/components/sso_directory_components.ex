defmodule EmisarWeb.SSODirectoryComponents do
  @moduledoc """
  The directory half of the SSO settings page: the Groups & access editor and
  the synced-members list, with the small copy helpers both use.

  Split out of `sso_settings_live.ex`, which was 4,249 lines and 44 event
  handlers — the most of any module in the app — even though these sections
  were already separate function components with their own state prefixes and
  their own event families. This is a VIEW split: every `handle_event` stays
  in the LiveView, because they own socket state. What moved is the markup and
  the words.
  """
  use Phoenix.Component
  use Gettext, backend: EmisarWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.CoreComponents
  import EmisarWeb.DomainComponents
  import EmisarWeb.TimeHelpers
  import EmisarWeb.RunnerScope, only: [runner_scope_select: 1]
  alias Emisar.{Accounts, SSO}
  alias EmisarWeb.{DirectoryGroups, GroupAccessForm, LiveTable, RoleCopy, RunnerScope}
  alias Phoenix.LiveView.JS

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
  def group_access_section(assigns) do
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

  def group_access_facts(assigns) do
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

  def reset_group_access_button(assigns) do
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

  def runner_access_mapping_fields(assigns) do
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
  def group_picker(assigns) do
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

  def synced_members_section(assigns) do
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

  def role_lock_tip(true), do: "Role is managed by directory sync — set it in Groups & access"

  def role_lock_tip(false),
    do: "Role is managed by directory sync — change this member's groups in your IdP"

  def role_label(role), do: Emisar.Auth.role_label(role)

  def members_label(1), do: "1 member"
  def members_label(count), do: "#{count} members"

  def mapping_runner_reach_phrase(:none), do: "None"
  def mapping_runner_reach_phrase(:all), do: "All"
  def mapping_runner_reach_phrase(:restricted), do: nil

  # Groups lead — a group is the wider grant, so the visible tags start there.
  def access_scope_tag_items(access) do
    Enum.map(access.groups, &{:group, &1}) ++
      Enum.map(access.runner_ids, &{:runner, &1})
  end
end
