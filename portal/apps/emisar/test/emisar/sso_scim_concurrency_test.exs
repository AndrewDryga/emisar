defmodule Emisar.SSOSCIMConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Billing, Fixtures, Repo, SSO, Users}
  alias Emisar.Accounts.{Account, Membership, RunnerAccess}
  alias Emisar.SSO.{DirectoryGroup, GroupRoleMapping, GroupRunnerAccessMapping}
  alias Emisar.SSO.{IdentityProvider, LinkRequest, SCIMUserUpdate, UserIdentity}
  alias Emisar.Users.User

  @moduletag timeout: 60_000

  for revocation <- [:disable, :delete], mutation <- [:create, :repost, :rename, :deactivate] do
    test "#{revocation} wins before a stale SCIM #{mutation} and leaves no mutation state" do
      revocation = unquote(revocation)
      mutation = unquote(mutation)

      unboxed_scim(fn context ->
        scenario = prepare_mutation(context, mutation)
        before = scenario.snapshot.()
        audit_count = audit_count(context.account.id, scenario.audit_types)
        :ok = Emisar.Audit.subscribe_account_audit(context.account.id)
        :ok = Accounts.subscribe_account_team(context.account.id)
        parent = self()

        blocker = provider_blocker(context.provider, parent)

        try do
          assert_receive {:provider_locked, blocker_backend}, 5_000

          revoker =
            unboxed_task(fn ->
              send(parent, {:revoker_backend, backend_pid()})
              revoke_provider(context, revocation)
            end)

          try do
            assert_receive {:revoker_backend, revoker_backend}, 5_000
            await_blocked_by(revoker_backend, blocker_backend)

            contender =
              unboxed_task(fn ->
                send(parent, {:mutation_backend, backend_pid()})
                scenario.run.()
              end)

            try do
              assert_receive {:mutation_backend, contender_backend}, 5_000
              await_blocked_by(contender_backend, revoker_backend)

              send(blocker.pid, :release)
              assert {:ok, %IdentityProvider{}} = Task.await(blocker, 30_000)

              assert {:ok, %IdentityProvider{} = revoked} = Task.await(revoker, 30_000)
              assert_provider_revoked(revoked, revocation)

              assert Task.await(contender, 30_000) == {:error, :directory_sync_disabled}
              assert scenario.snapshot.() == before
              assert audit_count(context.account.id, scenario.audit_types) == audit_count

              refute_receive {:audit_event, %Emisar.Audit.Event{actor_kind: "directory_sync"}},
                             100

              refute_receive {:list_changed, :team, "membership.reinstated", _user_id}, 100
              refute_receive {:list_changed, :team, "membership.suspended", _user_id}, 100
            after
              stop_tasks([contender])
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
  end

  test "a re-POST commits before a real disable, whose cleanup then clears its directory grant" do
    unboxed_scim(fn context ->
      attrs = scim_attrs(context, "mutation-first")

      {:ok, %{identity: identity, membership: membership}} =
        SSO.scim_provision_user(context.provider, attrs)

      assert {:ok, %{identity: %{scim_active: false}, membership: suspended}} =
               SSO.scim_update_user(
                 context.provider,
                 identity.id,
                 %SCIMUserUpdate{active: false}
               )

      assert %DateTime{} = suspended.disabled_at
      :ok = Emisar.Audit.subscribe_account_audit(context.account.id)

      parent = self()

      identity_blocker =
        unboxed_task(fn ->
          backend = backend_pid()

          result =
            Repo.transaction(fn ->
              locked = lock_identity!(identity.id)
              send(parent, {:identity_locked, backend})

              receive do
                :release -> locked
              end
            end)

          result
        end)

      try do
        assert_receive {:identity_locked, identity_backend}, 5_000

        mutation =
          unboxed_task(fn ->
            send(parent, {:mutation_backend, backend_pid()})
            SSO.scim_provision_user(context.provider, attrs)
          end)

        try do
          assert_receive {:mutation_backend, mutation_backend}, 5_000
          await_blocked_by(mutation_backend, identity_backend)

          revoker =
            unboxed_task(fn ->
              send(parent, {:revoker_backend, backend_pid()})
              SSO.disable_scim(context.provider, context.subject)
            end)

          try do
            assert_receive {:revoker_backend, revoker_backend}, 5_000
            await_blocked_by(revoker_backend, mutation_backend)

            send(identity_blocker.pid, :release)
            assert {:ok, %UserIdentity{}} = Task.await(identity_blocker, 30_000)

            assert {:ok,
                    %{
                      identity: %UserIdentity{scim_active: true},
                      membership: %Membership{disabled_at: nil}
                    }} = Task.await(mutation, 30_000)

            assert {:ok, %IdentityProvider{scim_enabled: false}} =
                     Task.await(revoker, 30_000)

            cleaned = Repo.reload!(membership)
            assert Repo.reload!(identity).scim_active
            assert is_nil(cleaned.disabled_at)
            refute cleaned.directory_managed
            refute cleaned.runner_access_directory_managed
            assert is_nil(cleaned.directory_provider_id)
            assert is_nil(cleaned.directory_authorization_pending_version)

            assert_receive {:audit_event,
                            %Emisar.Audit.Event{
                              event_type: "membership.reprovisioned_via_scim"
                            }}
          after
            stop_tasks([revoker])
          end
        after
          stop_tasks([mutation])
        end
      after
        send(identity_blocker.pid, :release)
        stop_tasks([identity_blocker])
      end
    end)
  end

  test "a mapping change crossing re-POST fact loading retries and unions the current grants" do
    unboxed_scim(fn context ->
      attrs = scim_attrs(context, "version-retry")

      {:ok, %{identity: identity, membership: membership}} =
        SSO.scim_provision_user(context.provider, attrs)

      assert membership.role == :viewer

      assert Accounts.runner_access_for_membership(context.account.id, membership.id) ==
               RunnerAccess.none()

      for group <- ["baseline", "mapped"] do
        Fixtures.Runners.create_runner(account_id: context.account.id, group: group)
      end

      for pack_id <- ["postgres", "redis"] do
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: context.account.id,
          pack_id: pack_id
        )
      end

      assert {:ok, _group} =
               SSO.scim_upsert_group(context.provider, %{
                 external_id: "grp-current",
                 member_ids: [identity.id]
               })

      membership = Fixtures.Memberships.force_role(membership, "admin")

      assert {:ok, _membership} =
               Repo.transaction(fn ->
                 Fixtures.Memberships.force_runner_access(membership, RunnerAccess.all())
               end)

      {_raw, api_key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: context.account.id,
          created_by_id: identity.user_id
        )

      assert is_nil(Repo.reload!(api_key).revoked_at)

      parent = self()
      writer = staged_provider_authorization(context.provider, parent)

      try do
        assert_receive {:provider_authorization_staged, writer_backend}, 5_000

        mutation =
          unboxed_task(fn ->
            send(parent, {:mutation_backend, backend_pid()})
            SSO.scim_provision_user(context.provider, attrs)
          end)

        try do
          assert_receive {:mutation_backend, mutation_backend}, 5_000
          await_blocked_by(mutation_backend, writer_backend)

          send(writer.pid, :commit)
          assert {:ok, %IdentityProvider{} = current_provider} = Task.await(writer, 30_000)

          assert {:ok, %{membership: updated}} = Task.await(mutation, 30_000)
          assert updated.role == :operator

          assert updated.directory_authorization_version ==
                   current_provider.authorization_version

          assert Accounts.runner_access_for_membership(context.account.id, updated.id) ==
                   %RunnerAccess{
                     mode: :restricted,
                     groups: ["baseline", "mapped"],
                     runner_ids: [],
                     pack_mode: :restricted,
                     pack_ids: ["postgres", "redis"]
                   }

          assert %DateTime{} = Repo.reload!(api_key).revoked_at
        after
          stop_tasks([mutation])
        end
      after
        send(writer.pid, :commit)
        stop_tasks([writer])
      end
    end)
  end

  test "mapping creation and group deletion serialize without resurrecting the deleted grant" do
    unboxed_scim(fn context ->
      attrs = scim_attrs(context, "map-delete")

      {:ok, %{identity: identity, membership: membership}} =
        SSO.scim_provision_user(context.provider, attrs)

      assert {:ok, group} =
               SSO.scim_upsert_group(context.provider, %{
                 display: "Concurrent Admins",
                 member_ids: [identity.id]
               })

      mapper =
        unboxed_task(fn ->
          SSO.create_group_mapping(
            context.provider,
            %{directory_group_id: group.id, role: :admin},
            context.subject
          )
        end)

      deleter = unboxed_task(fn -> SSO.scim_delete_group(context.provider, group.id) end)

      try do
        mapping_result = Task.await(mapper, 30_000)
        assert {:ok, _deleted_group} = Task.await(deleter, 30_000)

        assert match?({:ok, %GroupRoleMapping{}}, mapping_result) or
                 mapping_result == {:error, :not_found}

        assert SSO.scim_fetch_group(context.provider, group.id) == {:error, :not_found}
        assert Repo.reload!(membership).role == :viewer
      after
        stop_tasks([mapper, deleter])
      end
    end)
  end

  for family <- [:role, :runner_access], operation <- [:create, :update] do
    test "subscription cancellation fences a stale #{family} mapping #{operation}" do
      family = unquote(family)
      operation = unquote(operation)

      unboxed_scim(fn context ->
        scenario = paid_mapping_scenario(context, family, operation)
        before = scenario.snapshot.()
        parent = self()
        cancellation = staged_subscription_cancellation(context.account.id, parent)

        try do
          assert_receive {:subscription_cancellation_staged, cancellation_backend}, 5_000

          mutation =
            unboxed_task(fn ->
              send(parent, {:mapping_backend, backend_pid()})
              scenario.run.()
            end)

          try do
            assert_receive {:mapping_backend, mapping_backend}, 5_000
            await_blocked_by(mapping_backend, cancellation_backend)

            send(cancellation.pid, :commit)

            assert {:ok, %Billing.Subscription{status: "canceled"}} =
                     Task.await(cancellation, 30_000)

            assert Task.await(mutation, 30_000) ==
                     {:error, :directory_sync_not_available}

            assert scenario.snapshot.() == before
          after
            stop_tasks([mutation])
          end
        after
          send(cancellation.pid, :commit)
          stop_tasks([cancellation])
        end
      end)
    end
  end

  test "a fresh create waiting on provider config uses the locked current role and access defaults" do
    unboxed_scim(fn context ->
      parent = self()
      writer = staged_provider_defaults(context.provider, parent)

      try do
        assert_receive {:provider_defaults_staged, writer_backend}, 5_000

        mutation =
          unboxed_task(fn ->
            send(parent, {:mutation_backend, backend_pid()})
            SSO.scim_provision_user(context.provider, scim_attrs(context, "current-defaults"))
          end)

        try do
          assert_receive {:mutation_backend, mutation_backend}, 5_000
          await_blocked_by(mutation_backend, writer_backend)

          send(writer.pid, :commit)
          assert {:ok, %IdentityProvider{} = current_provider} = Task.await(writer, 30_000)

          assert {:ok, %{membership: membership}} = Task.await(mutation, 30_000)
          assert membership.role == :operator

          assert membership.directory_authorization_version ==
                   current_provider.authorization_version

          assert Accounts.runner_access_for_membership(context.account.id, membership.id) ==
                   %RunnerAccess{
                     mode: :restricted,
                     groups: ["current-default"],
                     runner_ids: []
                   }
        after
          stop_tasks([mutation])
        end
      after
        send(writer.pid, :commit)
        stop_tasks([writer])
      end
    end)
  end

  test "an unmatched link approval queues account and provider before failing closed" do
    unboxed_scim(fn context ->
      attrs = scim_attrs(context, "approval-order")

      {:ok, %{user: user, membership: membership}} =
        SSO.scim_provision_user(context.provider, attrs)

      membership = Fixtures.Memberships.force_role(membership, "owner")
      approver = Fixtures.Subjects.subject_for(user, context.account, role: :owner)

      request_email = "pending-#{context.suffix}@example.test"

      assert {:ok, %LinkRequest{} = request} =
               Emisar.SSO.Provisioning.capture_link_request(
                 context.provider,
                 "pending-#{context.suffix}",
                 request_email,
                 "Pending Person",
                 %{
                   "email" => request_email,
                   "email_verified" => true,
                   "name" => "Pending Person"
                 },
                 :oidc
               )

      parent = self()
      blocker = membership_blocker(membership, parent)

      try do
        assert_receive {:membership_locked, blocker_backend}, 5_000

        mutation =
          unboxed_task(fn ->
            send(parent, {:mutation_backend, backend_pid()})
            SSO.scim_provision_user(context.provider, attrs)
          end)

        try do
          assert_receive {:mutation_backend, mutation_backend}, 5_000
          await_blocked_by(mutation_backend, blocker_backend)

          approval =
            unboxed_task(fn ->
              send(parent, {:approval_backend, backend_pid()})
              SSO.approve_link_request(request, RunnerAccess.none(), approver)
            end)

          try do
            assert_receive {:approval_backend, approval_backend}, 5_000
            await_blocked_by(approval_backend, mutation_backend)

            send(blocker.pid, :release)
            assert {:ok, %Membership{}} = Task.await(blocker, 30_000)
            assert {:ok, %{membership: %Membership{role: :owner}}} = Task.await(mutation, 30_000)

            assert Task.await(approval, 30_000) ==
                     {:error, :scim_identity_unmatched}

            assert {:ok, %LinkRequest{id: request_id}} =
                     SSO.fetch_pending_link_request(request.id)

            assert request_id == request.id
          after
            stop_tasks([approval])
          end
        after
          stop_tasks([mutation])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "provider deletion wins a queued collision and the fallback refuses to refill" do
    unboxed_scim(fn context ->
      attrs = prepare_collision(context, "delete-first")
      parent = self()
      blocker = account_blocker(context.account.id, parent)

      try do
        assert_receive {:account_locked, blocker_backend}, 5_000

        deletion =
          unboxed_task(fn ->
            send(parent, {:deletion_backend, backend_pid()})
            SSO.delete_provider(context.provider, context.subject)
          end)

        try do
          assert_receive {:deletion_backend, deletion_backend}, 5_000
          await_blocked_by(deletion_backend, blocker_backend)

          collision =
            unboxed_task(fn ->
              send(parent, {:collision_backend, backend_pid()})
              SSO.scim_provision_user(context.provider, attrs)
            end)

          try do
            assert_receive {:collision_backend, collision_backend}, 5_000
            await_blocked_by(collision_backend, deletion_backend)

            send(blocker.pid, :release)
            assert {:ok, %Account{}} = Task.await(blocker, 30_000)

            assert {:ok, %IdentityProvider{deleted_at: %DateTime{}}} =
                     Task.await(deletion, 30_000)

            assert Task.await(collision, 30_000) == {:error, :directory_sync_disabled}
            refute link_request_exists?(context.provider.id)
          after
            stop_tasks([collision])
          end
        after
          stop_tasks([deletion])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "a colliding create queued first cannot refill after deletion wins its fallback" do
    unboxed_scim(fn context ->
      attrs = prepare_collision(context, "collision-first")
      parent = self()
      blocker = account_blocker(context.account.id, parent)

      try do
        assert_receive {:account_locked, blocker_backend}, 5_000

        collision =
          unboxed_task(fn ->
            send(parent, {:collision_backend, backend_pid()})
            SSO.scim_provision_user(context.provider, attrs)
          end)

        try do
          assert_receive {:collision_backend, collision_backend}, 5_000
          await_blocked_by(collision_backend, blocker_backend)

          deletion =
            unboxed_task(fn ->
              send(parent, {:deletion_backend, backend_pid()})
              SSO.delete_provider(context.provider, context.subject)
            end)

          try do
            assert_receive {:deletion_backend, deletion_backend}, 5_000
            await_blocked_by(deletion_backend, collision_backend)

            send(blocker.pid, :release)
            assert {:ok, %Account{}} = Task.await(blocker, 30_000)

            assert {:ok, %IdentityProvider{deleted_at: %DateTime{}}} =
                     Task.await(deletion, 30_000)

            assert Task.await(collision, 30_000) == {:error, :directory_sync_disabled}
            refute link_request_exists?(context.provider.id)
          after
            stop_tasks([deletion])
          end
        after
          stop_tasks([collision])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "a provider disable takes the account fence before the provider row" do
    unboxed_scim(fn context ->
      parent = self()
      account = account_blocker(context.account.id, parent)

      try do
        assert_receive {:account_locked, account_backend}, 5_000

        updater =
          unboxed_task(fn ->
            send(parent, {:update_backend, backend_pid()})
            SSO.update_provider(context.provider, %{enabled: false}, context.subject)
          end)

        try do
          assert_receive {:update_backend, update_backend}, 5_000
          await_blocked_by(update_backend, account_backend)

          provider = provider_blocker(context.provider, parent)

          try do
            # If update_provider still took provider -> account, this probe could
            # not acquire the provider while the update waits on the account.
            assert_receive {:provider_locked, provider_backend}, 5_000

            send(account.pid, :release)
            assert {:ok, %Account{}} = Task.await(account, 30_000)
            await_blocked_by(update_backend, provider_backend)

            send(provider.pid, :release)
            assert {:ok, %IdentityProvider{}} = Task.await(provider, 30_000)

            assert {:ok, %IdentityProvider{enabled: false}} =
                     Task.await(updater, 30_000)
          after
            send(provider.pid, :release)
            stop_tasks([provider])
          end
        after
          stop_tasks([updater])
        end
      after
        send(account.pid, :release)
        stop_tasks([account])
      end
    end)
  end

  defp prepare_mutation(context, :create) do
    attrs = scim_attrs(context, "fresh")

    %{
      run: fn -> SSO.scim_provision_user(context.provider, attrs) end,
      audit_types: ["user.provisioned_via_scim"],
      snapshot: fn ->
        %{
          user: Users.fetch_user_by_email(attrs.email),
          identities: identity_count(context.provider.id),
          memberships: membership_count(context.account.id)
        }
      end
    }
  end

  defp prepare_mutation(context, :repost) do
    attrs = scim_attrs(context, "repost")

    {:ok, %{identity: identity, membership: membership}} =
      SSO.scim_provision_user(context.provider, attrs)

    {:ok, _result} =
      SSO.scim_update_user(context.provider, identity.id, %SCIMUserUpdate{active: false})

    %{
      run: fn -> SSO.scim_provision_user(context.provider, attrs) end,
      audit_types: [
        "membership.reprovisioned_via_scim",
        "membership.role_synced_via_scim",
        "membership.runner_access_synced_via_scim"
      ],
      snapshot: fn -> existing_snapshot(identity, membership) end
    }
  end

  defp prepare_mutation(context, :rename) do
    attrs = scim_attrs(context, "rename")

    {:ok, %{identity: identity, membership: membership}} =
      SSO.scim_provision_user(context.provider, attrs)

    %{
      run: fn ->
        SSO.scim_update_user(context.provider, identity.id, %SCIMUserUpdate{
          name: {:replace, "After"},
          active: :keep
        })
      end,
      audit_types: ["membership.renamed_via_scim", "user.renamed_via_scim"],
      snapshot: fn -> existing_snapshot(identity, membership) end
    }
  end

  defp prepare_mutation(context, :deactivate) do
    attrs = scim_attrs(context, "deactivate")

    {:ok, %{identity: identity, membership: membership}} =
      SSO.scim_provision_user(context.provider, attrs)

    %{
      run: fn ->
        SSO.scim_update_user(context.provider, identity.id, %SCIMUserUpdate{active: false})
      end,
      audit_types: ["membership.deprovisioned_via_scim"],
      snapshot: fn -> existing_snapshot(identity, membership) end
    }
  end

  defp existing_snapshot(identity, membership) do
    current_identity = Repo.reload!(identity)
    current_membership = Repo.reload!(membership)
    {:ok, user} = Users.fetch_user_by_id(identity.user_id)

    %{
      identity: {current_identity.scim_external_id, current_identity.scim_active},
      user_name: user.full_name,
      membership: {current_membership.role, current_membership.disabled_at}
    }
  end

  defp prepare_collision(context, label) do
    email = "#{label}-#{context.suffix}@example.test"
    member = Fixtures.Users.create_user(%{email: email})

    _membership =
      Fixtures.Memberships.create_membership(
        account_id: context.account.id,
        user_id: member.id,
        role: :admin
      )

    %{
      external_id: "#{label}-#{context.suffix}",
      email: email,
      full_name: "Collision"
    }
  end

  defp paid_mapping_scenario(context, :role, operation) do
    {:ok, group} =
      SSO.scim_upsert_group(context.provider, %{
        external_id: "grp-role-#{operation}",
        member_ids: []
      })

    mapping =
      if operation == :update do
        {:ok, mapping} =
          SSO.create_group_mapping(
            context.provider,
            %{directory_group_id: group.id, role: :viewer},
            context.subject
          )

        mapping
      end

    run =
      case operation do
        :create ->
          fn ->
            SSO.create_group_mapping(
              context.provider,
              %{directory_group_id: group.id, role: :admin},
              context.subject
            )
          end

        :update ->
          fn -> SSO.update_group_mapping(mapping, %{role: :admin}, context.subject) end
      end

    %{run: run, snapshot: fn -> role_mapping_snapshot(context.provider.id) end}
  end

  defp paid_mapping_scenario(context, :runner_access, operation) do
    source_group = "source-#{operation}"
    target_group = "target-#{operation}"
    Fixtures.Runners.create_runner(account_id: context.account.id, group: source_group)
    Fixtures.Runners.create_runner(account_id: context.account.id, group: target_group)

    {:ok, group} =
      SSO.scim_upsert_group(context.provider, %{
        external_id: "grp-access-#{operation}",
        member_ids: []
      })

    attrs = fn runner_group ->
      %{
        directory_group_id: group.id,
        runner_access_mode: :restricted,
        scope: ["group:#{runner_group}"]
      }
    end

    mapping =
      if operation == :update do
        {:ok, mapping} =
          SSO.create_group_runner_access_mapping(
            context.provider,
            attrs.(source_group),
            context.subject
          )

        mapping
      end

    run =
      case operation do
        :create ->
          fn ->
            SSO.create_group_runner_access_mapping(
              context.provider,
              attrs.(target_group),
              context.subject
            )
          end

        :update ->
          fn ->
            SSO.update_group_runner_access_mapping(
              mapping,
              attrs.(target_group),
              context.subject
            )
          end
      end

    %{run: run, snapshot: fn -> runner_mapping_snapshot(context.provider.id) end}
  end

  defp role_mapping_snapshot(provider_id) do
    GroupRoleMapping.Query.not_deleted()
    |> GroupRoleMapping.Query.by_provider_id(provider_id)
    |> Repo.all()
    |> Enum.map(&{&1.id, &1.role})
    |> Enum.sort()
  end

  defp runner_mapping_snapshot(provider_id) do
    GroupRunnerAccessMapping.Query.not_deleted()
    |> GroupRunnerAccessMapping.Query.by_provider_id(provider_id)
    |> Repo.all()
    |> Enum.map(&{&1.id, &1.runner_access_mode, &1.runner_scope_groups})
    |> Enum.sort()
  end

  defp staged_subscription_cancellation(account_id, parent) do
    unboxed_task(fn ->
      backend = backend_pid()

      Repo.transaction(fn ->
        {:ok, _account} = Accounts.fetch_and_lock_account(account_id)
        {:ok, subscription} = Billing.upsert_subscription(account_id, %{status: "canceled"})
        send(parent, {:subscription_cancellation_staged, backend})

        receive do
          :commit -> subscription
        end
      end)
    end)
  end

  defp account_blocker(account_id, parent) do
    unboxed_task(fn ->
      backend = backend_pid()

      Repo.transaction(fn ->
        {:ok, locked} = Accounts.fetch_and_lock_account(account_id)
        send(parent, {:account_locked, backend})

        receive do
          :release -> locked
        end
      end)
    end)
  end

  defp membership_blocker(membership, parent) do
    unboxed_task(fn ->
      backend = backend_pid()

      Repo.transaction(fn ->
        locked =
          Membership.Query.not_deleted()
          |> Membership.Query.by_id(membership.id)
          |> Membership.Query.lock_for_update()
          |> Repo.fetch!(Membership.Query)

        send(parent, {:membership_locked, backend})

        receive do
          :release -> locked
        end
      end)
    end)
  end

  defp provider_blocker(provider, parent) do
    unboxed_task(fn ->
      backend = backend_pid()

      Repo.transaction(fn ->
        locked = lock_provider!(provider.id)
        send(parent, {:provider_locked, backend})

        receive do
          :release -> locked
        end
      end)
    end)
  end

  defp revoke_provider(context, :disable),
    do: SSO.disable_scim(context.provider, context.subject)

  defp revoke_provider(context, :delete),
    do: SSO.delete_provider(context.provider, context.subject)

  defp assert_provider_revoked(%IdentityProvider{scim_enabled: false}, :disable), do: :ok

  defp assert_provider_revoked(%IdentityProvider{deleted_at: %DateTime{}}, :delete), do: :ok

  defp staged_provider_authorization(provider, parent) do
    unboxed_task(fn ->
      backend = backend_pid()

      Repo.transaction(fn ->
        locked = lock_provider!(provider.id)

        group =
          DirectoryGroup.Query.not_deleted()
          |> DirectoryGroup.Query.by_account_id(provider.account_id)
          |> DirectoryGroup.Query.by_provider_id(provider.id)
          |> DirectoryGroup.Query.by_external_group_id("grp-current")
          |> Repo.fetch!(DirectoryGroup.Query)

        _role_mapping =
          provider.account_id
          |> GroupRoleMapping.Changeset.create(provider.id, group, %{role: :operator})
          |> Repo.insert!()

        _access_mapping =
          provider.account_id
          |> GroupRunnerAccessMapping.Changeset.create(
            provider.id,
            group,
            %{
              runner_access_mode: :restricted,
              scope: ["group:mapped"],
              pack_access_mode: :restricted,
              pack_scope: ["pack:redis"]
            },
            %{groups: ["mapped"], runners: [], packs: ["redis"]}
          )
          |> Repo.insert!()

        updated =
          locked
          |> Ecto.Changeset.change(
            default_runner_access_mode: :restricted,
            default_runner_scope_groups: ["baseline"],
            default_pack_access_mode: :restricted,
            default_pack_scope_pack_ids: ["postgres"],
            authorization_version: locked.authorization_version + 1
          )
          |> Repo.update!()

        send(parent, {:provider_authorization_staged, backend})

        receive do
          :commit -> updated
        end
      end)
    end)
  end

  defp staged_provider_defaults(provider, parent) do
    unboxed_task(fn ->
      backend = backend_pid()

      Repo.transaction(fn ->
        locked = lock_provider!(provider.id)

        updated =
          locked
          |> Ecto.Changeset.change(
            default_role: :operator,
            default_runner_access_mode: :restricted,
            default_runner_scope_groups: ["current-default"],
            authorization_version: locked.authorization_version + 1
          )
          |> Repo.update!()

        send(parent, {:provider_defaults_staged, backend})

        receive do
          :commit -> updated
        end
      end)
    end)
  end

  defp lock_provider!(provider_id) do
    IdentityProvider.Query.not_deleted()
    |> IdentityProvider.Query.by_id(provider_id)
    |> IdentityProvider.Query.lock_for_update()
    |> Repo.fetch!(IdentityProvider.Query)
  end

  defp lock_identity!(identity_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_id(identity_id)
    |> UserIdentity.Query.lock_for_update()
    |> Repo.fetch!(UserIdentity.Query)
  end

  defp unboxed_scim(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      owner = Fixtures.Users.create_user(%{email: "owner-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "SCIM race #{suffix}", slug: "scim-race-#{suffix}"},
          owner
        )

      _subscription = Fixtures.Accounts.create_subscription(account, "enterprise")
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      provider =
        Fixtures.SSO.create_identity_provider(%{
          account_id: account.id,
          kind: :okta,
          enabled: true,
          default_role: :viewer
        })
        |> Fixtures.SSO.enable_scim()

      try do
        fun.(%{
          account: account,
          subject: subject,
          provider: provider,
          suffix: suffix
        })
      after
        {deleted_accounts, _rows} =
          Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))

        if deleted_accounts != 1 do
          raise "SCIM concurrency fixture failed to delete account #{account.id}"
        end

        Repo.delete_all(from(user in User, where: like(user.email, ^"%-#{suffix}@example.test")))
      end
    end)
  end

  defp scim_attrs(context, label) do
    %{
      external_id: "#{label}-#{context.suffix}",
      email: "#{label}-#{context.suffix}@example.test",
      full_name: "Before"
    }
  end

  defp identity_count(provider_id) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_id(provider_id)
    |> Repo.aggregate(:count)
  end

  defp membership_count(account_id) do
    from(membership in Membership, where: membership.account_id == ^account_id)
    |> Repo.aggregate(:count)
  end

  defp audit_count(account_id, event_types) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account_id)
    |> Emisar.Audit.Event.Query.only_event_types(event_types)
    |> Repo.aggregate(:count)
  end

  defp link_request_exists?(provider_id) do
    LinkRequest.Query.all()
    |> LinkRequest.Query.by_provider_id(provider_id)
    |> Repo.exists?()
  end
end
