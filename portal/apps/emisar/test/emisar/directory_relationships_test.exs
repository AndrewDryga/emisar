defmodule Emisar.DirectoryRelationshipsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Fixtures, SSO}

  describe "member_group_summaries/3" do
    test "summaries cap groups across providers, while member groups remain searchable and paginated" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      first = Fixtures.SSO.create_identity_provider(account_id: account.id)

      second =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :openid_connect)

      member = Fixtures.SSO.create_directory_member(first)

      other_identity =
        Fixtures.SSO.create_directory_member(second,
          user: member.user,
          membership: member.membership
        )

      groups =
        for n <- 1..12 do
          {provider, identity} =
            if rem(n, 2) == 0,
              do: {first, member.identity},
              else: {second, other_identity.identity}

          Fixtures.SSO.create_directory_group(provider,
            display: "Group #{String.pad_leading(to_string(n), 2, "0")}",
            identities: [identity]
          )
        end

      assert {:ok, summaries} = SSO.member_group_summaries([member.user.id], owner)
      assert summaries[member.user.id].count == 12

      assert Enum.map(summaries[member.user.id].groups, & &1.display) == [
               "Group 01",
               "Group 02",
               "Group 03"
             ]

      assert Enum.map(summaries[member.user.id].groups, & &1.id) ==
               Enum.map(Enum.take(groups, 3), & &1.id)

      assert Enum.map(summaries[member.user.id].groups, & &1.provider_id) ==
               [second.id, first.id, second.id]

      assert {:ok, scoped} =
               SSO.member_group_summaries([member.user.id], owner, provider_id: first.id)

      assert scoped[member.user.id].count == 6

      assert {:ok, page, metadata} =
               SSO.list_member_groups(member.user.id, owner, page: [limit: 10])

      assert length(page) == 10
      assert metadata.count == 12

      assert {:ok, rest, _} =
               SSO.list_member_groups(member.user.id, owner,
                 page: [limit: 10, cursor: metadata.next_page_cursor]
               )

      assert MapSet.new(Enum.map(page ++ rest, & &1.id)) == MapSet.new(Enum.map(groups, & &1.id))

      assert {:ok, [found], _} =
               SSO.list_member_groups(member.user.id, owner, filter: [search: "Group 12"])

      assert found.display == "Group 12"

      assert {:ok, [by_id], _} =
               SSO.list_member_groups(member.user.id, owner, filter: [search: found.id])

      assert by_id.id == found.id
    end

    test "directory reads and connection group filtering deny viewers and cannot cross accounts" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      viewer_member =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      viewer = Fixtures.Subjects.membership_subject(viewer_member)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.SSO.create_directory_member(provider)
      group = Fixtures.SSO.create_directory_group(provider, identities: [member.identity])
      other_account = Fixtures.Accounts.create_account()
      other = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), other_account)

      assert SSO.member_group_summaries([member.user.id], viewer) == {:error, :unauthorized}
      assert SSO.list_member_groups(member.user.id, viewer) == {:error, :unauthorized}
      assert SSO.fetch_directory_group_facts(group.id, viewer) == {:error, :unauthorized}

      assert SSO.list_synced_users(provider, viewer, directory_group_id: group.id) ==
               {:error, :unauthorized}

      assert SSO.fetch_directory_group_facts(group.id, other) == {:error, :not_found}

      assert SSO.list_synced_users(provider, other, directory_group_id: group.id) ==
               {:error, :not_found}

      assert {:ok, summaries} = SSO.member_group_summaries([member.user.id], other)
      assert summaries[member.user.id] == %{groups: [], count: 0}
      assert {:ok, [], _} = SSO.list_member_groups(member.user.id, other)
      assert SSO.fetch_directory_group_facts("invalid", owner) == {:error, :not_found}

      assert SSO.member_group_summaries(List.duplicate(member.user.id, 101), owner) ==
               {:error, :invalid_request}

      assert SSO.member_group_summaries([%{}], owner) == {:error, :invalid_request}
    end
  end

  describe "list_member_groups/3" do
    test "can scope a member's groups to one provider and rejects malformed lookup options" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.SSO.create_directory_member(provider)

      group =
        Fixtures.SSO.create_directory_group(provider,
          display: "Platform",
          identities: [member.identity]
        )

      other = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :openid_connect)

      other_member =
        Fixtures.SSO.create_directory_member(other,
          user: member.user,
          membership: member.membership
        )

      Fixtures.SSO.create_directory_group(other, identities: [other_member.identity])

      assert {:ok, [listed], metadata} =
               SSO.list_member_groups(member.user.id, subject, provider_id: provider.id)

      assert listed.id == group.id
      assert metadata.count == 1
      assert SSO.list_member_groups("invalid", subject) == {:error, :not_found}

      assert SSO.list_member_groups(member.user.id, subject, provider_id: %{}) ==
               {:error, :not_found}

      assert {:ok, [], _} = SSO.list_member_groups(Ecto.UUID.generate(), subject)
    end
  end

  describe "fetch_directory_group_facts/3" do
    test "retired groups disappear from summaries and filter choices" do
      account = Fixtures.Accounts.create_account(plan: "enterprise")
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id)
        |> Fixtures.SSO.enable_scim()

      member = Fixtures.SSO.create_directory_member(provider, scim_active: false)
      group = Fixtures.SSO.create_directory_group(provider, identities: [member.identity])
      assert {:ok, facts} = SSO.fetch_directory_group_facts(group.id, owner)
      assert facts.id == group.id
      assert facts.provider_id == provider.id
      assert facts.provider_name == provider.name
      refute Map.has_key?(facts, :client_secret)
      refute Map.has_key?(facts, :issuer)
      assert {:ok, _} = SSO.scim_delete_group(provider, group.id)
      assert SSO.fetch_directory_group_facts(group.id, owner) == {:error, :not_found}
      assert {:ok, [], _} = SSO.list_directory_groups(owner)
      assert {:ok, summaries} = SSO.member_group_summaries([member.user.id], owner)
      assert summaries[member.user.id].count == 0
    end
  end

  describe "list_directory_groups/2" do
    test "group choices are bounded, searchable and fenced to the account and selected provider" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      groups =
        for n <- 1..12, do: Fixtures.SSO.create_directory_group(provider, display: "Group #{n}")

      other_provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :openid_connect)

      other_group =
        Fixtures.SSO.create_directory_group(other_provider, display: "Another connection")

      foreign_account = Fixtures.Accounts.create_account()
      foreign_provider = Fixtures.SSO.create_identity_provider(account_id: foreign_account.id)
      Fixtures.SSO.create_directory_group(foreign_provider, display: "Foreign secret")

      assert {:ok, page, metadata} =
               SSO.list_directory_groups(owner, provider_id: provider.id, page: [limit: 10])

      assert length(page) == 10
      assert metadata.count == 12

      assert {:ok, rest, _} =
               SSO.list_directory_groups(owner,
                 provider_id: provider.id,
                 page: [limit: 10, cursor: metadata.next_page_cursor]
               )

      assert MapSet.new(Enum.map(page ++ rest, & &1.id)) == MapSet.new(Enum.map(groups, & &1.id))

      assert {:ok, [found], _} =
               SSO.list_directory_groups(owner, filter: [search: "Another connection"])

      assert found.id == other_group.id
      assert {:ok, [], _} = SSO.list_directory_groups(owner, filter: [search: "Foreign secret"])
      assert {:ok, [], _} = SSO.list_directory_groups(owner, provider_id: foreign_provider.id)
      assert SSO.list_directory_groups(owner, provider_id: %{}) == {:error, :not_found}

      assert SSO.list_directory_groups(owner, filter: [search: <<0>>]) ==
               {:error, :invalid_request}

      denied = Fixtures.Subjects.permissionless_subject(account)
      assert SSO.list_directory_groups(denied) == {:error, :unauthorized}
    end
  end

  describe "directory_group_filters/0" do
    test "exposes the group search as a string filter" do
      assert [%Emisar.Repo.Filter{name: :search, type: :string, fun: matcher}] =
               SSO.directory_group_filters()

      assert is_function(matcher, 2)
    end
  end

  describe "directory_member_filters/0" do
    test "exposes member search as a string filter" do
      assert [%Emisar.Repo.Filter{name: :search, type: :string, fun: matcher}] =
               SSO.directory_member_filters()

      assert is_function(matcher, 2)
    end
  end

  describe "list_synced_users/3 — directory group filtering" do
    test "connection member group filters use the live roster and reject other connections" do
      account = Fixtures.Accounts.create_account(plan: "enterprise")
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id)
        |> Fixtures.SSO.enable_scim()

      member =
        Fixtures.SSO.create_directory_member(provider,
          full_name: "Selected member",
          scim_active: false
        )

      Fixtures.Memberships.suspend_membership(member.membership)
      removed = Fixtures.SSO.create_directory_member(provider)
      Fixtures.Memberships.mark_membership_as_deleted(removed.membership)
      Fixtures.SSO.create_directory_member(provider, full_name: "Outside group")

      group =
        Fixtures.SSO.create_directory_group(provider,
          identities: [member.identity, removed.identity]
        )

      other_provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :openid_connect)

      other_group = Fixtures.SSO.create_directory_group(other_provider)
      opts = [directory_group_id: group.id, filter: [search: "Selected member"]]
      assert {:ok, [identity], metadata} = SSO.list_synced_users(provider, owner, opts)
      assert identity.id == member.identity.id
      assert metadata.count == 1

      assert SSO.list_synced_users(provider, owner, directory_group_id: other_group.id) ==
               {:error, :not_found}

      assert SSO.fetch_directory_group_facts(other_group.id, owner, provider_id: provider.id) ==
               {:error, :not_found}

      for invalid <- [%{}, [group.id], "bad"] do
        assert SSO.list_synced_users(provider, owner, directory_group_id: invalid) ==
                 {:error, :not_found}
      end

      foreign_account = Fixtures.Accounts.create_account()
      foreign = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), foreign_account)
      assert SSO.list_synced_users(provider, foreign, opts) == {:error, :not_found}
      denied = Fixtures.Subjects.permissionless_subject(account)
      assert SSO.list_synced_users(provider, denied, opts) == {:error, :unauthorized}
      assert {:ok, _} = SSO.scim_delete_group(provider, group.id)
      assert SSO.list_synced_users(provider, owner, opts) == {:error, :not_found}
    end

    test "connection group filters paginate the live roster, including suspended people and account-local names" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      members =
        for n <- 1..7,
            do: Fixtures.SSO.create_directory_member(provider, full_name: "Person #{n}")

      first = Enum.min_by(members, & &1.user.id)
      Fixtures.Memberships.sync_display_name(first.membership, "Directory name")
      Fixtures.Memberships.suspend_membership(first.membership)

      group =
        Fixtures.SSO.create_directory_group(provider,
          display: "Platform",
          identities: Enum.map(members, & &1.identity)
        )

      removed = Enum.max_by(members, & &1.user.id)
      Fixtures.Memberships.mark_membership_as_deleted(removed.membership)

      assert {:ok, [suspended], metadata} =
               SSO.list_synced_users(provider, owner,
                 directory_group_id: group.id,
                 filter: [search: "Directory name"]
               )

      assert suspended.id == first.identity.id
      assert metadata.count == 1

      assert {:ok, page, metadata} =
               SSO.list_synced_users(provider, owner,
                 directory_group_id: group.id,
                 page: [limit: 4]
               )

      assert {:ok, rest, _} =
               SSO.list_synced_users(provider, owner,
                 directory_group_id: group.id,
                 page: [limit: 4, cursor: metadata.next_page_cursor]
               )

      assert length(Enum.uniq_by(page ++ rest, & &1.id)) == 6
      refute Enum.any?(page ++ rest, &(&1.user_id == removed.user.id))
    end

    test "directory member search stops exposing global profile names after membership removal" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.SSO.create_directory_member(provider, full_name: "Private profile name")
      Fixtures.Memberships.sync_display_name(member.membership, "Workspace name")

      assert {:ok, [named], _} =
               SSO.list_synced_users(provider, owner, filter: [search: "Workspace name"])

      assert named.user_id == member.user.id
      Fixtures.Memberships.mark_membership_as_deleted(member.membership)

      assert {:ok, [], _} =
               SSO.list_synced_users(provider, owner, filter: [search: "Private profile name"])

      assert {:ok, [], _} =
               SSO.list_synced_users(provider, owner, filter: [search: "Workspace name"])

      assert {:ok, [retained], _} =
               SSO.list_synced_users(provider, owner, filter: [search: member.user.email])

      assert retained.user_id == member.user.id
    end
  end
end
