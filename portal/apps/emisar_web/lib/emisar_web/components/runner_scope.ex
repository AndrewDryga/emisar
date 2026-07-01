defmodule EmisarWeb.RunnerScope do
  @moduledoc """
  The shared runner-scope picker: ONE `<select multiple>` listing runner GROUPS
  and, nested beneath each, its RUNNERS — so a scope is chosen in a single
  grouped control instead of a groups list plus a separate, ungrouped runners
  list. Selecting a group covers every runner in it, so those runners render
  disabled ("via group") — picking them on top would be redundant. Used by the
  team member scope editor and the MCP-key scope picker; both read the selection
  back with `parse/2`.

  Selection travels as `"group:<name>"` / `"runner:<id>"` strings so groups and
  runners share one multi-select field. Empty selection = all runners (the
  default) — the caller's copy states that.
  """
  use Phoenix.Component
  import EmisarWeb.CoreComponents, only: [multi_select: 1]

  # Non-breaking spaces so the browser keeps the indent (ASCII whitespace in an
  # <option> is stripped), nesting each runner under its group — same trick the
  # policies target picker uses.
  @indent "    "

  attr :name, :string, required: true, doc: ~s(multi-select field name, e.g. "scope[]")
  attr :runners, :list, required: true, doc: "the account's runners (need id, name, group)"
  attr :selected, :list, default: [], doc: ~s(chosen "group:x"/"runner:id" values)
  attr :label, :string, default: nil
  attr :rest, :global

  def runner_scope_select(assigns) do
    ~H"""
    <.multi_select name={@name} label={@label} options={options(@runners, @selected)} {@rest} />
    """
  end

  @doc """
  Option tree for the scope `<select multiple>`: each group (selectable) with its
  runners indented beneath, then any ungrouped runners under a disabled header. A
  runner whose group is in `selected` is disabled and tagged "via group" — the
  group already covers it. `selected` is the list of chosen `"group:x"`/`"runner:id"`.
  """
  def options(runners, selected) do
    selected = MapSet.new(selected)

    groups =
      runners |> Enum.map(& &1.group) |> Enum.reject(&blank?/1) |> Enum.uniq() |> Enum.sort()

    grouped =
      Enum.flat_map(groups, fn group ->
        group_selected? = MapSet.member?(selected, "group:" <> group)

        header = %{
          value: "group:" <> group,
          label: group,
          disabled: false,
          selected: group_selected?
        }

        runner_opts =
          runners
          |> runners_in_group(group)
          |> Enum.map(&runner_option(&1, selected, group_selected?))

        [header | runner_opts]
      end)

    case ungrouped_runners(runners) do
      [] ->
        grouped

      ungrouped ->
        header = %{value: "", label: "Ungrouped", disabled: true, selected: false}
        grouped ++ [header | Enum.map(ungrouped, &runner_option(&1, selected, false))]
    end
  end

  defp runner_option(runner, selected, group_selected?) do
    value = "runner:" <> runner.id

    %{
      value: value,
      label: @indent <> runner.name <> if(group_selected?, do: " — via group", else: ""),
      disabled: group_selected?,
      selected: not group_selected? and MapSet.member?(selected, value)
    }
  end

  @doc """
  Parse the multi-select values back to `%{groups: [name], runner_ids: [id]}`,
  allowlisted against `runners` (a crafted POST can't smuggle another account's
  ids/groups — IL-15), with any runner already covered by a selected group
  dropped (redundant). Empty both = "all runners".
  """
  def parse(values, runners) do
    valid_groups = runners |> Enum.map(& &1.group) |> Enum.reject(&blank?/1) |> MapSet.new()
    by_id = Map.new(runners, &{&1.id, &1})

    groups =
      for "group:" <> group <- values, MapSet.member?(valid_groups, group), uniq: true, do: group

    selected_groups = MapSet.new(groups)

    runner_ids =
      for "runner:" <> id <- values,
          Map.has_key?(by_id, id),
          not MapSet.member?(selected_groups, by_id[id].group),
          uniq: true,
          do: id

    %{groups: groups, runner_ids: runner_ids}
  end

  @doc ~s(The `"group:x"`/`"runner:id"` selection strings for a persisted {groups, runner_ids} scope.)
  def to_values(groups, runner_ids),
    do: Enum.map(groups, &("group:" <> &1)) ++ Enum.map(runner_ids, &("runner:" <> &1))

  defp runners_in_group(runners, group),
    do: runners |> Enum.filter(&(&1.group == group)) |> Enum.sort_by(& &1.name)

  defp ungrouped_runners(runners),
    do: runners |> Enum.filter(&blank?(&1.group)) |> Enum.sort_by(& &1.name)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
