defmodule Emisar.RunsDispatchAuthorityTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Fixtures, Repo, Runners, Runs}
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Auth.Subject

  test "ordinary unsigned dispatch freezes the verified pack for later authority checks" do
    membership = Fixtures.Memberships.create_membership(role: "operator")
    subject = Fixtures.Subjects.subject_for(membership)
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

  for invalidation <- [
        :demoted,
        :suspended,
        :deleted,
        :pending,
        :revoked_session,
        :disabled_account
      ] do
    test "dispatch and a previously composed batch reject #{invalidation} authority" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      session = Fixtures.Auth.create_session_token!(membership)
      subject = Fixtures.Subjects.subject_for(membership, session: session)
      runner = Fixtures.Runners.create_runner(account_id: subject.account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Fixtures.Policies.create_policy(account_id: subject.account.id)
      attrs = Fixtures.Runs.dispatch_attrs(account_id: subject.account.id, runner_id: runner.id)
      Runners.subscribe_runner_transport(runner)

      assert {:ok, multi} =
               Runs.compose_dispatch_batch_in_multi(Multi.new(), [attrs], subject, :test)

      held = %{membership: membership, session: session, subject: subject}
      invalidate(unquote(invalidation), held)

      assert {:error, _reason} = Runs.dispatch_run(attrs, subject)
      assert {:error, _reason} = Repo.commit_multi(multi)
      refute Repo.exists?(Runs.ActionRun)
      refute Repo.exists?(Approvals.Request)
      refute Repo.exists?(Audit.Event)
      refute_receive {:cloud_to_runner, _, _}
    end
  end

  test "a queued human run binds its exact live member and current dispatch permission" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.subject_for(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)

    run =
      Fixtures.Runs.create_run(
        account_id: subject.account.id,
        runner_id: runner.id,
        initiating_membership_id: membership.id,
        status: :pending
      )

    assert authorize_initiator(run) == {:ok, :authorized}
    foreign = Fixtures.Memberships.create_membership(role: "admin")

    assert authorize_initiator(%{run | initiating_membership_id: foreign.id}) ==
             {:error, :initiator_no_longer_authorized}

    Fixtures.Memberships.force_role(membership, "viewer")
    assert authorize_initiator(run) == {:error, :initiator_no_longer_authorized}
    membership = membership |> Repo.reload!() |> Fixtures.Memberships.force_role("admin")
    assert authorize_initiator(run) == {:ok, :authorized}
    Fixtures.Memberships.mark_membership_as_deleted(membership)
    assert authorize_initiator(run) == {:error, :initiator_no_longer_authorized}
  end

  test "a subject carrying another Member or another account's member cannot dispatch" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.subject_for(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id)
    Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
    Fixtures.Policies.create_policy(account_id: subject.account.id)
    attrs = Fixtures.Runs.dispatch_attrs(account_id: subject.account.id, runner_id: runner.id)
    Runners.subscribe_runner_transport(runner)
    foreign = Fixtures.Memberships.create_membership(role: "admin")
    other = Fixtures.Memberships.create_membership(account_id: subject.account.id, role: "admin")

    for forged <- [
          %{subject | membership_id: foreign.id},
          %{subject | actor: other}
        ] do
      assert Runs.dispatch_run(attrs, forged) == {:error, :unauthorized}
      assert locked_access(forged) == {:error, :unauthorized}
    end

    refute Repo.exists?(Runs.ActionRun)
    refute_receive {:cloud_to_runner, _, _}
  end

  test "delayed pack authority comes from the frozen reference without any current catalog" do
    membership = Fixtures.Memberships.create_membership(role: "operator")
    subject = Fixtures.Subjects.subject_for(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)
    {:ok, access} = RunnerAccess.new(:restricted, [], [runner.id], :restricted, ["postgres"])
    Fixtures.Memberships.force_runner_access(membership, access)

    run =
      Fixtures.Runs.create_run(
        account_id: subject.account.id,
        runner_id: runner.id,
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
    subject = Fixtures.Subjects.subject_for(membership)
    runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: subject.account.id,
        created_by_membership_id: subject.actor.id
      )

    other = Fixtures.Memberships.create_membership(account_id: subject.account.id, role: "admin")

    {_raw, other_key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: subject.account.id,
        created_by_membership_id: other.id
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
      owner = Fixtures.Subjects.subject_for(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: owner.account.id,
          created_by_membership_id: owner.actor.id
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

  defp invalidate(:demoted, %{membership: membership}),
    do: Fixtures.Memberships.force_role(membership, "viewer")

  defp invalidate(:suspended, %{membership: membership}),
    do: Fixtures.Memberships.suspend_membership(membership)

  defp invalidate(:deleted, %{membership: membership}),
    do: Fixtures.Memberships.mark_membership_as_deleted(membership)

  defp invalidate(:pending, %{membership: membership}),
    do: Fixtures.Memberships.mark_directory_authorization_pending(membership, 1)

  defp invalidate(:revoked_session, %{session: session}),
    do: Fixtures.Auth.delete_session_token!(session)

  defp invalidate(:disabled_account, %{subject: subject}),
    do: Fixtures.Accounts.disable_account(subject.account)
end
