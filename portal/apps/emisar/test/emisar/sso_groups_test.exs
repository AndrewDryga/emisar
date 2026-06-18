defmodule Emisar.SSOGroupsTest do
  @moduledoc """
  Slice 2b — IdP groups → emisar role mapping. The server-side group→role
  mapping config (enterprise + `manage_sso` gated, account-scoped) and the
  internal sync that recomputes a member's role as the HIGHEST mapped role over
  their synced groups — capped non-`:owner` (decision 7) and never demoting the
  account's last active owner (§9 N5). The internal sync functions take a
  provider explicitly and carry no `%Subject{}`.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Accounts, Repo, SSO}
  alias Emisar.SSO.IdentityProvider

  defp enterprise_owner do
    owner_subject_fixture(%{plan: "enterprise"})
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

  defp role_of(account_id, user_id), do: fetch_membership(account_id, user_id).role

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
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: :viewer)
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               SSO.create_group_mapping(
                 provider,
                 %{external_group_id: "grp-2", role: :admin},
                 viewer_subject
               )

      assert {:error, :unauthorized} = SSO.list_group_mappings(provider, viewer_subject)

      # Denial: a non-enterprise plan can't configure SSO at all.
      {_u, _team_account, team_subject} = owner_subject_fixture(%{plan: "team"})

      assert {:error, :sso_not_available} =
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

  # -- Sync: role from groups ------------------------------------------

  describe "scim_upsert_group / role recompute" do
    test "scim_upsert_group sets a member's role to the mapped role" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
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

    test "a group push recomputes the role for ALL its members (batched bulk path)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
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

    test "a member in two mapped groups gets the HIGHEST (admin > operator > viewer)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
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

    test "removing a member from their only mapped group resets them to the provider default_role (#3)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
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

    test "an unknown member external_id in a group is ignored (not yet provisioned)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
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
  end

  # -- Sync: the escalation + lockout guards ---------------------------

  describe "sync_set_membership_role guards" do
    test "sync_set_membership_role refuses :owner" do
      %{provider: provider, account: account} = scim_provider()
      %{membership: membership} = provision(provider, "okta|noowner")

      assert {:error, :owner_not_assignable} =
               Accounts.sync_set_membership_role(membership, :owner, provider)

      # The membership keeps its provisioned role — no escalation slipped through.
      assert role_of(account.id, membership.user_id) == :viewer
    end

    test "group recompute never re-roles a human owner (#3 — owners out of sync scope)" do
      %{provider: provider, subject: subject, account: account} = scim_provider()
      %{identity: identity, membership: membership} = provision(provider, "okta|ownerskip")

      # Make the provisioned member an account owner (a deliberate human grant).
      force_membership_role(membership, "owner")

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

    test "sync_set_membership_role won't demote the last active owner (defense in depth)" do
      %{provider: provider, account: account} = scim_provider()
      %{membership: membership} = provision(provider, "okta|lastowner")

      force_membership_role(membership, "owner")
      demote_other_owners(account.id, except: membership.user_id)

      # The direct sync path still guards the last owner (§9 N5).
      assert {:error, :last_owner} =
               Accounts.sync_set_membership_role(Repo.reload!(membership), :admin, provider)

      assert role_of(account.id, membership.user_id) == :owner
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp demote_other_owners(account_id, except: keep_user_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_role(:owner)
    |> Repo.all()
    |> Enum.reject(&(&1.user_id == keep_user_id))
    |> Enum.each(&force_membership_role(&1, "admin"))
  end
end
