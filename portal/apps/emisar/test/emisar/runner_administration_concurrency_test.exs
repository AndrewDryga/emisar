defmodule Emisar.RunnerAdministrationConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Audit, Fixtures, Repo, Runners, Users}
  alias Emisar.Accounts.RunnerAccess

  @moduletag timeout: 60_000

  test "all runner lifecycle mutations wait for the current group before acting" do
    for operation <- [:disable, :enable, :delete, :rotation] do
      unboxed_runners(fn context ->
        {:ok, access} = RunnerAccess.restricted(["staging"], [])
        Fixtures.Memberships.force_runner_access(context.membership, access)
        before = event_ids(context.account.id)

        result =
          contend(
            fn -> Fixtures.Runners.move_to_group(context.runner, "production") end,
            fn -> administer(operation, context) end
          )

        assert {:error, :not_found} = result
        runner = Repo.reload!(context.runner)
        refute runner.disabled_at
        refute runner.deleted_at
        refute runner.credential_rotation_requested_at
        assert event_ids(context.account.id) == before
      end)
    end
  end

  test "every operator administration boundary waits for a concurrent role loss" do
    for operation <- [
          :disable,
          :enable,
          :delete,
          :rotation,
          :create_key,
          :install,
          :revoke_key,
          :retention,
          :sweep
        ] do
      unboxed_runners(fn context ->
        before = administration_state(context)

        result =
          contend(
            fn -> Fixtures.Memberships.force_role(context.membership, "viewer") end,
            fn -> administer(operation, context) end
          )

        assert {:error, :unauthorized} = result
        assert administration_state(context) == before
      end)
    end
  end

  test "minting and runner retention wait for a concurrent loss of full runner access" do
    for operation <- [:create_key, :install, :retention] do
      unboxed_runners(fn context ->
        before = administration_state(context)

        result =
          contend(
            fn ->
              Fixtures.Memberships.force_runner_access(context.membership, RunnerAccess.none())
            end,
            fn -> administer(operation, context) end
          )

        assert {:error, :unauthorized} = result
        assert administration_state(context) == before
      end)
    end
  end

  defp contend(change, action) do
    parent = self()

    changer =
      unboxed_task(fn ->
        Repo.transaction(fn ->
          change.()
          send(parent, {:changed, backend_pid()})

          receive do
            :commit -> :committed
          end
        end)
      end)

    assert_receive {:changed, blocker}, 5_000

    manager =
      unboxed_task(fn ->
        send(parent, {:manager, backend_pid()})
        action.()
      end)

    try do
      assert_receive {:manager, waiting}, 5_000
      await_blocked_by(waiting, blocker)
      send(changer.pid, :commit)
      assert Task.await(changer, 30_000) == {:ok, :committed}
      Task.await(manager, 30_000)
    after
      send(changer.pid, :commit)
      stop_tasks([changer, manager])
    end
  end

  defp administer(:disable, context), do: Runners.disable_runner(context.runner, context.subject)
  defp administer(:enable, context), do: Runners.enable_runner(context.runner, context.subject)
  defp administer(:delete, context), do: Runners.delete_runner(context.runner, context.subject)

  defp administer(:rotation, context),
    do: Runners.request_credential_rotation(context.runner, context.subject)

  defp administer(:create_key, context), do: Runners.create_enrollment_key(%{}, context.subject)
  defp administer(:install, context), do: Runners.mint_install_key(context.subject)

  defp administer(:revoke_key, context),
    do: Runners.revoke_enrollment_key(context.key, context.subject)

  defp administer(:retention, context),
    do: Runners.update_inactive_retention_settings(context.account, %{hours: 48}, context.subject)

  defp administer(:sweep, context), do: Runners.sweep_inactive_runners(context.subject)

  defp administration_state(context) do
    {Repo.reload!(context.runner), Repo.reload!(context.account), Repo.reload!(context.key),
     Repo.all(
       from(key in Runners.EnrollmentKey,
         where: key.account_id == ^context.account.id,
         order_by: key.id
       )
     ), event_ids(context.account.id)}
  end

  defp event_ids(account_id) do
    Repo.all(
      from(event in Audit.Event,
        where: event.account_id == ^account_id,
        order_by: event.id,
        select: event.id
      )
    )
  end

  defp unboxed_runners(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      cleanup = fn ->
        Repo.delete_all(from(row in Accounts.Account, where: row.id == ^account.id))
        Repo.delete_all(from(row in Users.User, where: row.id == ^user.id))
      end

      on_exit(fn -> Sandbox.unboxed_run(Repo, cleanup) end)

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.membership_subject(membership)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "staging",
          connected?: false
        )

      {_raw, token} = Fixtures.Runners.create_token(runner)
      runner = Fixtures.Runners.set_connection_credential(runner, token)

      {_raw, key} =
        Fixtures.Runners.create_enrollment_key(account_id: account.id, created_by_id: user.id)

      Fixtures.Accounts.force_runner_inactive_retention_hours(account, 24)

      try do
        fun.(%{
          account: account,
          membership: membership,
          subject: subject,
          runner: runner,
          key: key
        })
      after
        cleanup.()
      end
    end)
  end
end
