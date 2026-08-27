defmodule Emisar.ConcurrencyCase do
  @moduledoc """
  Setup for the tests that prove a row lock actually serializes two writers.

  These cannot run inside the sandbox: a sandboxed test is one transaction, so
  two "concurrent" writers would share it and never contend. Each writer here
  checks out a real connection instead, which is why every one of them must be
  shut down explicitly — a leaked unboxed connection outlives the test and
  poisons later runs against the same database.

  Ten test files carried a byte-identical copy of this harness. It is one
  module now so a fix to the checkout, the teardown, or the blocked-on-exactly
  proof lands once.
  """

  # Deliberately NOT built on Emisar.DataCase: these tests run `async: false`
  # and outside the sandbox, so they get none of its per-test transaction.
  use ExUnit.CaseTemplate

  using do
    quote do
      import Emisar.ConcurrencyCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.Repo

  @doc """
  Runs `fun` on a real connection, outside the sandbox.

  Dropping `$callers` is what takes the task out of the sandbox's ownership
  tree — inherit it and the task silently rejoins the test's own transaction,
  which is exactly the contention these tests exist to observe, not create.
  """
  def unboxed_task(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  @doc "The Postgres backend serving the caller's connection."
  def backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  @doc """
  Shuts down every task, alive or not.

  Brutal kill on purpose: a task parked on a lock will never return, and the
  test has already learned what it needed from the fact that it is parked.
  """
  def stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end

  @doc """
  Blocks until `blocked_backend` is waiting on `blocking_backend` specifically.

  Proof that one transaction is queued on the exact other transaction rather
  than merely slow or waiting on an unrelated lock. Each poll is a round trip,
  so the loop paces itself without asserting on timing.
  """
  def await_blocked_by(
        blocked_backend,
        blocking_backend,
        deadline \\ System.monotonic_time(:millisecond) + 10_000
      ) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"

    cond do
      Repo.query!(query, [blocked_backend, blocking_backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk(
          "backend #{blocked_backend} was never blocked by backend #{blocking_backend}"
        )

      true ->
        await_blocked_by(blocked_backend, blocking_backend, deadline)
    end
  end

  @doc """
  Blocks until `backend` is waiting on anything at all.

  The weaker sibling of `await_blocked_by/3`, for a test whose blocker is the
  database itself (an advisory lock, a unique index) rather than another
  backend the test can name.
  """
  def await_blocked(backend, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    query = "SELECT cardinality(pg_blocking_pids($1::integer)) > 0"

    cond do
      Repo.query!(query, [backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("backend #{backend} was never blocked")

      true ->
        await_blocked(backend, deadline)
    end
  end
end
