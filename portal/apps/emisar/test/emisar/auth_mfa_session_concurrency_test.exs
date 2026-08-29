defmodule Emisar.AuthMfaSessionConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Crypto, Fixtures, Repo, Users}
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
            Crypto.hash(session_token),
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
            {label, Auth.enable_mfa(secret, otp, proof, Crypto.hash(token), subject)}
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

  test "TOTP time is sampled once after the user lock and stamps that exact bucket" do
    unboxed_owner(fn user, _account, _subject ->
      secret = "JBSWY3DPEHPK3PXP"
      before_boundary = ~U[2026-01-01 00:00:29.000000Z]
      boundary = ~U[2026-01-01 00:00:30.000000Z]
      code = NimbleTOTP.verification_code(secret, time: boundary)
      parent = self()

      assert NimbleTOTP.verification_code(secret, time: before_boundary) != code
      refute Crypto.valid_totp?(secret, code, before_boundary)
      assert Crypto.valid_totp?(secret, code, boundary)

      {:ok, user} =
        Users.update_user_mfa(user.id, secret, before_boundary, [],
          audit: &Emisar.Audit.user_changesets(&1, "user.mfa_enabled")
        )

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            from(locked_user in User,
              where: locked_user.id == ^user.id,
              lock: "FOR UPDATE"
            )
            |> Repo.one!()

            send(parent, {:totp_user_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:totp_user_locked, blocker_backend}, 5_000

      contender =
        unboxed_task(fn ->
          send(parent, {:totp_contender_backend, backend_pid()})

          clock = fn ->
            at =
              receive do
                {:totp_clock_at, %DateTime{} = at} -> at
              after
                5_000 -> raise "test clock was not advanced"
              end

            send(parent, {:totp_clock_sampled, self(), at})
            at
          end

          Users.verify_and_consume_mfa(user.id, code, clock: clock)
        end)

      try do
        assert_receive {:totp_contender_backend, contender_backend}, 5_000
        await_blocked_by(contender_backend, blocker_backend)
        refute_received {:totp_clock_sampled, _, _}

        send(contender.pid, {:totp_clock_at, boundary})
        send(blocker.pid, :release)

        assert {:ok, :ok} = Task.await(blocker, 30_000)
        assert {:ok, %User{mfa_last_used_at: ^boundary}} = Task.await(contender, 30_000)
        assert_receive {:totp_clock_sampled, contender_pid, ^boundary}, 5_000
        assert contender_pid == contender.pid
        refute_received {:totp_clock_sampled, _, _}
        assert Repo.reload!(user).mfa_last_used_at == boundary

        replay_clock = fn ->
          send(parent, {:replay_clock_sampled, boundary})
          boundary
        end

        assert Users.verify_and_consume_mfa(user.id, code, clock: replay_clock) ==
                 {:error, :replay}

        assert_receive {:replay_clock_sampled, ^boundary}
        refute_received {:replay_clock_sampled, _}
        assert Repo.reload!(user).mfa_last_used_at == boundary
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, contender])
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
end
