defmodule Emisar.ApplicationTest do
  use ExUnit.Case, async: true

  describe "start/2" do
    test "supervises the shared domain task supervisor" do
      task_supervisor = Process.whereis(Emisar.TaskSupervisor)

      assert is_pid(task_supervisor)
      assert Process.alive?(task_supervisor)

      children = Supervisor.which_children(Emisar.Supervisor)

      assert List.keyfind(children, Emisar.TaskSupervisor, 0) ==
               {Emisar.TaskSupervisor, task_supervisor, :supervisor, [Task.Supervisor]}
    end

    test "a crashing task leaves the supervisor and later tasks unaffected" do
      parent = self()
      task_supervisor = Process.whereis(Emisar.TaskSupervisor)

      {:ok, task} =
        Task.Supervisor.start_child(Emisar.TaskSupervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            {:exit, reason} -> exit(reason)
          end
        end)

      assert_receive {:ready, ^task}, 5_000

      ref = Process.monitor(task)
      send(task, {:exit, :test_crash})

      # The task logs its crash report before it exits, and ExUnit's log capture
      # can hold that call for its own 5 s await on a busy machine, so wait on the
      # monitor itself; ExUnit's test timeout still bounds a task that never exits.
      reason =
        receive do
          {:DOWN, ^ref, :process, ^task, reason} -> reason
        end

      assert reason == :test_crash
      assert Process.alive?(task_supervisor)

      assert {:ok, _task} =
               Task.Supervisor.start_child(Emisar.TaskSupervisor, fn ->
                 send(parent, :after_crash)
               end)

      assert_receive :after_crash, 5_000
    end
  end
end
