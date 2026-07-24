defmodule EmisarWeb.RunnerPresenceTest do
  use ExUnit.Case, async: true
  alias Emisar.Runners
  alias EmisarWeb.RunnerPresence

  test "normalizes metadata updates separately from topology changes" do
    heartbeat = 1_721_234_567

    changes =
      RunnerPresence.normalize(%{
        event: "presence_diff",
        payload: %{
          joins: %{
            "updated" => %{metas: [%{action_load: 3, last_heartbeat_at: heartbeat}]},
            "joined" => %{metas: [%{action_load: 0, last_heartbeat_at: nil}]}
          },
          leaves: %{
            "updated" => %{metas: [%{action_load: 1, last_heartbeat_at: heartbeat - 30}]},
            "left" => %{metas: [%{}]}
          }
        }
      })

    assert changes.joined_ids == MapSet.new(["joined"])
    assert changes.updated_ids == MapSet.new(["updated"])
    assert changes.offline_ids == MapSet.new(["left"])
    assert changes.topology_ids == MapSet.new(["joined", "left"])

    assert changes.online["updated"] == %{
             action_load: 3,
             last_heartbeat_at: DateTime.from_unix!(heartbeat)
           }
  end

  test "patches only the runner named by the diff" do
    runner = %Runners.Runner{id: "runner", online?: false}
    other = %Runners.Runner{id: "other", online?: false}

    changes =
      RunnerPresence.normalize(%{
        event: "presence_diff",
        payload: %{
          joins: %{
            "runner" => %{metas: [%{action_load: 4, last_heartbeat_at: 1_721_234_567}]}
          },
          leaves: %{"runner" => %{metas: [%{}]}}
        }
      })

    patched = RunnerPresence.patch_runner(runner, changes)
    assert patched.online?
    assert patched.action_load == 4
    assert %DateTime{} = patched.last_heartbeat_at
    assert RunnerPresence.patch_runner(other, changes) == other
  end

  test "patches local connection state and allowed online ids" do
    changes =
      RunnerPresence.normalize(%{
        event: "presence_diff",
        payload: %{
          joins: %{"joined" => %{metas: [%{}]}},
          leaves: %{"left" => %{metas: [%{}]}}
        }
      })

    assert RunnerPresence.patch_connection(:offline, "joined", changes) == :online
    assert RunnerPresence.patch_connection(:online, "left", changes) == :offline
    assert RunnerPresence.patch_connection(:online, "unrelated", changes) == :online

    online_ids = MapSet.new(["left"])
    allowed_ids = MapSet.new(["joined", "left"])

    assert RunnerPresence.patch_online_ids(online_ids, changes, allowed_ids) ==
             MapSet.new(["joined"])
  end
end
