defmodule EmisarWeb.RunnerScope do
  @moduledoc """
  The shared runner-scope picker: ONE grouped, touch-friendly control where a
  scope is chosen from runner GROUPS and, nested beneath each, its RUNNERS — so
  groups and runners live in one place instead of a groups list plus a separate,
  ungrouped runners list. Selecting a group covers every runner in it, so those
  runners render disabled ("via group") — picking them on top would be redundant.
  Used by explicit restricted-access controls for team members and SSO mappings;
  reads the selection back with `parse/2`.

  A custom checkbox tree (not a native `<select multiple>`): full-row tap targets,
  a hierarchy rail nesting runners under their group, brand-tinted selection — and
  it works on mobile, where a multi-select cannot. Selection travels as
  `"group:<name>"` / `"runner:<id>"` strings in one `scope[]` field, so the caller
  wraps it in a `phx-change` form and parses the checked values with `parse/2`.
  An empty selection is invalid restricted access; the surrounding mode control
  owns the separate no-access and all-runners choices.
  """
  use Phoenix.Component
  import EmisarWeb.CoreComponents, only: [callout: 1, checkbox: 1, error: 1, loading_state: 1]

  attr :name, :string, required: true, doc: ~s(checkbox field name, e.g. "scope[]")
  attr :runners, :list, required: true, doc: "the account's runners (need id, name, group)"
  attr :selected, :list, default: [], doc: ~s(chosen "group:x"/"runner:id" values)
  attr :label, :string, default: nil
  attr :variant, :atom, default: :standalone, values: [:standalone, :attached]
  attr :submit_error_field, Phoenix.HTML.FormField, default: nil
  attr :submit_error_message, :string, default: nil
  attr :loading?, :boolean, default: false
  attr :load_error, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def runner_scope_select(assigns) do
    assigns =
      assigns
      |> assign(:tree, tree(assigns.runners, assigns.selected))
      |> assign(
        :visible_submit_error,
        visible_submit_error(assigns.submit_error_field, assigns.submit_error_message)
      )

    ~H"""
    <div class={[scope_container_class(@variant), @class]} {@rest}>
      <p :if={@label} class="mb-2 text-sm font-medium text-zinc-300">{@label}</p>

      <div :if={@visible_submit_error} class={scope_feedback_class(@variant)}>
        <.error>{@visible_submit_error}</.error>
      </div>
      <div :if={@loading?} class={scope_feedback_class(@variant)}>
        <.loading_state />
      </div>
      <div :if={@load_error} class={scope_feedback_class(@variant)}>
        <.callout tone={:rose}>{@load_error}</.callout>
      </div>

      <div
        :if={not @loading? and is_nil(@load_error) and @runners == []}
        class={scope_empty_class(@variant)}
      >
        No runners registered yet.
      </div>

      <div
        :if={not @loading? and is_nil(@load_error) and @runners != []}
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
      </div>
    </div>
    """
  end

  @doc """
  Nested selection tree for the picker: `%{groups: [%{name, value, selected,
  runners: [%{name, value, selected, covered}]}], ungrouped: [runner…]}`. A
  runner whose group is in `selected` has `covered: true` (the group covers it,
  so it renders disabled). `selected` is the list of chosen `"group:x"`/`"runner:id"`.
  """
  def tree(runners, selected) do
    selected = MapSet.new(selected)

    groups =
      runners |> Enum.map(& &1.group) |> Enum.reject(&blank?/1) |> Enum.uniq() |> Enum.sort()

    group_nodes =
      Enum.map(groups, fn group ->
        group_selected? = MapSet.member?(selected, "group:" <> group)

        %{
          name: group,
          value: "group:" <> group,
          selected: group_selected?,
          runners:
            runners
            |> runners_in_group(group)
            |> Enum.map(&runner_node(&1, selected, group_selected?))
        }
      end)

    %{
      groups: group_nodes,
      ungrouped: runners |> ungrouped_runners() |> Enum.map(&runner_node(&1, selected, false))
    }
  end

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

  @doc """
  Parse the checked scope values back to `{:ok, %{groups: [name], runner_ids: [id]}}`,
  allowlisted against `runners` (a crafted POST can't smuggle another account's
  ids/groups — IL-15), with any runner already covered by a selected group
  dropped (redundant). An empty list remains an empty selection; the caller's
  explicit mode decides `none`/`all`, while `restricted` rejects it. Malformed or
  unknown values return `{:error, :invalid}` so they cannot widen access.
  """
  def parse(values, runners) when is_list(values) do
    valid_groups = runners |> Enum.map(& &1.group) |> Enum.reject(&blank?/1) |> MapSet.new()
    by_id = Map.new(runners, &{&1.id, &1})

    if valid_scope_values?(values, valid_groups, by_id) do
      groups =
        for "group:" <> group <- values,
            MapSet.member?(valid_groups, group),
            uniq: true,
            do: group

      selected_groups = MapSet.new(groups)

      runner_ids =
        for "runner:" <> id <- values,
            Map.has_key?(by_id, id),
            not MapSet.member?(selected_groups, by_id[id].group),
            uniq: true,
            do: id

      {:ok, %{groups: groups, runner_ids: runner_ids}}
    else
      {:error, :invalid}
    end
  end

  def parse(_values, _runners), do: {:error, :invalid}

  @doc ~s(The `"group:x"`/`"runner:id"` selection strings for a persisted {groups, runner_ids} scope.)
  def to_values(groups, runner_ids),
    do: Enum.map(groups, &("group:" <> &1)) ++ Enum.map(runner_ids, &("runner:" <> &1))

  defp runners_in_group(runners, group),
    do: runners |> Enum.filter(&(&1.group == group)) |> Enum.sort_by(& &1.name)

  defp ungrouped_runners(runners),
    do: runners |> Enum.filter(&blank?(&1.group)) |> Enum.sort_by(& &1.name)

  defp valid_scope_values?(values, valid_groups, by_id) do
    Enum.all?(values, fn
      "group:" <> group -> MapSet.member?(valid_groups, group)
      "runner:" <> id -> Map.has_key?(by_id, id)
      _ -> false
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
