defmodule Emisar.ApiKeysRotationConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, ApiKeys, Audit, Fixtures, Repo, Users}
  alias Emisar.ApiKeys.ApiKey

  @moduletag timeout: 60_000

  test "revoking the old key contains a successor whose first use is waiting" do
    unboxed_rotation(fn %{source: source, successor: successor, raw: raw, subject: subject} ->
      parent = self()

      blocker = source_blocker(source, parent)

      try do
        assert_receive {:source_locked, blocker_backend}, 5_000

        revoker =
          unboxed_task(fn ->
            send(parent, {:revoker_ready, backend_pid()})
            ApiKeys.revoke_api_key(source, subject)
          end)

        try do
          assert_receive {:revoker_ready, revoker_backend}, 5_000
          await_blocked_by(revoker_backend, blocker_backend)

          authenticator =
            unboxed_task(fn ->
              send(parent, {:authenticator_ready, backend_pid()})
              ApiKeys.peek_api_key_by_secret(raw)
            end)

          try do
            assert_receive {:authenticator_ready, authenticator_backend}, 5_000
            await_blocked(authenticator_backend)
            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)

            assert {:ok, %ApiKey{revoked_at: %DateTime{}}} = Task.await(revoker, 30_000)
            assert is_nil(Task.await(authenticator, 30_000))
            assert %DateTime{} = Repo.reload!(successor).revoked_at
            assert Repo.reload!(successor).revoked_by_membership_id == subject.membership_id
            refute ApiKeys.peek_api_key_by_secret(raw)
          after
            stop_tasks([authenticator])
          end
        after
          stop_tasks([revoker])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "first use finishes before a waiting revoke, which still contains the successor" do
    unboxed_rotation(fn %{source: source, successor: successor, raw: raw, subject: subject} ->
      parent = self()
      blocker = source_blocker(source, parent)

      try do
        assert_receive {:source_locked, blocker_backend}, 5_000

        authenticator =
          unboxed_task(fn ->
            send(parent, {:authenticator_ready, backend_pid()})
            ApiKeys.peek_api_key_by_secret(raw)
          end)

        try do
          assert_receive {:authenticator_ready, authenticator_backend}, 5_000
          await_blocked_by(authenticator_backend, blocker_backend)

          revoker =
            unboxed_task(fn ->
              send(parent, {:revoker_ready, backend_pid()})
              ApiKeys.revoke_api_key(source, subject)
            end)

          try do
            assert_receive {:revoker_ready, revoker_backend}, 5_000
            await_blocked_by(revoker_backend, authenticator_backend)
            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert %ApiKey{} = Task.await(authenticator, 30_000)
            assert {:ok, retired} = Task.await(revoker, 30_000)
            assert %DateTime{} = retired.revoked_at
            assert is_nil(retired.revoked_by_membership_id)
            assert Repo.reload!(successor).revoked_by_membership_id == subject.membership_id
            refute ApiKeys.peek_api_key_by_secret(raw)

            assert {:ok, [event], _} =
                     Audit.list_events(subject, filter: [event_type: ["api_key.revoked"]])

            assert event.target_id == successor.id

            assert {:ok, [retirement], _} =
                     Audit.list_events(subject,
                       filter: [event_type: ["api_key.retired_by_rotation"]]
                     )

            assert retirement.target_id == source.id
          after
            stop_tasks([revoker])
          end
        after
          stop_tasks([authenticator])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "an already-used successor does not wait for an account update" do
    unboxed_rotation(fn %{raw: raw, subject: subject} ->
      assert ApiKeys.peek_api_key_by_secret(raw)
      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, _account} = Accounts.fetch_and_lock_account(subject.account.id)
            send(parent, :account_locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      try do
        assert_receive :account_locked, 5_000
        authenticator = unboxed_task(fn -> ApiKeys.peek_api_key_by_secret(raw) end)

        try do
          assert %ApiKey{} = Task.await(authenticator, 5_000)
        after
          stop_tasks([authenticator])
        end
      after
        send(blocker.pid, :release)
        assert {:ok, :ok} = Task.await(blocker, 30_000)
        stop_tasks([blocker])
      end
    end)
  end

  defp source_blocker(source, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_id(source.id)
        |> ApiKey.Query.lock_for_update()
        |> Repo.fetch!(ApiKey.Query)

        send(parent, {:source_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp unboxed_rotation(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      try do
        {:ok, _raw, source} = ApiKeys.create_key(%{name: "Rotating key"}, subject)
        {:ok, raw, successor} = ApiKeys.rotate_api_key(source, subject)
        fun.(%{source: source, successor: successor, raw: raw, subject: subject})
      after
        Repo.delete_all(from(row in Accounts.Account, where: row.id == ^account.id))
        Repo.delete_all(from(row in Users.User, where: row.id == ^user.id))
      end
    end)
  end
end
