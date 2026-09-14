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

      # The abnormal exit is logged from inside the task before it terminates,
      # so the DOWN trails a synchronous crash report; under full-suite load
      # that round-trip needs the suite's standard cross-process window.
      assert_receive {:DOWN, ^ref, :process, ^task, :test_crash}, 5_000
      assert Process.alive?(task_supervisor)

      assert {:ok, _task} =
               Task.Supervisor.start_child(Emisar.TaskSupervisor, fn ->
                 send(parent, :after_crash)
               end)

      assert_receive :after_crash, 5_000
    end
  end
end
