defmodule Emisar.AuthMfaSessionConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Crypto, Fixtures, Repo}
  alias Emisar.Accounts.{Account, Membership}

  @moduletag timeout: 60_000

  test "session revocation wins before enrollment can stamp that credential" do
    unboxed_owner(fn user, account, subject ->
      secret = Auth.generate_mfa_secret()
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      session_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(user, session: session_token)
      peer_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      parent = self()

      revoker =
        unboxed_task(fn ->
          send(parent, {:revoker_backend, backend_pid()})

          Repo.transaction(fn ->
            # The revocation's own transaction cannot nest; its delete is held
            # open here the way an in-flight revocation holds the row.
            :ok = Fixtures.Auth.delete_session_token!(session_token)
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
            Fixtures.Auth.totp_code(secret),
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

        assert {:ok, peer_session} = Auth.fetch_session_by_token(peer_token, account.id)

        assert peer_session.mfa_enrollment_verified_at == nil
      after
        send(revoker.pid, :commit)
        stop_tasks([revoker, enrollment])
      end
    end)
  end

  test "two concurrent enrollments upgrade only the winning browser session" do
    unboxed_owner(fn user, account, subject ->
      secret = Auth.generate_mfa_secret()
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      otp = Fixtures.Auth.totp_code(secret)

      tokens = %{
        first: Fixtures.Auth.create_session_token!(user, :magic_link, nil),
        second: Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      }

      subjects =
        Map.new(tokens, fn {label, raw} ->
          {label, Fixtures.Subjects.subject_for(user, session: raw)}
        end)

      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, _locked} =
              Accounts.fetch_and_lock_active_membership(Repo, account.id, user.id)

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
            {label, Auth.enable_mfa(secret, otp, proof, Crypto.hash(token), subjects[label])}
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

        assert [{winner, {:ok, %Membership{} = enrolled, codes}}] =
                 Enum.filter(results, fn {_label, result} ->
                   match?({:ok, %Membership{}, _codes}, result)
                 end)

        assert length(codes) == 10

        assert [{loser, {:error, :mfa_already_enabled}}] =
                 Enum.reject(results, fn {label, _result} -> label == winner end)

        assert {:ok, winner_session} = Auth.fetch_session_by_token(tokens[winner], account.id)
        assert winner_session.membership.mfa_enabled_at == enrolled.mfa_enabled_at
        assert winner_session.mfa_enrollment_verified_at == enrolled.mfa_enabled_at

        assert {:ok, loser_session} = Auth.fetch_session_by_token(tokens[loser], account.id)
        assert loser_session.mfa_enrollment_verified_at == nil
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | enrollments])
      end
    end)
  end

  test "TOTP time is sampled once after the Member lock and stamps that exact bucket" do
    unboxed_owner(fn user, account, _subject ->
      secret = "JBSWY3DPEHPK3PXP"
      before_boundary = ~U[2026-01-01 00:00:29.000000Z]
      boundary = ~U[2026-01-01 00:00:30.000000Z]
      code = NimbleTOTP.verification_code(secret, time: boundary)
      parent = self()

      assert NimbleTOTP.verification_code(secret, time: before_boundary) != code
      refute Crypto.valid_totp?(secret, code, before_boundary)
      assert Crypto.valid_totp?(secret, code, boundary)

      user =
        Fixtures.Memberships.set_mfa_state(user,
          mfa_secret: secret,
          mfa_enabled_at: before_boundary
        )

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, _locked} =
              Accounts.fetch_and_lock_active_membership(Repo, account.id, user.id)

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

          Accounts.verify_and_consume_member_mfa(user, code, clock: clock)
        end)

      try do
        assert_receive {:totp_contender_backend, contender_backend}, 5_000
        await_blocked_by(contender_backend, blocker_backend)
        refute_received {:totp_clock_sampled, _, _}

        send(contender.pid, {:totp_clock_at, boundary})
        send(blocker.pid, :release)

        assert {:ok, :ok} = Task.await(blocker, 30_000)
        assert {:ok, %Membership{mfa_last_used_at: ^boundary}} = Task.await(contender, 30_000)
        assert_receive {:totp_clock_sampled, contender_pid, ^boundary}, 5_000
        assert contender_pid == contender.pid
        refute_received {:totp_clock_sampled, _, _}
        assert Repo.reload!(user).mfa_last_used_at == boundary

        replay_clock = fn ->
          send(parent, {:replay_clock_sampled, boundary})
          boundary
        end

        assert Accounts.verify_and_consume_member_mfa(user, code, clock: replay_clock) ==
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

      account =
        Fixtures.Accounts.create_account(%{
          name: "MFA session race #{suffix}",
          slug: "mfa-session-race-#{suffix}"
        })

      owner =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "mfa-session-race-#{suffix}@example.test"
        )

      {:ok, _policy} = Emisar.Policies.seed_policy(account.id, owner.id)
      subject = Fixtures.Subjects.subject_for(owner)

      try do
        fun.(owner, account, subject)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
      end
    end)
  end
end
