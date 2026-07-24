defmodule EmisarWeb.RunnerPresence do
  @moduledoc """
  Normalizes runner Presence diffs for LiveViews.

  Phoenix Presence represents a metadata update as the same key leaving with
  its old metadata and joining with its new metadata. Join-only and leave-only
  keys are real connection topology changes.
  """

  alias Emisar.Runners

  def normalize(%{event: "presence_diff", payload: payload}) when is_map(payload) do
    joins = Map.get(payload, :joins, %{})
    leaves = Map.get(payload, :leaves, %{})
    join_ids = joins |> Map.keys() |> MapSet.new()
    leave_ids = leaves |> Map.keys() |> MapSet.new()
    updated_ids = MapSet.intersection(join_ids, leave_ids)
    joined_ids = MapSet.difference(join_ids, leave_ids)
    offline_ids = MapSet.difference(leave_ids, join_ids)

    %{
      online: Map.new(joins, fn {id, presence} -> {id, connection_meta(presence)} end),
      joined_ids: joined_ids,
      updated_ids: updated_ids,
      offline_ids: offline_ids,
      topology_ids: MapSet.union(joined_ids, offline_ids)
    }
  end

  def normalize(_event) do
    %{
      online: %{},
      joined_ids: MapSet.new(),
      updated_ids: MapSet.new(),
      offline_ids: MapSet.new(),
      topology_ids: MapSet.new()
    }
  end

  def patch_runner(%Runners.Runner{} = runner, changes) do
    case Map.fetch(changes.online, runner.id) do
      {:ok, meta} ->
        %{
          runner
          | online?: true,
            action_load: meta.action_load,
            last_heartbeat_at: meta.last_heartbeat_at
        }

      :error ->
        if MapSet.member?(changes.offline_ids, runner.id) do
          %{runner | online?: false, action_load: 0, last_heartbeat_at: nil}
        else
          runner
        end
    end
  end

  def patch_connection(current, runner_id, changes) when is_binary(runner_id) do
    cond do
      Map.has_key?(changes.online, runner_id) -> :online
      MapSet.member?(changes.offline_ids, runner_id) -> :offline
      true -> current
    end
  end

  def patch_connection(current, _runner_id, _changes), do: current

  def patch_online_ids(%MapSet{} = online_ids, changes, %MapSet{} = allowed_ids) do
    online_changes =
      changes.online
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(allowed_ids)

    offline_changes = MapSet.intersection(changes.offline_ids, allowed_ids)

    online_ids
    |> MapSet.union(online_changes)
    |> MapSet.difference(offline_changes)
  end

  defp connection_meta(%{metas: [meta | _]}) do
    %{
      action_load: Map.get(meta, :action_load, 0),
      last_heartbeat_at: unix_to_datetime(Map.get(meta, :last_heartbeat_at))
    }
  end

  defp connection_meta(_presence), do: %{action_load: 0, last_heartbeat_at: nil}

  defp unix_to_datetime(nil), do: nil
  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
end
