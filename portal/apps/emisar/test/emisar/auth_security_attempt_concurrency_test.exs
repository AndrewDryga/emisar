defmodule Emisar.AuthSecurityAttemptConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Audit, Auth, Fixtures, Repo}
  alias Emisar.Accounts.Account
  alias Emisar.Auth.SecurityAttemptWindow
  alias Emisar.Users.User

  @moduletag timeout: 60_000

  test "concurrent first attempts create one window and never exceed the budget" do
    unboxed_user(fn user ->
      parent = self()

      inserter =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.insert_all(
              SecurityAttemptWindow,
              [security_window_attrs(user.id, :inbox_step_up)],
              on_conflict: :nothing,
              conflict_target: [:user_id, :scope]
            )

            send(parent, {:inserter_ready, backend_pid()})

            receive do
              :commit -> :committed
            end
          end)
        end)

      assert_receive {:inserter_ready, inserter_backend}, 5_000

      contender =
        unboxed_task(fn ->
          send(parent, {:contender_ready, backend_pid()})
          Auth.check_security_attempt(user, :inbox_step_up, 5, 300_000)
        end)

      try do
        assert_receive {:contender_ready, contender_backend}, 5_000
        await_blocked_by(contender_backend, inserter_backend)

        send(inserter.pid, :commit)
        assert Task.await(inserter, 30_000) == {:ok, :committed}
        assert Task.await(contender, 30_000) == :ok

        for _ <- 1..4 do
          assert Auth.check_security_attempt(user, :inbox_step_up, 5, 300_000) == :ok
        end

        assert Auth.check_security_attempt(user, :inbox_step_up, 5, 300_000) ==
                 {:error, :rate_limited, :exhausted}

        assert Auth.check_security_attempt(user, :inbox_step_up, 5, 300_000) ==
                 {:error, :rate_limited, :capped}

        assert [%SecurityAttemptWindow{attempt_count: 6}] =
                 Repo.all(SecurityAttemptWindow.Query.by_user_and_scope(user.id, :inbox_step_up))
      after
        send(inserter.pid, :commit)
        stop_tasks([inserter, contender])
      end
    end)
  end

  test "the final allowance and first rejection serialize behind the same row lock" do
    unboxed_user(fn user ->
      for _ <- 1..4 do
        assert Auth.check_security_attempt(user, :email_change_issue, 5, 300_000) == :ok
      end

      parent = self()

      locker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            SecurityAttemptWindow.Query.by_user_and_scope(user.id, :email_change_issue)
            |> SecurityAttemptWindow.Query.lock_for_update()
            |> Repo.one!()

            send(parent, {:locker_ready, backend_pid()})

            receive do
              :release -> :released
            end
          end)
        end)

      assert_receive {:locker_ready, locker_backend}, 5_000

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:contender_ready, self(), backend_pid()})
            Auth.check_security_attempt(user, :email_change_issue, 5, 300_000)
          end)
        end)

      try do
        contender_backends =
          Enum.map(1..2, fn _index ->
            assert_receive {:contender_ready, contender_pid, contender_backend}, 5_000
            {contender_pid, contender_backend}
          end)

        assert MapSet.new(Enum.map(contender_backends, &elem(&1, 0))) ==
                 MapSet.new(Enum.map(contenders, & &1.pid))

        # PostgreSQL may name the first waiter as the second waiter's soft
        # blocker. At least one of these independent backends must be queued on
        # the transaction holding the row before we release it; the two
        # outcomes below then prove that both attempts serialized at the budget
        # boundary.
        contender_backends
        |> Enum.map(&elem(&1, 1))
        |> await_any_blocked_by(locker_backend)

        send(locker.pid, :release)
        assert Task.await(locker, 30_000) == {:ok, :released}

        results = Enum.map(contenders, &Task.await(&1, 30_000))
        assert Enum.sort(results) == [:ok, {:error, :rate_limited, :exhausted}]

        assert %SecurityAttemptWindow{attempt_count: 6} =
                 Repo.get_by!(SecurityAttemptWindow,
                   user_id: user.id,
                   scope: :email_change_issue
                 )
      after
        send(locker.pid, :release)
        stop_tasks([locker | contenders])
      end
    end)
  end

  test "database time is sampled only after a contended row lock is acquired" do
    unboxed_user(fn user ->
      assert Auth.check_security_attempt(user, :mfa_enrollment_issue, 1, 300_000) == :ok

      expires_at = DateTime.add(database_now(), 5, :second)

      SecurityAttemptWindow.Query.by_user_and_scope(user.id, :mfa_enrollment_issue)
      |> Repo.update_all(set: [window_expires_at: expires_at])

      parent = self()

      locker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            window =
              SecurityAttemptWindow.Query.by_user_and_scope(user.id, :mfa_enrollment_issue)
              |> SecurityAttemptWindow.Query.lock_for_update()
              |> Repo.one!()

            send(parent, {:locker_ready, backend_pid()})

            receive do
              :release -> window
            end
          end)
        end)

      assert_receive {:locker_ready, locker_backend}, 5_000

      waiter =
        unboxed_task(fn ->
          send(parent, {:waiter_ready, backend_pid(), database_now()})
          Auth.check_security_attempt(user, :mfa_enrollment_issue, 1, 300_000)
        end)

      try do
        assert_receive {:waiter_ready, waiter_backend, waiter_started_at}, 5_000
        assert DateTime.compare(waiter_started_at, expires_at) == :lt
        await_blocked_by(waiter_backend, locker_backend)
        assert DateTime.compare(database_now(), expires_at) == :lt
        await_database_time_at_or_after(expires_at)

        send(locker.pid, :release)
        assert {:ok, %SecurityAttemptWindow{}} = Task.await(locker, 30_000)
        assert Task.await(waiter, 30_000) == :ok

        assert %SecurityAttemptWindow{attempt_count: 1} =
                 Repo.get_by!(SecurityAttemptWindow,
                   user_id: user.id,
                   scope: :mfa_enrollment_issue
                 )
      after
        send(locker.pid, :release)
        stop_tasks([locker, waiter])
      end
    end)
  end

  test "concurrent over-limit MFA attempts emit one bounded audit signal" do
    unboxed_owner(fn user, account ->
      for _ <- 1..5 do
        assert Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000) == :ok
      end

      parent = self()

      locker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            SecurityAttemptWindow.Query.by_user_and_scope(user.id, :mfa_challenge)
            |> SecurityAttemptWindow.Query.lock_for_update()
            |> Repo.one!()

            send(parent, {:locker_ready, backend_pid()})

            receive do
              :release -> :released
            end
          end)
        end)

      assert_receive {:locker_ready, locker_backend}, 5_000

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:contender_ready, self(), backend_pid()})
            Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000)
          end)
        end)

      try do
        contender_backends =
          Enum.map(1..2, fn _index ->
            assert_receive {:contender_ready, contender_pid, contender_backend}, 5_000
            {contender_pid, contender_backend}
          end)

        contender_backends
        |> Enum.map(&elem(&1, 1))
        |> await_any_blocked_by(locker_backend)

        send(locker.pid, :release)
        assert Task.await(locker, 30_000) == {:ok, :released}

        results = Enum.map(contenders, &Task.await(&1, 30_000))

        assert Enum.sort(results) == [
                 {:error, :rate_limited, :capped},
                 {:error, :rate_limited, :exhausted}
               ]

        events =
          Audit.Event.Query.all()
          |> Audit.Event.Query.by_account_id(account.id)
          |> Audit.Event.Query.by_event_type("user.mfa_rate_limited")
          |> Repo.all()

        assert [_only] = events
      after
        send(locker.pid, :release)
        stop_tasks([locker | contenders])
      end
    end)
  end

  defp unboxed_user(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      user =
        Fixtures.Users.create_user(%{
          email: "auth-security-concurrency-#{suffix}@example.test"
        })

      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      try do
        fun.(user)
      after
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
      end
    end)
  end

  defp unboxed_owner(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      user =
        Fixtures.Users.create_user(%{email: "auth-signal-concurrency-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Auth signal concurrency #{suffix}", slug: "auth-signal-concurrency-#{suffix}"},
          user
        )

      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      try do
        fun.(user, account)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
      end
    end)
  end

  defp database_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp security_window_attrs(user_id, scope) do
    expired = ~U[2000-01-01 00:00:00.000000Z]

    %{
      id: Repo.generate_id(),
      user_id: user_id,
      scope: scope,
      attempt_count: 0,
      window_started_at: expired,
      window_expires_at: expired,
      inserted_at: expired,
      updated_at: expired
    }
  end

  defp await_any_blocked_by(
         blocked_backends,
         blocking_backend,
         deadline \\ System.monotonic_time(:millisecond) + 10_000
       ) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"

    cond do
      Enum.any?(
        blocked_backends,
        &(Repo.query!(query, [&1, blocking_backend]).rows == [[true]])
      ) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("no contender was blocked by backend #{blocking_backend}")

      true ->
        await_any_blocked_by(blocked_backends, blocking_backend, deadline)
    end
  end

  defp await_database_time_at_or_after(
         target,
         deadline \\ System.monotonic_time(:millisecond) + 10_000
       ) do
    cond do
      DateTime.compare(database_now(), target) != :lt ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("database clock did not reach the arranged window expiry")

      true ->
        await_database_time_at_or_after(target, deadline)
    end
  end
end
