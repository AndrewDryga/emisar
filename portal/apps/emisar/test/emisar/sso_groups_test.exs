defmodule Emisar.SSOGroupsTest do
  @moduledoc """
  IdP groups → emisar role and runner-access mapping. Role is the highest mapped
  role; runner access is the additive union of the provider baseline and every
  mapped group, with `all` dominance. Both are recomputed from one directory
  snapshot and never grant owner.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Repo, SSO}
  alias Emisar.Fixtures
  alias Emisar.SSO.IdentityProvider

  @scim_string_limit 255
  @max_group_member_ids 5_000

  defp enterprise_owner do
    Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
  end

  defp provider_fixture(account, attrs) do
    attrs =
      Map.merge(
        %{
          kind: :okta,
          name: "Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true,
          default_role: :viewer
        },
        Map.new(attrs)
      )

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account.id, attrs))
    provider
  end

  # Enterprise account + a SCIM-enabled provider. Returns the provider, the
  # owner subject, and the account.
  defp scim_provider(provider_attrs \\ %{}) do
    {_user, account, subject} = enterprise_owner()
    provider = provider_fixture(account, provider_attrs)
    {:ok, provider, _raw_token} = SSO.enable_scim(provider, subject)
    %{provider: provider, subject: subject, account: account}
  end

  defp scim_attrs(attrs) do
    Map.merge(
      %{external_id: "okta|#{System.unique_integer([:positive])}", full_name: "Dir User"},
      Map.new(attrs)
    )
  end

  # Provision a directory user and return its identity + the membership role.
  defp provision(provider, external_id) do
    attrs = scim_attrs(%{external_id: external_id})

    {:ok, %{identity: identity, membership: membership}} =
      SSO.scim_provision_user(provider, attrs)

    %{identity: identity, membership: membership}
  end

  defp role_of(account_id, user_id),
    do: Fixtures.Memberships.fetch_membership(account_id, user_id).role

  defp access_of(account_id, user_id) do
    membership = Fixtures.Memberships.fetch_membership(account_id, user_id)
    Accounts.runner_access_for_membership(account_id, membership.id)
  end

  defp synced_access_audit_count(account_id, user_id) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account_id)
    |> Emisar.Audit.Event.Query.by_event_type("membership.runner_access_synced_via_scim")
    |> where([event], event.target_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  defp latest_synced_access_audit(account_id, user_id) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account_id)
    |> Emisar.Audit.Event.Query.by_event_type("membership.runner_access_synced_via_scim")
    |> where([event], event.target_id == ^user_id)
    |> order_by([event], desc: event.inserted_at, desc: event.id)
    |> limit(1)
    |> Repo.one!()
  end

  defp overlong_scim_id, do: String.duplicate("g", @scim_string_limit + 1)
  defp too_many_member_external_ids, do: for(n <- 1..(@max_group_member_ids + 1), do: "okta|#{n}")

  # -- Sync: role from groups ------------------------------------------

  describe "scim_upsert_group / role recompute" do
    setup do
      scim_provider()
    end

    test "scim_upsert_group sets a member's role to the mapped role", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|u1")
      assert role_of(account.id, identity.user_id) == :viewer

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{member_count: 1}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-ops",
                 display: "Operators",
                 member_external_ids: ["okta|u1"]
               })

      assert role_of(account.id, identity.user_id) == :operator
    end

    test "a group push recomputes the role for ALL its members (batched bulk path)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: id1} = provision(provider, "okta|u1")
      %{identity: id2} = provision(provider, "okta|u2")
      assert role_of(account.id, id1.user_id) == :viewer
      assert role_of(account.id, id2.user_id) == :viewer

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{member_count: 2}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-ops",
                 display: "Operators",
                 member_external_ids: ["okta|u1", "okta|u2"]
               })

      # Both members recomputed to :operator in one batched pass (the N+1 fix).
      assert role_of(account.id, id1.user_id) == :operator
      assert role_of(account.id, id2.user_id) == :operator
    end

    test "a member in two mapped groups gets the HIGHEST (admin > operator > viewer)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|multi")

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-view", role: :viewer},
          subject
        )

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-op", role: :operator},
          subject
        )

      # In all three groups → highest mapped role is :admin.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-view",
          member_external_ids: ["okta|multi"]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-op",
          member_external_ids: ["okta|multi"]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|multi"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Drop the admin group → falls back to the next-highest (:operator).
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-adm", member_external_ids: []})

      assert role_of(account.id, identity.user_id) == :operator
    end

    test "removing a member from their only mapped group resets them to the provider default_role (#3)",
         %{provider: provider, subject: subject, account: account} do
      %{identity: identity} = provision(provider, "okta|patch")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|patch"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Patch the member OUT of their only mapped group. With no mapped group
      # left, sync demotes them to the provider's default_role (least-privilege
      # on directory removal — provider default is :viewer).
      assert {:ok, %{removed: 1}} =
               SSO.scim_patch_group_members(provider, "grp-adm", [], ["okta|patch"])

      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "an unknown member external_id in a group is ignored (not yet provisioned)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|known")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-mix", role: :admin}, subject)

      # The group lists a known + an unprovisioned member id; only the known
      # one is tracked + recomputed.
      assert {:ok, %{member_count: 1}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-mix",
                 member_external_ids: ["okta|known", "okta|ghost-not-provisioned"]
               })

      assert role_of(account.id, identity.user_id) == :admin
    end

    test "rejects overlong group and member identifiers before syncing", %{provider: provider} do
      overlong = overlong_scim_id()

      assert {:error, :invalid_scim_group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: overlong,
                 member_external_ids: []
               })

      assert {:error, :invalid_scim_group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-valid",
                 display: overlong,
                 member_external_ids: []
               })

      assert {:error, :invalid_scim_group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-valid",
                 member_external_ids: [overlong]
               })

      assert {:error, :invalid_scim_group} =
               SSO.scim_patch_group_members(provider, "grp-valid", [overlong], [])
    end

    test "rejects oversized group member batches before querying", %{provider: provider} do
      too_many = too_many_member_external_ids()

      assert {:error, :invalid_scim_group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-too-large",
                 member_external_ids: too_many
               })

      assert {:error, :invalid_scim_group} =
               SSO.scim_patch_group_members(provider, "grp-too-large", too_many, [])
    end

    @tag capture_log: true
    test "a refused/failed per-member recompute is logged, not fatal — the push still succeeds",
         %{provider: provider, subject: subject, account: account} do
      %{identity: kept_identity} = provision(provider, "okta|kept")
      %{identity: gone_identity, membership: gone_membership} = provision(provider, "okta|gone")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      # An operator removed one member from the team (membership soft-deleted)
      # while their identity lived on — so the recompute will find no membership
      # for that identity and refuse with :not_found.
      {:ok, _} =
        gone_membership |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      refute Accounts.peek_sync_membership(account.id, gone_identity.user_id)

      # The push lands both members into the mapped group. The recompute for the
      # provisioned member succeeds; the one for the membership-less identity is
      # refused — that refusal is logged (#5), never surfaced as a failure.
      assert {:ok, %{member_count: 2}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-adm",
                 member_external_ids: ["okta|kept", "okta|gone"]
               })

      # The healthy member's role was still recomputed — the failed one didn't
      # abort the batch.
      assert role_of(account.id, kept_identity.user_id) == :admin
    end
  end

  describe "reconcile_pending_authorizations/1" do
    setup do
      scim_provider()
    end

    test "unions mapped groups and revokes access on group removal and mapping deletion", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|runner-union")
      assert access_of(account.id, identity.user_id) == Accounts.RunnerAccess.none()

      {:ok, db_mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            runner_scope_groups: ["db"]
          },
          subject
        )

      {:ok, app_mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-app",
            runner_access_mode: :restricted,
            runner_scope_groups: ["app"]
          },
          subject
        )

      for group_id <- ["grp-db", "grp-app"] do
        {:ok, _group} =
          SSO.scim_upsert_group(provider, %{
            external_id: group_id,
            member_external_ids: ["okta|runner-union"]
          })
      end

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: ["app", "db"],
                 runner_ids: []
               }

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-db",
          member_external_ids: []
        })

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{mode: :restricted, groups: ["app"], runner_ids: []}

      assert {:ok, _deleted} = SSO.delete_group_runner_access_mapping(app_mapping, subject)
      assert access_of(account.id, identity.user_id) == Accounts.RunnerAccess.none()

      assert {:ok, _deleted} = SSO.delete_group_runner_access_mapping(db_mapping, subject)
    end

    test "all dominates restricted grants and deletion reveals the remaining union", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|runner-all")

      {:ok, _restricted} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            runner_scope_groups: ["db"]
          },
          subject
        )

      {:ok, all_mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-all", runner_access_mode: :all},
          subject
        )

      for group_id <- ["grp-db", "grp-all"] do
        {:ok, _group} =
          SSO.scim_upsert_group(provider, %{
            external_id: group_id,
            member_external_ids: ["okta|runner-all"]
          })
      end

      assert access_of(account.id, identity.user_id) == Accounts.RunnerAccess.all()

      assert {:ok, _deleted} = SSO.delete_group_runner_access_mapping(all_mapping, subject)

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{mode: :restricted, groups: ["db"], runner_ids: []}
    end

    test "mapping changes reconcile a deactivated member before reactivation", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|runner-reactivate")

      {:ok, mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            runner_scope_groups: ["db"]
          },
          subject
        )

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-db",
          member_external_ids: ["okta|runner-reactivate"]
        })

      assert {:ok, _result} = SSO.scim_deactivate_user(provider, "okta|runner-reactivate")

      assert {:ok, _updated} =
               SSO.update_group_runner_access_mapping(
                 mapping,
                 %{
                   runner_access_mode: :restricted,
                   runner_scope_groups: ["app"],
                   runner_scope_runner_ids: []
                 },
                 subject
               )

      assert {:ok, _result} = SSO.scim_reactivate_user(provider, "okta|runner-reactivate")

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{mode: :restricted, groups: ["app"], runner_ids: []}
    end

    test "a failed provider change stays durable and fail-closed until a retry converges", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity, membership: membership} =
        provision(provider, "okta|durable-reconcile")

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-runner",
            runner_access_mode: :restricted,
            runner_scope_runner_ids: [runner.id]
          },
          subject
        )

      assert {:ok, _group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-runner",
                 member_external_ids: ["okta|durable-reconcile"]
               })

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: [],
                 runner_ids: [runner.id]
               }

      stale_provider = Repo.reload!(provider)
      audit_count_before = synced_access_audit_count(account.id, membership.user_id)

      deleted_runner =
        runner
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

      assert {:ok, _provider} =
               SSO.update_provider(
                 provider,
                 %{
                   default_runner_access_mode: :restricted,
                   default_runner_scope_groups: ["baseline"],
                   default_runner_scope_runner_ids: []
                 },
                 subject
               )

      pending = Repo.reload!(membership)
      assert is_integer(pending.directory_authorization_pending_version)
      assert access_of(account.id, identity.user_id) == Accounts.RunnerAccess.none()

      assert {:error, :stale_authorization_version} =
               Accounts.sync_set_membership_authorization(
                 pending,
                 :viewer,
                 Accounts.RunnerAccess.none(),
                 stale_provider
               )

      assert Repo.reload!(membership).directory_authorization_pending_version ==
               pending.directory_authorization_pending_version

      deleted_runner
      |> Ecto.Changeset.change(deleted_at: nil)
      |> Repo.update!()

      assert :ok = SSO.reconcile_pending_authorizations()

      reconciled = Repo.reload!(membership)
      assert reconciled.role == :viewer
      assert is_nil(reconciled.directory_authorization_pending_version)

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: ["baseline"],
                 runner_ids: [runner.id]
               }

      assert synced_access_audit_count(account.id, membership.user_id) ==
               audit_count_before + 1

      event = latest_synced_access_audit(account.id, membership.user_id)
      assert event.payload["before"]["mode"] == "none"
      assert event.payload["after"]["groups"] == ["baseline"]
      assert event.payload["after"]["runner_ids"] == [runner.id]

      assert :ok = SSO.reconcile_pending_authorizations()

      assert synced_access_audit_count(account.id, membership.user_id) ==
               audit_count_before + 1
    end

    test "a provider change converges healthy members while a failed member remains fail-closed",
         %{
           provider: provider,
           subject: subject,
           account: account
         } do
      %{identity: healthy_identity} = provision(provider, "okta|healthy")

      %{identity: blocked_identity, membership: blocked_membership} =
        provision(provider, "okta|blocked")

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-runner",
            runner_access_mode: :restricted,
            runner_scope_runner_ids: [runner.id]
          },
          subject
        )

      assert {:ok, _group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-runner",
                 member_external_ids: ["okta|blocked"]
               })

      deleted_runner =
        runner
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

      assert {:ok, _provider} =
               SSO.update_provider(
                 provider,
                 %{
                   default_runner_access_mode: :restricted,
                   default_runner_scope_groups: ["baseline"],
                   default_runner_scope_runner_ids: []
                 },
                 subject
               )

      healthy_membership =
        Fixtures.Memberships.fetch_membership(account.id, healthy_identity.user_id)

      assert is_nil(healthy_membership.directory_authorization_pending_version)

      assert access_of(account.id, healthy_identity.user_id) ==
               %Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: ["baseline"],
                 runner_ids: []
               }

      blocked = Repo.reload!(blocked_membership)
      assert is_integer(blocked.directory_authorization_pending_version)
      assert access_of(account.id, blocked_identity.user_id) == Accounts.RunnerAccess.none()

      deleted_runner
      |> Ecto.Changeset.change(deleted_at: nil)
      |> Repo.update!()

      assert :ok = SSO.reconcile_pending_authorizations()
      assert is_nil(Repo.reload!(blocked_membership).directory_authorization_pending_version)

      assert access_of(account.id, blocked_identity.user_id) ==
               %Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: ["baseline"],
                 runner_ids: [runner.id]
               }
    end
  end

  # -- Sync: the escalation + lockout guards ---------------------------

  describe "sync_set_membership_role guards" do
    setup do
      scim_provider()
    end

    test "sync_set_membership_role refuses :owner", %{provider: provider, account: account} do
      %{membership: membership} = provision(provider, "okta|noowner")

      assert {:error, :owner_not_assignable} =
               Accounts.sync_set_membership_role(membership, :owner, provider)

      # The membership keeps its provisioned role — no escalation slipped through.
      assert role_of(account.id, membership.user_id) == :viewer
    end

    test "group recompute never re-roles a human owner (#3 — owners out of sync scope)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity, membership: membership} = provision(provider, "okta|ownerskip")

      # Make the provisioned member an account owner (a deliberate human grant).
      Fixtures.Memberships.force_role(membership, "owner")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|ownerskip"]
        })

      # A mapped :admin group would otherwise demote owner→admin, but sync never
      # re-roles an owner — recompute leaves them untouched.
      assert role_of(account.id, membership.user_id) == :owner

      assert {:ok, %Accounts.Membership{role: :owner}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))
    end

    test "recompute_role_for_identity resets an elevated member in no mapped group to default_role",
         %{provider: provider, subject: subject, account: account} do
      %{identity: identity} = provision(provider, "okta|demote")

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|demote"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Drop the only mapping → the identity belongs to no mapped group. The
      # direct recompute entry point demotes them to the provider default_role
      # (:viewer) — least-privilege on directory removal (#3), never a stale
      # elevated role.
      {:ok, [mapping], _meta} = SSO.list_group_mappings(provider, subject)
      {:ok, _} = SSO.delete_group_mapping(mapping, subject)

      assert {:ok, %Accounts.Membership{role: :viewer}} =
               SSO.recompute_role_for_identity(provider, Repo.reload!(identity))

      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "sync_set_membership_role won't demote the last active owner (defense in depth)", %{
      provider: provider,
      account: account
    } do
      %{membership: membership} = provision(provider, "okta|lastowner")

      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: membership.user_id)

      # The direct sync path still guards the last owner (§9 N5).
      assert {:error, :last_owner} =
               Accounts.sync_set_membership_role(Repo.reload!(membership), :admin, provider)

      assert role_of(account.id, membership.user_id) == :owner
    end
  end

  describe "directory-sync writes are scoped to the provider's account" do
    setup do
      scim_provider()
    end

    # A provider's account IS the authorization on the no-Subject sync path, so a
    # membership in another account must never be writable through it — even if a
    # caller resolved it some other way. Today's callers always pass
    # provider-scoped memberships; this pins the write-path backstop.
    test "sync_suspend_membership rejects a membership outside the provider's account", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership()

      assert {:error, :not_found} = Accounts.sync_suspend_membership(other, provider)
      assert is_nil(Repo.reload!(other).disabled_at)
    end

    test "sync_reinstate_membership rejects a membership outside the provider's account", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership()

      assert {:error, :not_found} = Accounts.sync_reinstate_membership(other, provider)
    end

    test "sync_set_membership_role rejects a membership outside the provider's account", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert {:error, :not_found} = Accounts.sync_set_membership_role(other, :admin, provider)
      assert Repo.reload!(other).role == :operator
    end
  end

  # -- Sync: the map-after-first-sync picker source --------------------

  describe "list_synced_groups/2 — synced groups with member counts" do
    setup do
      scim_provider()
    end

    test "returns each distinct external group seen via SCIM with its member count", %{
      provider: provider,
      subject: subject
    } do
      %{identity: _} = provision(provider, "okta|u1")
      %{identity: _} = provision(provider, "okta|u2")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_external_ids: ["okta|u1", "okta|u2"]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          display: "Admins",
          member_external_ids: ["okta|u2"]
        })

      # Ordered by external group id; the count is distinct members per group.
      assert {:ok, groups} = SSO.list_synced_groups(provider, subject)

      assert groups == [
               %{external_group_id: "grp-adm", member_count: 1},
               %{external_group_id: "grp-ops", member_count: 2}
             ]
    end

    test "denies a non-Enterprise plan (:directory_sync_not_available)" do
      {_u, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account, %{})

      assert {:error, :directory_sync_not_available} = SSO.list_synced_groups(provider, subject)
    end

    test "is account-scoped — another account's enterprise owner can't read it", %{
      provider: provider
    } do
      {_u, _account_b, subject_b} = enterprise_owner()

      assert {:error, :not_found} = SSO.list_synced_groups(provider, subject_b)
    end
  end

  # -- Config: list + pagination ---------------------------------------

  describe "list_group_mappings/3 keyset pagination" do
    test "a multi-page walk returns every mapping once, ordered by external_group_id" do
      %{provider: provider, subject: subject} = scim_provider()

      for n <- 1..6 do
        {:ok, _} =
          SSO.create_group_mapping(
            provider,
            %{external_group_id: "grp-#{n}", role: :admin},
            subject
          )
      end

      {:ok, all, _} = SSO.list_group_mappings(provider, subject)
      assert Enum.map(all, & &1.external_group_id) == ~w[grp-1 grp-2 grp-3 grp-4 grp-5 grp-6]
      reference_order = Enum.map(all, & &1.id)

      # A cursor that disagreed with the ORDER BY (display vs external_group_id)
      # would skip or duplicate rows across pages.
      walked = walk_pages(&SSO.list_group_mappings(provider, subject, &1), 2)
      assert Enum.map(walked, & &1.id) == reference_order
    end
  end

  # -- Config: the :owner guard ----------------------------------------

  describe "group→role mapping config — :owner is never assignable" do
    test "a group→role mapping to :owner is rejected at config time" do
      %{provider: provider, subject: subject} = scim_provider()

      assert {:error, %Ecto.Changeset{} = changeset} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-owner", role: :owner},
                 subject
               )

      assert "directory sync cannot grant owner" in errors_on(changeset).role

      # And an existing non-owner mapping can't be edited up to :owner either.
      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-admins", role: :admin},
          subject
        )

      assert {:error, %Ecto.Changeset{} = changeset} =
               SSO.update_group_mapping(mapping, %{role: :owner}, subject)

      assert "directory sync cannot grant owner" in errors_on(changeset).role
    end
  end

  describe "group→role mapping changes reconcile existing members" do
    setup do
      scim_provider()
    end

    test "create, update, and delete immediately apply the group's current role", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|existing-group-member")

      assert {:ok, %{member_count: 1}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-existing",
                 member_external_ids: ["okta|existing-group-member"]
               })

      assert role_of(account.id, identity.user_id) == :viewer

      assert {:ok, mapping} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-existing", role: :admin},
                 subject
               )

      assert role_of(account.id, identity.user_id) == :admin

      assert {:ok, _mapping} = SSO.update_group_mapping(mapping, %{role: :operator}, subject)
      assert role_of(account.id, identity.user_id) == :operator

      assert {:ok, _mapping} = SSO.delete_group_mapping(mapping, subject)
      assert role_of(account.id, identity.user_id) == :viewer
    end
  end

  # -- Config: required + uniqueness -----------------------------------

  describe "group→role mapping config — required fields + uniqueness" do
    setup do
      scim_provider()
    end

    test "a create missing external_group_id or role is rejected", %{
      provider: provider,
      subject: subject
    } do
      assert {:error, changeset} =
               SSO.create_group_mapping(provider, %{role: :admin}, subject)

      assert "can't be blank" in errors_on(changeset).external_group_id

      assert {:error, changeset} =
               SSO.create_group_mapping(provider, %{external_group_id: "grp-x"}, subject)

      assert "can't be blank" in errors_on(changeset).role
    end

    test "a duplicate (provider, external_group_id) hits the unique index", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, _} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "00g-dupe", role: :admin},
                 subject
               )

      assert {:error, changeset} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "00g-dupe", role: :operator},
                 subject
               )

      # The unique index on (provider_id, external_group_id) maps the violation
      # onto the first constraint field, :provider_id.
      assert "has already been taken" in errors_on(changeset).provider_id
    end

    test "overlong group mapping identifiers are rejected before the database", %{
      provider: provider,
      subject: subject
    } do
      overlong = overlong_scim_id()

      assert {:error, changeset} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: overlong, role: :admin},
                 subject
               )

      assert "should be at most 255 character(s)" in errors_on(changeset).external_group_id

      assert {:ok, mapping} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-valid", role: :admin},
                 subject
               )

      assert {:error, changeset} =
               SSO.update_group_mapping(
                 mapping,
                 %{external_group_display: overlong},
                 subject
               )

      assert "should be at most 255 character(s)" in errors_on(changeset).external_group_display
    end
  end

  # -- Config: gating + cross-account ----------------------------------

  describe "group→role mapping config — enterprise + manage_sso gated" do
    test "create/list/update/delete group mappings is enterprise+manage_sso gated (denial + cross-account)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()

      # Happy path: an enterprise owner can CRUD the mappings.
      assert {:ok, mapping} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-1", external_group_display: "Admins", role: :admin},
                 subject
               )

      assert {:ok, [listed], _meta} = SSO.list_group_mappings(provider, subject)
      assert listed.id == mapping.id

      assert {:ok, updated} = SSO.update_group_mapping(mapping, %{role: :operator}, subject)
      assert updated.role == :operator

      assert {:ok, deleted} = SSO.delete_group_mapping(mapping, subject)
      assert deleted.deleted_at

      # Denial: a viewer (no manage_sso) on the same enterprise account.
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: :viewer
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-2", role: :admin},
                 viewer_subject
               )

      assert {:error, :unauthorized} = SSO.list_group_mappings(provider, viewer_subject)

      # Denial: a Team plan can configure OIDC but not SCIM group mappings.
      {_u, _team_account, team_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      assert {:error, :directory_sync_not_available} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-3", role: :admin},
                 team_subject
               )

      # Cross-account: account B's enterprise owner cannot touch account A's
      # provider's mappings (create can't find the provider; list scopes empty).
      {_ub, _account_b, subject_b} = enterprise_owner()

      assert {:error, :not_found} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-4", role: :admin},
                 subject_b
               )

      {:ok, mapping_a} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-5", role: :admin}, subject)

      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, subject_b)
      # And B can't update/delete A's mapping (row-scoped to B's account).
      assert {:error, :not_found} =
               SSO.update_group_mapping(mapping_a, %{role: :viewer}, subject_b)

      assert {:error, :not_found} = SSO.delete_group_mapping(mapping_a, subject_b)
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp demote_other_owners(account_id, except: keep_user_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_role(:owner)
    |> Repo.all()
    |> Enum.reject(&(&1.user_id == keep_user_id))
    |> Enum.each(&Fixtures.Memberships.force_role(&1, "admin"))
  end
end
