defmodule Emisar.ReleaseTest do
  # The lock tests hold real (unboxed) pool connections, so they cannot share
  # the suite's sandbox ownership with a concurrent test.
  use Emisar.DataCase, async: false
  alias Ecto.Adapters.SQL.Sandbox

  describe "with_migration_lock/2" do
    test "returns the function's result" do
      result =
        Sandbox.unboxed_run(Repo, fn ->
          Emisar.Release.with_migration_lock(Repo, fn -> :migrated end)
        end)

      assert result == :migrated
    end

    test "a second session waits until the first releases the lock" do
      test_pid = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Emisar.Release.with_migration_lock(Repo, fn ->
              send(test_pid, :holding)
              assert_receive :release, 2_000
              :first
            end)
          end)
        end)

      assert_receive :holding, 2_000

      waiter =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Emisar.Release.with_migration_lock(Repo, fn -> :second end)
          end)
        end)

      refute Task.yield(waiter, 300),
             "the second session ran the body while the first held the lock"

      send(holder.pid, :release)

      assert Task.await(holder) == :first
      assert Task.await(waiter) == :second
    end

    test "a raising body still releases the lock" do
      Sandbox.unboxed_run(Repo, fn ->
        assert_raise RuntimeError, "boom", fn ->
          Emisar.Release.with_migration_lock(Repo, fn -> raise "boom" end)
        end
      end)

      # A leaked session lock would make the next acquisition from another
      # session block forever, so a plain re-acquire is the assertion.
      task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Emisar.Release.with_migration_lock(Repo, fn -> :ok end)
          end)
        end)

      assert Task.await(task, 2_000) == :ok
    end
  end

  describe "seed/0" do
    test "refuses to run outside a development build" do
      assert_raise RuntimeError, ~r/only in a development build/, fn ->
        Emisar.Release.seed()
      end
    end
  end
end
