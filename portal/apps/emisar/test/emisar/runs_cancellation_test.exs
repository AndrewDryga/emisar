defmodule Emisar.RunsCancellationTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Approvals, Audit, Fixtures, Repo, Runners, Runs}

  describe "cancellation_allowed?/2" do
    test "checks the complete frozen targets without requiring a live catalog" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.disable_runner(runner)
      run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, status: :sent)
      foreign = Fixtures.Runs.create_run()

      assert Runs.cancellation_allowed?([run], subject)
      refute Runs.cancellation_allowed?([run, foreign], subject)
      refute Runs.cancellation_allowed?([%{run | pack_ref: "unproven"}], subject)
      refute Runs.cancellation_allowed?([], subject)
      refute Runs.cancellation_allowed?(List.duplicate(run, 257), subject)
      refute Runs.cancellation_allowed?([run], %{subject | permissions: MapSet.new()})

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
      refute Runs.cancellation_allowed?([run], subject)
      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.all())
      assert Runs.cancellation_allowed?([run], subject)
      Fixtures.Runners.mark_deleted(runner)
      refute Runs.cancellation_allowed?([run], subject)
      Fixtures.Memberships.suspend_membership(membership)
      refute Runs.cancellation_allowed?([run], subject)
      refute Repo.one(Audit.Event)
    end
  end

  describe "cancel_run/3" do
    test "an operator can cancel its frozen pack on a disabled offline runner without a catalog" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.disable_runner(runner)
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      {:ok, access} = RunnerAccess.new(:restricted, [], [runner.id], :restricted, ["postgres"])
      membership = Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          status: :sent,
          pack_ref: pack_ref("postgres")
        )

      assert {:ok, cancelled} = Runs.cancel_run(run, subject, "stop")
      assert cancelled.status == :cancelling
      assert Repo.reload!(run).reason_text == "stop"
      assert Repo.one(Audit.Event).event_type == "run.cancel_requested"
    end

    test "runner and pack scope independently deny every cancellable status without side effects" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      {:ok, wrong_runner} = RunnerAccess.new(:restricted, ["staging"], [], :all)
      {:ok, wrong_pack} = RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])
      Runners.subscribe_runner_transport(runner)

      for access <- [wrong_runner, wrong_pack],
          status <- [:pending, :pending_approval, :sent, :running, :cancelling] do
        Fixtures.Memberships.force_runner_access(membership, access)

        run =
          Fixtures.Runs.create_run(
            account_id: account.id,
            runner_id: runner.id,
            status: status,
            pack_ref: pack_ref("postgres")
          )

        request = Fixtures.Approvals.create_request(account_id: account.id, run_id: run.id)
        assert {:ok, _visible} = Runs.fetch_run_by_id(run.id, subject)
        assert Runs.cancel_run(run, subject, "forbidden") == {:error, :unauthorized}
        assert Repo.reload!(run) == run
        assert Repo.reload!(request) == request
      end

      refute Repo.one(Audit.Event)
      refute Repo.one(Approvals.Grant)
      refute_received {:cloud_to_runner, _, %{"type" => "cancel"}}
    end

    test "a runner's current group replaces its historical group for cancellation" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "staging")
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      membership = Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)
      run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, status: :sent)
      Fixtures.Runners.move_to_group(runner, "production")

      assert Runs.cancel_run(run, subject) == {:error, :unauthorized}
      assert Repo.reload!(run) == run
      refute Repo.one(Audit.Event)
    end

    test "a changed catalog cannot substitute its pack for the run's persisted pack" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      {:ok, postgres} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
      membership = Fixtures.Memberships.force_runner_access(membership, postgres)
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Catalog.create_action(runner: runner, action_id: "svc.read", pack_id: "linux-core")

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          status: :pending,
          pack_ref: pack_ref("postgres")
        )

      assert {:ok, cancelled} = Runs.cancel_run(run, subject)
      assert cancelled.status == :cancelled
    end

    test "deleted targets and malformed frozen refs are denied even to an owner" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      subject = Fixtures.Subjects.membership_subject(membership)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      invalid =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          status: :pending,
          pack_ref: "postgres@unproven"
        )

      assert Runs.cancel_run(invalid, subject) == {:error, :unauthorized}
      Fixtures.Runners.mark_deleted(runner)

      deleted =
        Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, status: :sent)

      assert {:ok, _visible} = Runs.fetch_run_by_id(deleted.id, subject)
      assert Runs.cancel_run(deleted, subject) == {:error, :unauthorized}
      assert Repo.reload!(invalid) == invalid
      assert Repo.reload!(deleted) == deleted
      refute Repo.one(Audit.Event)
    end

    test "terminal cancellation is a no-op even when an inconsistent pending request remains" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      subject = Fixtures.Subjects.membership_subject(membership)
      run = Fixtures.Runs.create_run(account_id: account.id)
      request = Fixtures.Approvals.create_request(account_id: account.id, run_id: run.id)
      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())

      assert {:ok, unchanged} = Runs.cancel_run(run, subject)
      assert unchanged.id == run.id
      assert Repo.reload!(run) == run
      assert Repo.reload!(request) == request
      refute Repo.one(Audit.Event)
    end
  end

  describe "fetch_and_lock_cancellation_access/2" do
    test "returns the bound member's current access and refuses a stale demoted role" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)

      assert Runs.fetch_and_lock_cancellation_access(subject, repo: Repo) == {:ok, access}
      Fixtures.Memberships.force_role(membership, "viewer")
      assert Runs.fetch_and_lock_cancellation_access(subject) == {:error, :unauthorized}
    end

    test "inactive and directory-pending memberships cannot use their old subject" do
      account = Fixtures.Accounts.create_account()

      for invalidate <- [
            &Fixtures.Memberships.suspend_membership/1,
            &Fixtures.Memberships.mark_membership_as_deleted/1,
            &Fixtures.Memberships.mark_directory_authorization_pending(&1, 2)
          ] do
        membership = Fixtures.Memberships.create_membership(account_id: account.id)
        subject = Fixtures.Subjects.membership_subject(membership)
        invalidate.(membership)
        assert Runs.fetch_and_lock_cancellation_access(subject) == {:error, :unauthorized}
      end
    end

    test "a different user's or account's membership never grants cancellation authority" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      subject = Fixtures.Subjects.membership_subject(membership)
      other_user = Fixtures.Users.create_user()
      foreign = Fixtures.Memberships.create_membership()
      mismatched = %{subject | actor: other_user}
      cross_account = %{subject | membership_id: foreign.id}

      assert Runs.fetch_and_lock_cancellation_access(mismatched) == {:error, :unauthorized}
      assert Runs.fetch_and_lock_cancellation_access(cross_account) == {:error, :unauthorized}
      Fixtures.Accounts.disable_account(account)
      assert Runs.fetch_and_lock_cancellation_access(subject) == {:error, :unauthorized}
    end
  end

  describe "ensure_cancellation_targets_authorized/4" do
    test "pack-less targets require all packs, while corrupt and incomplete targets fail closed" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      target = %{account_id: account.id, runner_id: runner.id, pack_ref: nil}
      {:ok, restricted} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

      assert Runs.ensure_cancellation_targets_authorized(account.id, [target], RunnerAccess.all()) ==
               :ok

      assert Runs.ensure_cancellation_targets_authorized(account.id, [target], restricted) ==
               {:error, :unauthorized}

      for targets <- [
            [],
            [%{target | runner_id: Ecto.UUID.generate()}],
            [%{target | account_id: Ecto.UUID.generate()}],
            [Map.delete(target, :runner_id)],
            [%{target | pack_ref: "invalid"}]
          ] do
        assert Runs.ensure_cancellation_targets_authorized(
                 account.id,
                 targets,
                 RunnerAccess.all()
               ) == {:error, :unauthorized}
      end
    end
  end

  defp pack_ref(pack_id), do: pack_id <> "@1.0.0/sha256:" <> String.duplicate("a", 64)
end
