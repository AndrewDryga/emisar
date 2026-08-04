defmodule Emisar.AccountsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Fixtures, Repo, Users}
  alias Emisar.Accounts.Account
  alias Emisar.Users.User

  @moduletag timeout: 60_000

  test "MFA enforcement cannot commit while the owner is concurrently disabling MFA" do
    unboxed_owner(fn account, owner, subject, recovery_code ->
      parent = self()

      disable =
        unboxed_task(fn ->
          send(parent, {:disable_backend, backend_pid()})

          Repo.transaction(fn ->
            {:ok, _locked_user} = Users.fetch_and_lock_user_by_id(owner.id, Repo)
            send(parent, :actor_locked)

            receive do
              :disable -> Auth.disable_mfa(recovery_code, subject)
            end
          end)
        end)

      assert_receive {:disable_backend, disable_backend}, 5_000
      assert_receive :actor_locked, 5_000

      enforce =
        unboxed_task(fn ->
          send(parent, {:enforce_backend, backend_pid()})
          Accounts.update_account(account, %{settings: %{require_mfa: true}}, subject)
        end)

      assert_receive {:enforce_backend, enforce_backend}, 5_000
      await_blocked_by(enforce_backend, disable_backend)

      send(disable.pid, :disable)
      assert {:ok, {:ok, %User{mfa_enabled_at: nil}}} = Task.await(disable, 30_000)

      assert Task.await(enforce, 30_000) == {:error, :mfa_enrollment_required}
      refute Repo.reload!(account).settings.require_mfa
      refute Repo.reload!(owner).mfa_enabled_at
    end)
  end

  test "MFA enrollment stays locked until enforcement commits" do
    unboxed_owner(fn account, owner, subject, recovery_code ->
      parent = self()

      enforce =
        unboxed_task(fn ->
          send(parent, {:enforce_backend, backend_pid()})

          Repo.transaction(fn ->
            result = Accounts.update_account(account, %{settings: %{require_mfa: true}}, subject)
            send(parent, {:enforcement_staged, result})

            receive do
              :commit -> result
            end
          end)
        end)

      assert_receive {:enforce_backend, enforce_backend}, 5_000

      assert_receive {:enforcement_staged, {:ok, %Account{settings: %{require_mfa: true}}}},
                     5_000

      disable =
        unboxed_task(fn ->
          send(parent, {:disable_backend, backend_pid()})
          Auth.disable_mfa(recovery_code, subject)
        end)

      assert_receive {:disable_backend, disable_backend}, 5_000
      await_blocked_by(disable_backend, enforce_backend)

      send(enforce.pid, :commit)

      assert {:ok, {:ok, %Account{settings: %{require_mfa: true}}}} =
               Task.await(enforce, 30_000)

      assert {:ok, %User{mfa_enabled_at: nil}} = Task.await(disable, 30_000)
      assert Repo.reload!(account).settings.require_mfa
      refute Repo.reload!(owner).mfa_enabled_at
    end)
  end

  defp unboxed_owner(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "accounts-concurrency-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Accounts concurrency #{suffix}", slug: "accounts-concurrency-#{suffix}"},
          user
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {owner, [recovery_code | _rest]} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      try do
        fun.(account, owner, subject, recovery_code)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
      end
    end)
  end

  # Each contender needs its own connection, so it drops the sandbox owner it
  # inherited through `$callers` and checks one out unboxed.
  defp unboxed_task(fun) do
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

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Proof that one transaction is queued on the exact other transaction rather
  # than merely slow or waiting on an unrelated lock. Each poll is a round trip,
  # so the loop paces itself without asserting on timing.
  defp await_blocked_by(
         blocked_backend,
         blocking_backend,
         deadline \\ System.monotonic_time(:millisecond) + 10_000
       ) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"

    cond do
      Repo.query!(query, [blocked_backend, blocking_backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{blocked_backend} was never blocked by backend #{blocking_backend}")

      true ->
        await_blocked_by(blocked_backend, blocking_backend, deadline)
    end
  end
end
