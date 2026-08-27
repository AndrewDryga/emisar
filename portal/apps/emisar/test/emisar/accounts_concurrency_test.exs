defmodule Emisar.AccountsConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Config, Crypto, Fixtures, Repo, Users}
  alias Emisar.Accounts.Account
  alias Emisar.Audit.Event, as: AuditEvent
  alias Emisar.Auth.UserToken
  alias Emisar.Users.User

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

  test "a committed actor-session revocation makes the waiting MFA reset stale" do
    unboxed_mfa_reset(fn reset ->
      parent = self()

      revoker =
        unboxed_task(fn ->
          send(parent, {:revoker_backend, backend_pid()})

          Repo.transaction(fn ->
            :ok = Auth.delete_session_token(reset.actor_session_token)
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
          refute is_nil(Repo.reload!(reset.target_user).mfa_enabled_at)

          assert {:ok, _target, _session} =
                   Auth.fetch_user_and_token_by_session_token(reset.target_session_token)

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
              Auth.delete_session_token(reset.actor_session_token)
            end)

          try do
            assert_receive {:waiting_revoker_backend, revoker_backend}, 5_000
            await_blocked_by(revoker_backend, reset_backend)

            send(target_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(target_blocker, 30_000)
            assert {:ok, %User{mfa_enabled_at: nil}} = Task.await(resetter, 30_000)
            assert :ok = Task.await(revoker, 30_000)

            expected_topic = Auth.live_socket_topic_for_session(reset.target_session_token)
            assert_receive {:mfa_reset_disconnect, [^expected_topic], false}, 5_000
            refute_receive {:mfa_reset_disconnect, _topics, _in_transaction?}

            assert Auth.fetch_user_and_token_by_session_token(reset.target_session_token) ==
                     {:error, :not_found}

            assert Auth.fetch_user_and_token_by_session_token(reset.actor_session_token) ==
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

  test "cross-account peer owners take globally ordered user locks" do
    unboxed_cross_account_mfa_reset(fn lower_reset, higher_reset, higher_user, accounts ->
      parent = self()
      user_blocker = user_blocker(higher_user, parent)

      try do
        assert_receive {:user_locked, user_backend}, 5_000
        lower_resetter = member_mfa_reset_task(lower_reset, parent, :lower_reset_backend)

        try do
          assert_receive {:lower_reset_backend, lower_backend}, 5_000
          await_blocked_by(lower_backend, user_backend)

          higher_resetter = member_mfa_reset_task(higher_reset, parent, :higher_reset_backend)

          try do
            assert_receive {:higher_reset_backend, higher_backend}, 5_000
            await_blocked_by(higher_backend, lower_backend)

            send(user_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(user_blocker, 30_000)

            assert {:ok, %User{mfa_enabled_at: nil}} = Task.await(lower_resetter, 30_000)

            assert Task.await(higher_resetter, 30_000) ==
                     {:error, :mfa_reset_proof_stale}

            expected_topic =
              Auth.live_socket_topic_for_session(higher_reset.actor_session_token)

            assert_receive {:mfa_reset_disconnect, [^expected_topic], false}, 5_000
            refute_receive {:mfa_reset_disconnect, _topics, _in_transaction?}
            assert is_nil(Repo.reload!(higher_reset.actor).mfa_enabled_at)
            refute is_nil(Repo.reload!(lower_reset.actor).mfa_enabled_at)

            assert Auth.fetch_user_and_token_by_session_token(higher_reset.actor_session_token) ==
                     {:error, :not_found}

            assert {:ok, _actor, _session} =
                     Auth.fetch_user_and_token_by_session_token(lower_reset.actor_session_token)

            assert Enum.map(accounts, &mfa_reset_audit_count(&1.id)) |> Enum.sum() == 1
          after
            stop_tasks([higher_resetter])
          end
        after
          stop_tasks([lower_resetter])
        end
      after
        send(user_blocker.pid, :release)
        stop_tasks([user_blocker])
      end
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

  defp unboxed_mfa_reset(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      actor = Fixtures.Users.create_user(%{email: "mfa-reset-actor-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "MFA reset concurrency #{suffix}", slug: "mfa-reset-#{suffix}"},
          actor
        )

      actor_subject = Fixtures.Subjects.subject_for(actor, account)

      {actor, [recovery_code | _remaining_codes]} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), actor_subject)

      subject = Fixtures.Subjects.subject_for(actor, account)
      actor_session_token = Fixtures.Auth.create_session_token!(actor, :magic_link, nil)

      target_user =
        Fixtures.Users.create_user(%{email: "mfa-reset-target-#{suffix}@example.test"})
        |> Fixtures.Users.set_mfa_state(
          mfa_secret: "JBSWY3DPEHPK3PXP",
          mfa_enabled_at: DateTime.utc_now(),
          mfa_recovery_codes: ["digest-a", "digest-b"]
        )

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      target_session_token = Fixtures.Auth.create_session_token!(target_user, :magic_link, nil)
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
          target_session_token: target_session_token,
          target_user: target_user
        })
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))

        Repo.delete_all(from(stored in User, where: stored.id in ^[actor.id, target_user.id]))
      end
    end)
  end

  defp unboxed_cross_account_mfa_reset(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      actor_a = Fixtures.Users.create_user(%{email: "peer-reset-a-#{suffix}@example.test"})
      actor_b = Fixtures.Users.create_user(%{email: "peer-reset-b-#{suffix}@example.test"})

      {:ok, account_a} =
        Accounts.create_account_with_owner(
          %{name: "Peer reset A #{suffix}", slug: "peer-reset-a-#{suffix}"},
          actor_a
        )

      {:ok, account_b} =
        Accounts.create_account_with_owner(
          %{name: "Peer reset B #{suffix}", slug: "peer-reset-b-#{suffix}"},
          actor_b
        )

      membership_b_in_a =
        Fixtures.Memberships.create_membership(
          account_id: account_a.id,
          user_id: actor_b.id,
          role: "owner"
        )

      membership_a_in_b =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: actor_a.id,
          role: "owner"
        )

      subject_a = Fixtures.Subjects.subject_for(actor_a, account_a)
      subject_b = Fixtures.Subjects.subject_for(actor_b, account_b)

      {actor_a, [recovery_a | _]} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject_a)

      {actor_b, [recovery_b | _]} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject_b)

      subject_a_in_a = Fixtures.Subjects.subject_for(actor_a, account_a)
      subject_b_in_b = Fixtures.Subjects.subject_for(actor_b, account_b)
      session_a = Fixtures.Auth.create_session_token!(actor_a, :magic_link, nil)
      session_b = Fixtures.Auth.create_session_token!(actor_b, :magic_link, nil)
      digest_a = Crypto.hash(session_a)
      digest_b = Crypto.hash(session_b)

      {:ok, local_proof_a} =
        Auth.verify_current_session_mfa_challenge(
          {:recovery_code, recovery_a},
          subject_a_in_a
        )

      {:ok, local_proof_b} =
        Auth.verify_current_session_mfa_challenge(
          {:recovery_code, recovery_b},
          subject_b_in_b
        )

      actor_a = Repo.reload!(actor_a)
      actor_b = Repo.reload!(actor_b)
      subject_a_in_a = Fixtures.Subjects.subject_for(actor_a, account_a)
      subject_b_in_b = Fixtures.Subjects.subject_for(actor_b, account_b)

      {:ok, proof_a} =
        Auth.issue_member_mfa_reset_proof(
          membership_b_in_a,
          actor_b,
          {:local, local_proof_a},
          digest_a,
          subject_a_in_a
        )

      {:ok, proof_b} =
        Auth.issue_member_mfa_reset_proof(
          membership_a_in_b,
          actor_a,
          {:local, local_proof_b},
          digest_b,
          subject_b_in_b
        )

      reset_a = %{
        actor: actor_a,
        actor_session_token: session_a,
        actor_session_token_digest: digest_a,
        proof: proof_a,
        subject: subject_a_in_a,
        target_membership: membership_b_in_a
      }

      reset_b = %{
        actor: actor_b,
        actor_session_token: session_b,
        actor_session_token_digest: digest_b,
        proof: proof_b,
        subject: subject_b_in_b,
        target_membership: membership_a_in_b
      }

      {lower_reset, higher_reset, higher_user} =
        if actor_a.id < actor_b.id,
          do: {reset_a, reset_b, actor_b},
          else: {reset_b, reset_a, actor_a}

      try do
        fun.(lower_reset, higher_reset, higher_user, [account_a, account_b])
      after
        account_ids = [account_a.id, account_b.id]
        Repo.delete_all(from(stored in Account, where: stored.id in ^account_ids))

        Repo.delete_all(from(stored in User, where: stored.id in ^[actor_a.id, actor_b.id]))
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

  defp user_blocker(user, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        User.Query.not_deleted()
        |> User.Query.by_id(user.id)
        |> User.Query.lock_for_update()
        |> Repo.fetch!(User.Query)

        send(parent, {:user_locked, backend_pid()})

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
