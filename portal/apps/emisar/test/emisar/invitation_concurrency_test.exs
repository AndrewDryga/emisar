defmodule Emisar.InvitationConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Fixtures, Repo}
  alias Emisar.Accounts.{Account, RunnerAccess}
  alias Emisar.Runners.Runner
  alias Emisar.Users.User

  test "inviting a group does not wait for a runner's unrelated update" do
    Sandbox.unboxed_run(Repo, fn ->
      owner = Fixtures.Users.create_user()
      invitee = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(membership)
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      parent = self()

      updater =
        unboxed_task(fn ->
          Repo.transact(fn ->
            Runner.Query.not_deleted()
            |> Runner.Query.by_id(runner.id)
            |> Runner.Query.lock_for_update()
            |> Repo.one!()

            send(parent, :runner_locked)

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)

      Process.unlink(updater.pid)

      try do
        assert_receive :runner_locked, 5_000

        attrs =
          Fixtures.Accounts.invitation_attrs(
            email: invitee.email,
            runner_access_mode: "restricted",
            scope: ["group:production"]
          )

        invitation = unboxed_task(fn -> Accounts.invite_user_to_account(attrs, subject) end)
        Process.unlink(invitation.pid)

        try do
          assert {:ok, {:ok, %{membership: invited}}} = Task.yield(invitation, 5_000)

          assert Accounts.runner_access_for_memberships([invited])[invited.id] ==
                   %RunnerAccess{mode: :restricted, groups: ["production"], runner_ids: []}
        after
          stop_tasks([invitation])
        end
      after
        send(updater.pid, :release)
        Task.yield(updater, 5_000) || Task.shutdown(updater, :brutal_kill)
        Repo.delete_all(from(a in Account, where: a.id == ^account.id))
        user_ids = [owner.id, invitee.id]
        Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      end
    end)
  end
end
