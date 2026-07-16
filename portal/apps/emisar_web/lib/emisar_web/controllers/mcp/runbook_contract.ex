defmodule EmisarWeb.MCP.RunbookContract do
  @moduledoc """
  Projects the stricter, bounded MCP view of one published runbook.

  The operator UI can own larger runbooks. MCP discovery and execution expose
  only definitions whose complete current expansion fits the fixed API's model
  and transport limits. One projection is shared by list, get, and execute so a
  runbook cannot be discoverable under facts that execution would reject.
  """

  alias Emisar.Runbooks
  alias EmisarWeb.MCP.ActionContract

  @max_steps 32
  @max_runners_per_step 16
  @max_runs 256
  @max_public_bytes 56 * 1_024
  @step_id ~r/\A[a-z][a-z0-9_-]{0,79}\z/
  @runbook_ref ~r/\A[a-z][a-z0-9_-]{0,79}@[1-9][0-9]*\z/

  @doc "Returns the complete bounded public runbook or fails closed."
  def project(runbook, snapshot) do
    steps = Runbooks.expand(runbook)

    with true <- length(steps) in 1..@max_steps,
         {:ok, public_steps, run_count} <- project_steps(steps, snapshot),
         true <- run_count <= @max_runs,
         public <- public_runbook(runbook, public_steps),
         true <- valid_public_runbook?(public),
         true <- encoded_size(public) <= @max_public_bytes do
      {:ok, public}
    else
      _ -> {:error, :incomplete_contract}
    end
  rescue
    Jason.EncodeError -> {:error, :incomplete_contract}
  end

  @doc "Validates the exact resolved execution plan against the MCP blast-radius limits."
  def valid_plan_size?(plan) when is_list(plan) and plan != [] do
    length(plan) <= @max_runs and
      plan
      |> Enum.frequencies_by(& &1.step_id)
      |> Enum.all?(fn {_step_id, count} -> count <= @max_runners_per_step end)
  end

  def valid_plan_size?(_plan), do: false

  defp project_steps(steps, snapshot) do
    packs_by_ref = Map.new(snapshot.packs, &{&1.pack_ref, &1})

    steps
    |> Enum.reduce_while({:ok, [], 0}, fn step, {:ok, public, run_count} ->
      with {:ok, item, selected_count} <- public_step(step, snapshot, packs_by_ref),
           next_count = run_count + selected_count,
           true <- next_count <= @max_runs do
        {:cont, {:ok, [item | public], next_count}}
      else
        _ -> {:halt, {:error, :incomplete_contract}}
      end
    end)
    |> case do
      {:ok, public, run_count} -> {:ok, Enum.reverse(public), run_count}
      error -> error
    end
  end

  defp public_step(step, snapshot, packs_by_ref) do
    with step_id when is_binary(step_id) <- step["id"],
         true <- Regex.match?(@step_id, step_id),
         action_id when is_binary(action_id) <- step["action_id"],
         args when is_map(args) <- step["args"] || %{},
         true <- encoded_size(args) <= 32_768,
         {:ok, pack} <- resolve_pack(step["pack_ref"], action_id, snapshot, packs_by_ref),
         pack_ref <- pack.pack_ref,
         %{} = action <- Enum.find(pack.actions, &(&1["action_id"] == action_id)),
         :ok <- ActionContract.validate(args, action),
         {:ok, selector, selected_count} <-
           public_selector(step["runner_selector"], snapshot, action) do
      {:ok,
       %{
         step_id: step_id,
         action_id: action_id,
         pack_ref: pack_ref,
         args: args,
         runner_selector: selector
       }, selected_count}
    else
      _ -> {:error, :incomplete_contract}
    end
  end

  # Recovering a missing ref is safe only when the current catalog has one
  # compatible exact pack; ambiguity must not silently retarget a runbook.
  defp resolve_pack(pack_ref, _action_id, _snapshot, packs_by_ref) when is_binary(pack_ref) do
    case Map.get(packs_by_ref, pack_ref) do
      %{} = pack -> {:ok, pack}
      _ -> {:error, :missing_pack}
    end
  end

  defp resolve_pack(nil, action_id, snapshot, _packs_by_ref) do
    candidates = Enum.filter(snapshot.packs, &pack_has_action?(&1, action_id))

    case candidates do
      [%{} = pack] -> {:ok, pack}
      _ -> {:error, :ambiguous_pack}
    end
  end

  defp resolve_pack(_pack_ref, _action_id, _snapshot, _packs_by_ref),
    do: {:error, :missing_pack}

  defp pack_has_action?(pack, action_id) do
    Enum.any?(pack.actions, fn action ->
      action["action_id"] == action_id and Map.get(action, :compatible_runner_ids, []) != []
    end)
  end

  defp public_selector(%{"runner_id" => ids}, snapshot, action)
       when is_list(ids) and length(ids) in 1..@max_runners_per_step do
    visible_by_id = Map.new(snapshot.runners, &{&1.id, &1})
    compatible = MapSet.new(action.compatible_runner_ids)
    selected = Enum.map(ids, &Map.get(visible_by_id, &1))

    if Enum.uniq(ids) == ids and
         Enum.all?(selected, &(&1 && MapSet.member?(compatible, &1.id))) do
      {:ok, %{runner_refs: Enum.map(selected, & &1.runner_ref)}, length(selected)}
    else
      {:error, :incomplete_contract}
    end
  end

  defp public_selector(%{"group" => groups}, snapshot, action)
       when is_list(groups) and length(groups) in 1..@max_runners_per_step do
    compatible = MapSet.new(action.compatible_runner_ids)
    visible_ids = MapSet.new(snapshot.runners, & &1.id)
    selected = Enum.filter(snapshot.account_runners, &(&1.group in groups))

    # Keep a scoped group visible when at least one member can execute it. The
    # dispatch plan still resolves and validates every active member later.
    if valid_groups?(groups) and length(selected) in 1..@max_runners_per_step and
         Enum.all?(selected, &MapSet.member?(visible_ids, &1.id)) and
         Enum.any?(selected, &MapSet.member?(compatible, &1.id)) do
      {:ok, %{groups: groups}, length(selected)}
    else
      {:error, :incomplete_contract}
    end
  end

  defp public_selector(_selector, _snapshot, _action), do: {:error, :incomplete_contract}

  defp valid_groups?(groups) do
    Enum.uniq(groups) == groups and
      Enum.all?(groups, &(is_binary(&1) and byte_size(&1) in 1..80))
  end

  defp public_runbook(runbook, steps) do
    %{
      runbook_ref: "#{runbook.slug}@#{runbook.version}",
      title: runbook.title,
      description: runbook.description || "",
      steps: steps
    }
  end

  defp valid_public_runbook?(public) do
    is_binary(public.runbook_ref) and Regex.match?(@runbook_ref, public.runbook_ref) and
      bounded_string?(public.title, 1, 160) and bounded_string?(public.description, 0, 4_096)
  end

  defp bounded_string?(value, min, max),
    do: is_binary(value) and byte_size(value) in min..max

  defp encoded_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
