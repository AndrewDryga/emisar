defmodule Emisar.AuthMfaSessionConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Fixtures, Repo}
  alias Emisar.Accounts.Account
  alias Emisar.Users.User

  @moduletag timeout: 60_000

  test "session revocation wins before enrollment can stamp that credential" do
    unboxed_owner(fn user, account, subject ->
      secret = Auth.generate_mfa_secret()
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      session_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      peer_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      parent = self()

      revoker =
        unboxed_task(fn ->
          send(parent, {:revoker_backend, backend_pid()})

          Repo.transaction(fn ->
            :ok = Auth.delete_session_token(session_token)
            send(parent, :session_revoked_uncommitted)

            receive do
              :commit -> :ok
            end
          end)
        end)

      assert_receive {:revoker_backend, revoker_backend}, 5_000
      assert_receive :session_revoked_uncommitted, 5_000

      enrollment =
        unboxed_task(fn ->
          send(parent, {:enrollment_backend, backend_pid()})

          Auth.enable_mfa(
            secret,
            NimbleTOTP.verification_code(secret),
            proof,
            session_token,
            subject
          )
        end)

      try do
        assert_receive {:enrollment_backend, enrollment_backend}, 5_000
        await_blocked_by(enrollment_backend, revoker_backend)

        send(revoker.pid, :commit)
        assert {:ok, :ok} = Task.await(revoker, 30_000)
        assert Task.await(enrollment, 30_000) == {:error, :session_not_found}

        refute Repo.reload!(user).mfa_enabled_at

        refute Repo.exists?(
                 Emisar.Audit.Event.Query.all()
                 |> Emisar.Audit.Event.Query.by_account_id(account.id)
                 |> Emisar.Audit.Event.Query.by_event_type("user.mfa_enabled")
               )

        assert {:ok, _user, peer_session} =
                 Auth.fetch_user_and_token_by_session_token(peer_token)

        assert peer_session.mfa_enrollment_verified_at == nil
      after
        send(revoker.pid, :commit)
        stop_tasks([revoker, enrollment])
      end
    end)
  end

  test "two concurrent enrollments upgrade only the winning browser session" do
    unboxed_owner(fn user, _account, subject ->
      secret = Auth.generate_mfa_secret()
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      otp = NimbleTOTP.verification_code(secret)

      tokens = %{
        first: Fixtures.Auth.create_session_token!(user, :magic_link, nil),
        second: Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      }

      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            from(locked_user in User,
              where: locked_user.id == ^user.id,
              lock: "FOR UPDATE"
            )
            |> Repo.one!()

            send(parent, :user_locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :user_locked, 5_000

      enrollments =
        Enum.map(tokens, fn {label, token} ->
          unboxed_task(fn ->
            send(parent, {:enrollment_backend, label, backend_pid()})
            {label, Auth.enable_mfa(secret, otp, proof, token, subject)}
          end)
        end)

      try do
        enrollment_backends =
          Map.new(tokens, fn {label, _token} ->
            assert_receive {:enrollment_backend, ^label, backend}, 5_000
            {label, backend}
          end)

        Enum.each(enrollment_backends, fn {_label, backend} -> await_blocked(backend) end)

        send(blocker.pid, :release)
        assert {:ok, :ok} = Task.await(blocker, 30_000)

        results = Enum.map(enrollments, &Task.await(&1, 30_000))

        assert [{winner, {:ok, %User{} = enrolled, codes}}] =
                 Enum.filter(results, fn {_label, result} ->
                   match?({:ok, %User{}, _codes}, result)
                 end)

        assert length(codes) == 10

        assert [{loser, {:error, :mfa_already_enabled}}] =
                 Enum.reject(results, fn {label, _result} -> label == winner end)

        assert {:ok, ^enrolled, winner_session} =
                 Auth.fetch_user_and_token_by_session_token(tokens[winner])

        assert winner_session.mfa_enrollment_verified_at == enrolled.mfa_enabled_at

        assert {:ok, ^enrolled, loser_session} =
                 Auth.fetch_user_and_token_by_session_token(tokens[loser])

        assert loser_session.mfa_enrollment_verified_at == nil
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | enrollments])
      end
    end)
  end

  defp unboxed_owner(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "mfa-session-race-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "MFA session race #{suffix}", slug: "mfa-session-race-#{suffix}"},
          user
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      try do
        fun.(user, account, subject)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
      end
    end)
  end

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

  defp stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end

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

  defp await_blocked(backend, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    query = "SELECT cardinality(pg_blocking_pids($1::integer)) > 0"

    cond do
      Repo.query!(query, [backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{backend} was never blocked")

      true ->
        await_blocked(backend, deadline)
    end
  end
end
