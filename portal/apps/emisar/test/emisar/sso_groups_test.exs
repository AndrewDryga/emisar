defmodule Emisar.SSOGroupsTest do
  @moduledoc """
  IdP groups → emisar role and runner-access mapping. Role is the highest mapped
  role; runner access is the additive union of the provider baseline and every
  mapped group, with `all` dominance. Both are recomputed from one directory
  snapshot and never grant owner.
  """
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Accounts, Auth, Repo, SSO}
  alias Emisar.Fixtures
  alias Emisar.SSO.{DirectoryGroup, SCIMUserUpdate}

  @scim_string_limit 255
  @max_group_member_ids 5_000

  defp enterprise_owner do
    Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
  end

  defp provider_fixture(account, attrs) do
    Fixtures.SSO.create_identity_provider(
      Map.merge(
        %{
          account_id: account.id,
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
    )
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

  defp too_many_member_ids,
    do: for(_n <- 1..(@max_group_member_ids + 1), do: Ecto.UUID.generate())

  defp group_id(provider, external_group_id) do
    DirectoryGroup.Query.not_deleted()
    |> DirectoryGroup.Query.by_provider_id(provider.id)
    |> DirectoryGroup.Query.by_external_group_id(external_group_id)
    |> Repo.fetch!(DirectoryGroup.Query)
    |> Map.fetch!(:id)
  end

  # The RFC 7644 PatchOp an IdP actually sends for a membership delta — what
  # `scim_patch_group/3` reduces. Written here rather than assumed, so these
  # tests drive the same entry point the SCIM Groups endpoint does.
  defp member_ops(add, remove) do
    Enum.concat(
      if(add == [], do: [], else: [members_op("add", add)]),
      if(remove == [], do: [], else: [members_op("remove", remove)])
    )
  end

  defp members_op(verb, ids),
    do: %{"op" => verb, "path" => "members", "value" => Enum.map(ids, &%{"value" => &1})}

  # -- Sync: role from groups ------------------------------------------

  # A synced group used to BE its member rows, so one with nobody in it had no row
  # anywhere: absent from GET /Groups, unmatched by a displayName filter, and its
  # name stored nowhere. The IdP flow that hits it is ordinary — create the group
  # empty, then PATCH members in — and each PATCH-added row carried no display, so
  # the group resurfaced nameless and the IdP re-pushed it forever.
  #
  # `sso_directory_groups` made the group its own row. These pin the three things
  # that were broken, in the order an IdP does them.
  describe "an empty synced group" do
    setup do
      scim_provider()
    end

    test "is listed, is found by a displayName filter, and keeps its name when members arrive",
         %{provider: provider, account: account} do
      assert {:ok, %{external_group_id: "grp-empty"}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-empty",
                 display: "Platform Engineers",
                 member_ids: []
               })

      assert {:ok, [%{external_group_id: "grp-empty", display: "Platform Engineers"}], 1} =
               SSO.scim_list_groups(provider)

      # Entra probes with this filter before every push; an unmatched probe is
      # what made it re-create a group it had already synced.
      assert {:ok, [%{external_group_id: "grp-empty"}], 1} =
               SSO.scim_list_groups(provider, display_name: "Platform Engineers")

      # A member op carries no displayName, so the group's name has to survive
      # from its own row rather than being re-derived from the arriving members.
      %{identity: identity} = provision(provider, "okta|joins-later")

      assert {:ok, _group} =
               SSO.scim_patch_group(
                 provider,
                 group_id(provider, "grp-empty"),
                 member_ops([identity.id], [])
               )

      assert {:ok, [%{display: "Platform Engineers", member_ids: members}], 1} =
               SSO.scim_list_groups(provider)

      assert members == [identity.id]
      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "keeps its name after its last member leaves", %{provider: provider} do
      %{identity: identity} = provision(provider, "okta|leaver")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-emptied",
          display: "Release Managers",
          member_ids: [identity.id]
        })

      assert {:ok, _group} =
               SSO.scim_patch_group(
                 provider,
                 group_id(provider, "grp-emptied"),
                 member_ops([], [identity.id])
               )

      assert {:ok, [%{display: "Release Managers", member_ids: []}], 1} =
               SSO.scim_list_groups(provider)
    end
  end

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
        create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{member_ids: [member_id]}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-ops",
                 display: "Operators",
                 member_ids: [identity.id]
               })

      assert member_id == identity.id
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
        create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      assert {:ok, %{member_ids: member_ids}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-ops",
                 display: "Operators",
                 member_ids: [id1.id, id2.id]
               })

      assert Enum.sort(member_ids) == Enum.sort([id1.id, id2.id])
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
        create_group_mapping(
          provider,
          %{external_group_id: "grp-view", role: :viewer},
          subject
        )

      {:ok, _} =
        create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        create_group_mapping(
          provider,
          %{external_group_id: "grp-op", role: :operator},
          subject
        )

      # In all three groups → highest mapped role is :admin.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-view",
          member_ids: [identity.id]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-op",
          member_ids: [identity.id]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Drop the admin group → falls back to the next-highest (:operator).
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-adm", member_ids: []})

      assert role_of(account.id, identity.user_id) == :operator
    end

    test "removing a member from their only mapped group resets them to the provider default_role (#3)",
         %{provider: provider, subject: subject, account: account} do
      %{identity: identity} = provision(provider, "okta|patch")

      {:ok, _} =
        create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Patch the member OUT of their only mapped group. With no mapped group
      # left, sync demotes them to the provider's default_role (least-privilege
      # on directory removal — provider default is :viewer).
      assert {:ok, _group} =
               SSO.scim_patch_group(
                 provider,
                 group_id(provider, "grp-adm"),
                 member_ops([], [identity.id])
               )

      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "an unknown member resource id in a group is ignored (not yet provisioned)", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|known")

      {:ok, _} =
        create_group_mapping(provider, %{external_group_id: "grp-mix", role: :admin}, subject)

      # The group lists a known + an unprovisioned member id; only the known
      # one is tracked + recomputed.
      assert {:ok, %{member_ids: [member_id]}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-mix",
                 member_ids: [identity.id, Ecto.UUID.generate()]
               })

      assert member_id == identity.id
      assert role_of(account.id, identity.user_id) == :admin
    end

    test "rejects overlong group and member identifiers before syncing", %{provider: provider} do
      overlong = overlong_scim_id()

      assert SSO.scim_upsert_group(provider, %{
               external_id: overlong,
               member_ids: []
             }) == {:error, :invalid_scim_group}

      assert SSO.scim_upsert_group(provider, %{
               external_id: "grp-valid",
               display: overlong,
               member_ids: []
             }) == {:error, :invalid_scim_group}

      assert SSO.scim_upsert_group(provider, %{
               external_id: "grp-valid",
               member_ids: [overlong]
             }) == {:error, :invalid_scim_group}

      {:ok, group} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-valid", member_ids: []})

      assert SSO.scim_patch_group(provider, group.id, member_ops([overlong], [])) ==
               {:error, :invalid_scim_group}
    end

    test "rejects oversized group member batches before querying", %{provider: provider} do
      too_many = too_many_member_ids()

      assert SSO.scim_upsert_group(provider, %{
               external_id: "grp-too-large",
               member_ids: too_many
             }) == {:error, :invalid_scim_group}

      {:ok, group} =
        SSO.scim_upsert_group(provider, %{external_id: "grp-too-large", member_ids: []})

      assert SSO.scim_patch_group(provider, group.id, member_ops(too_many, [])) ==
               {:error, :invalid_scim_group}
    end

    @tag capture_log: true
    test "a refused/failed per-member recompute is logged, not fatal — the push still succeeds",
         %{provider: provider, subject: subject, account: account} do
      %{identity: kept_identity} = provision(provider, "okta|kept")
      %{identity: gone_identity, membership: gone_membership} = provision(provider, "okta|gone")

      {:ok, _} =
        create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      # An operator removed one member from the team (membership soft-deleted)
      # while their identity lived on — so the recompute will find no membership
      # for that identity and refuse with :not_found.
      Fixtures.Memberships.mark_membership_as_deleted(gone_membership)

      refute Accounts.peek_sync_membership(account.id, gone_identity.user_id)

      # The push lands both members into the mapped group. The recompute for the
      # provisioned member succeeds; the one for the membership-less identity is
      # refused — that refusal is logged (#5), never surfaced as a failure.
      assert {:ok, %{member_ids: member_ids}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-adm",
                 member_ids: [kept_identity.id, gone_identity.id]
               })

      assert Enum.sort(member_ids) == Enum.sort([kept_identity.id, gone_identity.id])
      # The healthy member's role was still recomputed — the failed one didn't
      # abort the batch.
      assert role_of(account.id, kept_identity.user_id) == :admin
    end
  end

  describe "group writes after directory sync is turned off" do
    test "a request that authenticated before the disable cannot still mutate" do
      # The bearer resolves the provider once, at the start of the request. Sync
      # can be turned off while that request is in flight, and the write then
      # re-stamped the epoch, recreated rows the disable had discarded, and
      # reapplied roles from a directory the account had stopped trusting.
      %{provider: provider, subject: subject} = scim_provider()
      in_flight = provider
      {:ok, group} = SSO.scim_upsert_group(provider, %{external_id: "grp-late", member_ids: []})

      assert {:ok, _} = SSO.disable_scim(provider, subject)

      assert SSO.scim_upsert_group(in_flight, %{
               external_id: "grp-late",
               member_ids: []
             }) == {:error, :directory_sync_disabled}

      assert SSO.scim_rename_group(in_flight, group.id, "Too Late") ==
               {:error, :directory_sync_disabled}

      assert SSO.scim_patch_group(
               in_flight,
               group.id,
               member_ops([], [Ecto.UUID.generate()])
             ) == {:error, :not_found}
    end
  end

  describe "scim_delete_group/2" do
    setup do
      scim_provider()
    end

    test "retires the group and revokes what it granted", %{provider: provider, subject: subject} do
      {:ok, _} =
        create_group_mapping(
          provider,
          %{external_group_id: "grp-gone", role: :admin},
          subject
        )

      %{identity: identity} = provision(provider, "okta|member")

      {:ok, group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-gone",
          member_ids: [identity.id]
        })

      assert role_of(provider.account_id, identity.user_id) == :admin

      assert {:ok, _} = SSO.scim_delete_group(provider, group.id)

      # Gone means gone — deleting used to empty the members and leave the row,
      # so the very next GET still answered 200.
      assert SSO.scim_fetch_group(provider, group.id) == {:error, :not_found}
      assert role_of(provider.account_id, identity.user_id) == :viewer
    end

    test "a group this directory never pushed is not found", %{provider: provider} do
      # Answering 204 for an unknown id used to CREATE it.
      missing_id = Ecto.UUID.generate()
      assert SSO.scim_delete_group(provider, missing_id) == {:error, :not_found}
      assert SSO.scim_fetch_group(provider, missing_id) == {:error, :not_found}
    end

    test "one provider cannot delete another provider's group resource", %{
      provider: provider_a
    } do
      %{provider: provider_b} = scim_provider()
      {:ok, group_b} = SSO.scim_upsert_group(provider_b, %{external_id: "grp-b", member_ids: []})

      assert SSO.scim_delete_group(provider_a, group_b.id) == {:error, :not_found}
      assert {:ok, unchanged} = SSO.scim_fetch_group(provider_b, group_b.id)
      assert unchanged.external_group_id == "grp-b"
    end
  end

  describe "end_account_sessions_for_user/2" do
    test "ends the sessions this account minted, and only those" do
      %{provider: provider, account: account} = scim_provider()
      %{identity: identity} = provision(provider, "okta|sessions")
      {:ok, user} = Emisar.Users.fetch_user_by_id(identity.user_id)

      mine =
        Fixtures.Auth.create_session_token!(user, :sso, nil, %{}, user_identity_id: identity.id)

      other_account = Fixtures.Accounts.create_account()
      other_provider = Fixtures.SSO.create_identity_provider(account_id: other_account.id)

      other_identity =
        Fixtures.SSO.create_user_identity(
          account_id: other_account.id,
          provider_id: other_provider.id,
          user_id: user.id
        )

      theirs =
        Fixtures.Auth.create_session_token!(user, :sso, nil, %{},
          user_identity_id: other_identity.id
        )

      assert SSO.end_account_sessions_for_user(user.id, account.id) == :ok

      assert Auth.fetch_user_and_token_by_session_token(mine) == {:error, :not_found}
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(theirs)
    end

    test "a user with no identity in the account is a no-op" do
      %{account: account} = scim_provider()
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert SSO.end_account_sessions_for_user(user.id, account.id) == :ok
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "externalId-less group authorization" do
    setup do
      scim_provider()
    end

    test "the exact resource grants role and runner access; rename keeps it, delete/recreate does not",
         %{provider: provider, subject: subject, account: account} do
      %{identity: selected} = provision(provider, "okta|selected")
      %{identity: same_name} = provision(provider, "okta|same-name")

      assert {:ok, selected_group} =
               SSO.scim_upsert_group(provider, %{
                 display: "Certification Admins",
                 member_ids: [selected.id]
               })

      assert is_nil(selected_group.external_group_id)

      assert {:ok, same_name_group} =
               SSO.scim_upsert_group(provider, %{
                 display: "Certification Admins",
                 member_ids: [same_name.id]
               })

      refute same_name_group.id == selected_group.id

      assert {:ok, role_mapping} =
               SSO.create_group_mapping(
                 provider,
                 %{directory_group_id: selected_group.id, role: :admin},
                 subject
               )

      assert {:ok, access_mapping} =
               SSO.create_group_runner_access_mapping(
                 provider,
                 %{directory_group_id: selected_group.id, runner_access_mode: :all},
                 subject
               )

      assert role_mapping.directory_group_id == selected_group.id
      assert access_mapping.directory_group_id == selected_group.id
      assert role_of(account.id, selected.user_id) == :admin
      assert access_of(account.id, selected.user_id) == Accounts.RunnerAccess.all()
      assert role_of(account.id, same_name.user_id) == :viewer
      assert access_of(account.id, same_name.user_id) == Accounts.RunnerAccess.none()

      assert {:ok, renamed} =
               SSO.scim_rename_group(provider, selected_group.id, "Renamed Admins")

      assert renamed.id == selected_group.id
      assert role_of(account.id, selected.user_id) == :admin
      assert access_of(account.id, selected.user_id) == Accounts.RunnerAccess.all()

      assert {:ok, _deleted_group} = SSO.scim_delete_group(provider, selected_group.id)
      assert role_of(account.id, selected.user_id) == :viewer
      assert access_of(account.id, selected.user_id) == Accounts.RunnerAccess.none()

      assert {:ok, recreated} =
               SSO.scim_upsert_group(provider, %{
                 display: "Renamed Admins",
                 member_ids: [selected.id]
               })

      refute recreated.id == selected_group.id
      assert role_of(account.id, selected.user_id) == :viewer
      assert access_of(account.id, selected.user_id) == Accounts.RunnerAccess.none()

      # Dormant mappings remain operator-owned config and can still be removed
      # after the directory resource has gone away.
      assert {:ok, _deleted} = SSO.delete_group_mapping(role_mapping, subject)

      assert {:ok, _deleted} =
               SSO.delete_group_runner_access_mapping(access_mapping, subject)
    end

    test "foreign-provider resource ids are not found and the database rejects a forged tenant tuple",
         %{provider: provider, subject: subject, account: account} do
      %{provider: other_provider} = scim_provider()
      assert {:ok, foreign_group} = SSO.scim_upsert_group(other_provider, %{display: "Foreign"})

      assert SSO.create_group_mapping(
               provider,
               %{directory_group_id: foreign_group.id, role: :admin},
               subject
             ) == {:error, :not_found}

      group = Repo.get!(DirectoryGroup, foreign_group.id)

      changeset =
        Emisar.SSO.GroupRoleMapping.Changeset.create(
          account.id,
          provider.id,
          group,
          %{role: :admin}
        )

      assert {:error, rejected} = Repo.insert(changeset)
      assert "does not exist" in errors_on(rejected).directory_group_id
    end
  end

  describe "reconcile_pending_authorizations/1" do
    setup do
      context = scim_provider()

      # A grant may only name runner groups the account actually has, so the
      # groups these mappings hand out have to exist before they are granted.
      for group <- ["db", "app", "baseline"] do
        Fixtures.Runners.create_runner(account_id: context.account.id, group: group)
      end

      context
    end

    test "unions mapped groups and revokes access on group removal and mapping deletion", %{
      provider: provider,
      subject: subject,
      account: account
    } do
      %{identity: identity} = provision(provider, "okta|runner-union")
      assert access_of(account.id, identity.user_id) == Accounts.RunnerAccess.none()

      {:ok, db_mapping} =
        create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      {:ok, app_mapping} =
        create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-app",
            runner_access_mode: :restricted,
            scope: ["group:app"]
          },
          subject
        )

      for group_id <- ["grp-db", "grp-app"] do
        {:ok, _group} =
          SSO.scim_upsert_group(provider, %{
            external_id: group_id,
            member_ids: [identity.id]
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
          member_ids: []
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
        create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      {:ok, all_mapping} =
        create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-all", runner_access_mode: :all},
          subject
        )

      for group_id <- ["grp-db", "grp-all"] do
        {:ok, _group} =
          SSO.scim_upsert_group(provider, %{
            external_id: group_id,
            member_ids: [identity.id]
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
        create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-db",
            runner_access_mode: :restricted,
            scope: ["group:db"]
          },
          subject
        )

      {:ok, _group} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-db",
          member_ids: [identity.id]
        })

      assert {:ok, _result} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{
                 active: false
               })

      assert {:ok, _updated} =
               SSO.update_group_runner_access_mapping(
                 mapping,
                 %{runner_access_mode: :restricted, scope: ["group:app"]},
                 subject
               )

      assert {:ok, _result} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{
                 active: true
               })

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
        create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-runner",
            runner_access_mode: :restricted,
            scope: ["runner:#{runner.id}"]
          },
          subject
        )

      assert {:ok, _group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-runner",
                 member_ids: [identity.id]
               })

      assert access_of(account.id, identity.user_id) ==
               %Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: [],
                 runner_ids: [runner.id]
               }

      stale_provider = Repo.reload!(provider)
      audit_count_before = synced_access_audit_count(account.id, membership.user_id)

      deleted_runner = Fixtures.Runners.mark_deleted(runner)

      assert {:ok, _provider} =
               SSO.update_provider(
                 provider,
                 %{
                   default_runner_access_mode: :restricted,
                   default_runner_scope: ["group:baseline"]
                 },
                 subject
               )

      pending = Repo.reload!(membership)
      assert is_integer(pending.directory_authorization_pending_version)
      assert access_of(account.id, identity.user_id) == Accounts.RunnerAccess.none()

      assert Accounts.sync_set_membership_authorization(
               pending,
               :viewer,
               Accounts.RunnerAccess.none(),
               stale_provider
             ) == {:error, :stale_authorization_version}

      assert Repo.reload!(membership).directory_authorization_pending_version ==
               pending.directory_authorization_pending_version

      deleted_runner
      |> Ecto.Changeset.change(deleted_at: nil)
      |> Repo.update!()

      assert SSO.reconcile_pending_authorizations() == :ok

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

      assert SSO.reconcile_pending_authorizations() == :ok

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
        create_group_runner_access_mapping(
          provider,
          %{
            external_group_id: "grp-runner",
            runner_access_mode: :restricted,
            scope: ["runner:#{runner.id}"]
          },
          subject
        )

      assert {:ok, _group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-runner",
                 member_ids: [blocked_identity.id]
               })

      deleted_runner = Fixtures.Runners.mark_deleted(runner)

      assert {:ok, _provider} =
               SSO.update_provider(
                 provider,
                 %{
                   default_runner_access_mode: :restricted,
                   default_runner_scope: ["group:baseline"]
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

      assert SSO.reconcile_pending_authorizations() == :ok
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

  describe "sync_set_membership_authorization/4 guards" do
    setup do
      scim_provider()
    end

    test "the synced write refuses :owner", %{provider: provider, account: account} do
      %{membership: membership} = provision(provider, "okta|noowner")

      assert Accounts.sync_set_membership_authorization(
               membership,
               :owner,
               Accounts.RunnerAccess.all(),
               provider
             ) == {:error, :owner_not_assignable}

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
        create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
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
        create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_ids: [identity.id]
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
  end

  describe "directory-sync writes are scoped to the provider's account" do
    setup do
      scim_provider()
    end

    # A provider's account IS the authorization on the no-Subject sync path, so a
    # membership in another account must never be writable through it — even if a
    # caller resolved it some other way. Today's callers always pass
    # provider-scoped memberships; this pins the write-path backstop.
    test "a composed suspend rejects a membership outside the provider's account", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership()

      assert {:error, :not_found} =
               Multi.new()
               |> Accounts.put_sync_membership_lifecycle(other, provider, :suspend)
               |> Repo.commit_multi()

      assert is_nil(Repo.reload!(other).disabled_at)
    end

    test "a composed reinstate rejects a membership outside the provider's account", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership()

      assert {:error, :not_found} =
               Multi.new()
               |> Accounts.put_sync_membership_lifecycle(other, provider, :reinstate)
               |> Repo.commit_multi()
    end

    test "a synced authorization write rejects a membership outside the provider's account", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert Accounts.sync_set_membership_authorization(
               other,
               :admin,
               Accounts.RunnerAccess.all(),
               provider
             ) == {:error, :not_found}

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
      %{identity: id1} = provision(provider, "okta|u1")
      %{identity: id2} = provision(provider, "okta|u2")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          display: "Ops",
          member_ids: [id1.id, id2.id]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          display: "Admins",
          member_ids: [id2.id]
        })

      {:ok, role_mapping} =
        create_group_mapping(
          provider,
          %{external_group_id: "grp-adm", role: :admin},
          subject
        )

      {:ok, access_mapping} =
        create_group_runner_access_mapping(
          provider,
          %{external_group_id: "grp-ops", runner_access_mode: :all},
          subject
        )

      # Ordered by external group id; the count is distinct members per group.
      assert {:ok, groups} = SSO.list_synced_groups(provider, subject)

      assert [admin_group, ops_group] = groups
      assert admin_group.external_group_id == "grp-adm"
      assert admin_group.member_count == 1
      assert admin_group.mapping.id == role_mapping.id
      assert is_nil(admin_group.runner_access_mapping)
      assert ops_group.external_group_id == "grp-ops"
      assert ops_group.member_count == 2
      assert is_nil(ops_group.mapping)
      assert ops_group.runner_access_mapping.id == access_mapping.id
    end

    test "a downgraded plan still reads its synced groups" do
      {_u, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = provider_fixture(account, %{})

      assert SSO.list_synced_groups(provider, subject) == {:ok, []}
    end

    test "is account-scoped — another account's enterprise owner can't read it", %{
      provider: provider
    } do
      {_u, _account_b, subject_b} = enterprise_owner()

      assert SSO.list_synced_groups(provider, subject_b) == {:error, :not_found}
    end
  end

  # -- Config: list + pagination ---------------------------------------

  describe "list_group_mappings/3 keyset pagination" do
    test "a multi-page walk returns every immutable group mapping once" do
      %{provider: provider, subject: subject} = scim_provider()

      for n <- 1..6 do
        {:ok, _} =
          create_group_mapping(
            provider,
            %{external_group_id: "grp-#{n}", role: :admin},
            subject
          )
      end

      {:ok, all, _} = SSO.list_group_mappings(provider, subject)
      directory_group_ids = Enum.map(all, & &1.directory_group_id)
      assert directory_group_ids == Enum.sort(directory_group_ids)
      reference_order = Enum.map(all, & &1.id)

      # A cursor that disagreed with the UUID ORDER BY would skip or duplicate
      # rows across pages.
      walked = walk_pages(&SSO.list_group_mappings(provider, subject, &1), 2)
      assert Enum.map(walked, & &1.id) == reference_order
    end
  end

  # -- Config: the :owner guard ----------------------------------------

  describe "group→role mapping config — :owner is never assignable" do
    test "a group→role mapping to :owner is rejected at config time" do
      %{provider: provider, subject: subject} = scim_provider()

      assert {:error, %Ecto.Changeset{} = changeset} =
               create_group_mapping(
                 provider,
                 %{external_group_id: "grp-owner", role: :owner},
                 subject
               )

      assert "directory sync cannot grant owner" in errors_on(changeset).role

      # And an existing non-owner mapping can't be edited up to :owner either.
      {:ok, mapping} =
        create_group_mapping(
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

      assert {:ok, %{member_ids: [member_id]}} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "grp-existing",
                 member_ids: [identity.id]
               })

      assert member_id == identity.id
      assert role_of(account.id, identity.user_id) == :viewer

      assert {:ok, mapping} =
               create_group_mapping(
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

    test "a create missing directory_group_id or role is rejected", %{
      provider: provider,
      subject: subject
    } do
      assert {:error, changeset} =
               create_group_mapping(provider, %{role: :admin}, subject)

      assert "can't be blank" in errors_on(changeset).directory_group_id

      assert {:error, changeset} =
               create_group_mapping(provider, %{external_group_id: "grp-x"}, subject)

      assert "can't be blank" in errors_on(changeset).role
    end

    test "a duplicate (provider, directory_group_id) hits the unique index", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, _} =
               create_group_mapping(
                 provider,
                 %{external_group_id: "00g-dupe", role: :admin},
                 subject
               )

      assert {:error, changeset} =
               create_group_mapping(
                 provider,
                 %{external_group_id: "00g-dupe", role: :operator},
                 subject
               )

      # The unique index on (provider_id, directory_group_id) maps the violation
      # onto the first constraint field, :provider_id.
      assert "has already been taken" in errors_on(changeset).provider_id
    end

    test "external group attributes cannot retarget or rename a mapping", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, mapping} =
               create_group_mapping(
                 provider,
                 %{
                   external_group_id: "grp-stable",
                   external_group_display: "Stable",
                   role: :admin
                 },
                 subject
               )

      assert {:ok, updated} =
               SSO.update_group_mapping(
                 mapping,
                 %{
                   external_group_id: "grp-forged",
                   external_group_display: "Forged",
                   role: :operator
                 },
                 subject
               )

      assert updated.directory_group_id == mapping.directory_group_id
      assert updated.external_group_id == "grp-stable"
      assert updated.external_group_display == "Stable"
      assert updated.role == :operator
    end
  end

  # -- Config: gating + cross-account ----------------------------------

  describe "group→role mapping config — enterprise + manage_sso gated" do
    test "create/list/update/delete group mappings is enterprise+manage_sso gated (denial + cross-account)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()

      # Happy path: an enterprise owner can CRUD the mappings.
      assert {:ok, mapping} =
               create_group_mapping(
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

      assert create_group_mapping(
               provider,
               %{external_group_id: "grp-2", role: :admin},
               viewer_subject
             ) == {:error, :unauthorized}

      assert SSO.list_group_mappings(provider, viewer_subject) == {:error, :unauthorized}

      # Denial: a Team plan can configure OIDC but not SCIM group mappings.
      {_u, _team_account, team_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      assert create_group_mapping(
               provider,
               %{external_group_id: "grp-3", role: :admin},
               team_subject
             ) == {:error, :directory_sync_not_available}

      # Cross-account: account B's enterprise owner cannot touch account A's
      # provider's mappings (create can't find the provider; list scopes empty).
      {_ub, _account_b, subject_b} = enterprise_owner()

      assert create_group_mapping(
               provider,
               %{external_group_id: "grp-4", role: :admin},
               subject_b
             ) == {:error, :not_found}

      {:ok, mapping_a} =
        create_group_mapping(provider, %{external_group_id: "grp-5", role: :admin}, subject)

      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, subject_b)
      # And B can't update/delete A's mapping (row-scoped to B's account).
      assert SSO.update_group_mapping(mapping_a, %{role: :viewer}, subject_b) ==
               {:error, :not_found}

      assert SSO.delete_group_mapping(mapping_a, subject_b) == {:error, :not_found}
    end
  end

  # -- Helpers ---------------------------------------------------------

  # Most cases in this file predate server-owned Group ids and describe their
  # fixture group by externalId. Materialize that exact SCIM resource first,
  # then exercise the production mapping API with its immutable UUID. Denial
  # cases never get fixture-side writes before the authorization check.
  defp create_group_mapping(provider, attrs, subject) do
    with true <- subject.account.id == provider.account_id,
         true <- SSO.subject_can_configure_directory_sync?(subject),
         {:ok, group} <- mapping_group(provider, attrs) do
      attrs = put_directory_group_id(attrs, group.id)
      SSO.create_group_mapping(provider, attrs, subject)
    else
      false -> SSO.create_group_mapping(provider, attrs, subject)
      {:error, :missing_group} -> SSO.create_group_mapping(provider, attrs, subject)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_group_runner_access_mapping(provider, attrs, subject) do
    with true <- subject.account.id == provider.account_id,
         true <- SSO.subject_can_configure_directory_sync?(subject),
         {:ok, group} <- mapping_group(provider, attrs) do
      attrs = put_directory_group_id(attrs, group.id)
      SSO.create_group_runner_access_mapping(provider, attrs, subject)
    else
      false -> SSO.create_group_runner_access_mapping(provider, attrs, subject)
      {:error, :missing_group} -> SSO.create_group_runner_access_mapping(provider, attrs, subject)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mapping_group(provider, attrs) do
    directory_group_id = attrs[:directory_group_id] || attrs["directory_group_id"]
    external_group_id = attrs[:external_group_id] || attrs["external_group_id"]

    cond do
      is_binary(directory_group_id) ->
        group =
          DirectoryGroup.Query.not_deleted()
          |> DirectoryGroup.Query.by_account_id(provider.account_id)
          |> DirectoryGroup.Query.by_provider_id(provider.id)
          |> DirectoryGroup.Query.by_id(directory_group_id)
          |> Repo.peek()

        if group, do: {:ok, group}, else: {:error, :missing_group}

      is_binary(external_group_id) ->
        fetch_or_create_mapping_group(provider, external_group_id, attrs)

      true ->
        {:error, :missing_group}
    end
  end

  defp put_directory_group_id(attrs, id) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: Map.put(attrs, "directory_group_id", id),
      else: Map.put(attrs, :directory_group_id, id)
  end

  defp fetch_or_create_mapping_group(provider, external_group_id, attrs) do
    group =
      DirectoryGroup.Query.not_deleted()
      |> DirectoryGroup.Query.by_account_id(provider.account_id)
      |> DirectoryGroup.Query.by_provider_id(provider.id)
      |> DirectoryGroup.Query.by_external_group_id(external_group_id)
      |> Repo.peek()

    if group do
      {:ok, group}
    else
      SSO.scim_upsert_group(provider, %{
        external_id: external_group_id,
        display: attrs[:external_group_display] || attrs["external_group_display"],
        member_ids: []
      })
    end
  end
end
