defmodule Emisar.Runners.ConnectionChange do
  @moduledoc false
  alias Emisar.Runners.Runner

  @type meta :: %{action_load: non_neg_integer(), last_heartbeat_at: DateTime.t() | nil}
  @type runner :: %Runner{}
  @opaque t :: %__MODULE__{
            online: %{optional(String.t()) => meta()},
            joined_ids: MapSet.t(String.t()),
            updated_ids: MapSet.t(String.t()),
            offline_ids: MapSet.t(String.t())
          }

  defstruct online: %{},
            joined_ids: MapSet.new(),
            updated_ids: MapSet.new(),
            offline_ids: MapSet.new()

  # Phoenix Presence represents a metadata update as the same key leaving with
  # its old metadata and joining with its new metadata, so an id in both sets is
  # a heartbeat rather than a connect/disconnect. Anything that isn't a presence
  # diff normalizes to the empty change, so a stray broadcast can't move state.
  @spec normalize(term()) :: t()
  def normalize(%{event: "presence_diff", payload: payload}) when is_map(payload) do
    joins = Map.get(payload, :joins, %{})
    leaves = Map.get(payload, :leaves, %{})
    join_ids = joins |> Map.keys() |> MapSet.new()
    leave_ids = leaves |> Map.keys() |> MapSet.new()

    %__MODULE__{
      online: Map.new(joins, fn {id, presence} -> {id, connection_meta(presence)} end),
      joined_ids: MapSet.difference(join_ids, leave_ids),
      updated_ids: MapSet.intersection(join_ids, leave_ids),
      offline_ids: MapSet.difference(leave_ids, join_ids)
    }
  end

  def normalize(_event), do: %__MODULE__{}

  @spec topology_changed?(t()) :: boolean()
  def topology_changed?(%__MODULE__{} = change),
    do: MapSet.size(change.joined_ids) > 0 or MapSet.size(change.offline_ids) > 0

  @spec joined_runner_ids(t()) :: [String.t()]
  def joined_runner_ids(%__MODULE__{} = change), do: MapSet.to_list(change.joined_ids)

  @spec project_runner(runner(), t()) :: runner()
  def project_runner(%Runner{} = runner, %__MODULE__{} = change) do
    case Map.fetch(change.online, runner.id) do
      {:ok, meta} ->
        %{
          runner
          | online?: true,
            action_load: meta.action_load,
            last_heartbeat_at: meta.last_heartbeat_at
        }

      :error ->
        if MapSet.member?(change.offline_ids, runner.id) do
          %{runner | online?: false, action_load: 0, last_heartbeat_at: nil}
        else
          runner
        end
    end
  end

  @spec project_connection(atom(), term(), t()) :: atom()
  def project_connection(current, runner_id, %__MODULE__{} = change) when is_binary(runner_id) do
    cond do
      Map.has_key?(change.online, runner_id) -> :online
      MapSet.member?(change.offline_ids, runner_id) -> :offline
      true -> current
    end
  end

  def project_connection(current, _runner_id, %__MODULE__{}), do: current

  # The closing intersection is what keeps the set honest: an id the caller may
  # no longer see — revoked access, a runner deleted since the last projection —
  # is dropped even when it was already in `online_ids`.
  @spec project_allowed_online_ids(MapSet.t(String.t()), t(), MapSet.t(String.t())) ::
          MapSet.t(String.t())
  def project_allowed_online_ids(
        %MapSet{} = online_ids,
        %__MODULE__{} = change,
        %MapSet{} = allowed_ids
      ) do
    joined = change.online |> Map.keys() |> MapSet.new() |> MapSet.intersection(allowed_ids)
    left = MapSet.intersection(change.offline_ids, allowed_ids)

    online_ids
    |> MapSet.union(joined)
    |> MapSet.difference(left)
    |> MapSet.intersection(allowed_ids)
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
