defmodule EmisarWeb.RunnerScope do
  @moduledoc """
  The shared reach pickers — WHICH runners a grant covers, and WHICH packs on
  them.

  The runner picker is ONE grouped, touch-friendly control where a scope is
  chosen from runner GROUPS and, nested beneath each, its RUNNERS — so groups and
  runners live in one place instead of a groups list plus a separate, ungrouped
  runners list. Selecting a group covers every runner in it, so those runners
  render disabled ("via group") — picking them on top would be redundant. The
  pack picker is the flat sibling that narrows the same grant.
  Used by explicit restricted-access controls for team members and SSO mappings.

  A custom checkbox tree (not a native `<select multiple>`): full-row tap targets,
  a hierarchy rail nesting runners under their group, brand-tinted selection — and
  it works on mobile, where a multi-select cannot. Selection travels as
  `"group:<name>"` / `"runner:<id>"` strings in one `scope[]` field, so the caller
  wraps it in a `phx-change` form and hands the checked values to the domain
  (`Emisar.Accounts` / `Emisar.SSO`), which owns what they mean and what a
  subject may actually reach. This module renders and serializes only.
  """
  use Phoenix.Component

  import EmisarWeb.CoreComponents,
    only: [
      callout: 1,
      checkbox: 1,
      choice_cards: 1,
      error: 1,
      input: 1,
      label: 1,
      loading_state: 1
    ]

  alias Emisar.Accounts

  attr :name, :string, required: true, doc: ~s(checkbox field name, e.g. "scope[]")
  attr :runners, :list, required: true, doc: "the account's runners (need id, name, group)"
  attr :selected, :list, default: [], doc: ~s(chosen "group:x"/"runner:id" values)
  attr :label, :string, default: nil
  attr :variant, :atom, default: :standalone, values: [:standalone, :attached]
  attr :submit_error_field, Phoenix.HTML.FormField, default: nil
  attr :submit_error_message, :string, default: nil
  attr :validation_error, :string, default: nil
  attr :loading?, :boolean, default: false
  attr :load_error, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def runner_scope_select(assigns) do
    assigns =
      assigns
      |> assign(:tree, tree(assigns.runners, assigns.selected))
      |> assign(
        :visible_error,
        assigns.validation_error ||
          visible_submit_error(assigns.submit_error_field, assigns.submit_error_message)
      )

    ~H"""
    <div class={[scope_container_class(@variant), @class]} {@rest}>
      <p :if={@label} class="mb-2 text-sm font-medium text-zinc-300">{@label}</p>

      <div :if={@visible_error} class={scope_feedback_class(@variant)}>
        <.error>{@visible_error}</.error>
      </div>
      <div :if={@loading?} class={scope_feedback_class(@variant)}>
        <.loading_state />
      </div>
      <div :if={@load_error} class={scope_feedback_class(@variant)}>
        <.callout tone={:rose}>{@load_error}</.callout>
      </div>

      <div
        :if={not @loading? and is_nil(@load_error) and empty_tree?(@tree)}
        class={scope_empty_class(@variant)}
      >
        No runners registered yet.
      </div>

      <div
        :if={not @loading? and is_nil(@load_error) and not empty_tree?(@tree)}
        class={scope_tree_class(@variant)}
      >
        <div :for={group <- @tree.groups}>
          <.checkbox
            name={@name}
            value={group.value}
            checked={group.selected}
            class={group_row_class(group.selected)}
          >
            <span class="flex-1 truncate font-medium text-zinc-100">{group.name}</span>
            <span class="shrink-0 rounded-full bg-zinc-800/80 px-2 py-0.5 text-[10px] font-medium tabular-nums text-zinc-400">
              {length(group.runners)} {if length(group.runners) == 1, do: "runner", else: "runners"}
            </span>
          </.checkbox>

          <%!-- Runners nested under the group, along a hierarchy rail. When the
               group is picked they're disabled + tagged "via group" — the group
               already covers them, so an individual tick would be redundant. --%>
          <div class="relative ml-5 before:pointer-events-none before:absolute before:bottom-5 before:left-0 before:top-0 before:w-px before:bg-zinc-700/50 before:content-['']">
            <.checkbox
              :for={runner <- group.runners}
              name={@name}
              value={runner.value}
              checked={runner.selected or runner.covered}
              disabled={runner.covered}
              class={runner_row_class(runner.covered)}
            >
              <span class="flex-1 truncate text-zinc-400">{runner.name}</span>
              <span
                :if={runner.covered}
                class="shrink-0 rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400"
              >
                via group
              </span>
            </.checkbox>
          </div>
        </div>

        <div :if={@tree.ungrouped != []}>
          <p class="px-3 pb-1 pt-2.5 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
            Ungrouped
          </p>
          <.checkbox
            :for={runner <- @tree.ungrouped}
            name={@name}
            value={runner.value}
            checked={runner.selected}
            class="flex min-h-10 cursor-pointer select-none items-center gap-3 py-2 pl-3 pr-3 text-xs transition-colors hover:bg-white/[0.04]"
          >
            <span class="flex-1 truncate text-zinc-300">{runner.name}</span>
          </.checkbox>
        </div>

        <%!-- A chosen group or runner the account no longer has: keep it
             visible and TICKED so the operator can see what their rejected
             submission still names, and untick it to move on. --%>
        <div :if={@tree.unavailable != []}>
          <p class="px-3 pb-1 pt-2.5 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
            Unavailable
          </p>
          <.checkbox
            :for={ref <- @tree.unavailable}
            name={@name}
            value={ref.value}
            checked
            class="flex min-h-10 cursor-pointer select-none items-center gap-3 py-2 pl-3 pr-3 text-xs transition-colors hover:bg-white/[0.04]"
          >
            <span class={["flex-1 truncate", unavailable_name_class(ref.kind)]}>{ref.name}</span>
            <span class="shrink-0 rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400">
              unavailable
            </span>
          </.checkbox>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The pack half of a grant form: the mode choice plus, when it is `restricted`,
  the attached pack picker. Renders nothing while the runner mode grants no
  reach — there is nothing to narrow, and the domain drops a pack selection made
  against `none` anyway.

  The copy is shared on purpose: a member grant and a directory grant narrow the
  same way, so they must not drift into two vocabularies.
  """
  attr :runner_mode, :string, required: true, doc: "the runner mode this narrows"
  attr :runner_scope, :list, default: [], doc: ~s(the chosen "group:x"/"runner:id" values)
  attr :runners, :list, required: true, doc: "the account's runners (need id, group)"
  attr :advertisements, :map, required: true, doc: "%{pack_id => [runner_id]} from Catalog"
  attr :variant, :atom, default: :cards, values: [:cards, :select]
  attr :mode_name, :string, required: true, doc: ~s(mode field name, e.g. "pack_access_mode")
  attr :mode_value, :any, required: true
  attr :scope_name, :string, required: true, doc: ~s(checkbox field name, e.g. "pack_scope[]")
  attr :selected, :list, default: [], doc: ~s(chosen "pack:id" values)
  attr :submit_error_field, Phoenix.HTML.FormField, default: nil
  attr :submit_error_message, :string, default: nil
  attr :validation_error, :string, default: nil
  attr :loading?, :boolean, default: false
  attr :load_error, :string, default: nil

  def pack_access_field(assigns) do
    runner_ids = selected_runner_ids(assigns.runners, assigns.runner_mode, assigns.runner_scope)

    assigns =
      assigns
      |> assign(:packs, packs_in_scope(assigns.advertisements, runner_ids, assigns.selected))
      |> assign(:empty_message, pack_empty_message(assigns.runner_mode, runner_ids))

    pack_access_control(assigns)
  end

  defp pack_access_control(%{variant: :select} = assigns) do
    ~H"""
    <div :if={@runner_mode != "none"} class="space-y-2">
      <.input
        type="select"
        name={@mode_name}
        value={@mode_value}
        label="Packs"
        options={[{"All packs", "all"}, {"Selected packs", "restricted"}]}
      />
      <.pack_scope_select
        :if={to_string(@mode_value) == "restricted"}
        name={@scope_name}
        label="Selected packs"
        packs={@packs}
        selected={@selected}
        empty_message={@empty_message}
        validation_error={@validation_error}
      />
    </div>
    """
  end

  defp pack_access_control(assigns) do
    ~H"""
    <div :if={@runner_mode != "none"}>
      <%!-- Named, because two card groups stacked flush read as one long radio
            list: the operator cannot see that the second one is a separate
            decision until they miscount the options. --%>
      <.label variant={:eyebrow}>Packs</.label>
      <div class="mt-2">
        <.choice_cards name={@mode_name} value={@mode_value} attached_value="restricted">
          <:card value="all" title="All packs">
            Every pack on those runners, including ones installed later.
          </:card>
          <:card value="restricted" title="Selected packs">
            Only actions from the packs you name.
          </:card>
        </.choice_cards>

        <.pack_scope_select
          :if={to_string(@mode_value) == "restricted"}
          name={@scope_name}
          variant={:attached}
          packs={@packs}
          selected={@selected}
          empty_message={@empty_message}
          submit_error_field={@submit_error_field}
          submit_error_message={@submit_error_message}
          validation_error={@validation_error}
          loading?={@loading?}
          load_error={@load_error}
        />
      </div>
    </div>
    """
  end

  @doc """
  Runner ids a `"group:x"` / `"runner:id"` selection covers — every runner when
  the grant reaches them all.
  """
  def selected_runner_ids(runners, mode, _selected) when mode in ["all", :all],
    do: Enum.map(runners, & &1.id)

  def selected_runner_ids(runners, _mode, selected) do
    values = MapSet.new(selected)

    for runner <- runners,
        MapSet.member?(values, "runner:" <> runner.id) or
          (is_binary(runner.group) and MapSet.member?(values, "group:" <> runner.group)),
        do: runner.id
  end

  @doc """
  The packs a runner selection actually carries, as `[%{id: _, runner_count: _}]`
  sorted by id. `runner_count` counts only the SELECTED runners advertising the
  pack, so the number means the same thing as the "2 runners" beside a group row
  above it. A pack already chosen stays in the list even when nothing in scope
  advertises it any more, so the operator can see and untick it.
  """
  def packs_in_scope(advertisements, runner_ids, selected \\ []) do
    chosen = MapSet.new(selected)
    scope = MapSet.new(runner_ids)

    advertisements
    |> Enum.map(fn {pack_id, advertising} ->
      %{id: pack_id, runner_count: Enum.count(advertising, &MapSet.member?(scope, &1))}
    end)
    |> Enum.filter(&(&1.runner_count > 0 or MapSet.member?(chosen, "pack:" <> &1.id)))
    |> Enum.sort_by(& &1.id)
  end

  # The runner scope is the prerequisite: while it names nothing, the pack list
  # is empty for a reason the operator can fix upstream, not because the account
  # has no packs.
  defp pack_empty_message(mode, []) when mode not in ["all", :all],
    do: "Choose runners first — the packs they carry appear here."

  defp pack_empty_message(_mode, _runner_ids), do: "No packs on the selected runners."

  attr :name, :string, required: true, doc: ~s(checkbox field name, e.g. "pack_scope[]")
  attr :packs, :list, required: true, doc: "`[%{id: _, runner_count: _}]` from packs_in_scope/3"
  attr :empty_message, :string, default: "No packs on the selected runners."
  attr :selected, :list, default: [], doc: ~s(chosen "pack:id" values)
  attr :label, :string, default: nil
  attr :variant, :atom, default: :standalone, values: [:standalone, :attached]
  attr :submit_error_field, Phoenix.HTML.FormField, default: nil
  attr :submit_error_message, :string, default: nil
  attr :validation_error, :string, default: nil
  attr :loading?, :boolean, default: false
  attr :load_error, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def pack_scope_select(assigns) do
    assigns =
      assigns
      |> assign(:nodes, pack_nodes(assigns.packs, assigns.selected))
      |> assign(
        :visible_error,
        assigns.validation_error ||
          visible_submit_error(assigns.submit_error_field, assigns.submit_error_message)
      )

    ~H"""
    <div class={[scope_container_class(@variant), @class]} {@rest}>
      <p :if={@label} class="mb-2 text-sm font-medium text-zinc-300">{@label}</p>

      <div :if={@visible_error} class={scope_feedback_class(@variant)}>
        <.error>{@visible_error}</.error>
      </div>
      <div :if={@loading?} class={scope_feedback_class(@variant)}>
        <.loading_state />
      </div>
      <div :if={@load_error} class={scope_feedback_class(@variant)}>
        <.callout tone={:rose}>{@load_error}</.callout>
      </div>

      <div
        :if={not @loading? and is_nil(@load_error) and empty_pack_nodes?(@nodes)}
        class={scope_empty_class(@variant)}
      >
        {@empty_message}
      </div>

      <div
        :if={not @loading? and is_nil(@load_error) and not empty_pack_nodes?(@nodes)}
        class={scope_tree_class(@variant)}
      >
        <.checkbox
          :for={pack <- @nodes.available}
          name={@name}
          value={pack.value}
          checked={pack.selected}
          class="flex min-h-10 cursor-pointer select-none items-center gap-3 px-3 py-2 text-xs transition-colors hover:bg-white/[0.04]"
        >
          <span class="flex-1 truncate font-mono text-zinc-300">{pack.name}</span>
          <span class="shrink-0 rounded-full bg-zinc-800/80 px-2 py-0.5 text-[10px] font-medium tabular-nums text-zinc-400">
            {pack.runner_count} {if pack.runner_count == 1, do: "runner", else: "runners"}
          </span>
        </.checkbox>

        <%!-- A chosen pack the account no longer carries: keep it visible and
             TICKED so the operator can see what their rejected submission still
             names, and untick it to move on. --%>
        <div :if={@nodes.unavailable != []}>
          <p class="px-3 pb-1 pt-2.5 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
            Unavailable
          </p>
          <.checkbox
            :for={pack <- @nodes.unavailable}
            name={@name}
            value={pack.value}
            checked
            class="flex min-h-10 cursor-pointer select-none items-center gap-3 px-3 py-2 text-xs transition-colors hover:bg-white/[0.04]"
          >
            <span class="flex-1 truncate font-mono text-zinc-400">{pack.name}</span>
            <span class="shrink-0 rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400">
              unavailable
            </span>
          </.checkbox>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Selection rows for the pack picker: `%{available: [%{name, value, selected,
  runner_count}], unavailable: [%{name, value}]}`. `packs` is what
  `packs_in_scope/3` returned; `selected` is the list of chosen `"pack:id"`
  values, and one no runner in scope carries stays in `unavailable` so the
  operator can see and untick it.
  """
  def pack_nodes(packs, selected) do
    selected_set = MapSet.new(selected)

    available =
      packs |> Enum.reject(&(&1.runner_count == 0)) |> Enum.map(&pack_node(&1, selected_set))

    rendered = MapSet.new(available, & &1.value)

    unavailable =
      selected
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(rendered, &1))
      |> Enum.map(&unavailable_pack_node/1)

    %{available: available, unavailable: unavailable}
  end

  defp pack_node(pack, selected) do
    value = "pack:" <> pack.id

    %{
      name: pack.id,
      value: value,
      runner_count: pack.runner_count,
      selected: MapSet.member?(selected, value)
    }
  end

  defp unavailable_pack_node("pack:" <> pack_id = value), do: %{name: pack_id, value: value}
  defp unavailable_pack_node(value), do: %{name: value, value: value}

  defp empty_pack_nodes?(nodes), do: nodes.available == [] and nodes.unavailable == []

  @doc """
  Nested selection tree for the picker: `%{groups: [%{name, value, selected,
  runners: [%{name, value, selected, covered}]}], ungrouped: [runner…],
  unavailable: [%{kind, name, value}]}`. A runner whose group is in `selected`
  has `covered: true` (the group covers it, so it renders disabled). `selected`
  is the list of chosen `"group:x"`/`"runner:id"`.

  A selected value the current runners don't account for is `unavailable` — a
  group or runner that has since been removed, or one a rejected submission
  still names. It stays in the tree so the operator can see and untick it.
  """
  def tree(runners, selected) do
    selected_set = MapSet.new(selected)

    groups =
      runners |> Enum.map(& &1.group) |> Enum.reject(&blank?/1) |> Enum.uniq() |> Enum.sort()

    group_nodes =
      Enum.map(groups, fn group ->
        group_selected? = MapSet.member?(selected_set, "group:" <> group)

        %{
          name: group,
          value: "group:" <> group,
          selected: group_selected?,
          runners:
            runners
            |> runners_in_group(group)
            |> Enum.map(&runner_node(&1, selected_set, group_selected?))
        }
      end)

    ungrouped_nodes =
      runners |> ungrouped_runners() |> Enum.map(&runner_node(&1, selected_set, false))

    %{
      groups: group_nodes,
      ungrouped: ungrouped_nodes,
      unavailable: unavailable_nodes(selected, group_nodes, ungrouped_nodes)
    }
  end

  defp unavailable_nodes(selected, group_nodes, ungrouped_nodes) do
    rendered =
      group_nodes
      |> Enum.flat_map(&[&1.value | Enum.map(&1.runners, fn runner -> runner.value end)])
      |> Enum.concat(Enum.map(ungrouped_nodes, & &1.value))
      |> MapSet.new()

    selected
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(rendered, &1))
    |> Enum.map(&unavailable_node/1)
  end

  defp unavailable_node("group:" <> group = value), do: %{kind: :group, name: group, value: value}
  defp unavailable_node("runner:" <> id = value), do: %{kind: :runner, name: id, value: value}
  defp unavailable_node(value), do: %{kind: :runner, name: value, value: value}

  defp unavailable_name_class(:group), do: "font-medium text-zinc-100"
  defp unavailable_name_class(:runner), do: "text-zinc-400"

  defp empty_tree?(tree),
    do: tree.groups == [] and tree.ungrouped == [] and tree.unavailable == []

  defp runner_node(runner, selected, covered?) do
    value = "runner:" <> runner.id

    %{
      name: runner.name,
      value: value,
      covered: covered?,
      selected: not covered? and MapSet.member?(selected, value)
    }
  end

  @group_row "relative flex min-h-10 cursor-pointer select-none items-center gap-3 px-3 py-2 text-xs transition-colors after:pointer-events-none after:absolute after:bottom-0 after:left-5 after:top-[calc(50%+0.5rem)] after:w-px after:bg-zinc-700/50 after:content-[''] hover:bg-white/[0.05]"
  defp group_row_class(true), do: @group_row <> " bg-brand-500/[0.07]"
  defp group_row_class(false), do: @group_row <> " bg-white/[0.025]"

  @runner_row "relative flex min-h-10 select-none items-center gap-3 py-2 pl-3 pr-3 text-[11px] transition-colors before:pointer-events-none before:absolute before:left-0 before:top-1/2 before:h-px before:w-3 before:bg-zinc-700/50 before:content-['']"
  defp runner_row_class(true), do: @runner_row <> " opacity-55"
  defp runner_row_class(false), do: @runner_row <> " cursor-pointer hover:bg-white/[0.04]"

  defp scope_container_class(:attached) do
    "overflow-hidden rounded-b-lg border border-t border-white/25 bg-white/[0.04] " <>
      "peer-focus-within/attached-panel:border-x-brand-500/70 " <>
      "peer-focus-within/attached-panel:border-b-brand-500/70"
  end

  defp scope_container_class(:standalone), do: nil

  defp scope_tree_class(:attached) do
    "max-h-72 divide-y divide-zinc-800/70 overflow-y-auto overscroll-contain"
  end

  defp scope_tree_class(:standalone) do
    "max-h-72 divide-y divide-zinc-800/70 overflow-y-auto overscroll-contain rounded-lg bg-zinc-950/40 ring-1 ring-white/[0.08]"
  end

  defp scope_feedback_class(:attached), do: "px-3 pb-3"
  defp scope_feedback_class(:standalone), do: nil

  defp scope_empty_class(:attached), do: "px-3 py-4 text-xs text-zinc-400"

  defp scope_empty_class(:standalone) do
    "rounded-lg bg-black/30 px-3 py-4 text-xs text-zinc-400 ring-1 ring-white/[0.08]"
  end

  defp visible_submit_error(
         %Phoenix.HTML.FormField{
           errors: [_ | _],
           form: %Phoenix.HTML.Form{source: %{action: action}}
         },
         message
       )
       when action in [:insert, :update] and is_binary(message),
       do: message

  defp visible_submit_error(_field, _message), do: nil

  @doc ~s(The `"group:x"`/`"runner:id"` selection strings for a persisted {groups, runner_ids} scope — the selector format Accounts owns and parses back.)
  def to_values(groups, runner_ids),
    do: Accounts.runner_access_selection_values(groups, runner_ids)

  @doc ~s(The `"pack:id"` selection strings for a persisted pack scope.)
  def to_pack_values(pack_ids), do: Accounts.pack_access_selection_values(pack_ids)

  defp runners_in_group(runners, group),
    do: runners |> Enum.filter(&(&1.group == group)) |> Enum.sort_by(& &1.name)

  defp ungrouped_runners(runners),
    do: runners |> Enum.filter(&blank?(&1.group)) |> Enum.sort_by(& &1.name)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
