defmodule Emisar.AccountsConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Config, Crypto, Fixtures, Mail, Marketing, Repo, RequestContext}
  alias Emisar.Accounts.{Account, Membership, RunnerAccess}
  alias Emisar.Audit.Event, as: AuditEvent
  alias Emisar.Auth.UserToken

  @moduletag timeout: 60_000

  defmodule RecordingMfaResetSessionDisconnector do
    def disconnect_live_sessions(topics) do
      owner = Emisar.Config.fetch_env!(:emisar, :task07_disconnect_test_pid)
      send(owner, {:mfa_reset_disconnect, topics, Emisar.Repo.in_transaction?()})
      :ok
    end
  end

  test "MFA enforcement cannot commit while the owner is concurrently disabling MFA" do
    unboxed_owner(fn account, owner, subject, recovery_code ->
      parent = self()

      disable =
        unboxed_task(fn ->
          send(parent, {:disable_backend, backend_pid()})

          Repo.transaction(fn ->
            {:ok, _locked_member} =
              Accounts.fetch_and_lock_active_membership(Repo, owner.account_id, owner.id)

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
      assert {:ok, {:ok, %Membership{mfa_enabled_at: nil}}} = Task.await(disable, 30_000)

      assert Task.await(enforce, 30_000) == {:error, :mfa_enrollment_required}
      refute Repo.reload!(account).settings.require_mfa
      refute Repo.reload!(owner).mfa_enabled_at
    end)
  end

  test "MFA enrollment stays locked until enforcement commits" do
    unboxed_owner(fn account, owner, subject, recovery_code ->
      parent = self()

      # Enforcement takes the owner's row after the account's; holding that row
      # parks enforcement exactly where it has judged the enrollment and not
      # yet committed, and queues the disable behind it.
      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, _locked} =
              Accounts.fetch_and_lock_active_membership(Repo, owner.account_id, owner.id)

            send(parent, {:owner_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:owner_locked, blocker_backend}, 5_000

      enforce =
        unboxed_task(fn ->
          send(parent, {:enforce_backend, backend_pid()})
          Accounts.update_account(account, %{settings: %{require_mfa: true}}, subject)
        end)

      assert_receive {:enforce_backend, enforce_backend}, 5_000
      await_blocked_by(enforce_backend, blocker_backend)

      disable =
        unboxed_task(fn ->
          send(parent, {:disable_backend, backend_pid()})
          Auth.disable_mfa(recovery_code, subject)
        end)

      assert_receive {:disable_backend, disable_backend}, 5_000
      await_blocked_by(disable_backend, enforce_backend)

      send(blocker.pid, :release)
      assert {:ok, :ok} = Task.await(blocker, 30_000)

      assert {:ok, %Account{settings: %{require_mfa: true}}} = Task.await(enforce, 30_000)
      assert {:ok, %Membership{mfa_enabled_at: nil}} = Task.await(disable, 30_000)
      assert Repo.reload!(account).settings.require_mfa
      refute Repo.reload!(owner).mfa_enabled_at
    end)
  end

  test "a committed actor-session revocation makes the waiting MFA reset stale" do
    unboxed_mfa_reset(fn reset ->
      parent = self()

      revoker =
        unboxed_task(fn ->
          send(parent, {:revoker_backend, backend_pid()})

          Repo.transaction(fn ->
            # The revocation's own transaction cannot nest; its delete is held
            # open here the way an in-flight revocation holds the row.
            :ok = Fixtures.Auth.delete_session_token!(reset.actor_session_token)
            send(parent, :actor_session_revocation_staged)

            receive do
              :commit -> :ok
            end
          end)
        end)

      try do
        assert_receive {:revoker_backend, revoker_backend}, 5_000
        assert_receive :actor_session_revocation_staged, 5_000

        resetter = member_mfa_reset_task(reset, parent, :revoker_first_reset_backend)

        try do
          assert_receive {:revoker_first_reset_backend, reset_backend}, 5_000
          await_blocked_by(reset_backend, revoker_backend)

          send(revoker.pid, :commit)
          assert {:ok, :ok} = Task.await(revoker, 30_000)

          assert Task.await(resetter, 30_000) == {:error, :mfa_reset_proof_stale}
          refute is_nil(Repo.reload!(reset.target_membership).mfa_enabled_at)

          assert {:ok, _session} =
                   Auth.fetch_session_by_token(reset.target_session_token, reset.account.id)

          assert mfa_reset_audit_count(reset.account.id) == 0
          refute_receive {:mfa_reset_disconnect, _topics, _in_transaction?}
        after
          stop_tasks([resetter])
        end
      after
        send(revoker.pid, :commit)
        stop_tasks([revoker])
      end
    end)
  end

  test "an MFA reset holding the actor session makes a waiting revocation run after commit" do
    unboxed_mfa_reset(fn reset ->
      parent = self()
      target_blocker = session_token_blocker(reset.target_session_token, parent)

      try do
        assert_receive {:session_token_locked, target_backend}, 5_000
        resetter = member_mfa_reset_task(reset, parent, :reset_first_backend)

        try do
          assert_receive {:reset_first_backend, reset_backend}, 5_000
          await_blocked_by(reset_backend, target_backend)

          revoker =
            unboxed_task(fn ->
              send(parent, {:waiting_revoker_backend, backend_pid()})

              Auth.revoke_session_tokens(
                [reset.actor_session_token],
                :dead_entry,
                %RequestContext{}
              )
            end)

          try do
            assert_receive {:waiting_revoker_backend, revoker_backend}, 5_000
            await_blocked_by(revoker_backend, reset_backend)

            send(target_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(target_blocker, 30_000)
            assert {:ok, %Membership{mfa_enabled_at: nil}} = Task.await(resetter, 30_000)
            assert :ok = Task.await(revoker, 30_000)

            expected_topic = Auth.live_socket_topic(Crypto.hash(reset.target_session_token))
            assert_receive {:mfa_reset_disconnect, [^expected_topic], false}, 5_000
            refute_receive {:mfa_reset_disconnect, _topics, _in_transaction?}

            assert Auth.fetch_session_by_token(reset.target_session_token, reset.account.id) ==
                     {:error, :not_found}

            assert Auth.fetch_session_by_token(reset.actor_session_token, reset.account.id) ==
                     {:error, :not_found}

            assert mfa_reset_audit_count(reset.account.id) == 1
          after
            stop_tasks([revoker])
          end
        after
          stop_tasks([resetter])
        end
      after
        send(target_blocker.pid, :release)
        stop_tasks([target_blocker])
      end
    end)
  end

  test "a demotion that commits first refuses the stale owner's self-promotion queued behind it" do
    unboxed_stale_owner(fn %{demoting: demoting, stale_owner: stale_owner, stale: stale} ->
      parent = self()

      # Holding the stale owner's row parks the demotion right after it took the
      # workspace lock — the lock the stale owner's own attempt then queues on.
      blocker = membership_blocker(stale_owner, parent)

      try do
        assert_receive {:membership_locked, blocker_backend}, 5_000

        demoter =
          unboxed_task(fn ->
            send(parent, {:demoter_backend, backend_pid()})

            Accounts.update_membership_role(stale_owner, "admin", demoting,
              runner_access: RunnerAccess.all()
            )
          end)

        try do
          assert_receive {:demoter_backend, demoter_backend}, 5_000
          await_blocked_by(demoter_backend, blocker_backend)

          promoter =
            unboxed_task(fn ->
              send(parent, {:promoter_backend, backend_pid()})
              Accounts.update_membership_role(stale_owner, "owner", stale)
            end)

          try do
            assert_receive {:promoter_backend, promoter_backend}, 5_000
            await_blocked_by(promoter_backend, demoter_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert {:ok, %Membership{role: :admin}} = Task.await(demoter, 30_000)
            assert Task.await(promoter, 30_000) == {:error, :cannot_self_promote}
            assert Repo.reload!(stale_owner).role == :admin
          after
            stop_tasks([promoter])
          end
        after
          stop_tasks([demoter])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  # Two owners, each with the Subject its session gives it; the second one's is
  # taken before anything changes, the way a mounted Team page holds it.
  defp unboxed_stale_owner(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      account =
        Fixtures.Accounts.create_account(%{
          name: "Stale owner concurrency #{suffix}",
          slug: "stale-owner-#{suffix}"
        })

      demoting_owner =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "stale-owner-demoter-#{suffix}@example.test"
        )

      stale_owner =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "stale-owner-#{suffix}@example.test"
        )

      try do
        fun.(%{
          demoting: Fixtures.Subjects.subject_for(demoting_owner),
          stale_owner: stale_owner,
          stale: Fixtures.Subjects.subject_for(stale_owner)
        })
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))
      end
    end)
  end

  defp membership_blocker(%Membership{} = membership, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        {:ok, _locked} =
          Accounts.fetch_and_lock_active_membership(Repo, membership.account_id, membership.id)

        send(parent, {:membership_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  test "two erasures of one address in different workspaces clear it once no Member keeps it" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      address = "erased-#{suffix}@example.test"

      members =
        for n <- 1..2 do
          account =
            Fixtures.Accounts.create_account(%{
              name: "Erasure #{n} #{suffix}",
              slug: "erasure-#{n}-#{suffix}"
            })

          Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
          Fixtures.Memberships.create_membership(account_id: account.id, email: address)
        end

      {:ok, _} = Mail.suppress(address, :hard_bounce, "HardBounce")
      {:ok, _} = Marketing.capture_signup(%{email: address})
      parent = self()

      try do
        # Holding the address lock parks each erasure after it deleted its
        # Member and before it checks who still uses the address: the race in
        # which each one would otherwise see the other Member still live.
        holder =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.query!(
                "SELECT pg_advisory_xact_lock(hashtextextended($1 || lower($2), 0))",
                ["emisar.accounts.erased_address:", address]
              )

              send(parent, {:holder_backend, backend_pid()})

              receive do
                :release -> :ok
              end
            end)
          end)

        assert_receive {:holder_backend, holder_backend}, 5_000

        erasures =
          for member <- members do
            member_id = member.id

            erasure =
              unboxed_task(fn ->
                send(parent, {:erasure_backend, member_id, backend_pid()})
                Accounts.erase_member(member.account_id, member_id)
              end)

            assert_receive {:erasure_backend, ^member_id, erasure_backend}, 5_000
            await_blocked_by(erasure_backend, holder_backend)
            erasure
          end

        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 30_000)

        for erasure <- erasures do
          assert {:ok, %{account: nil}} = Task.await(erasure, 30_000)
        end

        refute Mail.suppressed?(address)
        refute Repo.one(Marketing.Signup.Query.by_email(address))
      after
        Repo.delete_all(
          from(account in Account, where: account.id in ^Enum.map(members, & &1.account_id))
        )

        Mail.erase_suppression(address)
        Marketing.erase_signup(address)
      end
    end)
  end

  defp unboxed_owner(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      account =
        Fixtures.Accounts.create_account(%{
          name: "Accounts concurrency #{suffix}",
          slug: "accounts-concurrency-#{suffix}"
        })

      owner =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "accounts-concurrency-#{suffix}@example.test"
        )

      {:ok, _policy} = Emisar.Policies.seed_policy(account.id, owner.id)
      subject = Fixtures.Subjects.subject_for(owner)

      {owner, [recovery_code | _rest]} =
        Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      try do
        fun.(account, owner, subject, recovery_code)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
      end
    end)
  end

  defp unboxed_mfa_reset(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      account =
        Fixtures.Accounts.create_account(%{
          name: "MFA reset concurrency #{suffix}",
          slug: "mfa-reset-#{suffix}"
        })

      actor =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "mfa-reset-actor-#{suffix}@example.test"
        )

      {:ok, _policy} = Emisar.Policies.seed_policy(account.id, actor.id)
      actor_subject = Fixtures.Subjects.subject_for(actor)

      {actor, [recovery_code | _remaining_codes]} =
        Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), actor_subject)

      actor_session_token = Fixtures.Auth.create_session_token!(actor, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(actor, session: actor_session_token)

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email: "mfa-reset-target-#{suffix}@example.test"
        )
        |> Fixtures.Memberships.set_mfa_state(
          mfa_secret: "JBSWY3DPEHPK3PXP",
          mfa_enabled_at: DateTime.utc_now(),
          mfa_recovery_codes: ["digest-a", "digest-b"]
        )

      target_session_token =
        Fixtures.Auth.create_session_token!(target_membership, :magic_link, nil)

      actor_session_token_digest = Crypto.hash(actor_session_token)

      {:ok, proof} =
        Accounts.verify_member_mfa_reset(
          target_membership,
          {:recovery_code, recovery_code},
          actor_session_token_digest,
          subject
        )

      try do
        fun.(%{
          account: account,
          actor: actor,
          actor_session_token: actor_session_token,
          actor_session_token_digest: actor_session_token_digest,
          proof: proof,
          subject: subject,
          target_membership: target_membership,
          target_session_token: target_session_token
        })
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))
      end
    end)
  end

  defp member_mfa_reset_task(reset, parent, backend_tag) do
    unboxed_task(fn ->
      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingMfaResetSessionDisconnector}
      )

      Config.put_override(:emisar, :task07_disconnect_test_pid, parent)
      send(parent, {backend_tag, backend_pid()})

      Accounts.reset_member_mfa(
        reset.target_membership,
        reset.proof,
        reset.actor_session_token_digest,
        reset.subject
      )
    end)
  end

  defp session_token_blocker(raw_token, parent) do
    digest = Crypto.hash(raw_token)

    unboxed_task(fn ->
      Repo.transaction(fn ->
        UserToken.Query.by_token_digest(digest)
        |> UserToken.Query.lock_for_update()
        |> Repo.fetch!(UserToken.Query)

        send(parent, {:session_token_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp mfa_reset_audit_count(account_id) do
    AuditEvent.Query.all()
    |> AuditEvent.Query.by_account_id(account_id)
    |> AuditEvent.Query.by_event_type("user.mfa_reset_by_admin")
    |> Repo.aggregate(:count)
  end
end
