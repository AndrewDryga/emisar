defmodule EmisarWeb.RunbookEditorCatalog do
  @moduledoc """
  The runbook editor's bounded projection of the current fleet catalog.

  Targets are selected first. The action picker then exposes only pack/action
  pairs advertised by every resolved runner in that target set. The compiler
  remains authoritative for trust, contract compatibility, and publication.
  """

  alias Emisar.Runners
  alias EmisarWeb.RunbookDraft

  @runner_indent "\u00A0\u00A0\u00A0\u00A0"

  @doc "Build the editor projection from the two complete, account-scoped reads."
  def build(runner_actions, runners) when is_list(runner_actions) and is_list(runners) do
    targets = eligible_targets(runners)

    %{
      actions: action_index(runner_actions, targets.runner_ids),
      target_labels: targets.labels,
      target_options: targets.options,
      target_runner_ids: targets.runner_ids
    }
  end

  @doc "Return the target picker choices, including unavailable selected refs."
  def target_options(catalog, selected_refs) do
    selected = MapSet.new(selected_refs)

    options =
      Enum.map(catalog.target_options, fn option ->
        %{option | selected: option.value in selected_refs}
      end)

    missing =
      selected
      |> MapSet.difference(MapSet.new(options, & &1.value))
      |> Enum.sort()
      |> Enum.map(fn ref ->
        %{
          value: ref,
          label: target_label(catalog, ref),
          disabled: false,
          selected: true,
          unavailable: true
        }
      end)

    options ++ missing
  end

  @doc "Human label for one tagged target reference."
  def target_label(catalog, ref), do: catalog.target_labels[ref] || fallback_target_label(ref)

  @doc "Action choices available on every runner resolved from the selected targets."
  def action_options(catalog, selected_refs, selected_value) do
    targets_resolved? = targets_resolved?(catalog, selected_refs)
    runner_ids = selected_runner_ids(catalog, selected_refs)

    options =
      catalog.actions
      |> Enum.filter(fn {_value, action} ->
        runner_ids != [] and Enum.all?(runner_ids, &MapSet.member?(action.runner_ids, &1))
      end)
      |> Enum.map(fn {value, action} ->
        %{
          value: value,
          label: action.action_id,
          description: action_description(action),
          search: action_search(action),
          pack_id: action.pack_id,
          disabled: false,
          selected: value == selected_value
        }
      end)
      |> Enum.sort_by(& &1.label)

    if selected_value in [nil, ""] or Enum.any?(options, &(&1.value == selected_value)) do
      options
    else
      [
        %{
          value: selected_value,
          label: saved_action_label(selected_value),
          description:
            if(targets_resolved?,
              do: "Unavailable on one or more selected runners",
              else: "Saved action"
            ),
          search: selected_value,
          pack_id: elem(split_action_value(selected_value), 0),
          unavailable: targets_resolved?,
          disabled: true,
          selected: true
        }
        | options
      ]
    end
  end

  @doc "Whether every selected target currently resolves to one or more eligible runners."
  def targets_resolved?(_catalog, []), do: false

  def targets_resolved?(catalog, refs) do
    Enum.all?(refs, &Map.has_key?(catalog.target_runner_ids, &1))
  end

  @doc "Whether the current pack/action choice is available on every selected runner."
  def action_available?(catalog, selected_refs, selected_value) do
    Enum.any?(action_options(catalog, selected_refs, selected_value), fn option ->
      option.value == selected_value and not option.disabled
    end)
  end

  @doc "Align descriptor-backed argument rows after an action choice changes or loads."
  def sync_step(step, previous, catalog) do
    choice = action_value(step["pack_id"], step["action"])
    previous_choice = action_value(previous["pack_id"], previous["action"])
    action = catalog.actions[choice]

    if action && (choice != previous_choice or argument_metadata_missing?(step["args"])) do
      existing = Map.new(step["args"], &{&1["name"], &1})

      Map.put(
        step,
        "args",
        Enum.map(action.args, &RunbookDraft.sync_argument(&1, existing[&1["name"]]))
      )
    else
      step
    end
  end

  @doc "Worst risk for the selected pack/action choice."
  def risk(catalog, pack_id, action_id) do
    case catalog.actions[action_value(pack_id, action_id)] do
      nil -> nil
      action -> action.risk
    end
  end

  @doc "Pack/action choice encoded as one stable form value."
  def action_value(pack_id, action_id)
      when is_binary(pack_id) and pack_id != "" and is_binary(action_id) and action_id != "",
      do: pack_id <> "|" <> action_id

  def action_value(_pack_id, _action_id), do: ""

  @doc "Decode one picker value back into the canonical pack and action fields."
  def split_action_value(value) when is_binary(value) do
    case String.split(value, "|", parts: 2) do
      [pack_id, action_id] when pack_id != "" and action_id != "" -> {pack_id, action_id}
      _other -> {"", ""}
    end
  end

  def split_action_value(_value), do: {"", ""}

  defp eligible_targets(runners) do
    runners =
      Enum.flat_map(runners, fn runner ->
        with nil <- runner.disabled_at,
             :online <- Runners.connection_state(runner),
             {:ok, ref} <- Runners.public_ref(runner) do
          [
            %{
              id: runner.id,
              ref: ref,
              name: runner.name,
              group: runner.group
            }
          ]
        else
          _unavailable -> []
        end
      end)

    groups =
      runners
      |> Enum.map(& &1.group)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    grouped_options =
      Enum.flat_map(groups, fn group ->
        group_ref = "group:" <> group

        group_option = %{value: group_ref, label: group, disabled: false, selected: false}

        runner_options =
          runners
          |> Enum.filter(&(&1.group == group))
          |> Enum.sort_by(& &1.name)
          |> Enum.map(&runner_option/1)

        [group_option | runner_options]
      end)

    ungrouped =
      runners
      |> Enum.filter(&blank?(&1.group))
      |> Enum.sort_by(& &1.name)

    ungrouped_options =
      case ungrouped do
        [] ->
          []

        rows ->
          [
            %{value: "", label: "Ungrouped", disabled: true, selected: false}
            | Enum.map(rows, &runner_option/1)
          ]
      end

    group_runner_ids =
      Map.new(groups, fn group ->
        {"group:" <> group, for(runner <- runners, runner.group == group, do: runner.id)}
      end)

    runner_ids = Map.new(runners, &{"runner:" <> &1.ref, [&1.id]})

    labels =
      Map.new(groups, &{"group:" <> &1, &1 <> " group"})
      |> Map.merge(Map.new(runners, &{"runner:" <> &1.ref, &1.name}))

    %{
      options: grouped_options ++ ungrouped_options,
      labels: labels,
      runner_ids: Map.merge(group_runner_ids, runner_ids)
    }
  end

  defp runner_option(runner) do
    %{
      value: "runner:" <> runner.ref,
      label: @runner_indent <> runner.name,
      disabled: false,
      selected: false
    }
  end

  defp action_index(runner_actions, target_runner_ids) do
    eligible_runner_ids =
      target_runner_ids
      |> Map.values()
      |> List.flatten()
      |> MapSet.new()

    runner_actions
    |> Enum.filter(&MapSet.member?(eligible_runner_ids, &1.runner_id))
    |> Enum.group_by(&action_value(&1.pack_id, &1.action_id))
    |> Map.new(fn {value, rows} ->
      representative = latest_action(rows)

      {value,
       %{
         pack_id: representative.pack_id,
         action_id: representative.action_id,
         title: representative.title,
         risk: Enum.max_by(Enum.map(rows, & &1.risk), &risk_rank/1),
         args: Map.get(representative.args_schema, "args", []),
         runner_ids: MapSet.new(rows, & &1.runner_id)
       }}
    end)
  end

  defp latest_action(actions) do
    Enum.max_by(actions, fn action ->
      case Version.parse(action.pack_version || "") do
        {:ok, version} -> {version.major, version.minor, version.patch, version.pre}
        :error -> {-1, -1, -1, []}
      end
    end)
  end

  defp selected_runner_ids(catalog, refs) do
    refs
    |> Enum.reduce_while([], fn ref, ids ->
      case Map.fetch(catalog.target_runner_ids, ref) do
        {:ok, selected} -> {:cont, selected ++ ids}
        :error -> {:halt, []}
      end
    end)
    |> Enum.uniq()
  end

  defp action_description(action) when action.title in [nil, ""], do: action.pack_id
  defp action_description(action), do: "#{action.title} · #{action.pack_id}"

  defp action_search(action),
    do: String.downcase("#{action.action_id} #{action.title} #{action.pack_id}")

  defp saved_action_label(value) do
    {_pack_id, action_id} = split_action_value(value)
    action_id
  end

  defp fallback_target_label("group:" <> group), do: group <> " group"

  defp fallback_target_label("runner:" <> ref) do
    ref
    |> String.split("~", parts: 2)
    |> List.first()
  end

  defp fallback_target_label(ref), do: ref

  defp argument_metadata_missing?([]), do: true

  defp argument_metadata_missing?(arguments) do
    Enum.any?(arguments, fn argument ->
      blank?(argument["type"]) or blank?(argument["required"]) or blank?(argument["sensitive"])
    end)
  end

  defp risk_rank(:critical), do: 4
  defp risk_rank(:high), do: 3
  defp risk_rank(:medium), do: 2
  defp risk_rank(:low), do: 1
  defp risk_rank(_risk), do: 0

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
