defmodule Emisar.ApprovalsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Approvals, Audit, Fixtures, Repo, Runbooks, Runners, Runs, Users}

  @moduletag timeout: 60_000

  test "concurrent overrides release, audit, and dispatch exactly once" do
    unboxed_request(fn %{request: request, owner: owner} ->
      parent = self()

      contenders =
        for reason <- ["primary incident commander", "backup incident commander"] do
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :override -> Approvals.override_request(request, reason, owner)
            end
          end)
        end

      contender_pids =
        for _ <- contenders do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(contender_pids, &send(&1, :override))
      results = Enum.map(contenders, &Task.await(&1, 30_000))

      assert Enum.count(
               results,
               &match?({:ok, {%Approvals.Request{status: :approved}, _run}}, &1)
             ) == 1

      assert Enum.count(results, fn
               {:error, reason} when reason in [:already_decided, :run_not_pending_approval] ->
                 true

               _ ->
                 false
             end) == 1

      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 1_000
      refute_receive {:cloud_to_runner, _generation, _message}, 100

      assert %Approvals.Request{status: :approved} = Repo.reload!(request)
      refute Repo.exists?(by_request(Approvals.Decision, request.id))
      refute Repo.exists?(by_approval_request(Approvals.Grant, request.id))

      events =
        Audit.Event
        |> where([event], event.target_id == ^request.id)
        |> where([event], event.event_type in ["approval.overridden", "approval.approved"])
        |> Repo.all()

      assert [%Audit.Event{event_type: "approval.overridden"}] = events
    end)
  end

  test "a concurrent runner group change closes a restricted owner's override scope" do
    unboxed_request(fn %{
                         request: request,
                         owner: owner,
                         owner_membership: owner_membership,
                         runner: runner,
                         run: run
                       } ->
      {:ok, restricted} = Accounts.RunnerAccess.restricted([runner.group], [])

      {:ok, _membership} =
        Repo.transaction(fn ->
          Fixtures.Memberships.force_runner_access(owner_membership, restricted)
        end)

      parent = self()

      group_changer =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, _runner} = Runners.apply_state(runner, %{"group" => "moved-out-of-scope"})
            send(parent, {:group_change_ready, backend_pid()})

            receive do
              :commit -> :committed
            end
          end)
        end)

      assert_receive {:group_change_ready, group_change_backend}, 5_000

      override =
        unboxed_task(fn ->
          send(parent, {:override_ready, backend_pid()})
          Approvals.override_request(request, "Emergency release", owner)
        end)

      try do
        assert_receive {:override_ready, override_backend}, 5_000
        await_blocked_by(override_backend, group_change_backend)

        send(group_changer.pid, :commit)
        assert Task.await(group_changer, 30_000) == {:ok, :committed}
        assert Task.await(override, 30_000) == {:error, :not_found}

        assert %Runners.Runner{group: "moved-out-of-scope"} = Repo.reload!(runner)
        assert %Approvals.Request{status: :pending} = Repo.reload!(request)
        assert %Runs.ActionRun{status: :pending_approval} = Repo.reload!(run)

        refute Repo.exists?(
                 Audit.Event
                 |> where([event], event.target_id == ^request.id)
                 |> where([event], event.event_type == "approval.overridden")
               )

        refute_receive {:cloud_to_runner, _generation, _message}, 100
      after
        send(group_changer.pid, :commit)
        stop_tasks([group_changer, override])
      end
    end)
  end

  test "a concurrent demotion prevents invalid-runbook cleanup" do
    Sandbox.unboxed_run(Repo, fn ->
      account = Fixtures.Accounts.create_account()
      owner_user = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner_user.id,
          role: "owner"
        )

      owner = Fixtures.Subjects.membership_subject(owner_membership)

      request =
        Fixtures.Approvals.create_execution_request(account, owner_user,
          executable?: false,
          min_approvals: 2
        )

      parent = self()

      demoter =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            assert %Accounts.Membership{role: :operator} =
                     Fixtures.Memberships.force_role(owner_membership, "operator")

            send(parent, {:demotion_ready, backend_pid()})

            receive do
              :commit -> :committed
            end
          end)
        end)

      assert_receive {:demotion_ready, demoter_backend}, 5_000

      override =
        unboxed_task(fn ->
          send(parent, {:override_ready, backend_pid()})
          Approvals.override_request(request, "Invalid plan cannot wait", owner)
        end)

      try do
        assert_receive {:override_ready, override_backend}, 5_000
        await_blocked_by(override_backend, demoter_backend)

        send(demoter.pid, :commit)
        assert Task.await(demoter, 30_000) == {:ok, :committed}
        assert Task.await(override, 30_000) == {:error, :unauthorized}

        assert %Accounts.Membership{role: :operator} = Repo.reload!(owner_membership)
        assert %Approvals.Request{status: :pending} = Repo.reload!(request)

        assert %Runbooks.RunbookExecution{status: :pending_approval} =
                 Repo.get!(Runbooks.RunbookExecution, request.runbook_execution_id)

        refute Repo.exists?(
                 Audit.Event
                 |> where([event], event.target_id == ^request.id)
                 |> where([event], event.event_type == "approval.overridden")
               )
      after
        send(demoter.pid, :commit)
        stop_tasks([demoter, override])

        Repo.delete_all(
          from(account_row in Accounts.Account, where: account_row.id == ^account.id)
        )

        Repo.delete_all(from(user in Users.User, where: user.id == ^owner_user.id))
      end
    end)
  end

  defp unboxed_request(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner)
      Emisar.Runners.subscribe_runner_transport(runner)

      initiator = Fixtures.Users.create_user()

      initiator_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: initiator.id,
          role: "operator"
        )

      owner_user = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner_user.id,
          role: "owner"
        )

      owner = Fixtures.Subjects.membership_subject(owner_membership)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          requested_by_id: initiator.id,
          initiating_membership_id: initiator_membership.id,
          args: %{},
          status: :pending_approval
        })

      {:ok, request} =
        Approvals.create_request(run, initiator.id, "urgent", min_approvals: 2)

      try do
        fun.(%{
          request: request,
          owner: owner,
          owner_membership: owner_membership,
          runner: runner,
          run: run
        })
      after
        Repo.delete_all(from(account in Accounts.Account, where: account.id == ^account.id))

        Repo.delete_all(
          from(user in Users.User, where: user.id in ^[initiator.id, owner_user.id])
        )
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

  defp by_request(queryable, request_id),
    do: where(queryable, [row], row.request_id == ^request_id)

  defp by_approval_request(queryable, request_id),
    do: where(queryable, [row], row.approval_request_id == ^request_id)

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
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

  defp stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end
end
