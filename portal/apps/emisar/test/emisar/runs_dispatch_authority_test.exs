defmodule Emisar.RunsDispatchAuthorityTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Fixtures, Repo, Runners, Runs}
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Auth.Subject

  test "ordinary unsigned dispatch freezes the verified pack for later authority checks" do
    membership = Fixtures.Memberships.create_membership(role: "operator")
    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id)
    Fixtures.Catalog.create_action(runner: runner)
    Fixtures.Policies.create_policy(account_id: subject.account.id)
    attrs = Fixtures.Runs.dispatch_attrs(runner_id: runner.id)
    Runners.subscribe_runner_transport(runner)

    assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)
    assert run.pack_ref == Fixtures.Catalog.default_pack_ref()
    assert Repo.reload!(run).pack_ref == run.pack_ref
    assert_receive {:cloud_to_runner, _generation, payload}, 500
    assert payload["pack_ref"] == run.pack_ref
    refute Map.has_key?(payload, "attestation")
  end

  for invalidation <- [:demoted, :suspended, :deleted, :pending, :deleted_user, :disabled_account] do
    test "dispatch and a previously composed batch reject #{invalidation} authority" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      runner = Fixtures.Runners.create_runner(account_id: subject.account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Fixtures.Policies.create_policy(account_id: subject.account.id)
      attrs = Fixtures.Runs.dispatch_attrs(account_id: subject.account.id, runner_id: runner.id)
      Runners.subscribe_runner_transport(runner)

      assert {:ok, multi} =
               Runs.compose_dispatch_batch_in_multi(Multi.new(), [attrs], subject, :test)

      invalidate(membership, subject, unquote(invalidation))

      assert {:error, _reason} = Runs.dispatch_run(attrs, subject)
      assert {:error, _reason} = Repo.commit_multi(multi)
      refute Repo.exists?(Runs.ActionRun)
      refute Repo.exists?(Approvals.Request)
      refute Repo.exists?(Audit.Event)
      refute_receive {:cloud_to_runner, _, _}
    end
  end

  test "a queued human run binds its exact live user and current dispatch permission" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)

    run =
      Fixtures.Runs.create_run(
        account_id: subject.account.id,
        runner_id: runner.id,
        requested_by_id: subject.actor.id,
        initiating_membership_id: membership.id,
        status: :pending
      )

    assert authorize_initiator(run) == {:ok, :authorized}
    foreign_user = Fixtures.Users.create_user()

    assert authorize_initiator(%{run | requested_by_id: foreign_user.id}) ==
             {:error, :initiator_no_longer_authorized}

    Fixtures.Memberships.force_role(membership, "viewer")
    assert authorize_initiator(run) == {:error, :initiator_no_longer_authorized}
    Fixtures.Memberships.force_role(membership, "admin")
    Fixtures.Users.mark_user_as_deleted(subject.actor)
    assert authorize_initiator(run) == {:error, :initiator_no_longer_authorized}
  end

  test "delayed pack authority comes from the frozen reference without any current catalog" do
    membership = Fixtures.Memberships.create_membership(role: "operator")
    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)
    {:ok, access} = RunnerAccess.new(:restricted, [], [runner.id], :restricted, ["postgres"])
    Fixtures.Memberships.force_runner_access(membership, access)

    run =
      Fixtures.Runs.create_run(
        account_id: subject.account.id,
        runner_id: runner.id,
        requested_by_id: subject.actor.id,
        initiating_membership_id: membership.id,
        status: :pending,
        pack_ref: "postgres@1.0.0/sha256:" <> String.duplicate("a", 64)
      )

    assert authorize_initiator(run) == {:ok, :authorized}

    assert authorize_initiator(%{run | pack_ref: Fixtures.Catalog.default_pack_ref()}) ==
             {:error, :initiator_no_longer_authorized}

    assert authorize_initiator(%{run | pack_ref: nil}) ==
             {:error, :initiator_no_longer_authorized}
  end

  test "a queued API run cannot borrow another creator's key in the same account" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: subject.account.id,
        created_by_id: subject.actor.id
      )

    other = Fixtures.Memberships.create_membership(account_id: subject.account.id, role: "admin")

    {_raw, other_key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: subject.account.id,
        created_by_id: other.user_id
      )

    run =
      Fixtures.Runs.create_run(
        account_id: subject.account.id,
        runner_id: runner.id,
        api_key_id: key.id,
        initiating_membership_id: membership.id,
        status: :pending
      )

    assert authorize_initiator(run) == {:ok, :authorized}

    assert authorize_initiator(%{run | api_key_id: other_key.id}) ==
             {:error, :initiator_no_longer_authorized}

    Fixtures.ApiKeys.mark_revoked(key)
    assert authorize_initiator(run) == {:error, :initiator_no_longer_authorized}
  end

  describe "fetch_and_lock_dispatch_access/2" do
    test "preserves attenuation, key identity and its fixed role" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      owner = Fixtures.Subjects.membership_subject(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: owner.account.id,
          created_by_id: owner.actor.id
        )

      subject = Subject.for_api_key(key, owner.account)
      assert locked_access(subject) == {:ok, RunnerAccess.all()}
      assert locked_access(%{subject | permissions: MapSet.new()}) == {:error, :unauthorized}

      assert locked_access(%{subject | actor: %{key | credential_lineage_id: Repo.generate_id()}}) ==
               {:error, :unauthorized}

      assert locked_access(%{subject | actor: %{key | kind: :audit_export}}) ==
               {:error, :unauthorized}

      Fixtures.ApiKeys.backdate_api_key_expiry(key)
      assert locked_access(subject) == {:error, :unauthorized}
    end
  end

  defp locked_access(subject) do
    Repo.transact(fn ->
      with {:ok, _account} <- Accounts.fetch_and_lock_account(subject.account.id) do
        Runs.fetch_and_lock_dispatch_access(subject)
      end
    end)
  end

  defp authorize_initiator(run) do
    Repo.transact(fn ->
      with {:ok, _account} <- Accounts.fetch_and_lock_account(run.account_id),
           :ok <- Runs.ensure_run_initiator_authorized(Repo, run) do
        {:ok, :authorized}
      end
    end)
  end

  defp invalidate(membership, _subject, :demoted),
    do: Fixtures.Memberships.force_role(membership, "viewer")

  defp invalidate(membership, _subject, :suspended),
    do: Fixtures.Memberships.suspend_membership(membership)

  defp invalidate(membership, _subject, :deleted),
    do: Fixtures.Memberships.mark_membership_as_deleted(membership)

  defp invalidate(membership, _subject, :pending),
    do: Fixtures.Memberships.mark_directory_authorization_pending(membership, 1)

  defp invalidate(_membership, subject, :deleted_user),
    do: Fixtures.Users.mark_user_as_deleted(subject.actor)

  defp invalidate(_membership, subject, :disabled_account),
    do: Fixtures.Accounts.disable_account(subject.account)
end
