defmodule EmisarWeb.RunbookEditorCatalog do
  @moduledoc """
  View formatting for the runbook editor's domain projection.

  `Emisar.Runbooks` owns target resolution, trust, pack-version choice, common
  action contracts, risk, and descriptor semantics. This module only turns that
  projection into picker headings, labels, search text, and the stable form
  encoding — and keeps a saved value that no longer resolves named, marked
  unavailable, and removable.
  """

  alias Emisar.Runbooks
  alias EmisarWeb.RunbookDraft

  @doc "Return the target picker choices, including unavailable selected refs."
  def target_options(projection, selected_refs, selection) do
    selected = MapSet.new(selected_refs)

    options =
      Enum.map(eligible_target_options(projection), fn option ->
        %{option | selected: option.value in selected_refs and option.selection == selection}
      end)

    missing_options =
      selected
      |> MapSet.difference(
        options
        |> Enum.filter(&(&1.selection == selection))
        |> MapSet.new(& &1.value)
      )
      |> Enum.sort()
      |> Enum.map(fn ref ->
        %{
          value: ref,
          selection: selection,
          label: target_label(projection, ref, selection),
          kind: target_kind(ref, selection),
          description: unavailable_target_description(ref),
          disabled: false,
          selected: true,
          unavailable: true
        }
      end)

    missing =
      if missing_options == [] do
        []
      else
        [
          %{
            value: "",
            selection: nil,
            label: "Unavailable",
            kind: :group,
            disabled: true,
            selected: false
          }
          | missing_options
        ]
      end

    options ++ missing
  end

  @doc "Human label for one tagged target reference."
  def target_label(projection, ref, selection \\ "all")

  def target_label(projection, "group:" <> group = ref, "all") do
    case Enum.count(projection.targets, &(&1.group == group)) do
      0 -> fallback_target_label(ref, "all")
      count -> "#{group} — all online runners (#{count})"
    end
  end

  def target_label(projection, "group:" <> group = ref, "random_one") do
    if Enum.any?(projection.targets, &(&1.group == group)),
      do: "#{group} — one online runner",
      else: fallback_target_label(ref, "random_one")
  end

  def target_label(projection, "runner:" <> runner_ref = ref, "all") do
    case Enum.find(projection.targets, &(&1.runner_ref == runner_ref)) do
      nil -> fallback_target_label(ref, "all")
      target -> target.name
    end
  end

  def target_label(_projection, ref, selection), do: fallback_target_label(ref, selection)

  @doc "Whether the editor currently offers any target at all."
  def targets_empty?(projection), do: projection.targets == []

  @doc "Whether one saved target ref still resolves to current eligible runners."
  def target_available?(projection, ref),
    do: match?({:ok, _targets}, Runbooks.editor_target_runners(projection, [ref], "all"))

  @doc "Whether every selected target currently resolves to one or more eligible runners."
  def targets_resolved?(projection, refs, selection),
    do: match?({:ok, _targets}, Runbooks.editor_target_runners(projection, refs, selection))

  @doc "Action choices the domain reports as eligible on every selected target."
  def action_options(projection, refs, selection, selected_value) do
    options =
      projection
      |> Runbooks.editor_actions(refs, selection)
      |> Enum.map(&action_option(&1, selected_value))
      |> Enum.sort_by(& &1.label)

    if selected_value in [nil, ""] or Enum.any?(options, &(&1.value == selected_value)) do
      options
    else
      [
        unavailable_action_option(selected_value, targets_resolved?(projection, refs, selection))
        | options
      ]
    end
  end

  @doc "Whether the current pack/action choice is eligible on every selected target."
  def action_available?(projection, refs, selection, value) do
    {pack_id, action_id} = split_action_value(value)

    match?(
      {:ok, _action},
      Runbooks.editor_action(projection, refs, selection, pack_id, action_id)
    )
  end

  @doc "Align descriptor-backed argument rows after an action choice changes or loads."
  def sync_step(step, previous, projection) do
    choice = action_value(step["pack_id"], step["action"])
    previous_choice = action_value(previous["pack_id"], previous["action"])

    if choice != previous_choice or argument_metadata_missing?(step["args"]) do
      sync_step_arguments(step, projection)
    else
      step
    end
  end

  @doc "Risk of the selected pack/action choice on the selected targets."
  def risk(projection, refs, selection, pack_id, action_id) do
    case Runbooks.editor_action(projection, refs, selection, pack_id, action_id) do
      {:ok, action} -> action.risk
      {:error, :not_found} -> nil
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

  defp sync_step_arguments(step, projection) do
    case Runbooks.editor_action(
           projection,
           step["target_refs"],
           step["target_selection"],
           step["pack_id"],
           step["action"]
         ) do
      {:ok, action} ->
        existing = Map.new(step["args"], &{&1["name"], &1})

        Map.put(step, "args", Enum.map(action.args, &synced_argument(&1, existing[&1["name"]])))

      {:error, :not_found} ->
        step
    end
  end

  defp action_option(action, selected_value) do
    value = action_value(action.pack_id, action.action_id)

    %{
      value: value,
      label: action.action_id,
      description: action_description(action),
      search: action_search(action),
      pack_id: action.pack_id,
      disabled: false,
      selected: value == selected_value
    }
  end

  defp unavailable_action_option(value, targets_resolved?) do
    %{
      value: value,
      label: saved_action_label(value),
      description:
        if(targets_resolved?,
          do: "Unavailable on one or more selected runners",
          else: "Saved action"
        ),
      search: value,
      pack_id: elem(split_action_value(value), 0),
      unavailable: targets_resolved?,
      disabled: true,
      selected: true
    }
  end

  defp eligible_target_options(projection) do
    targets = projection.targets

    groups =
      targets
      |> Enum.map(& &1.group)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    grouped_options =
      Enum.flat_map(groups, fn group ->
        group_ref = "group:" <> group

        group_heading = %{
          value: "",
          selection: nil,
          label: group,
          kind: :group,
          online_count: Enum.count(targets, &(&1.group == group)),
          disabled: true,
          selected: false
        }

        all_option = %{
          value: group_ref,
          selection: "all",
          label: "Every runner in group",
          kind: :group_all,
          disabled: false,
          selected: false
        }

        random_option = %{
          value: group_ref,
          selection: "random_one",
          label: "One random runner",
          kind: :group_one,
          disabled: false,
          selected: false
        }

        runner_options =
          targets
          |> Enum.filter(&(&1.group == group))
          |> Enum.sort_by(& &1.name)
          |> Enum.map(&runner_option/1)

        [group_heading, all_option, random_option | runner_options]
      end)

    ungrouped =
      targets
      |> Enum.filter(&blank?(&1.group))
      |> Enum.sort_by(& &1.name)

    grouped_options ++ ungrouped_options(ungrouped)
  end

  defp ungrouped_options([]), do: []

  defp ungrouped_options(targets) do
    [
      %{
        value: "",
        selection: nil,
        label: "Ungrouped",
        kind: :group,
        online_count: length(targets),
        disabled: true,
        selected: false
      }
      | Enum.map(targets, &runner_option/1)
    ]
  end

  defp runner_option(target) do
    %{
      value: "runner:" <> target.runner_ref,
      selection: "all",
      label: target.name,
      kind: :runner,
      disabled: false,
      selected: false
    }
  end

  defp target_kind("group:" <> _group, "random_one"), do: :group_one
  defp target_kind("group:" <> _group, _selection), do: :group_all
  defp target_kind("runner:" <> _ref, _selection), do: :runner
  defp target_kind(_ref, _selection), do: :runner

  defp unavailable_target_description("group:" <> _group),
    do: "Saved group is no longer available"

  defp unavailable_target_description(_ref), do: "Saved runner is no longer available"

  defp action_description(action) when action.title in [nil, ""], do: action.pack_id
  defp action_description(action), do: "#{action.title} · #{action.pack_id}"

  defp action_search(action),
    do: String.downcase("#{action.action_id} #{action.title} #{action.pack_id}")

  defp saved_action_label(value) do
    {_pack_id, action_id} = split_action_value(value)
    action_id
  end

  defp fallback_target_label("group:" <> group, "random_one"),
    do: group <> " — one online runner"

  defp fallback_target_label("group:" <> group, _selection), do: group <> " group"

  defp fallback_target_label("runner:" <> ref, _selection) do
    ref
    |> String.split("~", parts: 2)
    |> List.first()
  end

  defp fallback_target_label(ref, _selection), do: ref

  defp synced_argument(spec, existing) do
    command = RunbookDraft.argument_command(existing)

    spec
    |> Runbooks.Authoring.sync_argument(command)
    |> RunbookDraft.argument_from_command()
  end

  defp argument_metadata_missing?([]), do: true

  defp argument_metadata_missing?(arguments) do
    Enum.any?(arguments, fn argument ->
      blank?(argument["type"]) or blank?(argument["required"]) or blank?(argument["sensitive"])
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
