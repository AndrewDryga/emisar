defmodule Emisar.ApiKeysDeviceGrantConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, ApiKeys, Fixtures, Repo, RequestContext}
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.ApiKeys.{ApiKey, DeviceGrant}
  alias Emisar.Users.User

  @moduletag timeout: 60_000

  test "a committed role demotion beats a waiting device-grant claim" do
    assert_authorization_change_wins(fn state ->
      state.membership
      |> Repo.reload!()
      |> Membership.Changeset.update(%{role: :viewer})
      |> Repo.update()
    end)
  end

  test "a committed suspension beats a waiting device-grant claim" do
    assert_authorization_change_wins(fn state ->
      state.membership
      |> Repo.reload!()
      |> Membership.Changeset.suspend(nil)
      |> Repo.update()
    end)
  end

  test "a committed removal beats a waiting device-grant claim" do
    assert_authorization_change_wins(fn state ->
      state.membership
      |> Repo.reload!()
      |> Membership.Changeset.delete()
      |> Repo.update()
    end)
  end

  test "a claim holding the membership finishes before a waiting demotion" do
    unboxed_device_grant(fn state ->
      parent = self()
      blocker = grant_blocker(state.grant, parent)

      try do
        assert_receive {:grant_locked, blocker_backend}, 5_000

        claimant =
          unboxed_task(fn ->
            send(parent, {:claimant_backend, backend_pid()})
            ApiKeys.claim_device_grant(state.device_code)
          end)

        try do
          assert_receive {:claimant_backend, claimant_backend}, 5_000
          await_blocked_by(claimant_backend, blocker_backend)

          demoter =
            unboxed_task(fn ->
              send(parent, {:demoter_backend, backend_pid()})
              Accounts.update_membership_role(state.membership, :viewer, state.owner_subject)
            end)

          try do
            assert_receive {:demoter_backend, demoter_backend}, 5_000
            await_blocked_by(demoter_backend, claimant_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)

            assert {:ok, %{client_keys: %{"claude-code" => _raw}}} =
                     Task.await(claimant, 30_000)

            assert {:ok, %Membership{role: :viewer}} = Task.await(demoter, 30_000)
            assert Repo.reload!(state.grant).status == :claimed
            assert %ApiKey{revoked_at: %DateTime{}} = Repo.one!(ApiKey)
          after
            stop_tasks([demoter])
          end
        after
          stop_tasks([claimant])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  defp assert_authorization_change_wins(change) do
    unboxed_device_grant(fn state ->
      parent = self()

      changer =
        unboxed_task(fn ->
          send(parent, {:changer_backend, backend_pid()})

          Repo.transaction(fn ->
            result = change.(state)
            send(parent, {:authorization_change_staged, result})

            receive do
              :commit -> result
            end
          end)
        end)

      try do
        assert_receive {:changer_backend, changer_backend}, 5_000
        assert_receive {:authorization_change_staged, {:ok, _membership}}, 5_000

        claimant =
          unboxed_task(fn ->
            send(parent, {:claimant_backend, backend_pid()})
            ApiKeys.claim_device_grant(state.device_code)
          end)

        try do
          assert_receive {:claimant_backend, claimant_backend}, 5_000
          await_blocked_by(claimant_backend, changer_backend)

          send(changer.pid, :commit)
          assert {:ok, {:ok, _membership}} = Task.await(changer, 30_000)
          assert Task.await(claimant, 30_000) == {:error, :access_denied}
          # This direct row transition deliberately skips the public API's
          # defense-in-depth invalidation, so the surviving approved row proves
          # the claim-time membership check caused the denial.
          assert Repo.reload!(state.grant).status == :approved
          assert Repo.all(ApiKey) == []
        after
          stop_tasks([claimant])
        end
      after
        send(changer.pid, :commit)
        stop_tasks([changer])
      end
    end)
  end

  defp unboxed_device_grant(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      owner = Fixtures.Users.create_user(%{email: "grant-owner-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Device grant #{suffix}", slug: "device-grant-#{suffix}"},
          owner
        )

      member = Fixtures.Users.create_user(%{email: "grant-member-#{suffix}@example.test"})

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account)
      member_subject = Fixtures.Subjects.membership_subject(membership)

      {:ok, device_code, _user_code, pending_grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, grant} = ApiKeys.approve_device_grant(pending_grant, member_subject)

      try do
        fun.(%{
          account: account,
          device_code: device_code,
          grant: grant,
          membership: membership,
          owner_subject: owner_subject
        })
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))
        Repo.delete_all(from(stored in User, where: stored.id in ^[owner.id, member.id]))
        Repo.delete_all(from(stored in DeviceGrant, where: stored.id == ^grant.id))
      end
    end)
  end

  defp grant_blocker(%DeviceGrant{} = grant, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        DeviceGrant.Query.by_device_code_digest(grant.device_code_digest)
        |> DeviceGrant.Query.lock_for_update()
        |> Repo.fetch!(DeviceGrant.Query)

        send(parent, {:grant_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end
end
