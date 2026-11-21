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

  @doc "Whether the change names any runner at all."
  @spec names_runners?(t()) :: boolean()
  def names_runners?(%__MODULE__{} = change) do
    map_size(change.online) > 0 or MapSet.size(change.offline_ids) > 0 or
      MapSet.size(change.updated_ids) > 0
  end

  @doc """
  Resolves every runner the change names against the account's authoritative
  Presence map (`%{runner_id => %{metas: [...]}}`). A runner still tracked is
  online with its newest socket's metadata — a leave-only diff for it was one
  superseded socket, so it becomes a metadata update, never a disconnect. A
  runner no longer tracked keeps the diff's own reading.
  """
  @spec reconcile(t(), map()) :: t()
  def reconcile(%__MODULE__{} = change, presences) when is_map(presences) do
    change.online
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(change.offline_ids)
    |> Enum.reduce(change, fn id, acc ->
      case Map.get(presences, id) do
        %{metas: [_ | _]} = presence -> still_tracked(acc, id, presence)
        _absent -> acc
      end
    end)
  end

  defp still_tracked(change, id, presence) do
    updated_ids =
      if MapSet.member?(change.offline_ids, id),
        do: MapSet.put(change.updated_ids, id),
        else: change.updated_ids

    %{
      change
      | online: Map.put(change.online, id, connection_meta(presence)),
        offline_ids: MapSet.delete(change.offline_ids, id),
        updated_ids: updated_ids
    }
  end

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

  defp connection_meta(%{metas: [_ | _] = metas}) do
    meta = latest_meta(metas)

    %{
      action_load: Map.get(meta, :action_load, 0),
      last_heartbeat_at: unix_to_datetime(Map.get(meta, :last_heartbeat_at))
    }
  end

  defp connection_meta(_presence), do: %{action_load: 0, last_heartbeat_at: nil}

  @doc """
  Internal — lease reclamation can briefly leave the old and new socket metas
  under one Presence key, and Presence does not promise list order, so prefer
  the newest connection generation, then its newest heartbeat/online timestamp.
  """
  def latest_meta([_ | _] = metas) do
    Enum.max_by(metas, fn meta ->
      {
        integer_meta(meta, :connection_generation),
        integer_meta(meta, :last_heartbeat_at),
        integer_meta(meta, :online_at)
      }
    end)
  end

  defp integer_meta(meta, key) do
    case Map.get(meta, key) do
      value when is_integer(value) -> value
      _invalid -> -1
    end
  end

  @doc "Internal — a Presence unix timestamp as a DateTime, or nil when absent or invalid."
  def unix_to_datetime(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  def unix_to_datetime(_absent_or_invalid), do: nil
end
