defmodule Emisar.RunnerAdministrationAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Fixtures, Repo, Runners}
  alias Emisar.Accounts.RunnerAccess

  setup do
    {user, account, _owner} = Fixtures.Subjects.owner_subject()
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    membership = Fixtures.Memberships.force_role(membership, "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    {_raw, token} = Fixtures.Runners.create_token(runner)
    runner = Fixtures.Runners.set_connection_credential(runner, token)

    {_raw, key} =
      Fixtures.Runners.create_enrollment_key(account_id: account.id, created_by_id: user.id)

    Fixtures.Accounts.force_runner_inactive_retention_hours(account, 24)
    %{account: account, membership: membership, subject: subject, runner: runner, key: key}
  end

  for invalidation <- [
        :demoted,
        :suspended,
        :deleted,
        :directory_pending,
        :deleted_user,
        :disabled_account
      ] do
    test "all administration rejects #{invalidation} current authority without side effects",
         %{account: _, membership: _, subject: _, runner: _, key: _} = context do
      invalidate(context, unquote(invalidation))
      before = administration_state(context)

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
        assert {:error, _reason} = administer(operation, context)
      end

      assert {:error, _reason} =
               Accounts.put_account_runner_inactive_retention_hours(
                 context.account.id,
                 48,
                 context.subject
               )

      assert administration_state(context) == before
      refute Runners.subject_can_create_enrollment_keys?(context.subject)
      refute Runners.subject_can_manage_inactive_retention?(context.subject)
    end
  end

  test "explicit permission attenuation is retained at every administration boundary",
       %{account: _, membership: _, subject: _, runner: _, key: _} = context do
    context = %{context | subject: %{context.subject | permissions: MapSet.new()}}
    before = administration_state(context)

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
      assert {:error, :unauthorized} = administer(operation, context)
    end

    assert {:error, :unauthorized} =
             Accounts.put_account_runner_inactive_retention_hours(
               context.account.id,
               48,
               context.subject
             )

    assert administration_state(context) == before
  end

  test "scope-independent enrollment containment does not authorize install or runner mutations",
       %{account: _, membership: _, subject: _, runner: _, key: _} = context do
    Fixtures.Memberships.force_runner_access(context.membership, RunnerAccess.none())

    for operation <- [:disable, :enable, :delete, :rotation, :create_key, :install, :retention] do
      assert {:error, _reason} = administer(operation, context)
    end

    assert {:ok, revoked} = administer(:revoke_key, context)
    assert revoked.revoked_at
    before = administration_state(context)
    assert {:ok, ^revoked} = administer(:revoke_key, context)
    assert administration_state(context) == before
  end

  test "a supplied revoked timestamp cannot bypass durable revocation",
       %{account: _, membership: _, subject: _, runner: _, key: _} = context do
    forged = %{context.key | revoked_at: DateTime.utc_now()}
    assert {:ok, revoked} = Runners.revoke_enrollment_key(forged, context.subject)
    assert Repo.reload!(context.key).revoked_at == revoked.revoked_at
  end

  test "pack-only restrictions do not block runner lifecycle, install, or cleanup settings",
       %{account: _, membership: _, subject: _, runner: _, key: _} = context do
    {:ok, access} = RunnerAccess.new(:all, [], [], :restricted, [])
    Fixtures.Memberships.force_runner_access(context.membership, access)
    assert {:ok, _} = administer(:rotation, context)
    assert {:ok, _} = administer(:disable, context)
    assert {:ok, _} = administer(:enable, context)
    assert {:ok, _, _} = administer(:create_key, context)
    assert {:ok, _, _} = administer(:install, context)
    assert {:ok, _} = administer(:retention, context)
    assert Runners.subject_can_install_runners?(context.subject)
    assert {:ok, _} = administer(:delete, context)
  end

  test "the manual sweep is scoped while the system sweep remains account-wide",
       %{account: account, membership: membership, subject: subject} do
    inside = old_offline_runner(account, "staging")
    outside = old_offline_runner(account, "production")
    {:ok, access} = RunnerAccess.restricted(["staging"], [])
    Fixtures.Memberships.force_runner_access(membership, access)

    assert {:ok, 1} = Runners.sweep_inactive_runners(subject)
    assert Repo.reload!(inside).deleted_at
    refute Repo.reload!(outside).deleted_at
    assert {:ok, 1} = Runners.delete_inactive_runners(account.id, 24)
    assert Repo.reload!(outside).deleted_at
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

  defp invalidate(context, :demoted),
    do: Fixtures.Memberships.force_role(context.membership, "viewer")

  defp invalidate(context, :suspended),
    do: Fixtures.Memberships.suspend_membership(context.membership)

  defp invalidate(context, :deleted),
    do: Fixtures.Memberships.mark_membership_as_deleted(context.membership)

  defp invalidate(context, :directory_pending),
    do: Fixtures.Memberships.mark_directory_authorization_pending(context.membership, 1)

  defp invalidate(context, :deleted_user),
    do: Fixtures.Users.mark_user_as_deleted(context.subject.actor)

  defp invalidate(context, :disabled_account),
    do: Fixtures.Accounts.disable_account(context.account)

  defp administration_state(context) do
    {Repo.reload!(context.runner), Repo.reload!(context.account), Repo.all(Runners.EnrollmentKey),
     Repo.all(Audit.Event)}
  end

  defp old_offline_runner(account, group) do
    account.id
    |> then(&Fixtures.Runners.create_runner(account_id: &1, group: group, connected?: false))
    |> Fixtures.Runners.mark_disconnected_at(DateTime.add(DateTime.utc_now(), -48 * 3_600))
  end
end
