defmodule Emisar.Runners.ConnectionChangeTest do
  use ExUnit.Case, async: true
  alias Emisar.Runners

  defp presence_diff(joins, leaves),
    do: %{event: "presence_diff", payload: %{joins: joins, leaves: leaves}}

  defp metas(fields), do: %{metas: [fields]}

  describe "normalize_connection_change/1" do
    test "reads a join's metadata into the online map" do
      heartbeat = 1_721_234_567

      change =
        presence_diff(%{"joined" => metas(%{action_load: 3, last_heartbeat_at: heartbeat})}, %{})
        |> Runners.normalize_connection_change()

      assert Runners.joined_runner_ids(change) == ["joined"]

      runner = Runners.project_runner_connection(%Runners.Runner{id: "joined"}, change)
      assert runner.online?
      assert runner.action_load == 3
      assert runner.last_heartbeat_at == DateTime.from_unix!(heartbeat)
    end

    test "defaults missing metadata to no load and no heartbeat" do
      change =
        presence_diff(%{"joined" => metas(%{})}, %{})
        |> Runners.normalize_connection_change()

      runner =
        Runners.project_runner_connection(
          %Runners.Runner{id: "joined", action_load: 7, last_heartbeat_at: DateTime.utc_now()},
          change
        )

      assert runner.online?
      assert runner.action_load == 0
      refute runner.last_heartbeat_at
    end

    test "a non-presence event yields a change that moves nothing" do
      change = Runners.normalize_connection_change({:runner_registered, "runner"})
      runner = %Runners.Runner{id: "runner", online?: true, action_load: 2}

      refute Runners.connection_topology_changed?(change)
      assert Runners.joined_runner_ids(change) == []
      assert Runners.project_runner_connection(runner, change) == runner
      assert Runners.project_connection(:online, "runner", change) == :online
    end
  end

  describe "connection_topology_changed?/1" do
    test "true for a join and for a leave" do
      joined = Runners.normalize_connection_change(presence_diff(%{"a" => metas(%{})}, %{}))
      left = Runners.normalize_connection_change(presence_diff(%{}, %{"a" => metas(%{})}))

      assert Runners.connection_topology_changed?(joined)
      assert Runners.connection_topology_changed?(left)
    end

    test "false when a runner only refreshed its metadata" do
      heartbeat = 1_721_234_567

      change =
        presence_diff(
          %{"runner" => metas(%{action_load: 3, last_heartbeat_at: heartbeat})},
          %{"runner" => metas(%{action_load: 1, last_heartbeat_at: heartbeat - 30})}
        )
        |> Runners.normalize_connection_change()

      refute Runners.connection_topology_changed?(change)

      # Presence spells an update as a leave plus a join, so the join's metadata
      # is the current one and the runner must stay online.
      runner = Runners.project_runner_connection(%Runners.Runner{id: "runner"}, change)
      assert runner.online?
      assert runner.action_load == 3
      assert runner.last_heartbeat_at == DateTime.from_unix!(heartbeat)
    end
  end

  describe "joined_runner_ids/1" do
    test "lists connects only, never a metadata refresh" do
      change =
        presence_diff(
          %{"joined" => metas(%{}), "updated" => metas(%{})},
          %{"updated" => metas(%{}), "left" => metas(%{})}
        )
        |> Runners.normalize_connection_change()

      assert Runners.joined_runner_ids(change) == ["joined"]
    end
  end

  describe "project_runner_connection/2" do
    test "a leave takes the runner offline and clears its live metadata" do
      change = Runners.normalize_connection_change(presence_diff(%{}, %{"runner" => metas(%{})}))

      runner =
        Runners.project_runner_connection(
          %Runners.Runner{
            id: "runner",
            online?: true,
            action_load: 4,
            last_heartbeat_at: DateTime.utc_now()
          },
          change
        )

      refute runner.online?
      assert runner.action_load == 0
      refute runner.last_heartbeat_at
    end

    test "a runner the change does not name is untouched" do
      change = Runners.normalize_connection_change(presence_diff(%{"other" => metas(%{})}, %{}))
      runner = %Runners.Runner{id: "runner", online?: false, action_load: 2}

      assert Runners.project_runner_connection(runner, change) == runner
    end
  end

  describe "project_connection/3" do
    test "follows the diff for the named runner and keeps the current state otherwise" do
      change =
        presence_diff(%{"joined" => metas(%{})}, %{"left" => metas(%{})})
        |> Runners.normalize_connection_change()

      assert Runners.project_connection(:offline, "joined", change) == :online
      assert Runners.project_connection(:online, "left", change) == :offline
      assert Runners.project_connection(:online, "unrelated", change) == :online
      assert Runners.project_connection(:offline, nil, change) == :offline
    end
  end

  describe "project_allowed_online_ids/3" do
    test "applies joins and leaves inside the allowed scope" do
      change =
        presence_diff(%{"joined" => metas(%{})}, %{"left" => metas(%{})})
        |> Runners.normalize_connection_change()

      online_ids = MapSet.new(["left"])
      allowed_ids = MapSet.new(["joined", "left"])

      assert Runners.project_allowed_online_ids(online_ids, change, allowed_ids) ==
               MapSet.new(["joined"])
    end

    test "ignores a runner outside the allowed scope" do
      change = Runners.normalize_connection_change(presence_diff(%{"other" => metas(%{})}, %{}))
      allowed_ids = MapSet.new(["runner"])

      assert Runners.project_allowed_online_ids(MapSet.new(), change, allowed_ids) == MapSet.new()
    end

    test "drops an already-online runner that is no longer allowed" do
      change = Runners.normalize_connection_change(presence_diff(%{"runner" => metas(%{})}, %{}))
      online_ids = MapSet.new(["runner", "revoked"])
      allowed_ids = MapSet.new(["runner"])

      assert Runners.project_allowed_online_ids(online_ids, change, allowed_ids) ==
               MapSet.new(["runner"])
    end
  end
end
