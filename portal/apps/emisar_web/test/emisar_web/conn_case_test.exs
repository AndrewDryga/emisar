defmodule EmisarWeb.ConnCaseTest do
  @moduledoc """
  `register_and_log_in/2` runs inside each async test's own sandbox transaction,
  which cannot see another test's uncommitted rows. A default slug derived from
  the shared "Test Co" name therefore passed `Accounts.suggest_unique_slug/1`'s
  read-before-insert check in two tests at once, and the second INSERT queued
  on the `accounts.slug` unique index until the first test finished. Each case
  here runs two writers on their own sandbox connections to prove the boundary.
  """
  use EmisarWeb.ConnCase, async: true
  import Emisar.ConcurrencyCase, only: [await_blocked_by: 2, backend_pid: 0]
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.Accounts
  alias Emisar.Accounts.Account
  alias Emisar.Repo

  describe "register_and_log_in/2" do
    test "two isolated owners deriving a slug from one name queue on the unique index" do
      name = "Collide #{Fixtures.Random.unique_int()}"
      parent = self()

      first =
        isolated_owner(fn ->
          send(parent, {:first_backend, backend_pid()})
          {_conn, _user, account} = register_default_shape(name)
          send(parent, {:first_slug, account.slug})

          receive do
            :release -> :released
          end
        end)

      assert_receive {:first_backend, first_backend}, 5_000
      assert_receive {:first_slug, first_slug}, 5_000

      second =
        isolated_owner(fn ->
          send(parent, {:second_backend, backend_pid()})
          {_conn, _user, account} = register_default_shape(name)
          account
        end)

      assert_receive {:second_backend, second_backend}, 5_000
      await_blocked_by(second_backend, first_backend)

      send(first.pid, :release)
      assert Task.await(first, 5_000) == :released
      # The rollback frees the slug both owners chose, so the queued INSERT lands it.
      assert %Account{slug: ^first_slug} = Task.await(second, 5_000)
    end

    test "the default slug stays distinct while another owner holds an uncommitted account" do
      parent = self()

      first =
        isolated_owner(fn ->
          {_conn, _user, account} = register_and_log_in(Phoenix.ConnTest.build_conn())
          send(parent, {:first_account, account})

          receive do
            :release -> :released
          end
        end)

      assert_receive {:first_account, %Account{} = first_account}, 5_000

      second =
        isolated_owner(fn ->
          {_conn, _user, account} = register_and_log_in(Phoenix.ConnTest.build_conn())
          account
        end)

      assert {:ok, %Account{} = second_account} = Task.yield(second, 5_000)
      send(first.pid, :release)
      assert Task.await(first, 5_000) == :released

      assert first_account.name == "Test Co"
      assert second_account.name == "Test Co"
      assert first_account.slug != second_account.slug
    end
  end

  # Runs `fun` as its own sandbox owner on a separate connection. Dropping
  # `$callers` keeps the task out of the test's transaction; checking out in the
  # task process itself means a crash returns the connection with the process.
  defp isolated_owner(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      :ok = Sandbox.checkout(Repo)

      try do
        fun.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  # The former default shape: a slug derived from the name by a read-before-insert.
  defp register_default_shape(name) do
    account = %{name: name, slug: Accounts.suggest_unique_slug(name)}
    register_and_log_in(Phoenix.ConnTest.build_conn(), %{account: account})
  end
end
