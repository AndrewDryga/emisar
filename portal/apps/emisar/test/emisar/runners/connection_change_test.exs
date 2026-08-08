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

  describe "preload_runners_presence/1" do
    test "hydrates each runner from its own account's Presence topic" do
      account_a = Ecto.UUID.generate()
      account_b = Ecto.UUID.generate()
      runner_a = %Runners.Runner{id: Ecto.UUID.generate(), account_id: account_a}
      runner_b = %Runners.Runner{id: Ecto.UUID.generate(), account_id: account_b}
      heartbeat = 1_721_234_567

      {:ok, _ref} =
        Runners.Presence.track(
          self(),
          Runners.Presence.topic(account_a),
          runner_a.id,
          %{action_load: 4, last_heartbeat_at: heartbeat}
        )

      assert [hydrated_a, hydrated_b] =
               Runners.preload_runners_presence([runner_a, runner_b])

      assert hydrated_a.online?
      assert hydrated_a.action_load == 4
      assert hydrated_a.last_heartbeat_at == DateTime.from_unix!(heartbeat)
      refute hydrated_b.online?
      assert hydrated_b.action_load == 0
      refute hydrated_b.last_heartbeat_at
    end

    test "an empty result never reads Presence" do
      assert Runners.preload_runners_presence([]) == []
    end
  end
end
