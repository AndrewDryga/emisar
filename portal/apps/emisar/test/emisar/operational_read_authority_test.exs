defmodule Emisar.OperationalReadAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Fixtures, Policies, Runs}

  for role <- ["admin", "operator", "viewer"] do
    test "#{role} reads history, output, audit and saved policies without action grants" do
      membership = Fixtures.Memberships.create_membership(role: unquote(role))
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())
      run = Fixtures.Runs.create_run(account_id: subject.account.id)

      policy =
        Fixtures.Policies.create_policy(
          account_id: subject.account.id,
          scope_type: :group,
          scope_value: "production"
        )

      {:ok, event} = Audit.log(subject.account.id, "runner.created")

      assert {:ok, ^run} = Runs.fetch_run_by_id(run.id, subject)
      assert {:ok, %{}} = Runs.list_recent_events_for_runs([run.id], 8, subject)
      assert {:ok, [listed], _} = Runs.list_runs(subject)
      assert listed.id == run.id
      assert {:ok, ^event} = Audit.fetch_event_by_id(event.id, subject)
      assert {:ok, ^policy} = Policies.fetch_scoped_policy_by_id(policy.id, subject)

      assert {:ok, %{target: {:group, "production"}}} =
               Policies.preview_policy(Policies.editor_input(policy.rules), policy.id, subject)
    end
  end

  for invalidation <- [:suspended, :deleted_user, :disabled_account] do
    test "all operational read boundaries reject #{invalidation} live identity" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      run = Fixtures.Runs.create_run(account_id: subject.account.id)

      policy =
        Fixtures.Policies.create_policy(
          account_id: subject.account.id,
          scope_type: :group,
          scope_value: "production"
        )

      {:ok, event} = Audit.log(subject.account.id, "runner.created")
      invalidate(membership, subject, unquote(invalidation))

      for read <- [
            fn -> Runs.list_runs(subject) end,
            fn -> Runs.list_recent_runs(subject) end,
            fn -> Runs.list_run_operator_options(subject) end,
            fn -> Runs.list_run_runbook_options(subject) end,
            fn -> Runs.fetch_run_by_id(run.id, subject) end,
            fn -> Runs.list_recent_events_for_run(run, 8, subject) end,
            fn -> Runs.list_recent_events_for_runs([run.id], 8, subject) end,
            fn -> Audit.list_events(subject) end,
            fn -> Audit.fetch_event_by_id(event.id, subject) end,
            fn -> Audit.available_event_kinds(subject) end,
            fn -> Audit.list_actor_options("user", subject) end,
            fn -> Audit.list_target_options("runner", subject) end,
            fn -> Policies.fetch_policy(subject) end,
            fn -> Policies.list_scoped_policy_summaries(subject) end,
            fn -> Policies.fetch_scoped_policy_by_id(policy.id, subject) end
          ] do
        assert read.() == {:error, :unauthorized}
      end

      assert Audit.resolve_references([event], subject) == %{}
    end
  end

  test "demotion to Billing manager narrows a stale audit subject and its reference labels" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)

    {:ok, operational} =
      Audit.log(subject.account.id, "runner.created", target_kind: "runner", target_id: runner.id)

    {:ok, billing} = Audit.log(subject.account.id, "subscription.changed")
    Fixtures.Memberships.force_role(membership, "billing_manager")

    assert {:ok, [listed], _} = Audit.list_events(subject)
    assert listed.id == billing.id
    assert Audit.fetch_event_by_id(operational.id, subject) == {:error, :not_found}
    assert Audit.list_for_export(subject) == {:error, :unauthorized}
    assert Audit.resolve_references([operational], subject)["runner"] in [nil, %{}]
    assert Runs.list_runs(subject) == {:error, :unauthorized}
    assert Policies.list_scoped_policy_summaries(subject) == {:error, :unauthorized}
  end

  test "permission denials never query identity" do
    membership = Fixtures.Memberships.create_membership(role: "operator")
    subject = Fixtures.Subjects.membership_subject(membership)
    denied = %{subject | permissions: MapSet.new()}
    handler = "operational-read-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:emisar, :repo, :query], &__MODULE__.query_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    assert Runs.list_runs(denied) == {:error, :unauthorized}
    assert Audit.list_events(denied) == {:error, :unauthorized}
    assert Policies.fetch_policy(denied) == {:error, :unauthorized}
    refute_receive :operational_read_query
  end

  describe "project_authorized_account_args/2" do
    test "already-authorized per-row projection is query-free and rejects foreign runs" do
      account = Fixtures.Accounts.create_account()

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          args_raw: ~s({"token":"private","count":1}),
          sensitive_arg_names: ["token"]
        )

      foreign_id = Ecto.UUID.generate()
      handler = "run-projection-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(handler, [:emisar, :repo, :query], &__MODULE__.query_event/4, self())

      on_exit(fn -> :telemetry.detach(handler) end)

      for _row <- 1..100 do
        assert {:ok, %{"token" => "[REDACTED]", "count" => _}} =
                 Runs.project_authorized_account_args(run, account.id)
      end

      assert Runs.project_authorized_account_args(run, foreign_id) == {:error, :not_found}
      refute_receive :operational_read_query
    end
  end

  def query_event(_event, _measurements, _metadata, owner) do
    if self() == owner, do: send(owner, :operational_read_query)
  end

  defp invalidate(membership, _subject, :suspended),
    do: Fixtures.Memberships.suspend_membership(membership)

  defp invalidate(_membership, subject, :deleted_user),
    do: Fixtures.Users.mark_user_as_deleted(subject.actor)

  defp invalidate(_membership, subject, :disabled_account),
    do: Fixtures.Accounts.disable_account(subject.account)
end
